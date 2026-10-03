//// Instruments for durable-run tests: fresh temporary directories, owner
//// processes whose death takes down every Fabric process they started, and
//// access to a run's live runner.

import fabric/internal/store as store_core
import fabric/run.{type RunId}
import fabric/store.{type Store}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/otp/supervision

@external(erlang, "fabric_test_ffi", "temp_dir")
pub fn temp_dir() -> String

@external(erlang, "fabric_test_ffi", "remove_dir")
pub fn remove_dir(path: String) -> Nil

@external(erlang, "fabric_test_ffi", "list_dir")
pub fn list_dir(path: String) -> Result(List(String), Nil)

@external(erlang, "fabric_test_ffi", "read_file")
pub fn read_file(path: String) -> Result(String, Nil)

/// Sets the file's modification time `seconds` into the past.
@external(erlang, "fabric_test_ffi", "age_file")
pub fn age_file(path: String, seconds: Int) -> Result(Nil, Nil)

@external(erlang, "fabric_test_ffi", "write_file")
pub fn write_file(path: String, content: String) -> Result(Nil, Nil)

/// Runs `body` in a new process that then stays alive; everything `body`
/// starts linked (a store, and through it the runners) belongs to it.
pub fn owned(body: fn() -> a) -> #(Pid, a) {
  let reply = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      process.send(reply, body())
      let hold: process.Subject(Nil) = process.new_subject()
      process.receive_forever(hold)
    })
  #(pid, process.receive_forever(reply))
}

/// Kills `pid` and waits until it is gone.
pub fn kill(pid: Pid) -> Nil {
  let monitor = process.monitor(pid)
  process.kill(pid)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive_forever
  Nil
}

/// Waits until `pid` has exited.
pub fn gone(pid: Pid) -> Nil {
  let monitor = process.monitor(pid)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive_forever
}

/// The process of the runner the store has registered for `run`.
pub fn runner(store: Store, id: RunId) -> Result(Pid, Nil) {
  case store_core.get(store, run.id_to_string(id)) {
    Ok(store_core.Entry(live: Some(store_core.Live(mailbox:, ..)), ..)) ->
      process.subject_owner(mailbox)
    Ok(store_core.Entry(live: Some(store_core.GraphLive(mailbox:, ..)), ..)) ->
      process.subject_owner(mailbox)
    Ok(store_core.Entry(live: None, ..)) | Error(_) -> Error(Nil)
  }
}

/// Kills `owner` and waits until `store`, whose process it started, is
/// gone with it.
pub fn crash(owner: Pid, store: Store) -> Nil {
  let store_process = store_core.pid(store)
  kill(owner)
  case store_process {
    Ok(pid) -> gone(pid)
    Error(Nil) -> Nil
  }
}

/// Whether `pid` monitors `target` and is blocked in a receive.
@external(erlang, "fabric_test_ffi", "waits_on")
pub fn waits_on(pid: Pid, target: Pid) -> Bool

/// Whether `pid` is blocked in a receive that `module`'s own code entered
/// (not, say, a call into another module that waits for a reply).
@external(erlang, "fabric_test_ffi", "waits_in")
pub fn waits_in(pid: Pid, module: Atom) -> Bool

/// Suspends `pid`: it runs nothing until `resume`, while messages queue.
@external(erlang, "fabric_test_ffi", "suspend")
pub fn suspend(pid: Pid) -> Nil

@external(erlang, "fabric_test_ffi", "resume")
pub fn resume(pid: Pid) -> Nil

/// How many messages wait in `pid`'s mailbox.
@external(erlang, "fabric_test_ffi", "queued")
pub fn queued(pid: Pid) -> Int

/// An application whose supervisor runs a store's subtree, owned by its own
/// process, as an OTP application's top supervisor is.
pub type Application {
  Application(supervisor: Pid, stop: Subject(Nil))
}

/// Starts an application running `store`'s subtree (`store.supervised`).
pub fn application(store: Store) -> Application {
  application_with(store, [])
}

/// Runs the store followed by its dependent workers, in shutdown order.
pub fn application_with(
  store: Store,
  after: List(supervision.ChildSpecification(Nil)),
) -> Application {
  let reply = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(started) =
      static_supervisor.new(static_supervisor.RestForOne)
      |> static_supervisor.add(store.supervised(store))
      |> add_children(after)
      |> static_supervisor.start
    let stop = process.new_subject()
    process.send(reply, Application(started.pid, stop))
    let assert Ok(Nil) = process.receive(stop, 60_000)
    // As an application stops: its top supervisor's parent exits with
    // `shutdown`, and the supervisor stops its children in reverse order.
    exit_shutdown()
  })
  let assert Ok(application) = process.receive(reply, 5000)
  application
}

fn add_children(supervisor, children) {
  list.fold(children, supervisor, static_supervisor.add)
}

/// Begins stopping `application`; `stopped` waits for the end.
pub fn begin_stop(application: Application) -> Nil {
  process.send(application.stop, Nil)
}

/// Waits until `application`'s supervisor has stopped, with everything
/// under it.
pub fn stopped(application: Application) -> Nil {
  gone(application.supervisor)
}

/// Stops `application` and waits until everything under it has stopped.
pub fn stop(application: Application) -> Nil {
  begin_stop(application)
  stopped(application)
}

/// Waits until `store`'s runners are draining: its process hands out no
/// runner factory any more.
pub fn draining(store: Store) -> Nil {
  case store_core.runners(store) {
    Error(Nil) -> Nil
    Ok(_) -> {
      process.sleep(1)
      draining(store)
    }
  }
}

@external(erlang, "fabric_ffi", "exit_shutdown")
fn exit_shutdown() -> Nil

/// Whether `application`'s supervisor stops, with everything under it,
/// within `milliseconds`.
pub fn stopped_within(application: Application, milliseconds: Int) -> Bool {
  let monitor = process.monitor(application.supervisor)
  let stopped =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(milliseconds)
  process.demonitor_process(monitor)
  stopped == Ok(Nil)
}

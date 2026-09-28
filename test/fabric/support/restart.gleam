//// Instruments for durable-run tests: fresh temporary directories, owner
//// processes whose death takes down every Fabric process they started, and
//// access to a run's live runner.

import fabric/run.{type RunId}
import fabric/store.{type Store}
import gleam/erlang/process.{type Pid}
import gleam/option.{None, Some}

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
  case store.get(store, run.id_to_string(id)) {
    Ok(store.Entry(live: Some(store.Live(mailbox:, ..)), ..)) ->
      process.subject_owner(mailbox)
    Ok(store.Entry(live: None, ..)) | Error(_) -> Error(Nil)
  }
}

/// Kills `owner` and waits until `store`, whose process it started, is
/// gone with it.
pub fn crash(owner: Pid, store: Store) -> Nil {
  let store_process = store.pid(store)
  kill(owner)
  case store_process {
    Ok(pid) -> gone(pid)
    Error(Nil) -> Nil
  }
}

/// Whether `pid` monitors `target` and is blocked in a receive.
@external(erlang, "fabric_test_ffi", "waits_on")
pub fn waits_on(pid: Pid, target: Pid) -> Bool

/// Suspends `pid`: it runs nothing until `resume`, while messages queue.
@external(erlang, "fabric_test_ffi", "suspend")
pub fn suspend(pid: Pid) -> Nil

@external(erlang, "fabric_test_ffi", "resume")
pub fn resume(pid: Pid) -> Nil

/// How many messages wait in `pid`'s mailbox.
@external(erlang, "fabric_test_ffi", "queued")
pub fn queued(pid: Pid) -> Int

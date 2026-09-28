//// Where runs live: the store port and its two implementations.
////
//// A run is one encoded record (versioned JSON, see `fabric` docs) with a
//// revision. A backend supplies three functions over encoded records, and
//// Fabric writes only through `insert` and `compare_and_set`, so two owners
//// can never both advance the same revision.
////
//// The backend contract:
////
//// - `get(run)` returns the latest committed record with its revision, or
////   `NotFound`.
//// - `insert(run, record)` stores `record` as revision 1, or returns
////   `AlreadyExists` when the run exists.
//// - `compare_and_set(run, expected, record)` stores `record` as revision
////   `expected + 1` if and only if `expected` is the current revision, as
////   one atomic step; otherwise it returns `Conflict(current)` (or
////   `NotFound`). Two concurrent calls with the same `expected` must not
////   both succeed, also across processes and machines that share the
////   backend.
//// - Any other failure is `Unavailable(reason)`. A backend function that
////   crashes is treated as `Unavailable`. After an `Unavailable` write,
////   Fabric reads the run back: finding exactly the record it wrote at the
////   revision it wrote confirms the write. Every record Fabric writes
////   carries a fresh write token, so another writer's record is never
////   mistaken for this one. A write that is still unconfirmed stays
////   `Unavailable`: its outcome is unknown, since the backend may still
////   perform it later.
////
//// A `Store` value names a store process and starts nothing: it is plain
//// data that any process may hold and use. Start its process once, under
//// a supervisor (`supervised`) or owned by the caller (`start`, for
//// scripts and tests: it stops when the caller exits). The process calls the backend one request at a time
//// per run, tracks which runner currently drives each run in this VM, and
//// wakes `fabric.await` on commits made through it. A run outlives the
//// process that started it, which only uses the store.
////
//// Runners stop when their store process stops, and never commit through
//// a later process registered under the same name. A restarted store process
//// (for example by its supervisor) knows no runner, so every run with work
//// in flight reads as `Unattended` until `fabric.recover` takes it over. An
//// in-memory store keeps its records in its process, so a restart loses
//// them; a directory or application backend keeps them (the directory
//// store only up to a power loss: it is for development, tests, and one
//// host). Several stores may
//// open the same backend (for example the same directory): the backend's
//// compare-and-set keeps their commits safe, but each only knows its own
//// runners.

import fabric/internal/bounded
import fabric/internal/executor
import fabric/internal/live
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string

pub type StoreError {
  NotFound
  AlreadyExists
  /// The expected revision is no longer current.
  Conflict(current: Int)
  Unavailable(reason: String)
}

pub type Stored {
  Stored(revision: Int, record: String)
}

/// A named store: the name of its process and the backend that process
/// opens when it starts. A pinned store (`pin`) reaches one process of
/// that name only, never a later one.
pub opaque type Store {
  Store(
    name: Name(Message),
    open: fn() -> Result(Backend, String),
    pinned: Option(Subject(Message)),
    /// The name of the factory its runners are started under, derived from
    /// `name`: every `Store` value of one name reaches the same factory.
    factory: Name(FactoryMessage),
    /// Milliseconds each runner may take to finish its work when the
    /// store's subtree shuts down (`with_drain`).
    drain: Int,
  )
}

/// Why a drain window was refused (`with_drain`).
pub type DrainError {
  DrainNotPositive(Int)
  /// Longer than the longest timer the runtime can set (`limit`, 2^32 - 1
  /// ms).
  DrainTooLarge(value: Int, limit: Int)
}

/// What the store process receives.
pub opaque type Message {
  Get(run: String, reply: Subject(Result(Entry, StoreError)))
  Write(
    run: String,
    expected: Option(Int),
    record: String,
    ownership: Ownership,
    reply: Subject(Result(Int, StoreError)),
  )
  Watch(run: String, watcher: Subject(Nil), reply: Subject(Nil))
  Unwatch(run: String, watcher: Subject(Nil))
  Down(pid: Pid)
  /// A worker finished the backend call of the run's current request.
  Finished(run: String, done: Done)
  SetTimeout(milliseconds: Int)
  /// This process's own subject and the runner factory's process, if it
  /// runs and takes runners.
  Runners(
    factory: Name(FactoryMessage),
    reply: Subject(Result(#(Subject(Message), Pid), Nil)),
  )
  /// A runner of the factory `pid` received its shutdown: the factory takes
  /// no more runners.
  Draining(factory: Pid)
}

/// A store over application-supplied backend functions (for example a
/// database table), registered as `name`. See the module documentation for
/// the contract.
pub fn new(
  name: Name(Message),
  get get: fn(String) -> Result(Stored, StoreError),
  insert insert: fn(String, String) -> Result(Nil, StoreError),
  compare_and_set compare_and_set: fn(String, Int, String) ->
    Result(Nil, StoreError),
) -> Store {
  Store(
    name,
    fn() { Ok(Backend(get:, insert:, compare_and_set:)) },
    None,
    factory_name(name),
    default_drain,
  )
}

/// A store that keeps records in its own process, registered as `name`.
/// They are lost when that process stops, also when a supervisor restarts
/// it.
pub fn in_memory(name: Name(Message)) -> Store {
  Store(
    name,
    fn() { Ok(memory_backend()) },
    None,
    factory_name(name),
    default_drain,
  )
}

/// A store in the directory `path`, registered as `name`, for development,
/// tests, and a single host: its records survive a process or VM crash,
/// but not a power loss or an operating-system crash (see Atomicity). In
/// production use a database backend through `new` (a Postgres adapter is
/// planned) or another application backend. The directory is created
/// when the store starts, if missing. Each run is a directory
/// holding one file per revision, `<revision>.json`. Every revision name is
/// kept, but revisions older than the previous one are emptied, so disk use
/// follows the latest record rather than every record written. Starting the
/// store removes temporary files older than ten minutes that a crashed
/// writer left behind.
///
/// Atomicity: a revision is written to a temporary file in the run's
/// directory, flushed to disk (`fsync`), and then hard-linked under its
/// revision name. The link fails if that name exists, so exactly one of two
/// concurrent writers of the same revision succeeds, also across processes
/// and VMs on one local POSIX filesystem, and a reader never sees a partly
/// written revision. A crash leaves at most an ignored temporary file. The
/// directory entry itself is not flushed: after a power loss or an
/// operating-system crash (not a process or VM crash) the most recent
/// revisions may be missing, and since an older revision is emptied once
/// two newer ones are published, the run may then read as `Unavailable`;
/// a tool whose start was among the lost revisions could run again.
/// Flushing the directory entry would need a native extension, which Fabric
/// does not ship. Network filesystems without atomic hard links are not
/// supported.
pub fn directory(name: Name(Message), path: String) -> Store {
  Store(
    name,
    fn() {
      use Nil <- result.map(ensure_directory(path))
      Backend(
        get: directory_get(path, _),
        insert: fn(run, record) { directory_insert(path, run, record) },
        compare_and_set: fn(run, expected, record) {
          directory_compare_and_set(path, run, expected, record)
        },
      )
    },
    None,
    factory_name(name),
    default_drain,
  )
}

/// How long a runner may take to finish its work on shutdown, by default.
const default_drain = 25_000

/// The longest timer the runtime can set, in milliseconds.
const longest_timer = 4_294_967_295

/// Sets how long each runner may take to finish its work when the store's
/// subtree shuts down (default 25 000 ms): see `supervised`. Up to 2^32 - 1
/// ms. Give the application's own shutdown timeout for the store's
/// subtree room for it.
pub fn with_drain(
  store: Store,
  milliseconds: Int,
) -> Result(Store, DrainError) {
  case milliseconds {
    ms if ms <= 0 -> Error(DrainNotPositive(ms))
    ms if ms > longest_timer -> Error(DrainTooLarge(ms, longest_timer))
    ms -> Ok(Store(..store, drain: ms))
  }
}

/// The store's subtree, for the application's supervisor: a supervisor
/// (one for one, at most 3 restarts in 5 seconds) of the store's process (a
/// worker given 5000 ms to stop) and, after it, the factory its runners
/// are started under. A runner stops when the store process it belongs to
/// stops, so a crash of the store's process stops its runners, and its
/// runs with work in flight are `Unattended` until recovered (see the
/// module documentation); the restarted process takes new runners at once.
///
/// On shutdown the runners stop first, the store's process last. Each
/// runner drains within the store's drain window (`with_drain`, default
/// 25 000 ms): it starts no tool body, model call or sub-agent, waits for
/// the tool bodies running and a model reply in flight, commits their
/// results through the store's process, and hands the run off (see
/// `fabric.recover`). A runner still busy when the window ends is killed,
/// and its running tools become uncertain effects.
pub fn supervised(store: Store) -> supervision.ChildSpecification(Nil) {
  supervision.supervisor(fn() {
    subtree(store, None, supervision.Permanent)
    |> static_supervisor.start
    |> result.map(fn(started) { actor.Started(started.pid, Nil) })
  })
}

/// Starts the store's subtree (see `supervised`) for scripts and tests,
/// linked to the caller. The store's process stops when the caller exits
/// for any reason, normally or not, so its name is free again; its runners
/// stop with it without draining, as if the node had stopped. `Unavailable`
/// when its backend could not be opened or its name is taken.
pub fn start(store: Store) -> Result(Nil, StoreError) {
  let caller = process.self()
  let failed = process.new_subject()
  let started = process.new_subject()
  // The keeper is linked to the caller and owns the subtree: a subtree that
  // fails to start, or a caller that exits, stops the subtree with reason
  // `shutdown`, which is not logged as a crash; a subtree that gives up
  // after its restarts takes the keeper, and the caller, down with it.
  let keeper =
    process.spawn(fn() {
      process.trap_exits(True)
      let subtree =
        subtree(store, Some(#(caller, failed)), supervision.Transient)
        |> static_supervisor.start
      process.send(started, result.replace(subtree, Nil))
      case subtree {
        Error(_) -> Nil
        Ok(_) -> keep(caller)
      }
    })
  let monitor = process.monitor(keeper)
  let outcome =
    process.new_selector()
    |> process.select_map(started, fn(started) { started })
    |> process.select_specific_monitor(monitor, fn(down) {
      Error(actor.InitExited(down.reason))
    })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  outcome
  |> result.map_error(fn(error) {
    Unavailable(case process.receive(failed, 0) {
      Ok(reason) -> reason
      Error(Nil) -> describe_start(error)
    })
  })
}

/// Holds a started subtree until `caller` exits, then stops it; exits with
/// the subtree if it stops first.
fn keep(caller: Pid) -> Nil {
  let exit =
    process.new_selector()
    |> process.select_trapped_exits(fn(exit) { exit })
    |> process.selector_receive_forever
  case exit.pid == caller, exit.reason {
    True, _ -> exit_shutdown()
    False, process.Normal -> exit_shutdown()
    False, process.Killed -> process.kill(process.self())
    False, process.Abnormal(reason) -> exit_with(reason)
  }
}

@external(erlang, "fabric_ffi", "exit_shutdown")
fn exit_shutdown() -> Nil

@external(erlang, "erlang", "exit")
fn exit_with(reason: dynamic.Dynamic) -> Nil

/// The store's process first, then its runner factory, so that runners
/// stop before the process they commit through. With a `starter`, the
/// store's process stops when it exits and reports a failure to start to
/// its subject.
fn subtree(
  store: Store,
  starter: Option(#(Pid, Subject(String))),
  restart: supervision.Restart,
) -> static_supervisor.Builder {
  let store = Store(..store, pinned: None)
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.restart_tolerance(intensity: 3, period: 5)
  |> static_supervisor.add(
    supervision.worker(fn() {
      case run(store, option.map(starter, fn(starter) { starter.0 })) {
        Ok(started) -> Ok(actor.Started(started.pid, Nil))
        Error(error) -> {
          option.map(starter, fn(starter) {
            process.send(starter.1, describe_start(error))
          })
          Error(error)
        }
      }
    })
    |> supervision.timeout(ms: 5000)
    |> supervision.restart(restart),
  )
  |> static_supervisor.add(
    // Runners are temporary: one that stops is never restarted, since
    // recovery is explicit. Each is given the drain window to stop.
    factory_supervisor.worker_child(fn(spawn: fn(Pid) -> Pid) {
      Ok(actor.Started(spawn(process.self()), Nil))
    })
    |> factory_supervisor.restart_strategy(supervision.Temporary)
    |> factory_supervisor.timeout(ms: store.drain)
    |> factory_supervisor.named(store.factory)
    |> factory_supervisor.supervised,
  )
}

fn describe_start(error: actor.StartError) -> String {
  case error {
    actor.InitFailed(reason) -> reason
    actor.InitTimeout -> "the store did not start in time"
    actor.InitExited(reason) ->
      "the store exited while starting: " <> string.inspect(reason)
  }
}

// --- Fabric's side of the store ---------------------------------------------------

/// The runner that currently drives a run in this VM.
@internal
pub type Live {
  Live(incarnation: Int, mailbox: Subject(live.Message))
}

@internal
pub type Entry {
  Entry(revision: Int, record: String, live: Option(Live))
}

/// What a commit does to the run's live runner registration.
@internal
pub type Ownership {
  Keep
  /// The committing runner `Pid` gives the run up in the same step, so a
  /// watcher woken by this commit already sees no runner.
  Release(Pid)
  /// A new runner takes the run over in the same step.
  Claim(Pid, Live)
}

/// The store's process: the one registered under its name, or for a
/// pinned store the process it is pinned to, while it runs.
@internal
pub fn pid(store: Store) -> Result(Pid, Nil) {
  case store.pinned {
    None -> process.named(store.name)
    Some(subject) ->
      case process.subject_owner(subject) {
        Ok(pid) ->
          case process.is_alive(pid) {
            True -> Ok(pid)
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
  }
}

/// What the factory runners are started under receives.
@internal
pub type FactoryMessage =
  factory_supervisor.Message(fn(Pid) -> Pid, Nil)

/// The factory runners are started under.
@internal
pub type Factory =
  factory_supervisor.Supervisor(fn(Pid) -> Pid, Nil)

/// The factory's name for a store named `name`.
@external(erlang, "fabric_ffi", "factory_name")
fn factory_name(name: Name(Message)) -> Name(FactoryMessage)

/// `store` pinned to the process registered under its name now, with that
/// process's runner factory. Every call through the pinned store reaches
/// that process or, once it stopped, fails as a stopped store would, even
/// after a supervisor registers another process under the name. A runner
/// uses its store pinned to the process it monitors. `Error` when no store
/// process runs, or its factory takes no runners (it is shutting down).
@internal
pub fn runners(store: Store) -> Result(#(Store, Factory), Nil) {
  case call(store, Runners(store.factory, _)) {
    Ok(Ok(#(subject, _))) ->
      Ok(#(
        Store(..store, pinned: Some(subject)),
        factory_supervisor.get_by_name(store.factory),
      ))
    _ -> Error(Nil)
  }
}

/// Starts a runner under `factory`: `spawn` runs in the factory's process,
/// is given its pid, and must spawn the runner linked to it. `Error` when
/// the factory is not running or stops meanwhile.
@internal
pub fn start_runner(
  factory: Factory,
  spawn: fn(Pid) -> Pid,
) -> Result(Pid, Nil) {
  case
    executor.rescue(fn() { factory_supervisor.start_child(factory, spawn) })
  {
    Ok(Ok(started)) -> Ok(started.pid)
    Ok(Error(_)) | Error(_) -> Error(Nil)
  }
}

/// A runner of the factory `factory` received its shutdown: the store's
/// process hands that factory out no more.
@internal
pub fn draining(store: Store, factory: Pid) -> Nil {
  process.send(target(store), Draining(factory))
}

/// Where requests to the store's process go.
fn target(store: Store) -> Subject(Message) {
  case store.pinned {
    Some(subject) -> subject
    None -> process.named_subject(store.name)
  }
}

@internal
pub fn get(store: Store, run: String) -> Result(Entry, StoreError) {
  call(store, Get(run, _)) |> result.flatten
}

/// Inserts revision 1 of `run`.
@internal
pub fn insert(
  store: Store,
  run: String,
  record: String,
  ownership: Ownership,
) -> Result(Int, StoreError) {
  call(store, Write(run, None, record, ownership, _)) |> result.flatten
}

/// Commits `record` over `expected` and returns the new revision.
@internal
pub fn commit(
  store: Store,
  run: String,
  expected: Int,
  record: String,
  ownership: Ownership,
) -> Result(Int, StoreError) {
  call(store, Write(run, Some(expected), record, ownership, _))
  |> result.flatten
}

/// Sends `Nil` to `watcher` after every commit of `run` through this store
/// and whenever its runner exits, until `unwatch` or the watcher's owner
/// exits.
@internal
pub fn watch(
  store: Store,
  run: String,
  watcher: Subject(Nil),
) -> Result(Nil, StoreError) {
  call(store, Watch(run, watcher, _))
}

@internal
pub fn unwatch(store: Store, run: String, watcher: Subject(Nil)) -> Nil {
  process.send(target(store), Unwatch(run, watcher))
}

// --- the store process -----------------------------------------------------------

type Backend {
  Backend(
    get: fn(String) -> Result(Stored, StoreError),
    insert: fn(String, String) -> Result(Nil, StoreError),
    compare_and_set: fn(String, Int, String) -> Result(Nil, StoreError),
  )
}

type Done {
  Got(Result(Stored, StoreError))
  Wrote(Result(Int, StoreError))
}

type Loop {
  Loop(
    /// This process's own subject for its workers' reports: unlike the
    /// named subject, it never reaches a later process of the same name.
    subject: Subject(Message),
    backend: Backend,
    live: Dict(String, #(Pid, Live)),
    /// The runner factory process that reported it is shutting down.
    draining: Option(Pid),
    watchers: Dict(String, List(#(Pid, Subject(Nil)))),
    monitored: List(Pid),
    /// Per run: the request whose backend call is in flight, and the
    /// requests waiting behind it, oldest first.
    busy: Dict(String, #(Message, List(Message))),
    timeout: Int,
    /// The process that started this one with `start`: this one stops
    /// when it exits.
    starter: Option(Pid),
  )
}

/// How long one backend call may take, in milliseconds, before it is
/// abandoned and reported `Unavailable`.
const default_backend_timeout = 5000

/// Starts the store process, registered under the store's name and linked
/// to the caller. It opens its backend itself, so a backend process is
/// linked to the store process. With a `starter`, it stops when that
/// process exits.
fn run(
  store: Store,
  starter: Option(Pid),
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(default_backend_timeout, fn(named) {
    use backend <- result.map(store.open())
    option.map(starter, process.monitor)
    let subject = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(named)
      |> process.select(subject)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid:, ..) -> Down(pid)
          process.PortDown(..) -> Down(process.self())
        }
      })
    Loop(
      subject:,
      backend:,
      live: dict.new(),
      draining: None,
      watchers: dict.new(),
      monitored: [],
      busy: dict.new(),
      timeout: default_backend_timeout,
      starter:,
    )
    |> actor.initialised
    |> actor.selecting(selector)
  })
  |> actor.named(store.name)
  |> actor.on_message(fn(state, message) {
    case message {
      Down(pid) if state.starter == Some(pid) -> actor.stop()
      _ -> actor.continue(serve(state, message))
    }
  })
  |> actor.start
}

/// Sets how long one backend call may take (default 5000 ms). For tests.
@internal
pub fn with_backend_timeout(store: Store, milliseconds: Int) -> Store {
  process.send(target(store), SetTimeout(milliseconds))
  store
}

/// Sends a request to the store process and waits for its reply. A store
/// that is not running, or stops before replying, is `Unavailable`: a write
/// sent to it has an unknown outcome.
fn call(
  store: Store,
  request: fn(Subject(reply)) -> Message,
) -> Result(reply, StoreError) {
  case pid(store) {
    Error(Nil) ->
      case store.pinned {
        None -> Error(Unavailable("the store is not running"))
        Some(_) -> Error(Unavailable("the store stopped"))
      }
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      process.send(target(store), request(reply))
      let answer =
        process.new_selector()
        |> process.select_map(reply, Ok)
        |> process.select_specific_monitor(monitor, fn(_) {
          Error(Unavailable("the store stopped"))
        })
        |> process.selector_receive_forever
      process.demonitor_process(monitor)
      answer
    }
  }
}

/// The store process never calls the backend itself. Backend calls run in
/// worker processes, one run at a time in arrival order, each bounded by
/// the backend timeout, so a slow or hung call holds up only its own run.
fn serve(state: Loop, message: Message) -> Loop {
  case message {
    SetTimeout(milliseconds) -> Loop(..state, timeout: milliseconds)
    Runners(factory, reply) -> {
      process.send(reply, case process.named(factory) {
        Ok(pid) if state.draining != Some(pid) -> Ok(#(state.subject, pid))
        _ -> Error(Nil)
      })
      state
    }
    Draining(pid) -> Loop(..state, draining: Some(pid))
    Get(run, ..) as request | Write(run, ..) as request ->
      enqueue(state, run, request)
    Finished(run, done) -> finish(state, run, done)
    Watch(run, watcher, reply) -> {
      let state = case process.subject_owner(watcher) {
        Error(Nil) -> state
        Ok(owner) ->
          Loop(
            ..monitor(state, owner),
            watchers: dict.upsert(state.watchers, run, fn(existing) {
              [#(owner, watcher), ..option.unwrap(existing, [])]
            }),
          )
      }
      process.send(reply, Nil)
      state
    }
    Unwatch(run, watcher) ->
      Loop(
        ..state,
        watchers: dict.upsert(state.watchers, run, fn(existing) {
          option.unwrap(existing, [])
          |> list.filter(fn(entry) { entry.1 != watcher })
        }),
      )
    Down(pid) -> {
      let #(released, live) =
        dict.fold(state.live, #([], state.live), fn(acc, run, entry) {
          case entry.0 == pid {
            True -> #([run, ..acc.0], dict.delete(acc.1, run))
            False -> acc
          }
        })
      let watchers =
        dict.map_values(state.watchers, fn(_, entries) {
          list.filter(entries, fn(entry) { entry.0 != pid })
        })
      let state =
        Loop(
          ..state,
          live:,
          watchers:,
          monitored: list.filter(state.monitored, fn(p) { p != pid }),
        )
      list.each(released, notify(state, _))
      state
    }
  }
}

fn enqueue(state: Loop, run: String, request: Message) -> Loop {
  case dict.get(state.busy, run) {
    Ok(#(current, waiting)) ->
      Loop(
        ..state,
        busy: dict.insert(state.busy, run, #(
          current,
          list.append(waiting, [request]),
        )),
      )
    Error(Nil) -> {
      begin(state, run, request)
      Loop(..state, busy: dict.insert(state.busy, run, #(request, [])))
    }
  }
}

/// Starts the backend call of `request` in a worker linked to the store.
fn begin(state: Loop, run: String, request: Message) -> Nil {
  let backend = state.backend
  let timeout = state.timeout
  let subject = state.subject
  let _ =
    process.spawn(fn() {
      let done = case request {
        Write(expected:, record:, ..) -> {
          let revision = case expected {
            None -> 1
            Some(expected) -> expected + 1
          }
          bounded_backend(timeout, fn() {
            case expected {
              None -> backend.insert(run, record)
              Some(expected) -> backend.compare_and_set(run, expected, record)
            }
          })
          |> result.replace(revision)
          |> confirm(backend, timeout, run, revision, record)
          |> Wrote
        }
        _ -> Got(bounded_backend(timeout, fn() { backend.get(run) }))
      }
      process.send(subject, Finished(run, done))
    })
  Nil
}

/// Answers the run's current request and starts the next one.
fn finish(state: Loop, run: String, done: Done) -> Loop {
  case dict.get(state.busy, run) {
    Error(Nil) -> state
    Ok(#(current, waiting)) -> {
      let state = case current, done {
        Get(reply:, ..), Got(got) -> {
          process.send(
            reply,
            result.map(got, fn(stored) {
              Entry(
                stored.revision,
                stored.record,
                dict.get(state.live, run)
                  |> result.map(fn(l) { l.1 })
                  |> option.from_result,
              )
            }),
          )
          state
        }
        Write(ownership:, reply:, ..), Wrote(written) -> {
          process.send(reply, written)
          case written {
            Error(_) -> state
            Ok(_) -> {
              let state = own(state, run, ownership)
              notify(state, run)
              state
            }
          }
        }
        _, _ -> state
      }
      case waiting {
        [] -> Loop(..state, busy: dict.delete(state.busy, run))
        [next, ..rest] -> {
          begin(state, run, next)
          Loop(..state, busy: dict.insert(state.busy, run, #(next, rest)))
        }
      }
    }
  }
}

/// A backend call that crashes or exceeds the deadline is `Unavailable`.
fn bounded_backend(
  timeout: Int,
  body: fn() -> Result(a, StoreError),
) -> Result(a, StoreError) {
  case bounded.call(timeout, body) {
    Ok(result) -> result
    Error(bounded.Crashed(crash)) ->
      Error(Unavailable("the backend crashed: " <> crash))
    Error(bounded.TimedOut) ->
      Error(Unavailable(
        "the backend gave no answer within " <> int.to_string(timeout) <> " ms",
      ))
  }
}

/// A backend may commit and still report `Unavailable` (a lost reply). The
/// write is confirmed when reading back finds exactly this record at this
/// revision; otherwise the error stands.
fn confirm(
  written: Result(Int, StoreError),
  backend: Backend,
  timeout: Int,
  run: String,
  revision: Int,
  record: String,
) -> Result(Int, StoreError) {
  case written {
    Error(Unavailable(_)) ->
      case bounded_backend(timeout, fn() { backend.get(run) }) {
        Ok(Stored(found, stored)) if found == revision && stored == record ->
          Ok(revision)
        _ -> written
      }
    _ -> written
  }
}

fn own(state: Loop, run: String, ownership: Ownership) -> Loop {
  case ownership {
    Keep -> state
    Release(pid) ->
      case dict.get(state.live, run) {
        Ok(#(owner, _)) if owner == pid ->
          Loop(..state, live: dict.delete(state.live, run))
        _ -> state
      }
    Claim(pid, live) ->
      Loop(
        ..monitor(state, pid),
        live: dict.insert(state.live, run, #(pid, live)),
      )
  }
}

fn monitor(state: Loop, pid: Pid) -> Loop {
  case list.contains(state.monitored, pid) {
    True -> state
    False -> {
      let _ = process.monitor(pid)
      Loop(..state, monitored: [pid, ..state.monitored])
    }
  }
}

fn notify(state: Loop, run: String) -> Nil {
  dict.get(state.watchers, run)
  |> result.unwrap([])
  |> list.each(fn(entry) { process.send(entry.1, Nil) })
}

// --- in memory ---------------------------------------------------------------

type MemoryRequest {
  MemoryGet(String, Subject(Result(Stored, StoreError)))
  MemoryWrite(String, Option(Int), String, Subject(Result(Nil, StoreError)))
}

/// A backend process linked to the store process that builds it, which
/// stops when that process stops for any reason.
fn memory_backend() -> Backend {
  let ready = process.new_subject()
  let owner = process.self()
  process.spawn(fn() {
    let subject = process.new_subject()
    let requests =
      process.new_selector()
      |> process.select_map(subject, Ok)
      |> process.select_specific_monitor(process.monitor(owner), fn(_) {
        Error(Nil)
      })
    process.send(ready, subject)
    memory_loop(requests, dict.new())
  })
  let subject = process.receive_forever(ready)
  Backend(
    get: fn(run) { process.call_forever(subject, MemoryGet(run, _)) },
    insert: fn(run, record) {
      process.call_forever(subject, MemoryWrite(run, None, record, _))
    },
    compare_and_set: fn(run, expected, record) {
      process.call_forever(subject, MemoryWrite(run, Some(expected), record, _))
    },
  )
}

fn memory_loop(
  requests: process.Selector(Result(MemoryRequest, Nil)),
  records: Dict(String, Stored),
) -> Nil {
  case process.selector_receive_forever(requests) {
    Error(Nil) -> Nil
    Ok(MemoryGet(run, reply)) -> {
      process.send(
        reply,
        dict.get(records, run) |> result.replace_error(NotFound),
      )
      memory_loop(requests, records)
    }
    Ok(MemoryWrite(run, expected, record, reply)) -> {
      let outcome = case expected, dict.get(records, run) {
        None, Ok(_) -> Error(AlreadyExists)
        None, Error(Nil) -> Ok(Stored(1, record))
        Some(_), Error(Nil) -> Error(NotFound)
        Some(expected), Ok(current) if current.revision == expected ->
          Ok(Stored(expected + 1, record))
        Some(_), Ok(current) -> Error(Conflict(current.revision))
      }
      process.send(reply, result.replace(outcome, Nil))
      case outcome {
        Ok(stored) -> memory_loop(requests, dict.insert(records, run, stored))
        Error(_) -> memory_loop(requests, records)
      }
    }
  }
}

// --- directory ---------------------------------------------------------------

@external(erlang, "fabric_ffi", "ensure_directory")
fn ensure_directory(path: String) -> Result(Nil, String)

@external(erlang, "fabric_ffi", "directory_get")
fn directory_get(path: String, run: String) -> Result(Stored, StoreError)

@external(erlang, "fabric_ffi", "directory_insert")
fn directory_insert(
  path: String,
  run: String,
  record: String,
) -> Result(Nil, StoreError)

@external(erlang, "fabric_ffi", "directory_compare_and_set")
fn directory_compare_and_set(
  path: String,
  run: String,
  expected: Int,
  record: String,
) -> Result(Nil, StoreError)

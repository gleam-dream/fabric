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
//// a supervisor (`supervised`) or linked to the caller (`start`, for
//// scripts and tests). The process calls the backend one request at a time
//// per run, tracks which runner currently drives each run in this VM, and
//// wakes `fabric.await` on commits made through it. A run outlives the
//// process that started it, which only uses the store.
////
//// Runners stop when their store process stops. A restarted store process
//// (for example by its supervisor) knows no runner, so every run with work
//// in flight reads as `Unattended` until `fabric.recover` takes it over. An
//// in-memory store keeps its records in its process, so a restart loses
//// them; a directory or application backend keeps them. Several stores may
//// open the same backend (for example the same directory): the backend's
//// compare-and-set keeps their commits safe, but each only knows its own
//// runners.

import fabric/internal/bounded
import fabric/internal/live
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
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
/// opens when it starts.
pub opaque type Store {
  Store(name: Name(Message), open: fn() -> Result(Backend, String))
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
  Store(name, fn() { Ok(Backend(get:, insert:, compare_and_set:)) })
}

/// A store that keeps records in its own process, registered as `name`.
/// They are lost when that process stops, also when a supervisor restarts
/// it.
pub fn in_memory(name: Name(Message)) -> Store {
  Store(name, fn() { Ok(memory_backend()) })
}

/// A durable store in `path`, registered as `name`; the directory is
/// created when the store starts, if missing. Each run is a directory
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
/// two newer ones are published, the run may then read as `Unavailable`.
/// Network filesystems without atomic hard links are not supported.
pub fn directory(name: Name(Message), path: String) -> Store {
  Store(name, fn() {
    use Nil <- result.map(ensure_directory(path))
    Backend(
      get: directory_get(path, _),
      insert: fn(run, record) { directory_insert(path, run, record) },
      compare_and_set: fn(run, expected, record) {
        directory_compare_and_set(path, run, expected, record)
      },
    )
  })
}

/// The store's process as a supervised worker. A restart forgets its
/// runners (see the module documentation).
pub fn supervised(store: Store) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    run(store) |> result.map(fn(started) { actor.Started(started.pid, Nil) })
  })
}

/// Starts the store's process linked to the caller, for scripts and tests;
/// it stops when the caller does. `Unavailable` when its backend could not
/// be opened or its name is taken.
pub fn start(store: Store) -> Result(Nil, StoreError) {
  run(store)
  |> result.replace(Nil)
  |> result.map_error(fn(error) {
    Unavailable(case error {
      actor.InitFailed(reason) -> reason
      actor.InitTimeout -> "the store did not start in time"
      actor.InitExited(reason) ->
        "the store exited while starting: " <> string.inspect(reason)
    })
  })
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

/// The store's process, while one is registered under its name.
@internal
pub fn pid(store: Store) -> Result(Pid, Nil) {
  process.named(store.name)
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
  process.send(process.named_subject(store.name), Unwatch(run, watcher))
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
    watchers: Dict(String, List(#(Pid, Subject(Nil)))),
    monitored: List(Pid),
    /// Per run: the request whose backend call is in flight, and the
    /// requests waiting behind it, oldest first.
    busy: Dict(String, #(Message, List(Message))),
    timeout: Int,
  )
}

/// How long one backend call may take, in milliseconds, before it is
/// abandoned and reported `Unavailable`.
const default_backend_timeout = 5000

/// Starts the store process, registered under the store's name and linked
/// to the caller. It opens its backend itself, so a backend process is
/// linked to the store process.
fn run(store: Store) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(default_backend_timeout, fn(named) {
    use backend <- result.map(store.open())
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
      watchers: dict.new(),
      monitored: [],
      busy: dict.new(),
      timeout: default_backend_timeout,
    )
    |> actor.initialised
    |> actor.selecting(selector)
  })
  |> actor.named(store.name)
  |> actor.on_message(fn(state, message) {
    actor.continue(serve(state, message))
  })
  |> actor.start
}

/// Sets how long one backend call may take (default 5000 ms). For tests.
@internal
pub fn with_backend_timeout(store: Store, milliseconds: Int) -> Store {
  process.send(process.named_subject(store.name), SetTimeout(milliseconds))
  store
}

/// Sends a request to the store process and waits for its reply. A store
/// that is not running, or stops before replying, is `Unavailable`: a write
/// sent to it has an unknown outcome.
fn call(
  store: Store,
  request: fn(Subject(reply)) -> Message,
) -> Result(reply, StoreError) {
  case process.named(store.name) {
    Error(Nil) -> Error(Unavailable("the store is not running"))
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      process.send(process.named_subject(store.name), request(reply))
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

/// A backend process linked to the store process that builds it.
fn memory_backend() -> Backend {
  let ready = process.new_subject()
  process.spawn(fn() {
    let subject = process.new_subject()
    process.send(ready, subject)
    memory_loop(subject, dict.new())
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
  subject: Subject(MemoryRequest),
  records: Dict(String, Stored),
) -> Nil {
  case process.receive_forever(subject) {
    MemoryGet(run, reply) -> {
      process.send(
        reply,
        dict.get(records, run) |> result.replace_error(NotFound),
      )
      memory_loop(subject, records)
    }
    MemoryWrite(run, expected, record, reply) -> {
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
        Ok(stored) -> memory_loop(subject, dict.insert(records, run, stored))
        Error(_) -> memory_loop(subject, records)
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

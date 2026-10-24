//// The store's process and its backend, behind `fabric/store` (see that
//// module for what a store is) and `fabric/store/backend` (the port).
//// The runtime reads, writes and watches runs through these functions.

import fabric/internal/bounded
import fabric/internal/controller
import fabric/internal/drain
import fabric/internal/executor
import fabric/internal/graph/live as graph_live
import fabric/internal/live
import fabric/internal/observe
import fabric/internal/record
import fabric/store/backend.{
  type Current, type Holder, type Lease, type LeasedBackend, type StoreError,
  type Stored, AlreadyExists, Claim, Conflict, Current, Free, Held, Hold,
  LeaseRefused, LeasedBackend, NotFound, Release, Seize, Stored, Unavailable,
}
import fabric/telemetry as o
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
import sinal/correlation.{type Correlation}

/// A named store: the name of its process and the backend that process
/// opens when it starts. A pinned store (`pin`) reaches one process of
/// that name only, never a later one.
pub opaque type Store {
  Store(
    name: Name(Message),
    open: fn() -> Result(LeasedBackend, String),
    pinned: Option(Subject(Message)),
    /// Milliseconds each runner may take to finish its work when the
    /// store's subtree shuts down (`with_drain`).
    drain: Int,
    /// A leased store's node id and lease duration (`leased`).
    leasing: Option(Leasing),
    /// Writes through this value use this version; reads accept all
    /// supported versions. Configure before constructing run handles.
    write_version: record.WriteVersion,
  )
}

type Leasing {
  Leasing(node: String, ttl: Int)
}

/// Writes through the returned value use `writer`.
pub fn with_write_version(store: Store, writer: record.WriteVersion) -> Store {
  Store(..store, write_version: writer)
}

pub fn supports_family_budget(store: Store) -> Bool {
  store.write_version == record.V7 || store.write_version == record.V8
}

pub fn supports_history(store: Store) -> Bool {
  store.write_version == record.V8
}

/// Encode once per logical write, before effects, and reuse the bytes on
/// retries so the write token still confirms exactly that attempt.
pub fn encode(
  store: Store,
  state: controller.State,
) -> Result(String, StoreError) {
  record.encode_as(state, store.write_version)
  |> result.map_error(fn(problem) {
    let record.Unrepresentable(version, detail) = problem
    Unavailable("record version " <> int.to_string(version) <> ": " <> detail)
  })
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
  Wake(run: String, token: String)
  Awoke(run: String, token: String, disposition: WakeupDisposition)
  Down(pid: Pid, reason: process.ExitReason)
  /// A worker finished the backend call of the run's current request.
  Finished(run: String, done: Done)
  SetTimeout(milliseconds: Int)
  /// This process's own subject, and the name and process of its runner
  /// factory, if it runs and takes runners.
  Runners(
    reply: Subject(Result(#(Subject(Message), Name(FactoryMessage), Pid), Nil)),
  )
  /// A runner of the factory `pid` received its shutdown: the factory takes
  /// no more runners.
  Draining(factory: Pid)
  BeginDrain(factory: Pid, reply: Subject(Nil))
  TrackRunner(factory: Pid, runner: Pid, reply: Subject(Nil))
  HandoffFailed(runner: Pid)
  ReportDrain(reply: Subject(Result(o.Drain, Nil)))
  CompleteDrainReport
  /// A leased store renews the leases of its runners; `tick`: the timer's
  /// (which sets the next one), not a test's.
  Renew(tick: Bool)
  /// Whether a renewal is in flight, for tests.
  ReadRenewing(reply: Subject(Bool))
  /// A renewal sent at the monotonic time `sent` for `runs` (each with its
  /// runner) finished.
  Renewed(
    sent: Int,
    runs: List(#(String, Pid)),
    result: Result(List(String), StoreError),
  )
  /// Kill the runners whose lease could have expired.
  Fence
  ClaimExpired(limit: Int, reply: Subject(Result(List(String), StoreError)))
  ClaimReady(limit: Int, reply: Subject(Result(List(String), StoreError)))
  ReadClock(reply: Subject(Result(Int, StoreError)))
  ReadReadiness(reply: Subject(Result(Report, StoreError)))
  ReadinessChecked(
    reply: Subject(Result(Report, StoreError)),
    result: Result(Nil, StoreError),
  )
  /// The keeper of a store started with `start`; `None` under a supervisor.
  ReadStopper(reply: Subject(Option(Subject(Nil))))
  ReserveJobObservation(run: String, caller: Pid, reply: Subject(Bool))
  ReleaseJobObservation(run: String, caller: Pid)
}

pub fn new(
  name: Name(Message),
  get get: fn(String) -> Result(Stored, StoreError),
  insert insert: fn(String, String) -> Result(Nil, StoreError),
  compare_and_set compare_and_set: fn(String, Int, String) ->
    Result(Nil, StoreError),
) -> Store {
  Store(
    name,
    fn() { Ok(unleased(Backend(get:, insert:, compare_and_set:))) },
    None,
    default_drain,
    None,
    record.V8,
  )
}

pub fn in_memory(name: Name(Message)) -> Store {
  Store(
    name,
    fn() { Ok(unleased(memory_backend())) },
    None,
    default_drain,
    None,
    record.V8,
  )
}

pub fn directory(name: Name(Message), path: String) -> Store {
  Store(
    name,
    fn() {
      use Nil <- result.map(ensure_directory(path))
      unleased(
        Backend(
          get: directory_get(path, _),
          insert: fn(run, record) { directory_insert(path, run, record) },
          compare_and_set: fn(run, expected, record) {
            directory_compare_and_set(path, run, expected, record)
          },
        ),
      )
    },
    None,
    default_drain,
    None,
    record.V8,
  )
}

pub fn leased(
  name: Name(Message),
  node: String,
  ttl: Int,
  backend: LeasedBackend,
) -> Store {
  Store(
    name,
    fn() { Ok(backend) },
    None,
    default_drain,
    Some(Leasing(node, ttl)),
    record.V8,
  )
}

/// How long a runner may take to finish its work on shutdown, by default.
const default_drain = 25_000

/// Each runner may take `ms` to finish its work when the subtree stops.
pub fn with_drain(store: Store, ms: Int) -> Store {
  Store(..store, drain: ms)
}

pub fn supervised(store: Store) -> supervision.ChildSpecification(Nil) {
  supervision.supervisor(fn() {
    subtree(store, None, supervision.Permanent)
    |> static_supervisor.start
    |> result.map(fn(started) { actor.Started(started.pid, Nil) })
  })
}

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
      await_earlier_factory(store.name)
      let stop = process.new_subject()
      let subtree =
        subtree(
          store,
          Some(Starter(caller, failed, stop)),
          supervision.Transient,
        )
        |> static_supervisor.start
      process.send(started, result.replace(subtree, Nil))
      case subtree {
        Error(_) -> Nil
        Ok(started) -> keep(caller, stop, started.pid)
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

/// Stops the subtree of a store started with `start`, as a supervisor
/// stops one (its runners drain), and waits until its process has stopped,
/// up to the drain window and 10 seconds. `Ok` when no process of the store
/// runs.
pub fn stop(store: Store) -> Result(Nil, StoreError) {
  case pid(store) {
    Error(Nil) -> Ok(Nil)
    Ok(pid) -> {
      let monitor = process.monitor(pid)
      let stopped = fn(within) {
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Ok(Nil) })
        |> process.selector_receive(within)
        |> result.unwrap(Error(Unavailable("the store did not stop in time")))
      }
      // A store that is stopping already (its starter exited) may be gone
      // before it answers; its name then names no process, which a send
      // to it does not survive.
      let outcome = case bounded.call(5000, fn() { call(store, ReadStopper) }) {
        Ok(Ok(Some(stop))) -> {
          process.send(stop, Nil)
          stopped(store.drain + 10_000)
        }
        Ok(Ok(None)) ->
          Error(Unavailable(
            "the store runs under a supervisor: stop the supervisor",
          ))
        Ok(Error(_)) | Error(_) -> stopped(store.drain + 10_000)
      }
      process.demonitor_process(monitor)
      outcome
    }
  }
}

/// Waits, up to 5000 ms, until the runner factory of an earlier subtree of
/// the store `name` is gone, when no store process of that name runs: the
/// store's process stops at once when its starter exits, and its factory
/// only after it, so a script that starts the store again right away
/// would find the factory's name taken.
fn await_earlier_factory(name: Name(Message)) -> Nil {
  case process.named(name), process.named(factory_name(name)) {
    Error(Nil), Ok(factory) -> {
      let monitor = process.monitor(factory)
      let _ =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Nil })
        |> process.selector_receive(5000)
      process.demonitor_process(monitor)
    }
    _, _ -> Nil
  }
}

/// Holds a started subtree until `caller` exits or `stop` is asked for, then
/// stops it; exits with the subtree if it stops first.
fn keep(caller: Pid, stop: Subject(Nil), subtree: Pid) -> Nil {
  let exit =
    process.new_selector()
    |> process.select_trapped_exits(Some)
    |> process.select_map(stop, fn(_) { None })
    |> process.selector_receive_forever
  case exit {
    // Stopped on request: the caller lives on, so it must not receive the
    // keeper's exit.
    None -> {
      process.unlink(caller)
      exit_shutdown()
    }
    Some(exit) ->
      case exit.pid == caller, exit.reason {
        // The keeper outlives the subtree: once the processes linked to a
        // dead caller are gone, so is the store, and its name is free.
        True, _ -> {
          shut_down(subtree)
          exit_shutdown()
        }
        False, process.Normal -> exit_shutdown()
        False, process.Killed -> process.kill(process.self())
        False, process.Abnormal(reason) -> exit_with(reason)
      }
  }
}

/// The caller of `start`: the store's process stops when it exits, reports
/// a failure to start to `failed`, and hands `stop` to `stop`.
type Starter {
  Starter(caller: Pid, failed: Subject(String), stop: Subject(Nil))
}

@external(erlang, "fabric_ffi", "exit_shutdown")
fn exit_shutdown() -> Nil

/// Stops the supervisor `pid`, which this process started, as its parent
/// does, and waits until it has stopped.
@external(erlang, "fabric_ffi", "shut_down")
fn shut_down(pid: Pid) -> Nil

@external(erlang, "erlang", "exit")
fn exit_with(reason: dynamic.Dynamic) -> Nil

/// The store's process first, then the reporter and runner factory, so that
/// runners stop before reporting and the process they commit through. Last
/// a sentinel, which
/// stops first and tells the store's process that its runners are about
/// to drain, before any runner is told. With a `starter`, the store's
/// process stops when it exits and reports a failure to start to its
/// subject.
fn subtree(
  store: Store,
  starter: Option(Starter),
  restart: supervision.Restart,
) -> static_supervisor.Builder {
  let store = Store(..store, pinned: None)
  let factory = factory_name(store.name)
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.restart_tolerance(intensity: 3, period: 5)
  |> static_supervisor.add(
    supervision.worker(fn() {
      case run(store, starter) {
        Ok(started) -> Ok(actor.Started(started.pid, Nil))
        Error(error) -> {
          option.map(starter, fn(starter) {
            process.send(starter.failed, describe_start(error))
          })
          Error(error)
        }
      }
    })
    |> supervision.timeout(ms: 5000)
    |> supervision.restart(restart),
  )
  |> static_supervisor.add(
    supervision.worker(fn() { drain_reporter(store) })
    |> supervision.timeout(ms: 3000)
    |> supervision.restart(restart),
  )
  |> static_supervisor.add(
    // Runners are temporary: one that stops is never restarted, since
    // recovery is explicit. Each is given the drain window to stop.
    factory_supervisor.worker_child(fn(spawn: fn(Pid) -> Pid) {
      let factory = process.self()
      let runner = spawn(factory)
      case call(store, TrackRunner(factory, runner, _)) {
        Ok(Nil) -> Ok(actor.Started(runner, Nil))
        Error(_) -> {
          process.unlink(runner)
          process.kill(runner)
          Error(actor.InitFailed("the store stopped before runner registration"))
        }
      }
    })
    |> factory_supervisor.restart_strategy(supervision.Temporary)
    |> factory_supervisor.timeout(ms: store.drain)
    |> factory_supervisor.named(factory)
    |> factory_supervisor.supervised,
  )
  |> static_supervisor.add(
    supervision.worker(fn() { sentinel(store.name, factory) })
    |> supervision.restart(restart),
  )
}

/// A process that does nothing until its supervisor stops it, and then
/// tells the store's process (`name`) that the runners of `factory` are
/// about to drain: it stops before the factory, so the store's process
/// hands the factory out no more before any runner receives its shutdown.
fn sentinel(
  name: Name(Message),
  factory: Name(FactoryMessage),
) -> Result(actor.Started(Nil), actor.StartError) {
  let ready = process.new_subject()
  let pid =
    process.spawn(fn() {
      process.trap_exits(True)
      process.send(ready, Nil)
      let exit =
        process.new_selector()
        |> process.select_trapped_exits(fn(exit) { exit })
        |> process.selector_receive_forever
      // The store's process may be gone already (it failed to start), or be
      // exiting with its starter: its exit ends the wait, so a restart does
      // not find the factory's name held for the whole bound.
      case process.named(factory), process.named(name) {
        Ok(pid), Ok(store_process) -> {
          let down = process.monitor(store_process)
          let reply = process.new_subject()
          process.send(process.named_subject(name), BeginDrain(pid, reply))
          let _ =
            process.new_selector()
            |> process.select(reply)
            |> process.select_specific_monitor(down, fn(_) { Nil })
            |> process.selector_receive(1000)
          process.demonitor_process(down)
          Nil
        }
        _, _ -> Nil
      }
      case exit.reason {
        process.Normal -> Nil
        process.Killed -> process.kill(process.self())
        process.Abnormal(reason) -> exit_with(reason)
      }
    })
  process.receive_forever(ready)
  Ok(actor.Started(pid, Nil))
}

/// This worker stops after the factory and before the store. Both accounting
/// and observation are bounded, even when the store or a handler is stuck.
fn drain_reporter(
  store: Store,
) -> Result(actor.Started(Nil), actor.StartError) {
  let ready = process.new_subject()
  let pid =
    process.spawn(fn() {
      process.trap_exits(True)
      process.send(ready, Nil)
      let exit =
        process.new_selector()
        |> process.select_trapped_exits(fn(exit) { exit })
        |> process.selector_receive_forever
      let report = bounded.call(1250, fn() { call(store, ReportDrain) })
      let _ =
        bounded.call(1000, fn() {
          case report {
            Ok(Ok(Ok(summary))) ->
              observe.drained(summary, name_text(store.name))
            _ -> observe.drain_unavailable(name_text(store.name))
          }
        })
      case exit.reason {
        process.Normal -> Nil
        process.Killed -> process.kill(process.self())
        process.Abnormal(reason) -> exit_with(reason)
      }
    })
  process.receive_forever(ready)
  Ok(actor.Started(pid, Nil))
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
pub type Live {
  /// `root` and `correlation` name the run's family in the events the
  /// store emits about it (`lease_lost`).
  Live(
    incarnation: Int,
    mailbox: Subject(live.Message),
    root: String,
    correlation: Correlation,
  )
  GraphLive(
    incarnation: Int,
    mailbox: Subject(graph_live.Message),
    root: String,
    correlation: Correlation,
  )
}

pub type Entry {
  Entry(revision: Int, record: String, live: Option(Live), holding: Holding)
}

/// Who holds a run's lease, as this store's process sees it.
pub type Holding {
  /// No one holds it, or the store is not leased.
  Unheld
  HeldHere
  /// Another owner holds it; `live` is `False` when it expired, and when
  /// it belongs to an earlier process of this store (same node and name),
  /// which is gone.
  HeldElsewhere(owner: String, live: Bool)
}

/// What a commit does to the run's live runner registration and, in a
/// leased store, to its lease.
pub type Ownership {
  /// A runner's commit that keeps the run: in a leased store only while
  /// this store holds its lease (`Hold`).
  Keep
  /// The committing runner `Pid` gives the run up in the same step, so a
  /// watcher woken by this commit already sees no runner; nothing is left
  /// in flight (`Release`).
  Leave(Pid)
  /// A confirmed idle record releases its runner/lease and registers deployed
  /// recovery code for changes to any dependency. The registration is local;
  /// the durable record remains authoritative after any missed notification.
  Park(dependencies: List(String), wake: fn() -> WakeupDisposition)
  /// The committing runner `Pid` hands the run off with work in flight: the
  /// lease is released as already expired.
  HandOff(Pid)
  /// A new runner takes the run over in the same step (`Claim`, or
  /// `Seize` for a cancellation, which wins over a live lease).
  Launch(Pid, Live, seize: Bool)
  /// A commit by no runner: of work nobody drives yet (`in_flight`; the
  /// lease is claimed, or seized, as already expired) or of none (the
  /// lease is released).
  Detached(in_flight: Bool, seize: Bool)
}

pub type WakeupDisposition {
  KeepWatching
  StopWatching
}

/// The store's process: the one registered under its name, or for a
/// pinned store the process it is pinned to, while it runs.
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
pub type FactoryMessage =
  factory_supervisor.Message(fn(Pid) -> Pid, Nil)

/// The factory runners are started under.
pub type Factory =
  factory_supervisor.Supervisor(fn(Pid) -> Pid, Nil)

/// The factory's name for a store named `name`: the name's text followed
/// by `$runners`, a suffix no store name should end with. Made when the
/// store's subtree starts, never for a `Store` value that only sends
/// requests.
@external(erlang, "fabric_ffi", "factory_name")
fn factory_name(name: Name(Message)) -> Name(FactoryMessage)

/// `store` pinned to the process registered under its name now, with that
/// process's runner factory and the factory's process. Every call through
/// the pinned store reaches that process or, once it stopped, fails as a
/// stopped store would, even after a supervisor registers another process
/// under the name. A runner uses its store pinned to the process it
/// monitors. `Error` when no store process runs, or its factory takes no
/// runners (it is shutting down).
pub fn runners(store: Store) -> Result(#(Store, Factory, Pid), Nil) {
  case call(store, Runners) {
    Ok(Ok(#(subject, factory, pid))) ->
      Ok(#(
        Store(..store, pinned: Some(subject)),
        factory_supervisor.get_by_name(factory),
        pid,
      ))
    _ -> Error(Nil)
  }
}

/// Starts a runner under `factory`: `spawn` runs in the factory's process,
/// is given its pid, and must spawn the runner linked to it. `Error` when
/// the factory is not running or stops meanwhile.
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
pub fn draining(store: Store, factory: Pid) -> Nil {
  process.send(target(store), Draining(factory))
}

/// Also covers an encoding failure before a handoff reaches the write port.
pub fn handoff_failed(store: Store, runner: Pid) -> Nil {
  process.send(target(store), HandoffFailed(runner))
}

/// Where requests to the store's process go.
fn target(store: Store) -> Subject(Message) {
  case store.pinned {
    Some(subject) -> subject
    None -> process.named_subject(store.name)
  }
}

pub fn get(store: Store, run: String) -> Result(Entry, StoreError) {
  call(store, Get(run, _)) |> result.flatten
}

/// Inserts revision 1 of `run`.
pub fn insert(
  store: Store,
  run: String,
  record: String,
  ownership: Ownership,
) -> Result(Int, StoreError) {
  call(store, Write(run, None, record, ownership, _)) |> result.flatten
}

/// Commits `record` over `expected` and returns the new revision.
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

/// Serializes scheduled reads within this store's lease owner. A reservation
/// is local only: the caller must re-read and check the durable claim before
/// observing. Caller loss releases this reservation, never the durable claim.
pub fn reserve_job_observation(
  store: Store,
  run: String,
) -> Result(Bool, StoreError) {
  call(store, ReserveJobObservation(run, process.self(), _))
}

pub fn release_job_observation(store: Store, run: String) -> Nil {
  process.send(target(store), ReleaseJobObservation(run, process.self()))
}

/// Sends `Nil` to `watcher` after every commit of `run` through this store
/// and whenever its runner exits, until `unwatch` or the watcher's owner
/// exits.
pub fn watch(
  store: Store,
  run: String,
  watcher: Subject(Nil),
) -> Result(Nil, StoreError) {
  call(store, Watch(run, watcher, _))
}

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

/// An unleased backend as a leased one that never holds a lease: its
/// writes ignore the lease, and nothing is renewed or claimed.
fn unleased(backend: Backend) -> LeasedBackend {
  LeasedBackend(
    now: fn() { Ok(system_time_ms()) },
    get: fn(run) {
      backend.get(run)
      |> result.map(fn(stored) { Current(stored.revision, stored.record, Free) })
    },
    insert: fn(run, record, _) { backend.insert(run, record) },
    compare_and_set: fn(run, expected, record, _) {
      backend.compare_and_set(run, expected, record)
    },
    renew: fn(_, _, _) { Ok([]) },
    claim_expired: fn(_, _, _) { Ok([]) },
    claim_ready: fn(_, _, _) { Ok([]) },
  )
}

/// A leased store process's side of its leases.
type Lessee {
  Lessee(
    /// `<node>/<store name>/<random>`, new each time the process starts.
    owner: String,
    ttl: Int,
  )
}

type Done {
  Got(Result(Current, StoreError))
  /// `sent`: the monotonic time the write was sent to the backend.
  Wrote(Result(Int, StoreError), sent: Int)
}

type Loop {
  Loop(
    /// This process's own subject for its workers' reports: unlike the
    /// named subject, it never reaches a later process of the same name.
    subject: Subject(Message),
    backend: LeasedBackend,
    /// A leased store's owner token and lease duration.
    lessee: Option(Lessee),
    live: Dict(String, #(Pid, Live)),
    /// A leased store: per run with a live runner, the monotonic time until
    /// which its lease is surely held (see `valid_until`).
    valid: Dict(String, Int),
    renewal: Renewal,
    last_renewal: Option(Int),
    /// When the next `Fence` is due, if one is set.
    fence_at: Option(Int),
    /// The name of the factory its runners are started under.
    factory: Name(FactoryMessage),
    /// The runner factory process that reported it is shutting down.
    draining: Option(Pid),
    drain: drain.Accounting,
    drain_reply: Option(Subject(Result(o.Drain, Nil))),
    watchers: Dict(String, List(#(Pid, Subject(Nil)))),
    wakeups: Dict(String, Wakeup),
    job_observations: Dict(String, Pid),
    monitored: List(Pid),
    /// Per run: the request whose backend call is in flight, and the
    /// requests waiting behind it, oldest first.
    busy: Dict(String, #(Message, List(Message))),
    timeout: Int,
    /// The process that started this one with `start`: this one stops
    /// when it exits.
    starter: Option(Pid),
    /// What stops the subtree of a store started with `start`; `None` under
    /// a supervisor.
    stop: Option(Subject(Nil)),
  )
}

type Wakeup {
  Wakeup(
    dependencies: List(String),
    token: String,
    callback: fn() -> WakeupDisposition,
    status: WakeStatus,
  )
}

type WakeStatus {
  Dormant
  Waking(again: Bool)
}

/// Whether a renewal of a leased store is in flight.
type Renewal {
  Idle
  /// `missed`: a tick came while it was in flight, so another renewal is
  /// sent as soon as it completes.
  Sending(missed: Bool)
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
  starter: Option(Starter),
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(default_backend_timeout, fn(named) {
    use backend <- result.map(store.open())
    option.map(starter, fn(starter) { process.monitor(starter.caller) })
    let subject = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(named)
      |> process.select(subject)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid:, reason:, ..) -> Down(pid, reason)
          process.PortDown(reason:, ..) -> Down(process.self(), reason)
        }
      })
    let lessee =
      option.map(store.leasing, fn(leasing) {
        Lessee(
          leasing.node <> "/" <> name_text(store.name) <> "/" <> random_id(),
          leasing.ttl,
        )
      })
    option.map(lessee, fn(lessee) {
      process.send_after(subject, lessee.ttl / 3, Renew(True))
    })
    Loop(
      subject:,
      backend:,
      lessee:,
      live: dict.new(),
      valid: dict.new(),
      renewal: Idle,
      last_renewal: None,
      fence_at: None,
      factory: factory_name(store.name),
      draining: None,
      drain: drain.new(),
      drain_reply: None,
      watchers: dict.new(),
      wakeups: dict.new(),
      job_observations: dict.new(),
      monitored: [],
      busy: dict.new(),
      timeout: default_backend_timeout,
      starter: option.map(starter, fn(starter) { starter.caller }),
      stop: option.map(starter, fn(starter) { starter.stop }),
    )
    |> actor.initialised
    |> actor.selecting(selector)
  })
  |> actor.named(store.name)
  |> actor.on_message(fn(state, message) {
    case message {
      Down(pid, _) if state.starter == Some(pid) -> actor.stop()
      _ -> actor.continue(serve(state, message) |> finish_drain_report(False))
    }
  })
  |> actor.start
}

/// Sets how long one backend call may take (default 5000 ms). For tests.
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
    ReserveJobObservation(run, caller, reply) -> {
      let available =
        state.draining == None && !dict.has_key(state.job_observations, run)
      process.send(reply, available)
      case available {
        False -> state
        True ->
          Loop(
            ..monitor(state, caller),
            job_observations: dict.insert(state.job_observations, run, caller),
          )
      }
    }
    ReleaseJobObservation(run, caller) ->
      case dict.get(state.job_observations, run) {
        Ok(owner) if owner == caller ->
          Loop(
            ..state,
            job_observations: dict.delete(state.job_observations, run),
          )
        _ -> state
      }
    Wake(run, token) -> wake(state, run, token)
    Awoke(run, token, disposition) -> {
      case dict.get(state.wakeups, run) {
        Ok(Wakeup(token: current, ..))
          if token == current && disposition == StopWatching
        -> Loop(..state, wakeups: dict.delete(state.wakeups, run))
        Ok(Wakeup(token: current, status: Waking(again), ..) as wakeup)
          if token == current
        -> {
          case again {
            True -> process.send(state.subject, Wake(run, token))
            False -> Nil
          }
          Loop(
            ..state,
            wakeups: dict.insert(
              state.wakeups,
              run,
              Wakeup(..wakeup, status: Dormant),
            ),
          )
        }
        _ -> state
      }
    }
    SetTimeout(milliseconds) -> Loop(..state, timeout: milliseconds)
    Runners(reply) -> {
      process.send(reply, case process.named(state.factory) {
        Ok(pid) if state.draining != Some(pid) ->
          Ok(#(state.subject, state.factory, pid))
        _ -> Error(Nil)
      })
      state
    }
    Draining(pid) -> begin_drain(state, pid)
    BeginDrain(pid, reply) -> {
      let state = begin_drain(state, pid)
      process.send(reply, Nil)
      state
    }
    TrackRunner(factory, runner, reply) -> {
      let state =
        Loop(
          ..monitor(state, runner),
          drain: drain.track(state.drain, factory, runner),
        )
      process.send(reply, Nil)
      state
    }
    HandoffFailed(runner) ->
      Loop(..state, drain: drain.handoff(state.drain, runner, drain.Failed))
    ReportDrain(reply) -> {
      let _ = process.send_after(state.subject, 1000, CompleteDrainReport)
      Loop(..state, drain_reply: Some(reply))
    }
    CompleteDrainReport -> finish_drain_report(state, True)
    ReadReadiness(reply) -> {
      process.spawn(fn() {
        let checked =
          bounded_backend(state.timeout, fn() {
            case state.backend.get("fabric-readiness-" <> random_id()) {
              Ok(_) | Error(NotFound) -> Ok(Nil)
              Error(error) -> Error(error)
            }
          })
        process.send(state.subject, ReadinessChecked(reply, checked))
      })
      state
    }
    ReadinessChecked(reply, checked) -> {
      process.send(
        reply,
        result.map(checked, fn(_) { report_readiness(state) }),
      )
      state
    }
    ReadStopper(reply) -> {
      process.send(reply, state.stop)
      state
    }
    ReadClock(reply) -> {
      process.spawn(fn() {
        process.send(reply, bounded_backend(state.timeout, state.backend.now))
      })
      state
    }
    ClaimExpired(limit, reply) as request
    | ClaimReady(limit, reply) as request -> {
      case state.lessee, state.draining {
        Some(lessee), None -> {
          let claim = case request {
            ClaimExpired(..) -> state.backend.claim_expired
            _ -> state.backend.claim_ready
          }
          process.spawn(fn() {
            process.send(
              reply,
              bounded_backend(state.timeout, fn() {
                claim(lessee.owner, lessee.ttl, limit)
              }),
            )
          })
          Nil
        }
        _, _ ->
          process.send(reply, Error(Unavailable("the store cannot sweep")))
      }
      state
    }
    Renew(tick) -> renew(state, tick)
    ReadRenewing(reply) -> {
      process.send(reply, state.renewal != Idle)
      state
    }
    Renewed(sent, runs, renewed) -> renewed_leases(state, sent, runs, renewed)
    Fence -> Loop(..state, fence_at: None) |> fence |> schedule_fence
    Get(run, ..) as request -> enqueue(state, run, request)
    Write(run, ownership:, ..) as request -> {
      let state = case ownership {
        HandOff(runner) ->
          Loop(
            ..state,
            drain: drain.handoff(state.drain, runner, drain.Pending),
          )
        _ -> state
      }
      enqueue(state, run, request)
    }
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
    Down(pid, reason) -> {
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
          drain: drain.exited(state.drain, pid, case reason {
            process.Killed -> drain.Killed
            process.Normal | process.Abnormal(_) -> drain.Exited
          }),
          live:,
          valid: dict.drop(state.valid, released),
          watchers:,
          job_observations: dict.filter(state.job_observations, fn(_, owner) {
            owner != pid
          }),
          monitored: list.filter(state.monitored, fn(p) { p != pid }),
        )
      list.each(released, notify(state, _))
      state
    }
  }
}

fn begin_drain(state: Loop, factory: Pid) -> Loop {
  Loop(
    ..state,
    draining: Some(factory),
    drain: drain.begin(state.drain, factory, now_ms()),
  )
}

fn finish_drain_report(state: Loop, deadline: Bool) -> Loop {
  case state.drain_reply {
    None -> state
    Some(reply) ->
      case drain.report(state.drain, now_ms()) {
        None -> {
          process.send(reply, Error(Nil))
          Loop(..state, drain_reply: None)
        }
        Some(summary)
          if deadline
          || { summary.pending_handoffs == 0 && summary.unobserved == 0 }
        -> {
          process.send(reply, Ok(summary))
          Loop(..state, drain_reply: None)
        }
        Some(_) -> state
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
  let lessee = state.lessee
  let _ =
    process.spawn(fn() {
      let done = case request {
        Write(expected:, record:, ownership:, ..) -> {
          let revision = case expected {
            None -> 1
            Some(expected) -> expected + 1
          }
          let sent = now_ms()
          let lease = lease_for(lessee, ownership)
          bounded_backend(timeout, fn() {
            case expected {
              None -> backend.insert(run, record, lease)
              Some(expected) ->
                case
                  backend.compare_and_set(run, expected, record, lease),
                  lease,
                  lessee
                {
                  // The lease of an earlier process of this store, which is
                  // gone, is taken at once.
                  Error(LeaseRefused(Held(holder, _))) as refused,
                    Claim(owner, ttl),
                    Some(lessee)
                  ->
                    case earlier_self(lessee.owner, holder) {
                      True ->
                        backend.compare_and_set(
                          run,
                          expected,
                          record,
                          Seize(owner, ttl),
                        )
                      False -> refused
                    }
                  written, _, _ -> written
                }
            }
          })
          |> result.replace(revision)
          |> confirm(backend, timeout, run, revision, record)
          |> Wrote(sent)
        }
        _ -> Got(bounded_backend(timeout, fn() { backend.get(run) }))
      }
      process.send(subject, Finished(run, done))
    })
  Nil
}

/// The lease change of a commit with `ownership` for a leased store's
/// process (`lessee`); an unleased backend ignores it.
fn lease_for(lessee: Option(Lessee), ownership: Ownership) -> Lease {
  case lessee {
    None -> Release
    Some(Lessee(owner:, ttl:)) ->
      case ownership {
        Keep -> Hold(owner)
        Leave(_) | Park(..) | Detached(in_flight: False, ..) -> Release
        HandOff(_) | Detached(in_flight: True, seize: False) -> Claim(owner, 0)
        Detached(in_flight: True, seize: True) -> Seize(owner, 0)
        Launch(seize: False, ..) -> Claim(owner, ttl)
        Launch(seize: True, ..) -> Seize(owner, ttl)
      }
  }
}

/// Whether `other` is the owner token of an earlier process of the store
/// whose token is `me`: the same node and store name, another random
/// part. A store's name is registered by one process at a time, and a node
/// id names one VM, so that process is gone.
fn earlier_self(me: String, other: String) -> Bool {
  case token_parts(me), token_parts(other) {
    Ok(#(node, name, random)), Ok(#(other_node, other_name, other_random)) ->
      node == other_node && name == other_name && random != other_random
    _, _ -> False
  }
}

/// A token's node, store name, and random part: the node has no `/`, and
/// the random part is after the last one.
fn token_parts(token: String) -> Result(#(String, String, String), Nil) {
  use #(node, rest) <- result.try(string.split_once(token, "/"))
  case list.reverse(string.split(rest, "/")) {
    [random, first, ..others] ->
      Ok(#(node, string.join(list.reverse([first, ..others]), "/"), random))
    _ -> Error(Nil)
  }
}

/// How this store's process sees `holder`.
fn holding(lessee: Option(Lessee), holder: Holder) -> Holding {
  case lessee, holder {
    None, _ | _, Free -> Unheld
    Some(lessee), Held(owner, live) ->
      case owner == lessee.owner {
        True -> HeldHere
        False ->
          HeldElsewhere(owner, live && !earlier_self(lessee.owner, owner))
      }
  }
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
            result.map(got, fn(current) {
              Entry(
                current.revision,
                current.record,
                dict.get(state.live, run)
                  |> result.map(fn(l) { l.1 })
                  |> option.from_result,
                holding(state.lessee, current.holder),
              )
            }),
          )
          state
        }
        Write(ownership:, reply:, ..), Wrote(written, sent) -> {
          let state = case ownership {
            HandOff(runner) ->
              Loop(
                ..state,
                drain: drain.handoff(state.drain, runner, case written {
                  Ok(_) -> drain.Confirmed
                  Error(_) -> drain.Failed
                }),
              )
            _ -> state
          }
          process.send(reply, written)
          case written {
            Error(_) -> state
            Ok(_) -> {
              let state = own(state, run, ownership, sent)
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
  backend: LeasedBackend,
  timeout: Int,
  run: String,
  revision: Int,
  record: String,
) -> Result(Int, StoreError) {
  case written {
    Error(Unavailable(_)) ->
      case bounded_backend(timeout, fn() { backend.get(run) }) {
        Ok(Current(found, stored, _)) if found == revision && stored == record ->
          Ok(revision)
        _ -> written
      }
    _ -> written
  }
}

/// Applies a committed write's ownership. A write sent at `sent` that
/// claimed a lease holds it until `valid_until(sent)`.
fn own(state: Loop, run: String, ownership: Ownership, sent: Int) -> Loop {
  let state = Loop(..state, wakeups: dict.delete(state.wakeups, run))
  case ownership {
    Park(dependencies, callback) -> {
      let token = random_id()
      // Read after registration, even if the dependency changed before the
      // parent parked. This message is handled after the confirmed write.
      process.send(state.subject, Wake(run, token))
      Loop(
        ..state,
        live: dict.delete(state.live, run),
        valid: dict.delete(state.valid, run),
        wakeups: dict.insert(
          state.wakeups,
          run,
          Wakeup(dependencies, token, callback, Dormant),
        ),
      )
    }
    Keep | Detached(..) -> state
    Leave(pid) | HandOff(pid) ->
      case dict.get(state.live, run) {
        Ok(#(owner, _)) if owner == pid ->
          Loop(
            ..state,
            live: dict.delete(state.live, run),
            valid: dict.delete(state.valid, run),
          )
        _ -> state
      }
    Launch(pid, live, _) -> {
      let state =
        Loop(
          ..monitor(state, pid),
          live: dict.insert(state.live, run, #(pid, live)),
        )
      case state.lessee {
        None -> state
        Some(lessee) ->
          Loop(
            ..state,
            valid: dict.insert(state.valid, run, valid_until(lessee, sent)),
          )
          |> schedule_fence
      }
    }
  }
}

// --- leases ------------------------------------------------------------------

/// Until when a lease extended by a write or renewal sent at `sent` is
/// surely held, by this process's monotonic clock: the backend set its
/// expiry after `sent`, `ttl` ahead by its own clock, and a margin of a
/// fifth of the lease covers the clocks' drift and the kill's delay.
fn valid_until(lessee: Lessee, sent: Int) -> Int {
  sent + lessee.ttl - lessee.ttl / 5
}

/// Raw facts about the store's process, from which `fabric/store.readiness`
/// derives its report.
pub type Report {
  Report(
    draining: Bool,
    factory_running: Bool,
    /// Every local runner of a leased store is inside a confirmed lease
    /// window; `True` for an unleased store.
    leases_confirmed: Bool,
    runners: Int,
    /// A leased store's lease duration and the age of its last successful
    /// renewal, both in milliseconds; `None` for an unleased store.
    lease: Option(#(Int, Option(Int))),
  )
}

fn report_readiness(state: Loop) -> Report {
  let now = now_ms()
  let lease =
    option.map(state.lessee, fn(lessee) {
      #(
        lessee.ttl,
        option.map(state.last_renewal, fn(at) { int.max(now - at, 0) }),
      )
    })
  let leases_confirmed = case state.lessee {
    None -> True
    Some(_) ->
      dict.fold(state.live, True, fn(ok, run, _) {
        ok
        && case dict.get(state.valid, run) {
          Ok(until) -> until > now
          Error(_) -> False
        }
      })
  }
  Report(
    draining: option.is_some(state.draining),
    factory_running: result.is_ok(process.named(state.factory)),
    leases_confirmed:,
    runners: dict.size(state.live),
    lease:,
  )
}

/// Sends one renewal of the leases of every live runner, unless one is in
/// flight; on the timer's tick, also sets the next one and kills the
/// runners whose lease could have expired. A tick that finds a renewal in
/// flight is made up when that renewal completes.
fn renew(state: Loop, tick: Bool) -> Loop {
  case state.lessee {
    None -> state
    Some(lessee) -> {
      let state = case tick {
        True -> {
          process.send_after(state.subject, lessee.ttl / 3, Renew(True))
          fence(state)
        }
        False -> state
      }
      let runs =
        dict.to_list(state.live)
        |> list.map(fn(entry) { #(entry.0, entry.1.0) })
      case state.renewal, runs {
        Sending(_), _ if tick -> Loop(..state, renewal: Sending(True))
        Sending(_), _ | Idle, [] -> state
        Idle, _ -> {
          let backend = state.backend
          let subject = state.subject
          // A renewal slower than a third of the lease is as good as failed;
          // the next tick sends another.
          let timeout = int.min(state.timeout, int.max(lessee.ttl / 3, 1))
          let _ =
            process.spawn(fn() {
              let sent = now_ms()
              let renewed =
                bounded_backend(timeout, fn() {
                  backend.renew(
                    lessee.owner,
                    list.map(runs, fn(run) { run.0 }),
                    lessee.ttl,
                  )
                })
              process.send(subject, Renewed(sent, runs, renewed))
            })
          Loop(..state, renewal: Sending(False))
        }
      }
    }
  }
}

/// A renewal finished: each run it renewed is held a lease longer, and the
/// runner of each run it did not is killed, unless that runner is gone.
fn renewed_leases(
  state: Loop,
  sent: Int,
  runs: List(#(String, Pid)),
  renewed: Result(List(String), StoreError),
) -> Loop {
  let missed = state.renewal == Sending(True)
  let state = Loop(..state, renewal: Idle)
  let state = case state.lessee, renewed {
    None, _ -> state
    Some(lessee), Error(_) -> {
      let runs = list.length(runs)
      emit_apart(fn() { observe.renewal_failed(lessee.owner, runs) })
      state
    }
    Some(lessee), Ok(held) ->
      list.fold(runs, Loop(..state, last_renewal: Some(sent)), fn(state, entry) {
        let #(run, pid) = entry
        case dict.get(state.live, run), list.contains(held, run) {
          Ok(#(current, _)), True if current == pid ->
            Loop(
              ..state,
              valid: dict.upsert(state.valid, run, fn(valid) {
                int.max(option.unwrap(valid, 0), valid_until(lessee, sent))
              }),
            )
          Ok(#(current, live)), False if current == pid ->
            lose(state, lessee, run, pid, live, o.Revoked)
          _, _ -> state
        }
      })
      |> schedule_fence
  }
  case missed {
    True -> renew(state, False)
    False -> state
  }
}

/// Kills the runner of every run whose lease could have expired.
fn fence(state: Loop) -> Loop {
  case state.lessee {
    None -> state
    Some(lessee) -> {
      let now = now_ms()
      dict.fold(state.valid, state, fn(state, run, valid) {
        case valid <= now, dict.get(state.live, run) {
          True, Ok(#(pid, live)) ->
            lose(state, lessee, run, pid, live, o.Unrenewed)
          _, _ -> state
        }
      })
    }
  }
}

/// Sets a `Fence` for the earliest time a lease could expire, unless one
/// is set for an earlier time.
fn schedule_fence(state: Loop) -> Loop {
  let earliest =
    dict.values(state.valid)
    |> list.reduce(int.min)
  case earliest, state.fence_at {
    Error(Nil), _ -> state
    Ok(at), Some(set) if set <= at -> state
    Ok(at), _ -> {
      process.send_after(state.subject, int.max(at - now_ms(), 0), Fence)
      Loop(..state, fence_at: Some(at))
    }
  }
}

/// Kills the runner `pid` of `run`, whose lease this store lost, and with
/// it its model call and tool bodies (they are linked to it).
fn lose(
  state: Loop,
  lessee: Lessee,
  run: String,
  pid: Pid,
  live: Live,
  reason: o.LeaseLoss,
) -> Loop {
  process.kill(pid)
  let state =
    Loop(
      ..state,
      live: dict.delete(state.live, run),
      valid: dict.delete(state.valid, run),
    )
  notify(state, run)
  emit_apart(fn() {
    observe.lease_lost(run, lessee.owner, reason, live.root, live.correlation)
  })
  state
}

/// Emits an event of the store's own from a process of its own, so that
/// a slow handler holds up no request, renewal or fence of the store.
fn emit_apart(emit: fn() -> Nil) -> Nil {
  let _ = process.spawn_unlinked(emit)
  Nil
}

/// How often a wait on a run of a leased store reads the run again, since
/// another node's commits wake no watcher here: a third of the lease, at
/// least 10 and at most 1000 ms. `None` for an unleased store.
pub fn poll_interval(store: Store) -> Option(Int) {
  option.map(store.leasing, fn(leasing) {
    int.clamp(leasing.ttl / 3, min: 10, max: 1000)
  })
}

/// Sends the store's process a renewal now, for tests.
pub fn renew_now(store: Store) -> Nil {
  process.send(target(store), Renew(False))
}

/// Sends the store's process its renewal timer's tick now, for tests that
/// must not depend on when the timer fires.
pub fn tick_now(store: Store) -> Nil {
  process.send(target(store), Renew(True))
}

/// Whether the store has a renewal in flight, for tests that must wait
/// until one completed rather than for a while.
pub fn renewing(store: Store) -> Result(Bool, Nil) {
  call(store, ReadRenewing) |> result.replace_error(Nil)
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
  dict.each(state.wakeups, fn(parent, wakeup) {
    case list.contains(wakeup.dependencies, run) {
      True -> process.send(state.subject, Wake(parent, wakeup.token))
      False -> Nil
    }
  })
}

/// Each dependency registration runs at most one bounded check at a time.
/// The worker is linked to the store, while bounded catches callback crashes
/// and kills its callback if either the worker or store disappears.
fn wake(state: Loop, run: String, token: String) -> Loop {
  case dict.get(state.wakeups, run), state.draining {
    Ok(wakeup), None if wakeup.token == token -> {
      let status = case wakeup.status {
        Waking(_) -> Waking(True)
        Dormant -> {
          let subject = state.subject
          let timeout = state.timeout
          let callback = wakeup.callback
          process.spawn(fn() {
            let disposition =
              bounded.call(timeout, callback) |> result.unwrap(KeepWatching)
            process.send(subject, Awoke(run, token, disposition))
          })
          Waking(False)
        }
      }
      Loop(
        ..state,
        wakeups: dict.insert(state.wakeups, run, Wakeup(..wakeup, status:)),
      )
    }
    _, _ -> state
  }
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

@external(erlang, "fabric_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "fabric_ffi", "system_time_ms")
fn system_time_ms() -> Int

@external(erlang, "fabric_ffi", "random_id")
fn random_id() -> String

@external(erlang, "erlang", "atom_to_binary")
fn name_text(name: Name(Message)) -> String

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

/// Reserves at most `limit` expired runs for this store process. A sweeper
/// uses a pinned store, so a delayed response never reaches a new owner.
pub fn claim_expired(
  store: Store,
  limit: Int,
) -> Result(List(String), StoreError) {
  call(store, ClaimExpired(limit, _)) |> result.flatten
}

/// Claims idle dependencies through this pinned store's current owner.
pub fn claim_ready(
  store: Store,
  limit: Int,
) -> Result(List(String), StoreError) {
  call(store, ClaimReady(limit, _)) |> result.flatten
}

pub fn now(store: Store) -> Result(Int, StoreError) {
  call(store, ReadClock) |> result.flatten
}

pub fn readiness(store: Store) -> Result(Report, StoreError) {
  call(store, ReadReadiness) |> result.flatten
}

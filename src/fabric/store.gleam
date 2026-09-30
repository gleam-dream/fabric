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
//// Leases. A leased backend (`LeasedBackend`) keeps, next to each run's
//// record, a lease: an owner and an expiry judged by the backend's own
//// clock. Several nodes sharing one database use it to agree on which
//// node drives a run; the lease never authorizes a write, which the
//// revision alone decides. Its contract, over the one above:
////
//// - `get(run)` returns the record, its revision, and its `Holder`:
////   `Free`, or `Held(owner, live)`, `live` while the expiry is ahead.
//// - `insert(run, record, lease)` stores revision 1 with the lease of a
////   `Claim` or `Seize` (held by its owner for its `ttl`), and none for a
////   `Hold` or `Release`.
//// - `compare_and_set(run, expected, record, lease)` checks the revision
////   first (`NotFound`, `Conflict(current)`), then the lease condition in
////   the same atomic step: `Hold(owner)` only while `owner` holds the
////   lease (live or expired) and leaves it unchanged; `Claim(owner, ttl)`
////   only while the lease is free, held by `owner`, or expired; `Seize`
////   and `Release` whoever holds it. A refused condition is
////   `LeaseRefused(holder)` and writes nothing. After the write, a `Claim`
////   or `Seize` owner holds the lease for `ttl` and a `Release` frees it.
//// - `renew(owner, runs, ttl)` extends, to `ttl` from now, the lease of
////   each of `runs` that `owner` holds while it is still live, and
////   returns those runs. An expired lease is not renewed, so a renewal
////   sent before a handoff (which leaves the lease expired) and applied
////   after it does not make the lease live again. It changes no revision.
//// - `claim_expired(owner, ttl, limit)` claims for `owner` up to `limit`
////   runs whose lease is held and expired, and returns them. It changes
////   no revision, and concurrent calls never return the same run.
////
//// `fabric/testing.leased_backend_checks` checks a backend against this
//// contract; `fabric/testing.leased_memory` is one kept in memory, for
//// tests.
////
//// A `Store` value names a store process and starts nothing: it is plain
//// data that any process may hold and use. Start its subtree once: the
//// store's process and the factory its runners are started under, under
//// the application's supervisor (`supervised`) or owned by the caller
//// (`start`, for scripts and tests: it stops when the caller exits). The
//// process calls the backend one request at a time per run, tracks which
//// runner currently drives each run in this VM, and wakes `fabric.await`
//// on commits made through it. A run outlives the process that started
//// it, which only uses the store.
////
//// Runners stop when their store process stops, and never commit through
//// a later process registered under the same name. A restarted store
//// process (for example by its supervisor) knows no runner, so every run
//// with work in flight reads as `Unattended` until `fabric.recover` takes
//// it over. When the subtree shuts down, its runners drain before its
//// process stops (see `supervised`), and the runs they hand off read
//// `Unattended` too, with nothing uncertain. A suspended or finished run
//// has no runner, so a shutdown leaves it untouched. An in-memory store
//// keeps its records in its process, so a restart loses them; a directory
//// or application backend keeps them (the directory store only up to a
//// power loss: it is for development, tests, and one host). Several
//// stores may open the same backend (for example the same directory): the
//// backend's compare-and-set keeps their commits safe, but each unleased
//// store only knows its own runners. Several nodes that share one
//// database coordinate through leases instead (`leased`): a store knows
//// which node drives each run, and never takes over a run another node
//// drives.

import fabric/internal/bounded
import fabric/internal/controller
import fabric/internal/executor
import fabric/internal/graph/live as graph_live
import fabric/internal/live
import fabric/internal/observe
import fabric/internal/record
import fabric/observation as o
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
  /// A leased backend refused the write's lease condition (see Leases):
  /// `holder` is the run's lease as the backend found it. Nothing was
  /// written.
  LeaseRefused(holder: Holder)
  Unavailable(reason: String)
}

pub type Stored {
  Stored(revision: Int, record: String)
}

/// Who holds a run's lease in a leased backend.
pub type Holder {
  Free
  /// `live`: the lease's expiry, judged by the backend's clock, is still
  /// ahead.
  Held(owner: String, live: Bool)
}

/// A run's latest record in a leased backend, with its revision and lease.
pub type Current {
  Current(revision: Int, record: String, holder: Holder)
}

/// What a write in a leased backend does to the run's lease, in the same
/// atomic step as the record (see Leases). `ttl` is in milliseconds, from
/// the backend's clock.
pub type Lease {
  /// Only while `owner` holds the lease, live or expired; the lease is
  /// unchanged.
  Hold(owner: String)
  /// Only while the lease is free, held by `owner`, or expired; `owner`
  /// then holds it for `ttl`.
  Claim(owner: String, ttl: Int)
  /// Whoever holds the lease; `owner` then holds it for `ttl`.
  Seize(owner: String, ttl: Int)
  /// Whoever holds the lease; it is then free.
  Release
}

/// The functions of a leased backend over encoded records (see Leases).
pub type LeasedBackend {
  LeasedBackend(
    get: fn(String) -> Result(Current, StoreError),
    /// `insert(run, record, lease)`.
    insert: fn(String, String, Lease) -> Result(Nil, StoreError),
    /// `compare_and_set(run, expected, record, lease)`.
    compare_and_set: fn(String, Int, String, Lease) -> Result(Nil, StoreError),
    /// `renew(owner, runs, ttl)`: returns the runs renewed, those whose
    /// lease `owner` holds live.
    renew: fn(String, List(String), Int) -> Result(List(String), StoreError),
    /// `claim_expired(owner, ttl, limit)`: returns the runs claimed.
    claim_expired: fn(String, Int, Int) -> Result(List(String), StoreError),
  )
}

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

/// Why a leased store's settings were refused (`leased`).
pub type LeaseConfigError {
  /// A node id is 1 to 128 letters, digits, and `.`, `_`, `-`, `@` or
  /// `:`, and not `nonode@nohost`, which names no machine.
  InvalidNodeId(String)
  /// Shorter than the shortest lease a store renews (`minimum` ms).
  LeaseTooShort(value: Int, minimum: Int)
  /// Longer than the longest timer the runtime can set (`limit` ms).
  LeaseTooLong(value: Int, limit: Int)
}

/// Why a drain window was refused (`with_drain`).
pub type DrainError {
  DrainNotPositive(Int)
  /// Longer than the longest timer the runtime can set (`limit`, 2^32 - 1
  /// ms).
  DrainTooLarge(value: Int, limit: Int)
}

/// Versions this runtime can write without discarding state.
pub type UnwritableVersion {
  UnwritableVersion(requested: Int, oldest: Int, newest: Int)
}

/// Chooses the record format for writes through this Store value. The
/// default is 7; versions 2 through 7 can be written, and 1 through 7 read.
/// Configure before starting the store and use the returned value for
/// every handle and sweeper. Existing values and runners are unchanged.
///
/// During a rolling upgrade, select a version every node can read. Versions
/// 2 and 3 refuse assistant provider data, which requires version 4.
/// Graph parent links require version 5; terminal child settlement requires
/// version 6; family budgets require version 7. Upgrade all readers before selecting a newer writer.
/// Records are changed only by ordinary writes, never by this setting.
pub fn with_record_version(
  store: Store,
  version: Int,
) -> Result(Store, UnwritableVersion) {
  record.writer(version)
  |> result.map(fn(writer) { Store(..store, write_version: writer) })
  |> result.replace_error(UnwritableVersion(version, 2, record.version))
}

/// Encode once per logical write, before effects, and reuse the bytes on
/// retries so the write token still confirms exactly that attempt.
@internal
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
  Down(pid: Pid)
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
  /// A leased store renews the leases of its runners; `tick`: the timer's
  /// (which sets the next one), not a test's.
  Renew(tick: Bool)
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
}

/// A store over application-supplied backend functions (for example a
/// database table), registered as `name`. See the module documentation for
/// the contract. Its runner factory is registered as `name` followed by
/// `$runners`, so no store's name may end with that suffix.
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
    record.V7,
  )
}

/// A store that keeps records in its own process, registered as `name`.
/// They are lost when that process stops, also when a supervisor restarts
/// it.
pub fn in_memory(name: Name(Message)) -> Store {
  Store(
    name,
    fn() { Ok(unleased(memory_backend())) },
    None,
    default_drain,
    None,
    record.V7,
  )
}

/// A store in the directory `path`, registered as `name`, for development,
/// tests, and a single host: its records survive a process or VM crash,
/// but not a power loss or an operating-system crash (see Atomicity). In
/// production use `fabric_postgres` or an application database backend. The directory is created
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
    record.V7,
  )
}

/// A leased store over `backend`, registered as `name`, for several nodes
/// that share one database (see Leases in the module documentation). Its
/// process identifies itself to the backend as
/// `<node>/<name>/<random>`, with a new random part each time it starts;
/// `node` must be unique to the VM and the same after a restart. Names
/// made by `process.new_name` are unique only within a VM: two live VMs
/// sharing a node id can mistake each other's store for an earlier self.
///
/// A run's lease is claimed in the commit that hands its work to a runner
/// of this store and held, for `lease` milliseconds from the backend's
/// clock, while the runner lives: every commit that keeps work in flight,
/// including a tool's start, requires this store to hold it. The process
/// renews its runners' leases every `lease / 3` ms in one batch. A runner
/// whose lease the renewal no longer returns (another node took the run
/// over, or cancelled it) is killed with its model call and tool bodies,
/// and so is one whose lease could have expired since the last renewal
/// that succeeded (the backend is unreachable). A commit that leaves
/// nothing in flight releases the lease with the revision check alone;
/// a handoff releases it as already expired, so that any node may take
/// the run over at once.
///
/// Across nodes: a run with work in flight and a live foreign lease reads
/// `Working`; a free or expired lease reads `Unattended`. This node also
/// reads its own lease as `Unattended` when its runner is gone, including
/// a lease of an earlier store process. A command on an idle run works
/// from any node, which then
/// claims the lease; one that needs the runner of another node is
/// `fabric.RunUnattended` and changes nothing; a cancellation wins over a
/// live lease, and its owner learns of it at its next renewal.
/// `fabric.recover` takes over a free or expired lease, one held by an
/// earlier process of this store (same node and name), or this process's
/// own lease whose runner is gone. It is safe to call at any time.
///
/// `lease` is at least 100 ms and at most 2^32 - 1 ms.
pub fn leased(
  name: Name(Message),
  node node: String,
  lease milliseconds: Int,
  backend backend: LeasedBackend,
) -> Result(Store, LeaseConfigError) {
  use Nil <- result.try(check_node(node))
  case milliseconds {
    ms if ms < shortest_lease -> Error(LeaseTooShort(ms, shortest_lease))
    ms if ms > longest_timer -> Error(LeaseTooLong(ms, longest_timer))
    ms ->
      Ok(Store(
        name,
        fn() { Ok(backend) },
        None,
        default_drain,
        Some(Leasing(node, ms)),
        record.V7,
      ))
  }
}

/// The shortest lease a store renews, in milliseconds.
const shortest_lease = 100

fn check_node(node: String) -> Result(Nil, LeaseConfigError) {
  let allowed = fn(grapheme) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:",
      grapheme,
    )
  }
  let graphemes = string.to_graphemes(node)
  case
    graphemes != []
    && list.length(graphemes) <= 128
    && list.all(graphemes, allowed)
    && node != "nonode@nohost"
  {
    True -> Ok(Nil)
    False -> Error(InvalidNodeId(node))
  }
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
/// On shutdown the store's process is told first that its runners are
/// draining, so that it starts no runner meanwhile; then the runners stop,
/// and the store's process last. Each
/// runner drains within the store's drain window (`with_drain`, default
/// 25 000 ms): it starts no tool body, model call or sub-agent, waits for
/// the tool bodies running and a model reply in flight, commits their
/// results through the store's process, and hands the run off (see
/// `fabric.recover`). A runner still busy when the window ends is killed,
/// and its running tools become uncertain effects.
///
/// The handoff gives back the turn of a model call that was never issued
/// (also one waiting out a retry backoff, which is then never issued),
/// keeps queued tools queued, and asks again for an approved tool that
/// never started (its approval was checked with a context that does not
/// outlive the runner; the old reference is then stale). A stopped tool
/// awaiting its late settlement (`tool.bind_settling`) is waited for like
/// a running body. A sub-agent run is drained by its own runner; its
/// parent's delegation stays delegated, and recovering the parent recovers
/// it. A command the draining runner takes is committed, but starts
/// nothing: an approval it takes is asked for again at the handoff. Work
/// committed meanwhile through a store whose runners are draining starts
/// no runner and reads `Unattended`.
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
      await_earlier_factory(store.name)
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
/// stop before the process they commit through, and last a sentinel, which
/// stops first and tells the store's process that its runners are about
/// to drain, before any runner is told. With a `starter`, the store's
/// process stops when it exits and reports a failure to start to its
/// subject.
fn subtree(
  store: Store,
  starter: Option(#(Pid, Subject(String))),
  restart: supervision.Restart,
) -> static_supervisor.Builder {
  let store = Store(..store, pinned: None)
  let factory = factory_name(store.name)
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
      // The store's process may be gone already (it failed to start).
      case process.named(factory), process.named(name) {
        Ok(pid), Ok(_) -> {
          let _ =
            executor.rescue(fn() {
              process.send(process.named_subject(name), Draining(pid))
            })
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
  GraphLive(incarnation: Int, mailbox: Subject(graph_live.Message))
}

@internal
pub type Entry {
  Entry(revision: Int, record: String, live: Option(Live), holding: Holding)
}

/// Who holds a run's lease, as this store's process sees it.
@internal
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
@internal
pub type Ownership {
  /// A runner's commit that keeps the run: in a leased store only while
  /// this store holds its lease (`Hold`).
  Keep
  /// The committing runner `Pid` gives the run up in the same step, so a
  /// watcher woken by this commit already sees no runner; nothing is left
  /// in flight (`Release`).
  Leave(Pid)
  /// A confirmed idle record releases its runner/lease and registers deployed
  /// recovery code for changes to one dependency. The registration is local;
  /// the durable record remains authoritative after any missed notification.
  Park(dependency: String, wake: fn() -> WakeupDisposition)
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

@internal
pub type WakeupDisposition {
  KeepWatching
  StopWatching
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
@internal
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

/// An unleased backend as a leased one that never holds a lease: its
/// writes ignore the lease, and nothing is renewed or claimed.
fn unleased(backend: Backend) -> LeasedBackend {
  LeasedBackend(
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
    /// When the next `Fence` is due, if one is set.
    fence_at: Option(Int),
    /// The name of the factory its runners are started under.
    factory: Name(FactoryMessage),
    /// The runner factory process that reported it is shutting down.
    draining: Option(Pid),
    watchers: Dict(String, List(#(Pid, Subject(Nil)))),
    wakeups: Dict(String, Wakeup),
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

type Wakeup {
  Wakeup(
    dependency: String,
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
      fence_at: None,
      factory: factory_name(store.name),
      draining: None,
      watchers: dict.new(),
      wakeups: dict.new(),
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
    Draining(pid) -> Loop(..state, draining: Some(pid))
    ClaimExpired(limit, reply) -> {
      case state.lessee, state.draining {
        Some(lessee), None -> {
          process.spawn(fn() {
            process.send(
              reply,
              bounded_backend(state.timeout, fn() {
                state.backend.claim_expired(lessee.owner, lessee.ttl, limit)
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
    Renewed(sent, runs, renewed) -> renewed_leases(state, sent, runs, renewed)
    Fence -> Loop(..state, fence_at: None) |> fence |> schedule_fence
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
          valid: dict.drop(state.valid, released),
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
    Park(dependency, callback) -> {
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
          Wakeup(dependency, token, callback, Dormant),
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
      list.fold(runs, state, fn(state, entry) {
        let #(run, pid) = entry
        case dict.get(state.live, run), list.contains(held, run) {
          Ok(#(current, _)), True if current == pid ->
            Loop(
              ..state,
              valid: dict.upsert(state.valid, run, fn(valid) {
                int.max(option.unwrap(valid, 0), valid_until(lessee, sent))
              }),
            )
          Ok(#(current, _)), False if current == pid ->
            lose(state, lessee, run, pid, o.Revoked)
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
          True, Ok(#(pid, _)) -> lose(state, lessee, run, pid, o.Unrenewed)
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
  emit_apart(fn() { observe.lease_lost(run, lessee.owner, reason) })
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
@internal
pub fn poll_interval(store: Store) -> Option(Int) {
  option.map(store.leasing, fn(leasing) {
    int.clamp(leasing.ttl / 3, min: 10, max: 1000)
  })
}

/// Sends the store's process a renewal now, for tests.
@internal
pub fn renew_now(store: Store) -> Nil {
  process.send(target(store), Renew(False))
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
    case wakeup.dependency == run {
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
@internal
pub fn claim_expired(
  store: Store,
  limit: Int,
) -> Result(List(String), StoreError) {
  call(store, ClaimExpired(limit, _)) |> result.flatten
}

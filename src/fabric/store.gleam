//// Where runs live: a named store, its process and its backend.
////
//// `in_memory` and `directory` are built in; `new` and `leased` take an
//// application backend (`fabric/store/backend` documents its contract).
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

import fabric/internal/record
import fabric/internal/store as core
import fabric/store/backend.{type LeasedBackend, type StoreError, type Stored}
import gleam/erlang/process.{type Name}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}

/// A named store: the name of its process and the backend that process
/// opens when it starts. It is plain data that any process may hold.
pub type Store =
  core.Store

/// What the store's process receives; name it with `process.new_name`.
pub type Message =
  core.Message

/// An instantaneous operational report, not permission to execute work.
pub type Readiness {
  Readiness(status: ReadinessStatus, runners: Int, lease: LeaseHealth)
}

pub type ReadinessStatus {
  Accepting
  StoreDraining
  RunnerFactoryUnavailable
  /// A local runner no longer has a confirmed safe lease window.
  LeaseUnconfirmed
}

pub type LeaseHealth {
  Unleased
  /// Milliseconds from the start of the last successful renewal request.
  /// `None` before any successful renewal in this store process.
  Leased(duration_ms: Int, last_success_age_ms: Option(Int))
}

/// Why a leased store's settings were refused (`leased`).
pub type LeaseConfigError {
  /// A node id is 1 to 128 letters, digits, and `.`, `_`, `-`, `@` or
  /// `:`, and not `nonode@nohost`, which names no machine.
  InvalidNodeId(String)
  /// Shorter than the shortest lease a store renews (`minimum`, 100 ms).
  LeaseTooShort(value: Duration, minimum: Duration)
  /// Longer than the longest timer the runtime can set (`limit`, 2^32 - 1
  /// ms).
  LeaseTooLong(value: Duration, limit: Duration)
}

/// Why a drain window was refused (`with_drain`).
pub type DrainError {
  /// Shorter than 1 ms.
  DrainNotPositive(Duration)
  /// Longer than the longest timer the runtime can set (`limit`, 2^32 - 1
  /// ms).
  DrainTooLarge(value: Duration, limit: Duration)
}

/// Versions this runtime can write without discarding state.
pub type UnwritableVersion {
  UnwritableVersion(requested: Int, oldest: Int, newest: Int)
}

/// Chooses the record format for writes through this Store value. The
/// default is 8; versions 2 through 8 can be written, and 1 through 8 read.
/// Configure before starting the store and use the returned value for
/// every handle and sweeper. Existing values and runners are unchanged.
///
/// During a rolling upgrade, select a version every node can read. Versions
/// 2 and 3 refuse assistant provider data, which requires version 4.
/// Graph parent links require version 5; terminal child settlement requires
/// version 6; family budgets require version 7; imported history requires
/// version 8. Upgrade all readers before selecting a newer writer.
/// Records are changed only by ordinary writes, never by this setting.
pub fn with_record_version(
  store: Store,
  version: Int,
) -> Result(Store, UnwritableVersion) {
  record.writer(version)
  |> result.map(core.with_write_version(store, _))
  |> result.replace_error(UnwritableVersion(version, 2, record.version))
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
  core.new(name, get:, insert:, compare_and_set:)
}

/// A store that keeps records in its own process, registered as `name`.
/// They are lost when that process stops, also when a supervisor restarts
/// it.
pub fn in_memory(name: Name(Message)) -> Store {
  core.in_memory(name)
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
  core.directory(name, path)
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
/// of this store and held, for `lease` by the backend's
/// clock, while the runner lives: every commit that keeps work in flight,
/// including a tool's start, requires this store to hold it. The process
/// renews its runners' leases every third of `lease` in one batch. A runner
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
  lease lease: Duration,
  backend backend: LeasedBackend,
) -> Result(Store, LeaseConfigError) {
  use Nil <- result.try(check_node(node))
  case duration.to_milliseconds(lease) {
    ms if ms < shortest_lease ->
      Error(LeaseTooShort(lease, duration.milliseconds(shortest_lease)))
    ms if ms > longest_timer ->
      Error(LeaseTooLong(lease, duration.milliseconds(longest_timer)))
    ms -> Ok(core.leased(name, node, ms, backend))
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

/// The longest timer the runtime can set, in milliseconds.
const longest_timer = 4_294_967_295

/// Sets how long each runner may take to finish its work when the store's
/// subtree shuts down (default 25 s): see `supervised`. From 1 ms up to
/// 2^32 - 1 ms. Give the application's own shutdown timeout for the store's
/// subtree room for it, plus bounded admission/accounting/observation work
/// (up to four seconds) and process cleanup.
pub fn with_drain(store: Store, drain: Duration) -> Result(Store, DrainError) {
  case duration.to_milliseconds(drain) {
    ms if ms <= 0 -> Error(DrainNotPositive(drain))
    ms if ms > longest_timer ->
      Error(DrainTooLarge(drain, duration.milliseconds(longest_timer)))
    ms -> Ok(core.with_drain(store, ms))
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
/// a bounded reporter emits `telemetry.drain`, and the store's process
/// stops last. Accounting that cannot be read emits `drain_unavailable`.
/// Keep the event forwarder and backend alive until after this subtree. Each
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
  core.supervised(store)
}

/// Starts the store's subtree (see `supervised`) for scripts and tests,
/// linked to the caller. The store's process stops when the caller exits
/// for any reason, normally or not, so its name is free again once every
/// process linked to the caller is gone; its runners stop with it without
/// draining, as if the node had stopped. `Unavailable`
/// when its backend could not be opened or its name is taken.
///
/// `stop` stops it again, draining its runners.
pub fn start(store: Store) -> Result(Nil, StoreError) {
  core.start(store)
}

/// Stops a store started with `start` as a supervisor would (its runners
/// drain within the drain window, see `supervised`) and returns once its
/// process has stopped, at most the drain window and 10 seconds later.
/// `Ok(Nil)` when no process of the store runs. A store started under a
/// supervisor (`supervised`) is stopped by that supervisor: `stop` then
/// changes nothing and returns `Unavailable`.
pub fn stop(store: Store) -> Result(Nil, StoreError) {
  core.stop(store)
}

/// Read UTC Unix milliseconds from the store's backend clock. Use this time
/// domain for persisted deadlines, never the calling VM's monotonic epoch.
/// A failure is returned without falling back to local time. Like other store
/// reads, the callback is bounded by `with_backend_timeout`.
pub fn now(store: Store) -> Result(Int, StoreError) {
  core.now(store)
}

/// Checks storage with a bounded read, then samples current local readiness.
/// Missing probe keys are healthy; backend errors, crashes and timeouts are
/// errors. This never writes, claims or renews a record. Idle stores need no
/// renewal; a new runner's committed claim supplies its initial lease evidence.
/// During work, all runners must remain inside their confirmed safe lease
/// windows. The existing lease safety margin applies. A draining store never
/// reports `Accepting`, even when shutdown began during the backend probe.
pub fn readiness(store: Store) -> Result(Readiness, StoreError) {
  use report <- result.map(core.readiness(store))
  let status = case report.draining, report.factory_running {
    True, _ -> StoreDraining
    False, False -> RunnerFactoryUnavailable
    False, True ->
      case report.leases_confirmed {
        True -> Accepting
        False -> LeaseUnconfirmed
      }
  }
  let lease = case report.lease {
    None -> Unleased
    Some(#(duration_ms, last_success_age_ms)) ->
      Leased(duration_ms:, last_success_age_ms:)
  }
  Readiness(status, report.runners, lease)
}

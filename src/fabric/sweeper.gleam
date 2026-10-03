//// Automatic recovery for a leased store: a sweeper that scans for runs
//// whose lease expired (their node died), for idle graph waits that are
//// due, and for agent approval requests whose deadline passed
//// (`agent.with_approval_expiry`), and recovers each through its registered
//// root; recovery rejects an expired request, so the model sees it.
////
//// Register every root agent and root graph whose runs the sweeper may
//// meet, then put `supervised` under the application's supervisor in place
//// of `store.supervised`: it starts the store's subtree and the sweeper in
//// the order recovery needs, so the sweeper always stops before the store's
//// runners drain.
////
//// ```gleam
//// let assert Ok(runs) =
////   store.leased(name, node: "node-a", lease: duration.seconds(30), backend:)
//// let assert Ok(subtree) =
////   sweeper.supervised(
////     runs,
////     [sweeper.agent(desk, context: fn(_run) { Context(user: "sweeper") })],
////     every: duration.seconds(5),
////   )
//// static_supervisor.new(static_supervisor.OneForOne)
//// |> static_supervisor.add(subtree)
//// |> static_supervisor.start
//// ```

import fabric/agent.{type Agent}
import fabric/graph.{type Runtime}
import fabric/internal/bounded
import fabric/internal/graph/compiled
import fabric/internal/graph/runner
import fabric/internal/graph/runtime as graph_runtime
import fabric/internal/store as store_core
import fabric/internal/sweeper
import fabric/run.{type DefinitionId, type RunId}
import fabric/store.{type Store}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import gleam/time/duration.{type Duration}

/// A registered root and its deployed recovery code. Build one with `agent`
/// or `graph`.
pub type Root =
  sweeper.Root

/// Why `supervised` refused its configuration.
pub type SweeperError {
  /// Shorter than 1 ms.
  EveryNotPositive(Duration)
  /// Longer than the longest timer the runtime can set (`limit`, 2^32 - 1
  /// ms).
  EveryTooLarge(value: Duration, limit: Duration)
  /// Two roots share this agent or graph definition.
  DuplicateRoot(DefinitionId)
  /// The sweeper recovers through leases: only a `store.leased` store has
  /// them.
  StoreNotLeased
  /// `start` found no running process of the store (`store.start` it
  /// first).
  StoreNotRunning
}

/// The root agent `agent`, whose runs the sweeper recovers with the context
/// `context` builds for each run (in 5 seconds at most).
pub fn agent(
  agent: Agent(context),
  context context: fn(RunId) -> context,
) -> Root {
  sweeper.agent_root(agent, context)
}

/// The root graph `identity`. `build` rebuilds its complete runtime, and
/// its children's, against the store it is given, in 5 seconds at most; the
/// sweeper also discovers the graph's idle waits that are due, including
/// those whose local wakeup was lost.
pub fn graph(
  identity: DefinitionId,
  build build: fn(Store) -> Runtime(context, state, answer),
) -> Root {
  sweeper.graph_root(identity, fn(runs, id) {
    use runtime <- result.try(
      bounded.call(5000, fn() { build(runs) }) |> result.replace_error(Nil),
    )
    use Nil <- result.try(
      case
        compiled.identity(graph_runtime.definition(runtime)).identity
        == identity,
        store_core.pid(graph_runtime.store(runtime)),
        store_core.pid(runs)
      {
        True, Ok(actual), Ok(expected) if actual == expected -> Ok(Nil)
        _, _, _ -> Error(Nil)
      },
    )
    runner.discover(
      runs,
      graph_runtime.work(runtime),
      graph_runtime.options(runtime),
      id,
      3,
    )
    |> result.replace(Nil)
    |> result.replace_error(Nil)
  })
}

/// The leased store's subtree (see `store.supervised`) followed by its
/// sweeper, for the application's supervisor: use it instead of
/// `store.supervised`, not beside it. The sweeper restarts with the store
/// and stops before the store's runners drain.
///
/// The sweeper scans at boot, then waits `every` after each bounded batch
/// of at most 50 expired leases and 50 changed idle dependencies; no scans
/// overlap. Each candidate is recovered through its registered root, in 30
/// seconds at most; a crashed running effect becomes uncertain according to
/// its recovery contract. A failure or an unregistered root leaves its
/// claim to expire and does not prevent the next root's recovery.
/// `telemetry.sweep` reports each scan; synchronous sweep handlers have 1
/// second before their emitter is stopped. Held work waits for its lease to
/// expire (`fabric.recover` can take an earlier local lease at once). A
/// signal wait without a deadline needs explicit delivery.
///
/// Every problem is reported at once.
pub fn supervised(
  store: Store,
  roots: List(Root),
  every every: Duration,
) -> Result(supervision.ChildSpecification(Nil), List(SweeperError)) {
  use child <- result.map(worker(store, roots, every, None))
  supervision.supervisor(fn() {
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 5)
    |> static_supervisor.add(store.supervised(store))
    |> static_supervisor.add(child)
    |> static_supervisor.start
    |> result.map(fn(started) { actor.Started(started.pid, Nil) })
  })
}

/// Starts the sweeper of a store already started with `store.start`, for
/// scripts and tests, linked to the caller; it stops when the store or the
/// caller stops, also when the caller exits normally.
/// Returns the sweeper's process. Under a supervisor use `supervised`,
/// which also orders the sweeper after the store.
pub fn start(
  store: Store,
  roots: List(Root),
  every every: Duration,
) -> Result(Pid, List(SweeperError)) {
  use child <- result.try(worker(store, roots, every, Some(process.self())))
  child.start()
  |> result.map(fn(started) { started.pid })
  |> result.replace_error([StoreNotRunning])
}

fn worker(
  store: Store,
  roots: List(Root),
  every: Duration,
  caller: Option(Pid),
) -> Result(supervision.ChildSpecification(Nil), List(SweeperError)) {
  sweeper.new(store, roots, duration.to_milliseconds(every), caller)
  |> result.map_error(
    list.map(_, fn(error) {
      case error {
        sweeper.EveryNotPositive(_) -> EveryNotPositive(every)
        sweeper.EveryTooLarge(_) ->
          EveryTooLarge(every, duration.milliseconds(longest_timer))
        sweeper.DuplicateRoot(identity) -> DuplicateRoot(identity)
        sweeper.StoreNotLeased -> StoreNotLeased
      }
    }),
  )
}

/// The longest timer the runtime can set, in milliseconds.
const longest_timer = 4_294_967_295

pub fn describe_error(error: SweeperError) -> String {
  case error {
    EveryNotPositive(_) -> "the sweep interval must be at least 1 ms"
    EveryTooLarge(value, _) ->
      "the sweep interval of "
      <> int.to_string(duration.to_milliseconds(value))
      <> " ms is longer than 2^32 - 1 ms"
    DuplicateRoot(identity) ->
      "two roots are registered for "
      <> identity.name
      <> " version "
      <> int.to_string(identity.version)
    StoreNotLeased -> "the sweeper needs a leased store (store.leased)"
    StoreNotRunning -> "the sweeper's store is not running"
  }
}

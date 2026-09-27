//// Fabric runs bounded, typed LLM agents.
////
//// ```gleam
//// let agent = agent.new(model, [weather_tool, transfer_tool], my_policy)
//// let assert Ok(handle) = fabric.start(agent, context, "What is the weather?")
//// let assert Ok(run.Finished(run.Completed(answer))) = fabric.await(handle, 5000)
//// ```
////
//// A run's record lives in a store owned by the process that called `start`
//// (the store is linked to it). A runner process exists only while a model
//// call or a tool is in flight; a suspended or finished run has no process.
//// Commands (`cancel`, `reconcile`) go to the live runner, or are applied to
//// the stored record when there is none.

import fabric/agent.{type Agent, type ConfigError}
import fabric/internal/bounded
import fabric/internal/controller.{type Event, type State}
import fabric/internal/runner.{type RunStore}
import fabric/internal/store
import fabric/policy.{type ActionId}
import fabric/run.{type Snapshot, type Status}
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/result

pub opaque type Run {
  Run(
    id: String,
    store: RunStore,
    command: fn(Event) -> Result(Status, CommandError),
  )
}

pub type StartError {
  InvalidAgent(List(ConfigError))
}

pub type CommandError {
  /// The run has finished; nothing more can change it.
  RunEnded
  /// No action with this identity exists in the current tool batch.
  UnknownAction(ActionId)
  /// The action is not an uncertain effect.
  NotReconcilable(ActionId)
  /// The run is in a phase that does not accept this command (for example
  /// reconciling while the model is being called).
  WrongPhase
  /// The command lost every retry against concurrent commits.
  Contended
  /// The store holding the run is gone (its owner exited).
  StoreUnavailable
}

pub type AwaitError {
  /// The run was still working when the time ran out.
  StillWorking
  AwaitStoreUnavailable
}

/// Validates `agent`, then starts the run: stores its first record and
/// spawns a runner for the first model call.
pub fn start(
  agent: Agent(context),
  context: context,
  prompt: String,
) -> Result(Run, StartError) {
  use admitted <- result.try(
    agent.admit(agent) |> result.map_error(InvalidAgent),
  )
  let run_store = store.start()
  let id = "run-" <> random_id()
  let env =
    controller.Env(
      registry: admitted.registry,
      policy: contain_policy(admitted.policy, admitted.policy_timeout),
      context:,
      system: admitted.system_prompt,
    )
  let limits =
    controller.Limits(
      max_turns: admitted.max_turns,
      token_budget: admitted.token_budget,
    )
  let setup =
    runner.Setup(
      env:,
      model: admitted.model,
      max_concurrency: admitted.max_concurrency,
      store: run_store,
    )
  let #(state, effects) =
    controller.start(env, id, admitted.identity, limits, prompt)
  let assert Ok(revision) = store.insert(run_store, id, state)
    as "a fresh store accepts the first record"
  runner.spawn(setup, state, revision, effects)
  Ok(
    Run(id:, store: run_store, command: fn(event) {
      command(setup, id, event, 3)
    }),
  )
}

pub fn id(run: Run) -> String {
  run.id
}

/// Blocks until the run is no longer `Working` (suspended or finished), or
/// until `within` milliseconds pass.
pub fn await(run: Run, within: Int) -> Result(Status, AwaitError) {
  let watcher = process.new_subject()
  let deadline = now() + within
  case store.watch(run.store, run.id, watcher) {
    Error(_) -> Error(AwaitStoreUnavailable)
    Ok(Nil) -> {
      let outcome = case store.get(run.store, run.id) {
        Error(_) -> Error(AwaitStoreUnavailable)
        Ok(entry) -> wait(watcher, controller.status(entry.record), deadline)
      }
      store.unwatch(run.store, run.id, watcher)
      outcome
    }
  }
}

fn wait(
  watcher: process.Subject(store.Committed(State)),
  status: Status,
  deadline: Int,
) -> Result(Status, AwaitError) {
  case status {
    run.Working ->
      case process.receive(watcher, int_max(0, deadline - now())) {
        Error(Nil) -> Error(StillWorking)
        Ok(store.Committed(_, record)) ->
          wait(watcher, controller.status(record), deadline)
      }
    _ -> Ok(status)
  }
}

pub fn status(run: Run) -> Result(Status, CommandError) {
  load(run) |> result.map(controller.status)
}

pub fn snapshot(run: Run) -> Result(Snapshot, CommandError) {
  load(run) |> result.map(controller.snapshot)
}

/// Whether a runner process currently drives the run.
pub fn is_live(run: Run) -> Bool {
  case store.get(run.store, run.id) {
    Ok(store.Entry(live: Some(_), ..)) -> True
    _ -> False
  }
}

/// Cancels an active or suspended run. Running tools are killed and
/// recorded as uncertain effects, never retried; queued and waiting actions
/// are recorded as not started. Returns the status right after the
/// cancellation was committed: `Working` while tools are being stopped,
/// then `Finished(Cancelled)` (see `await`).
pub fn cancel(run: Run) -> Result(Status, CommandError) {
  run.command(controller.Cancel)
}

/// Records what actually happened for an uncertain effect. `content` is what
/// the model will see as that call's result. When nothing else is pending
/// the run continues with its next model turn. Reconciliation does not
/// consume a turn.
pub fn reconcile(
  run: Run,
  action: ActionId,
  content: String,
) -> Result(Status, CommandError) {
  run.command(controller.Reconcile(action, content))
}

fn load(run: Run) -> Result(State, CommandError) {
  store.get(run.store, run.id)
  |> result.map(fn(entry) { entry.record })
  |> result.replace_error(StoreUnavailable)
}

/// Sends `event` to the live runner, or applies it to the stored record and
/// spawns a runner if the transition produced work. A lost race re-reads
/// the newer record and validates the command again.
fn command(
  setup: runner.Setup(context),
  id: String,
  event: Event,
  tries: Int,
) -> Result(Status, CommandError) {
  use entry <- result.try(
    store.get(setup.store, id) |> result.replace_error(StoreUnavailable),
  )
  case entry.live {
    Some(live) ->
      case send_live(live, event) {
        Ok(outcome) -> outcome |> result.map_error(rejection)
        Error(Nil) -> retry(setup, id, event, tries)
      }
    None ->
      case controller.step(setup.env, entry.record, event) {
        Error(error) -> Error(rejection(error))
        Ok(#(state, effects)) ->
          case
            store.compare_and_set(
              setup.store,
              id,
              entry.revision,
              state,
              release: False,
            )
          {
            Error(store.Conflict(_)) -> retry(setup, id, event, tries)
            Error(_) -> Error(StoreUnavailable)
            Ok(revision) -> {
              case controller.needs_runner(state) {
                True -> runner.spawn(setup, state, revision, effects)
                False -> Nil
              }
              Ok(controller.status(state))
            }
          }
      }
  }
}

fn retry(
  setup: runner.Setup(context),
  id: String,
  event: Event,
  tries: Int,
) -> Result(Status, CommandError) {
  case tries > 1 {
    True -> command(setup, id, event, tries - 1)
    False -> Error(Contended)
  }
}

/// `Error(Nil)` when the runner exited before answering.
fn send_live(
  live: process.Subject(runner.Message),
  event: Event,
) -> Result(Result(Status, controller.Rejection), Nil) {
  case process.subject_owner(live) {
    Error(Nil) -> Error(Nil)
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      process.send(live, runner.Command(event, reply))
      let answer =
        process.new_selector()
        |> process.select_map(reply, Ok)
        |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
        |> process.selector_receive_forever
      process.demonitor_process(monitor)
      answer
    }
  }
}

fn rejection(rejection: controller.Rejection) -> CommandError {
  case rejection {
    controller.RunEnded -> RunEnded
    controller.UnknownAction(id) | controller.ReportNotExpected(id) ->
      UnknownAction(id)
    controller.NotReconcilable(id) -> NotReconcilable(id)
    controller.StaleEvent -> WrongPhase
    controller.WrongReference
    | controller.StaleReference
    | controller.AlreadyAnswered -> WrongPhase
  }
}

/// A policy that crashes or gives no decision in time has failed: the run
/// stops closed.
fn contain_policy(
  policy: policy.Policy(context),
  timeout: Int,
) -> policy.Policy(context) {
  fn(context, action) {
    case bounded.call(timeout, fn() { policy(context, action) }) {
      Ok(decision) -> decision
      Error(bounded.Crashed(crash)) -> Error("policy crashed: " <> crash)
      Error(bounded.TimedOut) ->
        Error(
          "policy gave no decision within " <> int.to_string(timeout) <> " ms",
        )
    }
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

@external(erlang, "fabric_ffi", "random_id")
fn random_id() -> String

@external(erlang, "fabric_ffi", "now_ms")
fn now() -> Int

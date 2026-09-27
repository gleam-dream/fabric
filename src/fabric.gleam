//// Fabric runs bounded, typed LLM agents whose runs can pause durably,
//// wait for a human, survive a restart, and be cancelled at any point.
////
//// ```gleam
//// let store = store.in_memory()            // or store.directory(path)
//// let agent = agent.new(model, [weather_tool, transfer_tool], my_policy)
//// let assert Ok(handle) = fabric.start(store, agent, context, "Pay Bob")
//// case fabric.await(handle, 5000) {
////   Ok(run.Suspended([pending, ..], _)) ->
////     fabric.answer(handle, pending.reference, run.Approve,
////       reviewer: Some("alice"), context: current_context)
////   ...
//// }
//// ```
////
//// A run's record lives in a store. A runner process exists only while a
//// model call or a tool is in flight; a suspended or finished run has no
//// process. Commands (`answer`, `cancel`, `reconcile`) go to the live
//// runner, or are applied to the stored record when there is none, and a
//// runner is started if the command produced work.
////
//// After a restart, `recover` opens a stored run under the same agent. If
//// work was in flight when its runner was lost, recovery takes it over as a
//// new incarnation: tools that had started become uncertain effects, which
//// are never retried and must be reconciled; queued tools and a lost model
//// call are started again.

import fabric/agent.{type Agent, type ConfigError}
import fabric/internal/bounded
import fabric/internal/controller.{type Event, type State}
import fabric/internal/live
import fabric/internal/record
import fabric/internal/runner
import fabric/policy.{type ActionId}
import fabric/run.{
  type Answer, type ApprovalRef, type Incompatibility, type PendingApproval,
  type Snapshot, type Status,
}
import fabric/store.{type Store}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A handle on one run, for the agent and context it was started or
/// recovered with. It holds no process: it can be dropped and rebuilt with
/// `recover`.
pub opaque type Run(context) {
  Run(id: String, setup: runner.Setup(context), agent: run.Identity)
}

pub type StartError {
  InvalidAgent(List(ConfigError))
  /// The store refused the first record.
  StartFailed(store.StoreError)
}

/// Why a stored run could not be read or continued.
pub type RecordError {
  RunNotFound
  StoreFailed(store.StoreError)
  /// The record was written by a Fabric version this one cannot read.
  UnsupportedVersion(found: Int)
  CorruptRecord(detail: String)
  /// The run cannot continue under this agent.
  IncompatibleAgent(List(Incompatibility))
}

pub type CommandError {
  /// The run has finished (completed, failed, or cancelled); nothing more
  /// can change it. A pending approval of a cancelled run is void.
  RunEnded
  /// No action with this identity exists in the current tool batch.
  UnknownAction(ActionId)
  /// The action is not an uncertain effect.
  NotReconcilable(ActionId)
  /// The run is in a phase that does not accept this command (for example
  /// reconciling while the model is being called).
  WrongPhase
  /// No approval request of this run matches the reference.
  WrongReference
  /// The action's approval request has another revision or requirement.
  StaleReference
  /// This approval request was already answered.
  AlreadyAnswered
  /// The current policy now requires another approval for the action; the
  /// answer was not applied. Answer the new request.
  RequirementChanged(PendingApproval)
  /// Work was in flight when the run's runner was lost; call `recover`
  /// first. (`cancel` never needs this: it starts nothing.)
  RecoveryRequired
  /// The command lost every retry against concurrent commits.
  Contended
  Unreadable(RecordError)
}

pub type AwaitError {
  /// The run was still working when the time ran out.
  StillWorking
  /// Work is in flight but no runner drives it (the runner was lost, or it
  /// runs in another VM); call `recover`.
  NoRunner
  AwaitUnreadable(RecordError)
}

pub type RecoverError {
  RecoverInvalidAgent(List(ConfigError))
  RecoverUnreadable(RecordError)
  /// Recovery lost every retry against concurrent commits.
  RecoverContended
}

const retries = 3

/// Validates `agent`, then starts a run in `store`: stores its first record
/// and hands the first model call to a new runner.
pub fn start(
  store: Store,
  agent: Agent(context),
  context: context,
  prompt: String,
) -> Result(Run(context), StartError) {
  use #(setup, admitted) <- result.try(
    prepare(store, agent, context) |> result.map_error(InvalidAgent),
  )
  let id = "run-" <> random_id()
  let limits =
    controller.Limits(
      max_turns: admitted.max_turns,
      token_budget: admitted.token_budget,
    )
  let #(state, effects) =
    controller.start(setup.env, id, admitted.identity, limits, prompt)
  use _ <- result.map(
    runner.launch(setup, None, state, effects) |> result.map_error(StartFailed),
  )
  Run(id:, setup:, agent: admitted.identity)
}

/// Opens the stored run `id` under `agent` and `context`. When work was in
/// flight and no runner in this VM drives it, recovery takes the work over
/// as a new incarnation (committed with compare-and-set, so concurrent
/// recoveries have one winner): running tools become uncertain effects,
/// queued tools are dispatched again, and a lost model call is issued again
/// against the turn budget. A suspended or finished run is opened
/// unchanged. Calling it again is harmless.
pub fn recover(
  store: Store,
  agent: Agent(context),
  context: context,
  id: String,
) -> Result(Run(context), RecoverError) {
  use #(setup, admitted) <- result.try(
    prepare(store, agent, context) |> result.map_error(RecoverInvalidAgent),
  )
  let run = Run(id:, setup:, agent: admitted.identity)
  take_over(run, retries) |> result.replace(run)
}

fn take_over(run: Run(context), tries: Int) -> Result(Nil, RecoverError) {
  use #(entry, state) <- result.try(
    load_checked(run) |> result.map_error(RecoverUnreadable),
  )
  case live_runner(entry, state), controller.needs_runner(state) {
    Some(_), _ | None, False -> Ok(Nil)
    None, True -> {
      let #(state, effects) = controller.recover(run.setup.env, state)
      case runner.launch(run.setup, Some(entry.revision), state, effects) {
        Ok(_) -> Ok(Nil)
        Error(store.Conflict(_)) if tries > 1 -> take_over(run, tries - 1)
        Error(store.Conflict(_)) -> Error(RecoverContended)
        Error(error) -> Error(RecoverUnreadable(StoreFailed(error)))
      }
    }
  }
}

fn prepare(
  store: Store,
  agent: Agent(context),
  context: context,
) -> Result(
  #(runner.Setup(context), agent.Admitted(context)),
  List(ConfigError),
) {
  use admitted <- result.map(agent.admit(agent))
  let env =
    controller.Env(
      registry: admitted.registry,
      policy: contain_policy(admitted.policy, admitted.policy_timeout),
      context:,
      system: admitted.system_prompt,
    )
  #(
    runner.Setup(
      env:,
      model: admitted.model,
      max_concurrency: admitted.max_concurrency,
      store:,
    ),
    admitted,
  )
}

pub fn id(run: Run(context)) -> String {
  run.id
}

/// Blocks until the run is no longer `Working` (suspended or finished), or
/// until `within` milliseconds pass. It wakes on commits made through this
/// run's store and when the run's runner exits.
pub fn await(run: Run(context), within: Int) -> Result(Status, AwaitError) {
  let watcher = process.new_subject()
  let deadline = now() + within
  case store.watch(run.setup.store, run.id, watcher) {
    Error(error) -> Error(AwaitUnreadable(StoreFailed(error)))
    Ok(Nil) -> {
      let monitor = process.monitor(store.pid(run.setup.store))
      let outcome = wait(run, watcher, monitor, deadline)
      process.demonitor_process(monitor)
      store.unwatch(run.setup.store, run.id, watcher)
      outcome
    }
  }
}

fn wait(
  run: Run(context),
  watcher: process.Subject(Nil),
  monitor: process.Monitor,
  deadline: Int,
) -> Result(Status, AwaitError) {
  use #(entry, state) <- result.try(
    load(run) |> result.map_error(AwaitUnreadable),
  )
  case controller.status(state), live_runner(entry, state) {
    run.Working, None -> Error(NoRunner)
    run.Working, Some(_) -> {
      let woken =
        process.new_selector()
        |> process.select_map(watcher, Ok)
        |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
        |> process.selector_receive(int.max(0, deadline - now()))
      case woken {
        Error(Nil) -> Error(StillWorking)
        Ok(Error(Nil)) ->
          Error(
            AwaitUnreadable(
              StoreFailed(store.Unavailable("the store is closed")),
            ),
          )
        Ok(Ok(Nil)) -> wait(run, watcher, monitor, deadline)
      }
    }
    status, _ -> Ok(status)
  }
}

pub fn status(run: Run(context)) -> Result(Status, RecordError) {
  use #(_, state) <- result.map(load(run))
  controller.status(state)
}

pub fn snapshot(run: Run(context)) -> Result(Snapshot, RecordError) {
  use #(_, state) <- result.map(load(run))
  controller.snapshot(state)
}

/// The approval requests waiting for an answer, oldest first. They can be
/// answered while other tools of the batch still run.
pub fn pending(
  run: Run(context),
) -> Result(List(PendingApproval), RecordError) {
  use #(_, state) <- result.map(load(run))
  pending_of(state)
}

fn pending_of(state: State) -> List(PendingApproval) {
  case state.phase {
    controller.Acting(_, actions) ->
      list.filter_map(actions, fn(action) {
        case action.state {
          run.AwaitingApproval(requirement, revision) ->
            Ok(run.PendingApproval(
              run.ApprovalRef(state.run, action.id, requirement, revision),
              action.call.name,
              action.call.arguments_json,
            ))
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

/// Whether a runner in this VM currently drives the run.
pub fn is_live(run: Run(context)) -> Bool {
  case load(run) {
    Ok(#(entry, state)) -> option.is_some(live_runner(entry, state))
    Error(_) -> False
  }
}

/// Answers an approval request. `context` is the application's current
/// context: the policy is checked again with it, and a current denial or
/// policy failure wins over an approval. If the approved action runs from
/// here (no runner was live), it runs with this context.
///
/// Works with no process holding the run: the answer is committed to the
/// stored record with compare-and-set, so of concurrent answers exactly one
/// wins and the others get `AlreadyAnswered` (or `RunEnded` after a cancel).
///
/// `reviewer` is recorded with the answer as given. Fabric does not
/// authenticate it: the application must authenticate and authorize whoever
/// answers before calling this.
pub fn answer(
  run: Run(context),
  reference: ApprovalRef,
  answer: Answer,
  reviewer reviewer: Option(String),
  context context: context,
) -> Result(Status, CommandError) {
  let env = controller.Env(..run.setup.env, context:)
  let answering = Run(..run, setup: runner.Setup(..run.setup, env:))
  use state <- result.try(command(
    answering,
    controller.Answer(reference, answer, reviewer),
    retries,
  ))
  let reissued =
    list.find(pending_of(state), fn(pending) {
      pending.reference.id == reference.id
      && pending.reference.revision != reference.revision
    })
  case reissued {
    Ok(pending) -> Error(RequirementChanged(pending))
    Error(Nil) -> Ok(controller.status(state))
  }
}

/// Cancels a run that is active, suspended, or whose runner was lost.
/// Running tools are stopped and recorded as uncertain effects, never
/// retried; queued actions and pending approvals are recorded as not
/// started. Returns the status right after the cancellation was committed:
/// `Working` while tools are being stopped, then `Finished(Cancelled)` (see
/// `await`).
pub fn cancel(run: Run(context)) -> Result(Status, CommandError) {
  command(run, controller.Cancel, retries) |> result.map(controller.status)
}

/// Records what actually happened for an uncertain effect. `content` is what
/// the model will see as that call's result. When nothing else is pending
/// the run continues with its next model turn. Reconciliation does not
/// consume a turn.
pub fn reconcile(
  run: Run(context),
  action: ActionId,
  content: String,
) -> Result(Status, CommandError) {
  command(run, controller.Reconcile(action, content), retries)
  |> result.map(controller.status)
}

/// Sends `event` to the live runner, or applies it to the stored record
/// and starts a runner if the transition produced work. A lost race reads
/// the newer record and validates the command again.
fn command(
  run: Run(context),
  event: Event,
  tries: Int,
) -> Result(State, CommandError) {
  use #(entry, state) <- result.try(
    load_checked(run) |> result.map_error(Unreadable),
  )
  let retry = fn() {
    case tries > 1 {
      True -> command(run, event, tries - 1)
      False -> Error(Contended)
    }
  }
  case live_runner(entry, state) {
    Some(mailbox) ->
      case
        send_live(mailbox, fn(state) {
          controller.step(run.setup.env, state, event)
        })
      {
        Ok(live.Applied(state)) -> Ok(state)
        Ok(live.Refused(rejection)) -> Error(refusal(rejection))
        Ok(live.Superseded) | Error(Nil) -> retry()
      }
    None -> {
      let orphaned = controller.needs_runner(state)
      let transition = case orphaned, event {
        False, _ -> Ok(controller.step(run.setup.env, state, event))
        // Cancelling starts nothing, so it needs no recovery first.
        True, controller.Cancel ->
          Ok(controller.step(run.setup.env, controller.abandon(state), event))
        True, _ -> Error(RecoveryRequired)
      }
      use transition <- result.try(transition)
      use #(next, effects) <- result.try(
        transition |> result.map_error(refusal),
      )
      case runner.launch(run.setup, Some(entry.revision), next, effects) {
        Ok(_) -> Ok(next)
        Error(store.Conflict(_)) -> retry()
        Error(error) -> Error(Unreadable(StoreFailed(error)))
      }
    }
  }
}

/// `Error(Nil)` when the runner exited before answering.
fn send_live(
  mailbox: process.Subject(live.Message),
  step: fn(State) ->
    Result(#(State, List(controller.Effect)), controller.Rejection),
) -> Result(live.CommandReply, Nil) {
  case process.subject_owner(mailbox) {
    Error(Nil) -> Error(Nil)
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      process.send(mailbox, live.Command(step, reply))
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

fn refusal(rejection: controller.Rejection) -> CommandError {
  case rejection {
    controller.RunEnded -> RunEnded
    controller.UnknownAction(id) | controller.ReportNotExpected(id) ->
      UnknownAction(id)
    controller.NotReconcilable(id) -> NotReconcilable(id)
    controller.StaleEvent -> WrongPhase
    controller.WrongReference -> WrongReference
    controller.StaleReference -> StaleReference
    controller.AlreadyAnswered -> AlreadyAnswered
  }
}

// --- loading -------------------------------------------------------------------

fn load(run: Run(context)) -> Result(#(store.Entry, State), RecordError) {
  use entry <- result.try(
    store.get(run.setup.store, run.id)
    |> result.map_error(fn(error) {
      case error {
        store.NotFound -> RunNotFound
        other -> StoreFailed(other)
      }
    }),
  )
  use state <- result.map(
    record.decode(entry.record)
    |> result.map_error(fn(error) {
      case error {
        record.UnsupportedVersion(found) -> UnsupportedVersion(found)
        record.Corrupt(detail) -> CorruptRecord(detail)
      }
    }),
  )
  #(entry, state)
}

/// `load`, and the record must be able to continue under this run's agent.
fn load_checked(
  run: Run(context),
) -> Result(#(store.Entry, State), RecordError) {
  use #(entry, state) <- result.try(load(run))
  record.check(state, run.agent, run.setup.env.registry)
  |> result.map(fn(state) { #(entry, state) })
  |> result.map_error(IncompatibleAgent)
}

/// The runner registered for the record's current incarnation. A runner of
/// an older incarnation lost the run to a recovery elsewhere; its commits
/// will fail.
fn live_runner(
  entry: store.Entry,
  state: State,
) -> Option(process.Subject(live.Message)) {
  case entry.live {
    Some(store.Live(incarnation, mailbox)) if incarnation == state.incarnation ->
      Some(mailbox)
    _ -> None
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

@external(erlang, "fabric_ffi", "random_id")
fn random_id() -> String

@external(erlang, "fabric_ffi", "now_ms")
fn now() -> Int

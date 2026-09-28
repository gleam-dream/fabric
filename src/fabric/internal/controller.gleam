//// The pure agent controller.
////
//// `step(env, state, event)` either refuses the event or returns the next
//// state with the effects the runner must perform after committing it. The
//// state is plain data with no closures: the tools, policy, context, and
//// system prompt come from `Env` on every step, so an idle run is just its
//// stored state.
////
//// Phases:
////
//// ```text
//// AwaitingModel(turn) --reply--> Acting(batch) | Ended
//// Acting(batch)       --all model-visible--> AwaitingModel(turn + 1)
//// Acting(batch)       --cancel or host fault, tools or children active--> Stopping
//// Stopping            --tools stopped, settlements in, children ended--> Ended
//// ```
////
//// A stopped tool bound with `tool.bind_settling` stays running after the
//// executor stops until its late settlement (`Settled`) arrives or its
//// bound passes (`SettlementDue`). A stopping run accepts that settlement
//// only in that window: before `ToolsStopped` it is early (the task may
//// still act), after the bound it is refused. An action that became
//// uncertain in a run that is not stopping accepts one definite
//// settlement, like a reconciliation. Either way an action accepts at most
//// one settlement: the first moves it out of the state that awaits one.
////
//// `answer` resolves an approval request of the current batch; `abandon`
//// and `recover` take over a record whose runner was lost.
////
//// An approved action runs with the context its answer's policy recheck
//// passed with: the effects of that step (its `Dispatch` or `StartChild`)
//// belong to the step's environment, and the runner performs them with its
//// context. That context is not stored. An approved action that had not
//// started when its runner was lost therefore asks for its approval again:
//// a stored answer alone does not authorize a later incarnation.
////
//// A delegation (a call that starts a sub-agent run) is admitted like a
//// tool call, after checking the run's sub-agent budgets. When allowed it
//// is committed `Running` with its child run id (the fence), the runner
//// then stores the child and reports `ChildStarted` (`Delegated`), and the
//// child's end arrives as `ChildEnded`. A delegated action needs no runner:
//// the child run drives itself.

import fabric/internal/invocation
import fabric/internal/registry.{type Registry}
import fabric/model.{
  type Message, type ModelError, type Reply, type Request, type ToolCall,
}
import fabric/policy.{type Policy}
import fabric/run.{
  type ActionId, type ActionRecord, type ActionState, type Answer,
  type ApprovalRef, type HostFailure, type Identity, type Outcome, type Status,
  type TokenUsage, ActionId, ActionRecord,
}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set

// --- vocabulary ----------------------------------------------------------------

pub type Env(context) {
  Env(
    registry: Registry(context),
    policy: Policy(context),
    context: context,
    system: Option(String),
  )
}

/// `max_depth` counts levels below the root run: a run at `depth` may start
/// sub-agents while `depth < max_depth`.
pub type Limits {
  Limits(
    max_turns: Int,
    token_budget: Option(Int),
    max_children: Int,
    max_depth: Int,
  )
}

pub type StopReason {
  CancelRequested
  HostFault(HostFailure)
}

pub type Phase {
  /// Model attempt `turn` is in flight.
  AwaitingModel(turn: Int)
  /// The tool batch requested by the reply to `turn`.
  Acting(turn: Int, actions: List(ActionRecord))
  /// Waiting for the executor to confirm that no tool of the batch runs
  /// (`tools_stopped`), for the late settlements of stopped tools, and for
  /// every child run of the batch to end. Once `tools_stopped`, a tool
  /// action still `Running` is a stopped tool awaiting its settlement.
  Stopping(
    turn: Int,
    actions: List(ActionRecord),
    reason: StopReason,
    tools_stopped: Bool,
  )
  Ended(Outcome)
  /// A child run cancelled before it was ever stored, recorded by its
  /// cancelling parent (`never_started`) so that a start or recovery racing
  /// the cancellation finds it ended and never runs it. It reads as
  /// `Finished(Cancelled)` and, for its delegation, as a missing child.
  NeverStarted
}

pub type State {
  State(
    run: String,
    agent: Identity,
    /// Increases by one each time a lost runner's work is taken over.
    incarnation: Int,
    /// The action that started this run, for a sub-agent run.
    parent: Option(run.ActionRef),
    /// Levels below the root run: 0 for a root run.
    depth: Int,
    limits: Limits,
    turns_used: Int,
    usage: TokenUsage,
    transcript: List(Message),
    /// Actions of earlier batches, oldest first.
    history: List(ActionRecord),
    approvals_issued: Int,
    phase: Phase,
  )
}

pub type Event {
  ModelReplied(turn: Int, reply: Reply)
  ModelFailed(turn: Int, error: ModelError)
  /// The fence: an executor asks to start an action's body.
  ToolStarting(ActionId)
  ToolReported(ActionId, invocation.Outcome)
  /// A task died without reporting.
  ToolLost(ActionId, reason: String)
  /// The executor confirms nothing of this batch runs any more.
  ToolsStopped
  Reconcile(ActionId, content: String)
  /// A reviewer's answer; the policy is checked again with the context of
  /// the environment the event is applied with.
  Answer(reference: ApprovalRef, answer: Answer, reviewer: Option(String))
  Cancel
  /// The child run of a delegation is stored and runs.
  ChildStarted(ActionId)
  /// The child run of a delegation ended (or cannot be continued).
  ChildEnded(ActionId, ChildResult)
  /// A late settlement of a stopped or uncertain action
  /// (`tool.bind_settling`).
  Settled(ActionId, invocation.Outcome)
  /// A stopped action's bound for its settlement has passed.
  SettlementDue(ActionId)
}

/// What became of a delegation's child run.
pub type ChildResult {
  /// The child finished with `outcome`; `unknown_effects` when it left an
  /// effect of unknown status (an unreconciled uncertain action).
  ChildFinished(outcome: Outcome, unknown_effects: Bool)
  /// The child's record cannot be read or continued.
  ChildLost(detail: String)
  /// The child was cancelled and is still stopping (it waits for a stopped
  /// tool's settlement or for its own children): it has not ended, and
  /// delivers its end itself.
  ChildStopping
  /// The child was never stored (its start was cut short).
  ChildMissing
}

pub type Effect {
  CallModel(turn: Int, request: Request)
  Dispatch(List(#(ActionId, ToolCall)))
  StopTools
  AbortModel
  /// Store and start the child run `child` for the delegation `call`.
  StartChild(id: ActionId, child: String, call: ToolCall)
  /// Cancel these child runs (action, child run id).
  CancelChildren(List(#(ActionId, String)))
  /// Report `SettlementDue(id)` after `within` milliseconds.
  AwaitSettlement(id: ActionId, within: Int)
}

pub type Rejection {
  StaleEvent
  UnknownAction(ActionId)
  ReportNotExpected(ActionId)
  NotReconcilable(ActionId)
  RunEnded
  /// No approval request of this run matches the reference.
  WrongReference
  /// The action's approval request has another revision or requirement.
  StaleReference
  /// This approval request was already answered.
  AlreadyAnswered
  /// The action does not await a late settlement.
  SettlementNotAwaited(ActionId)
  /// The action's task may still run: a settlement is awaited only once
  /// its task was stopped (a stopping run's executor confirmed the stop)
  /// or it became uncertain.
  SettlementEarly(ActionId)
  /// The action already has a definite result: nothing is lost.
  SettlementRecorded(ActionId)
}

type Transition =
  Result(#(State, List(Effect)), Rejection)

// --- transitions ---------------------------------------------------------------

pub fn start(
  env: Env(context),
  run: String,
  agent: Identity,
  limits: Limits,
  prompt: String,
  parent: Option(run.ActionRef),
  depth: Int,
) -> #(State, List(Effect)) {
  let state =
    State(
      run:,
      agent:,
      incarnation: 1,
      parent:,
      depth:,
      limits:,
      turns_used: 0,
      usage: run.TokenUsage(0, 0, 0),
      transcript: [model.UserMessage(prompt)],
      history: [],
      approvals_issued: 0,
      phase: AwaitingModel(0),
    )
  call_model(env, state)
}

pub fn step(env: Env(context), state: State, event: Event) -> Transition {
  case event {
    Answer(reference, answer, reviewer) ->
      answer_approval(env, state, reference, answer, reviewer)
    Settled(id, _) ->
      step_phase(env, state, event)
      |> result.map_error(settlement_refused(state, id, _))
    _ -> step_phase(env, state, event)
  }
}

/// Why a settlement of `id` was refused: early, or else whether the action
/// already has a definite result (nothing is lost) or not.
fn settlement_refused(
  state: State,
  id: ActionId,
  rejection: Rejection,
) -> Rejection {
  let actions = list.append(state.history, current(state))
  case rejection, list.find(actions, fn(action) { action.id == id }) {
    SettlementEarly(_), _ | _, Error(Nil) -> rejection
    _, Ok(action) ->
      case model_content(action.state) {
        Ok(_) -> SettlementRecorded(id)
        Error(Nil) -> SettlementNotAwaited(id)
      }
  }
}

fn step_phase(env: Env(context), state: State, event: Event) -> Transition {
  case state.phase, event {
    Ended(_), _ | NeverStarted, _ -> Error(RunEnded)

    AwaitingModel(turn), ModelReplied(t, reply) if t == turn ->
      Ok(model_replied(env, state, turn, reply))
    AwaitingModel(turn), ModelFailed(t, error) if t == turn ->
      Ok(model_failed(env, state, error))
    _, Cancel -> cancel(state)
    AwaitingModel(_), _ -> Error(StaleEvent)

    Acting(turn, actions), ToolStarting(id) ->
      update(actions, id, fn(action_state) {
        case action_state {
          run.Queued -> Ok(run.Running)
          _ -> Error(StaleEvent)
        }
      })
      |> result.map(fn(actions) {
        #(State(..state, phase: Acting(turn, actions)), [])
      })
    Acting(turn, actions), ToolReported(id, outcome) -> {
      use actions <- result.try(update(actions, id, accept_report(id, outcome)))
      let state = State(..state, phase: Acting(turn, actions))
      case host_fault(id, outcome) {
        Some(failure) -> Ok(stop(state, turn, actions, HostFault(failure)))
        None -> Ok(settle(env, state))
      }
    }
    Acting(turn, actions), ToolLost(id, reason) -> {
      use actions <- result.try(update(actions, id, lose(id, reason)))
      Ok(settle(env, State(..state, phase: Acting(turn, actions))))
    }
    Acting(turn, actions), Reconcile(id, content) -> {
      use actions <- result.try(
        update(actions, id, fn(action_state) {
          case action_state {
            run.Uncertain(_) -> Ok(run.Reconciled(content))
            _ -> Error(NotReconcilable(id))
          }
        }),
      )
      Ok(settle(env, State(..state, phase: Acting(turn, actions))))
    }
    // The task of a running action may still act, or have died without
    // its loss being applied yet: its settlement is early.
    Acting(turn, actions), Settled(id, outcome) -> {
      use actions <- result.try(
        update_record(actions, id, fn(action) {
          case action.state, action.child, settled_state(outcome) {
            run.Uncertain(_), _, Definite(settled) ->
              Ok(ActionRecord(..action, state: settled))
            run.Running, None, _ -> Error(SettlementEarly(id))
            _, _, _ -> Error(SettlementNotAwaited(id))
          }
        }),
      )
      Ok(settle(env, State(..state, phase: Acting(turn, actions))))
    }
    Acting(turn, actions), ChildStarted(id) -> {
      use actions <- result.try(child_started(actions, id))
      Ok(#(State(..state, phase: Acting(turn, actions)), []))
    }
    Acting(turn, actions), ChildEnded(id, ChildMissing) ->
      child_missing(state, turn, actions, id)
    Acting(turn, actions), ChildEnded(id, result) -> {
      use #(actions, fault) <- result.try(child_ended(
        actions,
        id,
        result,
        settle_with(env),
      ))
      let state = State(..state, phase: Acting(turn, actions))
      case fault {
        Some(failure) -> Ok(stop(state, turn, actions, HostFault(failure)))
        None -> Ok(settle(env, state))
      }
    }
    Acting(..), _ -> Error(StaleEvent)

    Stopping(turn, actions, reason, halted), ToolReported(id, outcome) -> {
      use actions <- result.try(update(actions, id, accept_report(id, outcome)))
      Ok(#(State(..state, phase: Stopping(turn, actions, reason, halted)), []))
    }
    Stopping(turn, actions, reason, halted), ToolLost(id, why) -> {
      use actions <- result.try(update(actions, id, lose(id, why)))
      Ok(#(State(..state, phase: Stopping(turn, actions, reason, halted)), []))
    }
    Stopping(turn, actions, reason, _), ToolsStopped -> {
      // A stopped tool that can settle late keeps running until its
      // settlement arrives or its bound passes.
      let awaiting =
        list.filter_map(actions, fn(action) {
          case
            action.state,
            action.child,
            registry.settles_within(env.registry, action.call.name)
          {
            run.Running, None, Some(within) -> Ok(#(action.id, within))
            _, _, _ -> Error(Nil)
          }
        })
      let stopped =
        finish_stop(
          state,
          turn,
          actions,
          reason,
          "stopped while running",
          list.map(awaiting, fn(entry) { entry.0 }),
        )
      Ok(#(
        stopped,
        list.map(awaiting, fn(entry) { AwaitSettlement(entry.0, entry.1) }),
      ))
    }
    // A settlement is accepted once, while the action awaits it: after the
    // executor confirmed that its task no longer runs, and before its
    // bound passed.
    Stopping(turn, actions, reason, halted), Settled(id, outcome) -> {
      use actions <- result.try(
        update_record(actions, id, fn(action) {
          case action.state, action.child, halted {
            run.Running, None, True ->
              Ok(
                ActionRecord(..action, state: case settled_state(outcome) {
                  Definite(settled) | Indefinite(settled) -> settled
                }),
              )
            run.Running, None, False -> Error(SettlementEarly(id))
            _, _, _ -> Error(SettlementNotAwaited(id))
          }
        }),
      )
      Ok(#(stopped_when_idle(state, turn, actions, reason, halted), []))
    }
    Stopping(turn, actions, reason, halted), SettlementDue(id) -> {
      use actions <- result.try(
        update(actions, id, fn(action_state) {
          case action_state {
            run.Running -> Ok(run.Uncertain(no_settlement))
            _ -> Error(StaleEvent)
          }
        }),
      )
      Ok(#(stopped_when_idle(state, turn, actions, reason, halted), []))
    }
    Stopping(turn, actions, reason, halted), ChildStarted(id) -> {
      use actions <- result.try(child_started(actions, id))
      Ok(#(State(..state, phase: Stopping(turn, actions, reason, halted)), []))
    }
    Stopping(turn, actions, reason, halted), ChildEnded(id, result) -> {
      use #(actions, _) <- result.try(child_ended(
        actions,
        id,
        result,
        settle_with(env),
      ))
      Ok(#(stopped_when_idle(state, turn, actions, reason, halted), []))
    }
    Stopping(..), _ -> Error(StaleEvent)
  }
}

/// Cancels the run. It needs no environment: cancelling starts nothing.
/// A run that is already stopping asks again to cancel the child runs it
/// still waits on, in case an earlier request did not reach them.
pub fn cancel(state: State) -> Transition {
  case state.phase {
    Ended(_) | NeverStarted -> Error(RunEnded)
    AwaitingModel(_) ->
      Ok(#(State(..state, phase: Ended(run.Cancelled)), [AbortModel]))
    Acting(turn, actions) -> Ok(stop(state, turn, actions, CancelRequested))
    Stopping(actions:, ..) -> Ok(#(state, cancel_children(actions)))
  }
}

/// Cancels a run whose runner was lost: its work is abandoned first. A
/// stop the lost runner had begun is completed by abandoning it, and that
/// ending is the cancellation; one still waiting for child runs is asked
/// to cancel them again.
pub fn cancel_abandoned(state: State) -> Transition {
  case state.phase, abandon(state) {
    Stopping(..), State(phase: Ended(_), ..) as ended -> Ok(#(ended, []))
    Stopping(..), State(phase: Stopping(actions:, ..), ..) as stopping ->
      Ok(#(stopping, cancel_children(actions)))
    _, abandoned -> cancel(abandoned)
  }
}

/// Cancels a run with no agent and no runner (`fabric.cancel_stored`):
/// the work of a lost runner is abandoned, the ends of its children (read
/// by the caller after cancelling them) are applied with no delegation to
/// map them, so each is recorded as uncertain unless it never started, and
/// the run ends in this one transition.
pub fn cancel_unattended(
  state: State,
  ended: List(#(ActionId, ChildResult)),
) -> Transition {
  let stopping = case state.phase {
    Stopping(..) -> True
    _ -> False
  }
  let state = case needs_runner(state) {
    True -> abandon(state)
    False -> state
  }
  let unmapped = fn(_, _) { Error(Nil) }
  let apply = fn(actions) {
    list.fold(ended, actions, fn(actions, entry) {
      let #(id, result) = entry
      case child_ended(actions, id, result, unmapped) {
        Ok(#(actions, _)) -> actions
        Error(_) -> actions
      }
    })
  }
  let state = case state.phase {
    Acting(turn, actions) -> State(..state, phase: Acting(turn, apply(actions)))
    Stopping(turn, actions, reason, halted) ->
      stopped_when_idle(state, turn, apply(actions), reason, halted)
    AwaitingModel(_) | Ended(_) | NeverStarted -> state
  }
  case stopping, state.phase {
    True, Ended(_) -> Ok(#(state, []))
    _, _ -> cancel(state)
  }
}

const no_settlement = "stopped while running; no settlement arrived within the tool's bound"

/// A late settlement as an action state: definite (the model may see it),
/// or an effect that stays uncertain.
type SettledState {
  Definite(run.ActionState)
  Indefinite(run.ActionState)
}

fn settled_state(outcome: invocation.Outcome) -> SettledState {
  case outcome {
    invocation.Returned(content) -> Definite(run.Succeeded(content))
    invocation.FailedVisibly(content) -> Definite(run.ToolFailed(content))
    invocation.EffectUncertain(evidence) -> Indefinite(run.Uncertain(evidence))
    invocation.OutputUnencodable(detail)
    | invocation.ArgumentsRejected(detail) ->
      Indefinite(run.Uncertain(
        "the settlement could not be recorded: " <> detail,
      ))
  }
}

/// The executor has confirmed that no tool runs: running tools become
/// uncertain, queued ones not started, except the running ones in
/// `awaiting`, which wait for their late settlement. The run ends unless
/// child runs of the batch are still ending or settlements are awaited.
fn finish_stop(
  state: State,
  turn: Int,
  actions: List(ActionRecord),
  reason: StopReason,
  evidence: String,
  awaiting: List(ActionId),
) -> State {
  let actions =
    list.map(actions, fn(action) {
      case action.state, action.child {
        run.Running, None ->
          case list.contains(awaiting, action.id) {
            True -> action
            False -> ActionRecord(..action, state: run.Uncertain(evidence))
          }
        run.Running, Some(_) -> ActionRecord(..action, state: run.Delegated)
        run.Queued, _ -> ActionRecord(..action, state: run.NotStarted)
        _, _ -> action
      }
    })
  stopped_when_idle(state, turn, actions, reason, True)
}

/// Ends a stopping run once no tool runs, no settlement is awaited, and no
/// child run is active. `tools_stopped`: the executor confirmed that no
/// tool task runs.
fn stopped_when_idle(
  state: State,
  turn: Int,
  actions: List(ActionRecord),
  reason: StopReason,
  tools_stopped: Bool,
) -> State {
  case list.any(actions, fn(a) { tool_running(a) || child_active(a) }) {
    True ->
      State(..state, phase: Stopping(turn, actions, reason, tools_stopped))
    False -> end(state, actions, stop_outcome(reason))
  }
}

fn tool_running(action: ActionRecord) -> Bool {
  action.state == run.Running && action.child == None
}

/// A delegation whose child run is being started or runs.
fn child_active(action: ActionRecord) -> Bool {
  case action.state, action.child {
    run.Delegated, _ | run.Running, Some(_) -> True
    _, _ -> False
  }
}

fn cancel_children(actions: List(ActionRecord)) -> List(Effect) {
  case
    list.filter_map(actions, fn(action) {
      case child_active(action), action.child {
        True, Some(child) -> Ok(#(action.id, run.id_to_string(child)))
        _, _ -> Error(Nil)
      }
    })
  {
    [] -> []
    children -> [CancelChildren(children)]
  }
}

// --- sub-agents ----------------------------------------------------------------

/// Recovery found no record of a delegated child. An approved start asks
/// for its approval again, with no child: the context that passed its
/// recheck is gone. An allowed one is started again by recovery, and in a
/// live batch the report is out of date.
fn child_missing(
  state: State,
  turn: Int,
  actions: List(ActionRecord),
  id: ActionId,
) -> Transition {
  let issued = state.approvals_issued + 1
  use actions <- result.map(
    update_record(actions, id, fn(action) {
      case action.state, action.child, list.last(action.approvals) {
        run.Delegated, Some(_), Ok(approval) ->
          Ok(
            ActionRecord(
              ..action,
              state: run.AwaitingApproval(approval.requirement, issued),
              child: None,
            ),
          )
        _, _, _ -> Error(ReportNotExpected(id))
      }
    }),
  )
  #(State(..state, approvals_issued: issued, phase: Acting(turn, actions)), [])
}

fn child_started(
  actions: List(ActionRecord),
  id: ActionId,
) -> Result(List(ActionRecord), Rejection) {
  update_record(actions, id, fn(action) {
    case action.state, action.child {
      run.Running, Some(_) -> Ok(ActionRecord(..action, state: run.Delegated))
      _, _ -> Error(ReportNotExpected(id))
    }
  })
}

type Settle =
  fn(String, Outcome) -> Result(invocation.Outcome, Nil)

fn settle_with(env: Env(context)) -> Settle {
  fn(name, outcome) { registry.settle(env.registry, name, outcome) }
}

/// Applies a child run's end to its delegation. A child that left effects
/// of unknown status, or cannot be read, makes the delegation uncertain;
/// otherwise the delegation maps the child's outcome.
fn child_ended(
  actions: List(ActionRecord),
  id: ActionId,
  result: ChildResult,
  settle: Settle,
) -> Result(#(List(ActionRecord), Option(HostFailure)), Rejection) {
  use action <- result.try(
    list.find(actions, fn(action) { action.id == id })
    |> result.replace_error(UnknownAction(id)),
  )
  use child <- result.try(case child_active(action), action.child {
    True, Some(child) -> Ok(child)
    _, _ -> Error(ReportNotExpected(id))
  })
  let named = "the sub-agent run " <> run.id_to_string(child)
  let #(action_state, fault) = case result {
    ChildMissing -> #(run.NotStarted, None)
    ChildLost(detail) -> #(
      run.Uncertain(named <> " cannot be continued: " <> detail),
      None,
    )
    ChildStopping -> #(
      run.Uncertain(
        named <> " was cancelled and is still stopping; its end is not applied",
      ),
      None,
    )
    ChildFinished(_, True) -> #(
      run.Uncertain(named <> " ended with effects of unknown status"),
      None,
    )
    ChildFinished(outcome, False) ->
      case settle(action.call.name, outcome) {
        Ok(invocation.Returned(content)) -> #(run.Succeeded(content), None)
        Ok(invocation.FailedVisibly(content)) -> #(
          run.ToolFailed(content),
          None,
        )
        Ok(invocation.EffectUncertain(evidence)) -> #(
          run.Uncertain(evidence),
          None,
        )
        Ok(invocation.OutputUnencodable(detail)) -> #(
          run.Faulted(detail),
          Some(run.OutputEncodingFailed(id, detail)),
        )
        Ok(invocation.ArgumentsRejected(detail)) -> #(
          run.Faulted(detail),
          Some(run.ToolChanged(id, detail)),
        )
        Error(Nil) -> #(
          run.Uncertain(named <> " ended, and no delegation maps its outcome"),
          None,
        )
      }
  }
  let actions =
    list.map(actions, fn(other) {
      case other.id == id {
        True -> ActionRecord(..other, state: action_state)
        False -> other
      }
    })
  Ok(#(actions, fault))
}

/// How many sub-agent runs `records` started or may still start (awaiting
/// an approval).
fn children_reserved(env: Env(context), records: List(ActionRecord)) -> Int {
  list.count(records, fn(record) {
    case record.child, record.state {
      Some(_), _ -> True
      None, run.AwaitingApproval(..) ->
        registry.is_delegation(env.registry, record.call.name)
      None, _ -> False
    }
  })
}

/// The id of the next child run: the parent's id and a sequence number, so
/// that it is deterministic and a valid run id.
fn next_child(state: State, records: List(ActionRecord)) -> String {
  let started = list.count(records, fn(record) { record.child != None })
  state.run <> "-" <> int.to_string(started + 1)
}

fn start_children(actions: List(ActionRecord)) -> List(Effect) {
  list.filter_map(actions, fn(action) {
    case action.state, action.child {
      run.Running, Some(child) ->
        Ok(StartChild(action.id, run.id_to_string(child), action.call))
      _, _ -> Error(Nil)
    }
  })
}

fn update_record(
  actions: List(ActionRecord),
  id: ActionId,
  change: fn(ActionRecord) -> Result(ActionRecord, Rejection),
) -> Result(List(ActionRecord), Rejection) {
  case list.any(actions, fn(action) { action.id == id }) {
    False -> Error(UnknownAction(id))
    True ->
      list.try_map(actions, fn(action) {
        case action.id == id {
          False -> Ok(action)
          True -> change(action)
        }
      })
  }
}

// --- approvals -----------------------------------------------------------------

fn answer_approval(
  env: Env(context),
  state: State,
  reference: ApprovalRef,
  answer: Answer,
  reviewer: Option(String),
) -> Transition {
  let find = fn(actions: List(ActionRecord)) {
    list.find(actions, fn(action) { action.id == reference.id })
  }
  case run.id_to_string(reference.run) == state.run, state.phase {
    False, _ -> Error(WrongReference)
    True, Ended(_) | True, NeverStarted ->
      Error(after_end(state.history, reference))
    True, Stopping(actions:, ..) ->
      Error(after_end(list.append(state.history, actions), reference))
    True, Acting(turn, actions) ->
      case find(actions) {
        Ok(
          ActionRecord(state: run.AwaitingApproval(requirement, revision), ..) as action,
        )
          if requirement == reference.requirement
          && revision == reference.revision
        ->
          Ok(decide(
            env,
            state,
            turn,
            actions,
            action,
            run.Approval(requirement, revision, answer, reviewer),
          ))
        Ok(action) -> Error(unanswerable(action, reference))
        Error(Nil) -> Error(in_history(state, reference))
      }
    True, AwaitingModel(_) -> Error(in_history(state, reference))
  }
}

/// An ended run accepts no answer. A request it answered is reported as
/// answered; any other request of the run was voided by the ending.
fn after_end(actions: List(ActionRecord), reference: ApprovalRef) -> Rejection {
  case list.find(actions, fn(action) { action.id == reference.id }) {
    Error(Nil) -> WrongReference
    Ok(action) ->
      case
        list.any(action.approvals, fn(approval) {
          approval.revision == reference.revision
        })
      {
        True -> AlreadyAnswered
        False -> RunEnded
      }
  }
}

fn in_history(state: State, reference: ApprovalRef) -> Rejection {
  case list.find(state.history, fn(action) { action.id == reference.id }) {
    Ok(action) -> unanswerable(action, reference)
    Error(Nil) -> WrongReference
  }
}

/// Why `reference` cannot be answered on `action`.
fn unanswerable(action: ActionRecord, reference: ApprovalRef) -> Rejection {
  let answered =
    list.any(action.approvals, fn(approval) {
      approval.revision == reference.revision
    })
  case answered, action.approvals, action.state {
    // A request superseded by a new one is stale even though it was
    // answered.
    _, _, run.AwaitingApproval(..) -> StaleReference
    True, _, _ -> AlreadyAnswered
    False, [], _ -> WrongReference
    False, _, _ -> StaleReference
  }
}

/// Applies an answer to an action awaiting it. An approval is checked
/// again against the current policy and context: a denial or a policy
/// failure wins, and a different requirement issues a new request.
fn decide(
  env: Env(context),
  state: State,
  turn: Int,
  actions: List(ActionRecord),
  action: ActionRecord,
  approval: run.Approval,
) -> #(State, List(Effect)) {
  let answered = fn(action_state) {
    ActionRecord(
      ..action,
      state: action_state,
      approvals: list.append(action.approvals, [approval]),
    )
  }
  let replace = fn(changed: ActionRecord) {
    list.map(actions, fn(other) {
      case other.id == changed.id {
        True -> changed
        False -> other
      }
    })
  }
  case approval.answer {
    run.Reject(reason) -> {
      let actions = replace(answered(run.Rejected(reason)))
      settle(env, State(..state, phase: Acting(turn, actions)))
    }
    run.Approve -> {
      let others =
        list.append(
          state.history,
          list.filter(actions, fn(other) { other.id != action.id }),
        )
      case gate(env, state, action.id, action.call, others) {
        Error(failure) ->
          stop(state, turn, replace(answered(action.state)), HostFault(failure))
        Ok(Decided(policy.RequireApproval(required)))
          if required != approval.requirement
        -> {
          let issued = state.approvals_issued + 1
          // The superseded answer stays on the action for the audit
          // trail; it authorizes nothing.
          let actions =
            replace(answered(run.AwaitingApproval(required, issued)))
          #(
            State(
              ..state,
              approvals_issued: issued,
              phase: Acting(turn, actions),
            ),
            [],
          )
        }
        Ok(gated) -> {
          // The approval answers the requirement the policy still asks for.
          let gated = case gated {
            Decided(policy.RequireApproval(_)) -> Decided(policy.Allow)
            other -> other
          }
          let admitted =
            admitted(env, state, action.id, action.call, gated, 0, others)
          let approved =
            ActionRecord(..answered(admitted.state), child: admitted.child)
          let state = State(..state, phase: Acting(turn, replace(approved)))
          let #(state, effects) = settle(env, state)
          #(
            state,
            list.flatten([
              dispatch([approved]),
              start_children([approved]),
              effects,
            ]),
          )
        }
      }
    }
  }
}

fn model_replied(
  env: Env(context),
  state: State,
  turn: Int,
  reply: Reply,
) -> #(State, List(Effect)) {
  let state = State(..state, usage: add_usage(state.usage, reply_usage(reply)))
  case reply {
    model.FinalAnswer(text, _) -> #(
      State(
        ..state,
        transcript: list.append(state.transcript, [
          model.AssistantMessage(text, []),
        ]),
        phase: Ended(run.Completed(text)),
      ),
      [],
    )
    model.Refusal(reason, _) -> #(
      State(..state, phase: Ended(run.Refused(reason))),
      [],
    )
    model.Truncated(partial, _) -> #(
      State(..state, phase: Ended(run.OutputLimited(partial))),
      [],
    )
    model.ToolRequest(text, calls, usage) ->
      tools_requested(env, state, turn, text, calls, usage)
  }
}

fn tools_requested(
  env: Env(context),
  state: State,
  turn: Int,
  text: String,
  calls: List(ToolCall),
  usage: Option(model.Usage),
) -> #(State, List(Effect)) {
  case protocol_violation(calls) {
    Some(reason) -> #(
      State(
        ..state,
        phase: Ended(run.Failed(run.ModelProtocolViolation(reason))),
      ),
      [],
    )
    None -> {
      let state =
        State(
          ..state,
          transcript: list.append(state.transcript, [
            model.AssistantMessage(text, calls),
          ]),
        )
      let withdrawn =
        list.map(calls, fn(call) {
          ActionRecord(ActionId(turn, call.id), call, run.NotStarted, [], None)
        })
      case continuation_blocked(state, usage) {
        Some(outcome) -> #(end(state, withdrawn, outcome), [])
        None -> admit_batch(env, state, turn, calls, withdrawn)
      }
    }
  }
}

fn protocol_violation(calls: List(ToolCall)) -> Option(String) {
  case calls {
    [] -> Some("the model requested an empty tool batch")
    _ -> {
      let ids = list.map(calls, fn(call) { call.id })
      case set.size(set.from_list(ids)) == list.length(ids) {
        True -> None
        False -> Some("the model reused a call id within one turn")
      }
    }
  }
}

/// Whether the results of new tool calls could still be sent to the model.
fn continuation_blocked(
  state: State,
  usage: Option(model.Usage),
) -> Option(Outcome) {
  case state.limits.token_budget, usage {
    Some(_), None -> Some(run.BudgetUnverifiable(state.turns_used))
    Some(budget), Some(_) ->
      case tokens_used(state.usage) >= budget {
        True -> Some(token_exhausted(state, budget))
        False -> turn_blocked(state)
      }
    None, _ -> turn_blocked(state)
  }
}

fn turn_blocked(state: State) -> Option(Outcome) {
  case state.turns_used >= state.limits.max_turns {
    True -> Some(run.BudgetExhausted(run.TurnLimit(state.limits.max_turns)))
    False -> None
  }
}

fn token_exhausted(state: State, budget: Int) -> Outcome {
  run.BudgetExhausted(run.TokenLimit(budget, tokens_used(state.usage)))
}

fn admit_batch(
  env: Env(context),
  state: State,
  turn: Int,
  calls: List(ToolCall),
  withdrawn: List(ActionRecord),
) -> #(State, List(Effect)) {
  let admitted =
    list.try_fold(calls, #(state.approvals_issued, []), fn(acc, call) {
      let #(issued, records) = acc
      let id = ActionId(turn, call.id)
      let others = list.append(state.history, records)
      use gated <- result.map(gate(env, state, id, call, others))
      let record = admitted(env, state, id, call, gated, issued, others)
      let issued = case record.state {
        run.AwaitingApproval(..) -> issued + 1
        _ -> issued
      }
      #(issued, list.append(records, [record]))
    })
  case admitted {
    Error(failure) -> #(end(state, withdrawn, run.Failed(failure)), [])
    Ok(#(issued, actions)) -> {
      let state =
        State(..state, approvals_issued: issued, phase: Acting(turn, actions))
      let #(state, effects) = settle(env, state)
      #(
        state,
        list.flatten([dispatch(actions), start_children(actions), effects]),
      )
    }
  }
}

/// What the gate says about a call: refused before the policy (unknown
/// tool, malformed arguments), or the policy's decision.
type Gated {
  Refused(ActionState)
  Decided(policy.Decision)
}

/// `others` are the run's other actions, for the sub-agent budgets: a
/// delegation is refused before the policy when the run is too deep or has
/// reserved every child it may start.
fn gate(
  env: Env(context),
  state: State,
  id: ActionId,
  call: ToolCall,
  others: List(ActionRecord),
) -> Result(Gated, HostFailure) {
  let target = registry.target(env.registry, call.name)
  let limits = state.limits
  case registry.admit(env.registry, call.name, call.arguments_json), target {
    Error(registry.NotRegistered), _ -> Ok(Refused(run.UnknownTool))
    Error(registry.MalformedArguments(detail)), _ ->
      Ok(Refused(run.InvalidArguments(detail)))
    Ok(Nil), policy.StartAgent(..) if state.depth >= limits.max_depth ->
      Ok(Refused(run.LimitReached(run.DepthLimit(limits.max_depth))))
    Ok(Nil), policy.StartAgent(..) ->
      case children_reserved(env, others) >= limits.max_children {
        True ->
          Ok(Refused(run.LimitReached(run.ChildLimit(limits.max_children))))
        False -> decide_policy(env, state.run, id, call, target)
      }
    Ok(Nil), policy.InvokeTool ->
      decide_policy(env, state.run, id, call, target)
  }
}

fn decide_policy(
  env: Env(context),
  run_id: String,
  id: ActionId,
  call: ToolCall,
  target: policy.Target,
) -> Result(Gated, HostFailure) {
  env.policy(
    env.context,
    policy.Action(
      run.issued(run_id),
      id,
      call.name,
      call.arguments_json,
      target,
    ),
  )
  |> result.map(Decided)
  |> result.map_error(run.PolicyFailed(id, _))
}

/// The record of a gated call. An allowed tool is queued for the executor;
/// an allowed delegation is committed running with its child run id, and
/// the runner starts the child after the commit.
fn admitted(
  env: Env(context),
  state: State,
  id: ActionId,
  call: ToolCall,
  gated: Gated,
  issued: Int,
  others: List(ActionRecord),
) -> ActionRecord {
  let record = fn(action_state) {
    ActionRecord(id, call, action_state, [], None)
  }
  case gated {
    Refused(action_state) -> record(action_state)
    Decided(policy.Deny(reason)) -> record(run.Denied(reason))
    Decided(policy.RequireApproval(requirement)) ->
      record(run.AwaitingApproval(requirement, issued + 1))
    Decided(policy.Allow) ->
      case registry.is_delegation(env.registry, call.name) {
        False -> record(run.Queued)
        True ->
          ActionRecord(
            ..record(run.Running),
            child: Some(run.issued(next_child(state, others))),
          )
      }
  }
}

fn accept_report(
  id: ActionId,
  outcome: invocation.Outcome,
) -> fn(ActionState) -> Result(ActionState, Rejection) {
  fn(action_state) {
    case action_state {
      run.Running ->
        Ok(case outcome {
          invocation.Returned(content) -> run.Succeeded(content)
          invocation.FailedVisibly(content) -> run.ToolFailed(content)
          invocation.EffectUncertain(evidence) -> run.Uncertain(evidence)
          invocation.ArgumentsRejected(detail)
          | invocation.OutputUnencodable(detail) -> run.Faulted(detail)
        })
      _ -> Error(ReportNotExpected(id))
    }
  }
}

/// A task that died without reporting may have started its body even when
/// its fence was not yet committed, so both cases are uncertain.
fn lose(
  id: ActionId,
  reason: String,
) -> fn(ActionState) -> Result(ActionState, Rejection) {
  fn(action_state) {
    case action_state {
      run.Running | run.Queued ->
        Ok(run.Uncertain("tool task exited without a report: " <> reason))
      _ -> Error(ReportNotExpected(id))
    }
  }
}

/// A report that means the host, not the tool's business logic, failed.
fn host_fault(
  id: ActionId,
  outcome: invocation.Outcome,
) -> Option(HostFailure) {
  case outcome {
    invocation.OutputUnencodable(detail) ->
      Some(run.OutputEncodingFailed(id, detail))
    invocation.ArgumentsRejected(detail) -> Some(run.ToolChanged(id, detail))
    invocation.Returned(_)
    | invocation.FailedVisibly(_)
    | invocation.EffectUncertain(_) -> None
  }
}

/// Withdraws everything not started. Running tools must be stopped first.
fn stop(
  state: State,
  turn: Int,
  actions: List(ActionRecord),
  reason: StopReason,
) -> #(State, List(Effect)) {
  let actions =
    list.map(actions, fn(action) {
      case action.state {
        run.Queued | run.AwaitingApproval(..) ->
          ActionRecord(..action, state: run.NotStarted)
        _ -> action
      }
    })
  let running = list.any(actions, tool_running)
  let stop_tools = case running {
    True -> [StopTools]
    False -> []
  }
  let effects = list.append(stop_tools, cancel_children(actions))
  #(stopped_when_idle(state, turn, actions, reason, !running), effects)
}

fn stop_outcome(reason: StopReason) -> Outcome {
  case reason {
    CancelRequested -> run.Cancelled
    HostFault(failure) -> run.Failed(failure)
  }
}

/// When every action of the batch has a model-visible result, feed the
/// results back in the model's call order and request the next turn.
fn settle(env: Env(context), state: State) -> #(State, List(Effect)) {
  case state.phase {
    Acting(_, actions) ->
      case list.try_map(actions, fn(action) { model_content(action.state) }) {
        Error(Nil) -> #(state, [])
        Ok(contents) -> {
          let results =
            list.map2(actions, contents, fn(action, content) {
              model.ToolResultMessage(action.call.id, content)
            })
          State(
            ..state,
            transcript: list.append(state.transcript, results),
            history: list.append(state.history, actions),
          )
          |> call_model(env, _)
        }
      }
    _ -> #(state, [])
  }
}

fn model_failed(
  env: Env(context),
  state: State,
  error: ModelError,
) -> #(State, List(Effect)) {
  case error.retryable {
    // A retry the turn budget refuses ends the run on the budget.
    True -> call_model(env, state)
    False -> #(
      State(..state, phase: Ended(run.Failed(run.ModelFailed(error)))),
      [],
    )
  }
}

/// Every attempted model call counts against the turn limit.
fn call_model(env: Env(context), state: State) -> #(State, List(Effect)) {
  case state.turns_used >= state.limits.max_turns {
    True -> #(
      State(
        ..state,
        phase: Ended(run.BudgetExhausted(run.TurnLimit(state.limits.max_turns))),
      ),
      [],
    )
    False -> {
      let turn = state.turns_used + 1
      let request =
        model.Request(
          system: env.system,
          messages: state.transcript,
          tools: offered_tools(env, state),
        )
      #(State(..state, turns_used: turn, phase: AwaitingModel(turn)), [
        CallModel(turn, request),
      ])
    }
  }
}

/// The tools declared to the model. Delegations are left out when this
/// run may start no sub-agent at all (no children allowed, as for a record
/// written before sub-agents, or no depth left): they would always be
/// refused.
fn offered_tools(env: Env(context), state: State) -> List(model.ToolSpec) {
  let declared = registry.declarations(env.registry)
  case state.limits.max_children == 0 || state.depth >= state.limits.max_depth {
    False -> declared
    True ->
      list.filter(declared, fn(spec) {
        !registry.is_delegation(env.registry, spec.name)
      })
  }
}

fn end(state: State, actions: List(ActionRecord), outcome: Outcome) -> State {
  State(
    ..state,
    history: list.append(state.history, actions),
    phase: Ended(outcome),
  )
}

fn dispatch(actions: List(ActionRecord)) -> List(Effect) {
  case list.filter(actions, fn(action) { action.state == run.Queued }) {
    [] -> []
    queued -> [
      Dispatch(list.map(queued, fn(action) { #(action.id, action.call) })),
    ]
  }
}

fn update(
  actions: List(ActionRecord),
  id: ActionId,
  change: fn(ActionState) -> Result(ActionState, Rejection),
) -> Result(List(ActionRecord), Rejection) {
  case list.any(actions, fn(action) { action.id == id }) {
    False -> Error(UnknownAction(id))
    True ->
      list.try_map(actions, fn(action) {
        case action.id == id {
          False -> Ok(action)
          True ->
            change(action.state)
            |> result.map(fn(action_state) {
              ActionRecord(..action, state: action_state)
            })
        }
      })
  }
}

fn add_usage(total: TokenUsage, usage: Option(model.Usage)) -> TokenUsage {
  case usage {
    Some(model.Usage(input, output)) ->
      run.TokenUsage(
        ..total,
        input_tokens: total.input_tokens + input,
        output_tokens: total.output_tokens + output,
      )
    None ->
      run.TokenUsage(..total, unreported_replies: total.unreported_replies + 1)
  }
}

fn reply_usage(reply: Reply) -> Option(model.Usage) {
  case reply {
    model.FinalAnswer(usage:, ..)
    | model.ToolRequest(usage:, ..)
    | model.Refusal(usage:, ..)
    | model.Truncated(usage:, ..) -> usage
  }
}

fn tokens_used(usage: TokenUsage) -> Int {
  usage.input_tokens + usage.output_tokens
}

/// The content the model sees for a settled action.
pub fn model_content(action_state: ActionState) -> Result(String, Nil) {
  case action_state {
    run.Succeeded(content)
    | run.ToolFailed(content)
    | run.Reconciled(content) -> Ok(content)
    run.Denied(reason) -> Ok(invocation.error_detail_content("denied", reason))
    run.Rejected(reason) ->
      Ok(invocation.error_detail_content("rejected", reason))
    run.InvalidArguments(detail) ->
      Ok(invocation.error_detail_content("invalid_arguments", detail))
    run.UnknownTool -> Ok(invocation.error_content("unknown_tool"))
    run.LimitReached(budget) ->
      Ok(invocation.error_detail_content("limit_reached", describe(budget)))
    run.Queued
    | run.Running
    | run.AwaitingApproval(..)
    | run.Uncertain(_)
    | run.NotStarted
    | run.Delegated
    | run.Faulted(_) -> Error(Nil)
  }
}

fn describe(limit: run.DelegationLimit) -> String {
  case limit {
    run.ChildLimit(limit) ->
      "at most " <> int.to_string(limit) <> " sub-agent runs per run"
    run.DepthLimit(limit) ->
      "sub-agents nest at most " <> int.to_string(limit) <> " levels deep"
  }
}

// --- recovery ------------------------------------------------------------------

const lost_evidence = "the runner was lost while the tool ran; its effect may have happened"

/// Takes over a record whose runner was lost, as a new incarnation. A
/// running tool may have taken effect, so it becomes an uncertain effect
/// (never retried); a stop in progress completes. Queued actions never
/// started and stay queued; a lost model call stays pending.
pub fn abandon(state: State) -> State {
  let state = State(..state, incarnation: state.incarnation + 1)
  case state.phase {
    Acting(turn, actions) ->
      State(
        ..state,
        phase: Acting(
          turn,
          list.map(actions, fn(action) {
            case action.state, action.child {
              run.Running, None ->
                ActionRecord(..action, state: run.Uncertain(lost_evidence))
              // The child run is durable: it exists, or recovery starts it.
              run.Running, Some(_) ->
                ActionRecord(..action, state: run.Delegated)
              _, _ -> action
            }
          }),
        ),
      )
    Stopping(turn, actions, reason, _) ->
      finish_stop(state, turn, actions, reason, lost_evidence, [])
    AwaitingModel(_) | Ended(_) | NeverStarted -> state
  }
}

/// `abandon`, then restarts the work that is safe to restart: queued
/// actions are dispatched again and a lost model call is issued again as a
/// new attempt against the turn budget. A queued action that was approved
/// is not: it asks for its approval again (`ask_again`).
///
/// Delegated actions are left to the runtime, which reattaches their child
/// runs; a stop still waiting for child runs asks to cancel them again.
pub fn recover(env: Env(context), state: State) -> #(State, List(Effect)) {
  let state = abandon(state)
  case state.phase {
    AwaitingModel(_) -> call_model(env, state)
    Acting(turn, actions) -> {
      let state = ask_again(state, turn, actions)
      #(state, dispatch(current(state)))
    }
    Stopping(actions:, ..) -> #(state, cancel_children(actions))
    Ended(_) | NeverStarted -> #(state, [])
  }
}

/// Queued actions that an answer approved ask for their approval again,
/// under the requirement last answered, as new requests: the approval was
/// checked with the answer's context, which a later incarnation does not
/// have. The earlier answers stay in the approvals; they authorize nothing.
fn ask_again(state: State, turn: Int, actions: List(ActionRecord)) -> State {
  let #(issued, actions) =
    list.map_fold(actions, state.approvals_issued, fn(issued, action) {
      case action.state, list.last(action.approvals) {
        run.Queued, Ok(approval) -> #(
          issued + 1,
          ActionRecord(
            ..action,
            state: run.AwaitingApproval(approval.requirement, issued + 1),
          ),
        )
        _, _ -> #(issued, action)
      }
    })
  State(..state, approvals_issued: issued, phase: Acting(turn, actions))
}

/// The actions of the current batch.
fn current(state: State) -> List(ActionRecord) {
  case state.phase {
    Acting(_, actions) | Stopping(actions:, ..) -> actions
    AwaitingModel(_) | Ended(_) | NeverStarted -> []
  }
}

/// The delegations whose child run is active: (action, delegation name,
/// child run id).
pub fn active_children(state: State) -> List(#(ActionId, String, String)) {
  case state.phase {
    Acting(_, actions) | Stopping(actions:, ..) ->
      list.filter_map(actions, fn(action) {
        case child_active(action), action.child {
          True, Some(child) ->
            Ok(#(action.id, action.call.name, run.id_to_string(child)))
          _, _ -> Error(Nil)
        }
      })
    AwaitingModel(_) | Ended(_) | NeverStarted -> []
  }
}

/// The record of the child run `child` of `parent`'s delegation `action`
/// that was cancelled before it was ever stored: a cancelling parent
/// stores it (insert-if-absent) in place of a child it could not find, so
/// that a start or a recovery racing the cancellation finds the run ended
/// and never runs it. It has no transcript.
pub fn never_started(
  parent: State,
  action: ActionId,
  child: String,
  agent: Identity,
) -> State {
  State(
    run: child,
    agent:,
    incarnation: 1,
    parent: Some(run.ActionRef(run.issued(parent.run), action)),
    depth: parent.depth + 1,
    limits: parent.limits,
    turns_used: 0,
    usage: run.TokenUsage(0, 0, 0),
    transcript: [],
    history: [],
    approvals_issued: 0,
    phase: NeverStarted,
  )
}

/// What the run's end means for the delegation that started it. A run
/// cancelled before it started (`never_started`) is missing.
pub fn child_result(state: State) -> Result(ChildResult, Nil) {
  case state.phase {
    NeverStarted -> Ok(ChildMissing)
    Ended(outcome) ->
      Ok(ChildFinished(
        outcome,
        list.any(state.history, fn(action) {
          case action.state {
            run.Uncertain(_) -> True
            _ -> False
          }
        }),
      ))
    AwaitingModel(_) | Acting(..) | Stopping(..) -> Error(Nil)
  }
}

// --- read model ----------------------------------------------------------------

pub fn status(state: State) -> Status {
  case state.phase {
    Ended(outcome) -> run.Finished(outcome)
    NeverStarted -> run.Finished(run.Cancelled)
    AwaitingModel(_) | Stopping(..) -> run.Working
    Acting(_, actions) ->
      case in_flight(actions) {
        True -> run.Working
        False ->
          run.Suspended(
            list.filter_map(actions, fn(action) {
              case action.state {
                run.AwaitingApproval(requirement, revision) ->
                  Ok(run.PendingApproval(
                    run.ApprovalRef(
                      run.issued(state.run),
                      action.id,
                      requirement,
                      revision,
                    ),
                    action.call.name,
                    action.call.arguments_json,
                  ))
                _ -> Error(Nil)
              }
            }),
            list.filter_map(actions, fn(action) {
              case action.state {
                run.Uncertain(evidence) ->
                  Ok(run.UncertainAction(
                    run.ActionRef(run.issued(state.run), action.id),
                    action.call.name,
                    evidence,
                  ))
                _ -> Error(Nil)
              }
            }),
          )
      }
  }
}

/// Whether a live process is needed: a model call or tools are in flight.
pub fn needs_runner(state: State) -> Bool {
  case state.phase {
    AwaitingModel(_) | Stopping(..) -> True
    Acting(_, actions) -> in_flight(actions)
    Ended(_) | NeverStarted -> False
  }
}

fn in_flight(actions: List(ActionRecord)) -> Bool {
  list.any(actions, fn(action) {
    action.state == run.Queued || action.state == run.Running
  })
}

pub fn snapshot(state: State) -> run.Snapshot {
  run.Snapshot(
    run: run.issued(state.run),
    agent: state.agent,
    incarnation: state.incarnation,
    parent: state.parent,
    status: status(state),
    turns_used: state.turns_used,
    max_turns: state.limits.max_turns,
    usage: state.usage,
    transcript: state.transcript,
    actions: list.append(state.history, current(state)),
  )
}

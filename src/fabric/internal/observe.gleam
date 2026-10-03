//// Emits Fabric's Sinal events for one committed transition, derived from
//// the state before and after the commit (see `fabric/telemetry`). The
//// runtime calls it after every successful commit. `sinal.emit` follows
//// forwarder routes, so the application decides whether `[fabric]`
//// handlers run in the committing process or in a forwarder; a dropped
//// event is ignored, because observation never controls a run.

import fabric/internal/controller.{type State}
import fabric/internal/invocation
import fabric/model
import fabric/run.{type ActionId, type ActionRecord}
import fabric/telemetry.{Action} as o
import fabric/tool as fabric_tool
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import sinal
import sinal/correlation.{type Correlation}

pub fn committed(before: Option(State), after: State) -> Nil {
  started(before, after)
  recovered(before, after)
  model_turn(before, after)
  actions(before, after)
  cancelled(before, after)
  finished(before, after)
}

/// A draining runner committed the handoff of `state`.
pub fn handed_off(state: State) -> Nil {
  emit(
    o.run_handed_off(),
    Nil,
    o.RunHandedOff(state.run, state.incarnation, state.correlation),
  )
}

pub fn drained(summary: o.Drain, store: String) -> Nil {
  emit(o.drain(), summary, store)
}

pub fn drain_unavailable(store: String) -> Nil {
  emit(o.drain_unavailable(), Nil, store)
}

/// A recovery took over `state` from the lease of `previous_owner`.
pub fn taken_over(state: State, previous_owner: String) -> Nil {
  emit(
    o.run_taken_over(),
    Nil,
    o.RunTakenOver(
      state.run,
      state.incarnation,
      previous_owner,
      state.correlation,
    ),
  )
}

/// The leased store `owner` killed the runner of `run`.
pub fn lease_lost(run: String, owner: String, reason: o.LeaseLoss) -> Nil {
  emit(o.lease_lost(), Nil, o.LeaseLost(run, owner, reason))
}

/// The leased store `owner` failed to renew the leases of `runs` runners.
pub fn renewal_failed(owner: String, runs: Int) -> Nil {
  emit(o.renewal_failed(), Nil, o.RenewalFailed(owner, runs))
}

fn started(before: Option(State), after: State) -> Nil {
  case before {
    Some(_) -> Nil
    None ->
      emit(
        o.run_started(),
        Nil,
        o.RunStarted(
          after.run,
          after.agent.name,
          after.agent.version,
          option.map(after.parent, fn(parent) { run.id_to_string(parent.run) }),
          after.correlation,
        ),
      )
  }
}

fn recovered(before: Option(State), after: State) -> Nil {
  case before {
    Some(before) if after.incarnation > before.incarnation ->
      emit(
        o.run_recovered(),
        Nil,
        o.RunRecovered(after.run, after.incarnation, after.correlation),
      )
    _ -> Nil
  }
}

fn model_turn(before: Option(State), after: State) -> Nil {
  case before {
    Some(before) if before.incarnation == after.incarnation ->
      case before.phase {
        controller.AwaitingModel(turn) ->
          case turn_result(turn, after) {
            Some(result) ->
              emit(
                o.model_turn(),
                turn_usage(before, after, result),
                o.ModelTurn(after.run, turn, result, after.correlation),
              )
            None -> Nil
          }
        _ -> Nil
      }
    _ -> Nil
  }
}

/// The tokens the reply to this attempt reported; `None` when no reply
/// arrived or it did not report usage, never a zero that was not reported.
fn turn_usage(
  before: State,
  after: State,
  result: o.TurnResult,
) -> Option(model.Usage) {
  let replied = case result {
    o.Retry | o.ModelFailure -> False
    // A budget stop ends the run either after a reply (whose assistant turn
    // the transcript then holds) or after a failed or aborted attempt.
    o.BudgetStop ->
      list.length(after.transcript) > list.length(before.transcript)
    o.ToolRequest
    | o.FinalAnswer
    | o.Refusal
    | o.Truncated
    | o.ProtocolViolation -> True
  }
  let reported =
    after.usage.unreported_replies == before.usage.unreported_replies
  case replied && reported {
    True ->
      Some(model.Usage(
        after.usage.input_tokens - before.usage.input_tokens,
        after.usage.output_tokens - before.usage.output_tokens,
      ))
    False -> None
  }
}

/// What the attempt `turn` produced, judged by where the run went; `None`
/// when the attempt is still in flight or was cancelled.
fn turn_result(turn: Int, after: State) -> Option(o.TurnResult) {
  case after.phase {
    controller.AwaitingModel(next) if next == turn -> None
    controller.AwaitingModel(_) -> Some(o.Retry)
    controller.Acting(..) | controller.Stopping(..) -> Some(o.ToolRequest)
    controller.Ended(run.Completed(_)) -> Some(o.FinalAnswer)
    controller.Ended(run.Refused(_)) -> Some(o.Refusal)
    controller.Ended(run.OutputLimited(_)) -> Some(o.Truncated)
    controller.Ended(run.Failed(run.ModelFailed(_))) -> Some(o.ModelFailure)
    controller.Ended(run.Failed(run.ModelProtocolViolation(_))) ->
      Some(o.ProtocolViolation)
    controller.Ended(run.Failed(_)) -> Some(o.ToolRequest)
    controller.Ended(run.BudgetExhausted(_))
    | controller.Ended(run.BudgetUnverifiable(_)) -> Some(o.BudgetStop)
    controller.Ended(run.Cancelled) | controller.NeverStarted -> None
  }
}

fn every_action(state: State) -> List(ActionRecord) {
  case state.phase {
    controller.Acting(_, actions) | controller.Stopping(actions:, ..) ->
      list.append(state.history, actions)
    controller.AwaitingModel(_)
    | controller.Ended(_)
    | controller.NeverStarted -> state.history
  }
}

fn actions(before: Option(State), after: State) -> Nil {
  let earlier = case before {
    Some(before) ->
      every_action(before)
      |> list.map(fn(action) { #(action.id, action) })
      |> dict.from_list
    None -> dict.new()
  }
  list.each(every_action(after), fn(action) {
    let previous = dict.get(earlier, action.id) |> option.from_result
    action_changed(after.run, after.correlation, previous, action)
  })
}

fn action_changed(
  run_id: String,
  correlation: Correlation,
  before: Option(ActionRecord),
  after: ActionRecord,
) -> Nil {
  let reference =
    Action(run_id, after.id.turn, after.id.call_id, after.call.name)
  let old_state = option.map(before, fn(action) { action.state })
  let old_approvals = case before {
    Some(action) -> list.length(action.approvals)
    None -> 0
  }
  // Answers, oldest first.
  list.drop(after.approvals, old_approvals)
  |> list.each(fn(approval) {
    emit(
      o.approval_answered(),
      Nil,
      o.ApprovalAnswered(
        reference,
        approval.revision,
        case approval.answer {
          run.Approve -> o.Approved
          run.Reject(_) -> o.Rejected
        },
        correlation,
      ),
    )
  })
  case after.state {
    run.AwaitingApproval(requirement, revision)
      if old_state != Some(run.AwaitingApproval(requirement, revision))
    ->
      emit(
        o.approval_requested(),
        Nil,
        o.ApprovalRequested(
          reference,
          requirement.name,
          requirement.version,
          revision,
          correlation,
        ),
      )
    _ -> Nil
  }
  case after.child {
    None -> tool_changed(reference, correlation, old_state, after.state)
    Some(child) ->
      child_changed(
        reference,
        correlation,
        run.id_to_string(child),
        old_state,
        after.state,
      )
  }
}

fn tool_changed(
  reference: o.Action,
  correlation: Correlation,
  before: Option(run.ActionState),
  after: run.ActionState,
) -> Nil {
  case before, after {
    Some(run.Running), run.Running -> Nil
    _, run.Running ->
      emit(o.tool_dispatched(), Nil, o.ToolDispatched(reference, correlation))
    Some(run.Running), _ ->
      case disposition(after) {
        Some(disposition) ->
          emit(
            o.tool_settled(),
            Nil,
            o.ToolSettled(reference, disposition, correlation),
          )
        None -> Nil
      }
    // A task lost before its fence may have run its body.
    Some(run.Queued), run.Uncertain(_) ->
      emit(
        o.tool_settled(),
        Nil,
        o.ToolSettled(reference, o.EffectUncertain, correlation),
      )
    _, _ -> Nil
  }
}

fn child_changed(
  reference: o.Action,
  correlation: Correlation,
  child: String,
  before: Option(run.ActionState),
  after: run.ActionState,
) -> Nil {
  let was_active = case before {
    Some(run.Delegated) | Some(run.Running) -> True
    _ -> False
  }
  case after, was_active {
    run.Delegated, _ if before != Some(run.Delegated) ->
      emit(
        o.child_started(),
        Nil,
        o.ChildStarted(reference, child, correlation),
      )
    run.Delegated, _ | run.Running, _ -> Nil
    _, True ->
      case disposition(after) {
        Some(disposition) ->
          emit(
            o.child_settled(),
            Nil,
            o.ChildSettled(reference, child, disposition, correlation),
          )
        None -> Nil
      }
    _, False -> Nil
  }
}

fn disposition(state: run.ActionState) -> Option(o.Disposition) {
  case state {
    run.Succeeded(_) | run.ToolFailed(_) -> Some(o.ModelVisible)
    run.Uncertain(_) -> Some(o.EffectUncertain)
    run.Faulted(_) -> Some(o.HostFailure)
    run.NotStarted -> Some(o.Withdrawn)
    _ -> None
  }
}

fn cancelled(before: Option(State), after: State) -> Nil {
  let cancelling = fn(state: State) {
    case state.phase {
      controller.Stopping(reason: controller.CancelRequested, ..)
      | controller.Ended(run.Cancelled) -> True
      _ -> False
    }
  }
  case before {
    Some(before) ->
      case cancelling(after) && !cancelling(before) {
        True ->
          emit(
            o.run_cancelled(),
            Nil,
            o.RunCancelled(after.run, after.correlation),
          )
        False -> Nil
      }
    None -> Nil
  }
}

fn finished(before: Option(State), after: State) -> Nil {
  let ended = fn(state: State) {
    case state.phase {
      controller.Ended(_) -> True
      _ -> False
    }
  }
  case after.phase, option.map(before, ended) {
    controller.Ended(outcome), Some(False) | controller.Ended(outcome), None ->
      emit(
        o.run_finished(),
        o.RunTotals(
          after.turns_used,
          after.usage.input_tokens,
          after.usage.output_tokens,
          after.usage.unreported_replies,
        ),
        o.RunFinished(after.run, outcome_kind(outcome), after.correlation),
      )
    _, _ -> Nil
  }
}

fn outcome_kind(outcome: run.Outcome) -> o.OutcomeKind {
  case outcome {
    run.Completed(_) -> o.Completed
    run.Refused(_) -> o.Refused
    run.OutputLimited(_) -> o.OutputLimited
    run.BudgetExhausted(_) -> o.BudgetExhausted
    run.BudgetUnverifiable(_) -> o.BudgetUnverifiable
    run.Cancelled -> o.Cancelled
    run.Failed(_) -> o.Failed
  }
}

/// A late settlement `outcome` of the action `id` of `run`, a call of
/// `tool`, was refused with `error`; `summary` is what the tool gave a
/// person to reconcile it. Emitted by the process that offered it: nothing
/// was committed.
pub fn settlement_refused(
  run: String,
  correlation: Correlation,
  id: ActionId,
  tool: String,
  outcome: invocation.Outcome,
  summary: String,
  error: fabric_tool.SettleError,
) -> Nil {
  let offered = case outcome {
    invocation.Returned(_) | invocation.FailedVisibly(_) -> o.ModelVisible
    invocation.EffectUncertain(_) -> o.EffectUncertain
    invocation.OutputUnencodable(_) | invocation.ArgumentsRejected(_) ->
      o.HostFailure
  }
  let reason = case error {
    fabric_tool.AlreadyRecorded -> o.AlreadyRecorded
    fabric_tool.NotAwaited -> o.NotAwaited
    fabric_tool.SettleUnconfirmed(_) -> o.NotReached
  }
  emit(
    o.settlement_refused(),
    Nil,
    o.SettlementRefused(
      Action(run, id.turn, id.call_id, tool),
      offered,
      reason,
      summary,
      correlation,
    ),
  )
}

fn emit(event: sinal.Event(m, d), measurements: m, metadata: d) -> Nil {
  sinal.emit(event, measurements, metadata)
}

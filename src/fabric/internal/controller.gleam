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
//// Acting(batch)       --cancel or host fault, tools running--> Stopping
//// Stopping            --tools stopped--> Ended
//// ```
////
//// `answer` resolves an approval request of the current batch; `abandon`
//// and `recover` take over a record whose runner was lost.

import fabric/internal/invocation
import fabric/internal/registry.{type Registry}
import fabric/model.{
  type Message, type ModelError, type Reply, type Request, type ToolCall,
}
import fabric/policy.{type ActionId, type Policy, ActionId}
import fabric/run.{
  type ActionRecord, type ActionState, type Answer, type ApprovalRef,
  type HostFailure, type Identity, type Outcome, type Status, type TokenUsage,
  ActionRecord,
}
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

pub type Limits {
  Limits(max_turns: Int, token_budget: Option(Int))
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
  /// Waiting for the executor to confirm that no tool of the batch runs.
  Stopping(turn: Int, actions: List(ActionRecord), reason: StopReason)
  Ended(Outcome)
}

pub type State {
  State(
    run: String,
    agent: Identity,
    /// Increases by one each time a lost runner's work is taken over.
    incarnation: Int,
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
}

pub type Effect {
  CallModel(turn: Int, request: Request)
  Dispatch(List(#(ActionId, ToolCall)))
  StopTools
  AbortModel
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
) -> #(State, List(Effect)) {
  let state =
    State(
      run:,
      agent:,
      incarnation: 1,
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
    _ -> step_phase(env, state, event)
  }
}

fn step_phase(env: Env(context), state: State, event: Event) -> Transition {
  case state.phase, event {
    Ended(_), _ -> Error(RunEnded)

    AwaitingModel(turn), ModelReplied(t, reply) if t == turn ->
      Ok(model_replied(env, state, turn, reply))
    AwaitingModel(turn), ModelFailed(t, error) if t == turn ->
      Ok(model_failed(env, state, error))
    AwaitingModel(_), Cancel ->
      Ok(#(State(..state, phase: Ended(run.Cancelled)), [AbortModel]))
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
      Ok(after_report(env, State(..state, phase: Acting(turn, actions))))
    }
    Acting(turn, actions), ToolLost(id, reason) -> {
      use actions <- result.try(update(actions, id, lose(id, reason)))
      Ok(after_report(env, State(..state, phase: Acting(turn, actions))))
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
    Acting(turn, actions), Cancel ->
      Ok(stop(state, turn, actions, CancelRequested))
    Acting(..), _ -> Error(StaleEvent)

    Stopping(turn, actions, reason), ToolReported(id, outcome) -> {
      use actions <- result.try(update(actions, id, accept_report(id, outcome)))
      Ok(#(State(..state, phase: Stopping(turn, actions, reason)), []))
    }
    Stopping(turn, actions, reason), ToolLost(id, why) -> {
      use actions <- result.try(update(actions, id, lose(id, why)))
      Ok(#(State(..state, phase: Stopping(turn, actions, reason)), []))
    }
    Stopping(_, actions, reason), ToolsStopped ->
      Ok(#(finish_stop(state, actions, reason, "stopped while running"), []))
    Stopping(..), Cancel -> Ok(#(state, []))
    Stopping(..), _ -> Error(StaleEvent)
  }
}

fn finish_stop(
  state: State,
  actions: List(ActionRecord),
  reason: StopReason,
  evidence: String,
) -> State {
  let actions =
    list.map(actions, fn(action) {
      case action.state {
        run.Running -> ActionRecord(..action, state: run.Uncertain(evidence))
        run.Queued -> ActionRecord(..action, state: run.NotStarted)
        _ -> action
      }
    })
  end(state, actions, stop_outcome(reason))
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
  case reference.run == state.run, state.phase {
    False, _ -> Error(WrongReference)
    True, Ended(_) | True, Stopping(..) -> Error(RunEnded)
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
    True, _, _ -> AlreadyAnswered
    False, [], run.AwaitingApproval(..) -> StaleReference
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
    run.Approve ->
      case gate(env, state.run, action.id, action.call) {
        Error(failure) ->
          stop(state, turn, replace(answered(action.state)), HostFault(failure))
        Ok(Decided(policy.RequireApproval(required)))
          if required != approval.requirement
        -> {
          let issued = state.approvals_issued + 1
          let actions =
            replace(
              ActionRecord(
                ..action,
                state: run.AwaitingApproval(required, issued),
              ),
            )
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
          let approved =
            answered(case gated {
              Refused(action_state) -> action_state
              Decided(policy.Deny(reason)) -> run.Denied(reason)
              Decided(policy.Allow) | Decided(policy.RequireApproval(_)) ->
                run.Queued
            })
          let state = State(..state, phase: Acting(turn, replace(approved)))
          let #(state, effects) = settle(env, state)
          #(state, list.append(dispatch([approved]), effects))
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
          ActionRecord(ActionId(turn, call.id), call, run.NotStarted, [])
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
      use action_state <- result.map(admit(env, state.run, id, call, issued))
      let issued = case action_state {
        run.AwaitingApproval(..) -> issued + 1
        _ -> issued
      }
      #(issued, [ActionRecord(id, call, action_state, []), ..records])
    })
  case admitted {
    Error(failure) -> #(end(state, withdrawn, run.Failed(failure)), [])
    Ok(#(issued, records)) -> {
      let actions = list.reverse(records)
      let state =
        State(..state, approvals_issued: issued, phase: Acting(turn, actions))
      let #(state, effects) = settle(env, state)
      #(state, list.append(dispatch(actions), effects))
    }
  }
}

/// What the gate says about a call: refused before the policy (unknown
/// tool, malformed arguments), or the policy's decision.
type Gated {
  Refused(ActionState)
  Decided(policy.Decision)
}

fn gate(
  env: Env(context),
  run: String,
  id: ActionId,
  call: ToolCall,
) -> Result(Gated, HostFailure) {
  case registry.admit(env.registry, call.name, call.arguments_json) {
    Error(registry.NotRegistered) -> Ok(Refused(run.UnknownTool))
    Error(registry.MalformedArguments(detail)) ->
      Ok(Refused(run.InvalidArguments(detail)))
    Ok(Nil) ->
      env.policy(
        env.context,
        policy.Action(run, id, call.name, call.arguments_json),
      )
      |> result.map(Decided)
      |> result.map_error(run.PolicyFailed(id, _))
  }
}

fn admit(
  env: Env(context),
  run: String,
  id: ActionId,
  call: ToolCall,
  issued: Int,
) -> Result(ActionState, HostFailure) {
  use gated <- result.map(gate(env, run, id, call))
  case gated {
    Refused(action_state) -> action_state
    Decided(policy.Allow) -> run.Queued
    Decided(policy.Deny(reason)) -> run.Denied(reason)
    Decided(policy.RequireApproval(requirement)) ->
      run.AwaitingApproval(requirement, issued + 1)
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
          invocation.ArgumentsRejected(detail) -> run.InvalidArguments(detail)
          invocation.OutputUnencodable(detail) -> run.Faulted(detail)
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

fn after_report(env: Env(context), state: State) -> #(State, List(Effect)) {
  case state.phase {
    Acting(turn, actions) ->
      case
        list.find_map(actions, fn(action) {
          case action.state {
            run.Faulted(detail) ->
              Ok(run.OutputEncodingFailed(action.id, detail))
            _ -> Error(Nil)
          }
        })
      {
        Ok(failure) -> stop(state, turn, actions, HostFault(failure))
        Error(Nil) -> settle(env, state)
      }
    _ -> #(state, [])
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
  case list.any(actions, fn(action) { action.state == run.Running }) {
    True -> #(State(..state, phase: Stopping(turn, actions, reason)), [
      StopTools,
    ])
    False -> #(end(state, actions, stop_outcome(reason)), [])
  }
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
          tools: registry.declarations(env.registry),
        )
      #(State(..state, turns_used: turn, phase: AwaitingModel(turn)), [
        CallModel(turn, request),
      ])
    }
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
    run.Queued
    | run.Running
    | run.AwaitingApproval(..)
    | run.Uncertain(_)
    | run.NotStarted
    | run.Faulted(_) -> Error(Nil)
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
            case action.state {
              run.Running ->
                ActionRecord(..action, state: run.Uncertain(lost_evidence))
              _ -> action
            }
          }),
        ),
      )
    Stopping(_, actions, reason) ->
      finish_stop(state, actions, reason, lost_evidence)
    AwaitingModel(_) | Ended(_) -> state
  }
}

/// `abandon`, then restarts the work that is safe to restart: queued
/// actions are dispatched again and a lost model call is issued again as a
/// new attempt against the turn budget.
pub fn recover(env: Env(context), state: State) -> #(State, List(Effect)) {
  let state = abandon(state)
  case state.phase {
    AwaitingModel(_) -> call_model(env, state)
    Acting(_, actions) -> #(state, dispatch(actions))
    Stopping(..) | Ended(_) -> #(state, [])
  }
}

// --- read model ----------------------------------------------------------------

pub fn status(state: State) -> Status {
  case state.phase {
    Ended(outcome) -> run.Finished(outcome)
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
                    run.ApprovalRef(state.run, action.id, requirement, revision),
                    action.call.name,
                    action.call.arguments_json,
                  ))
                _ -> Error(Nil)
              }
            }),
            list.filter_map(actions, fn(action) {
              case action.state {
                run.Uncertain(evidence) ->
                  Ok(run.UncertainAction(action.id, action.call.name, evidence))
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
    Ended(_) -> False
  }
}

fn in_flight(actions: List(ActionRecord)) -> Bool {
  list.any(actions, fn(action) {
    action.state == run.Queued || action.state == run.Running
  })
}

pub fn snapshot(state: State) -> run.Snapshot {
  let current = case state.phase {
    Acting(_, actions) | Stopping(_, actions, _) -> actions
    AwaitingModel(_) | Ended(_) -> []
  }
  run.Snapshot(
    run: state.run,
    agent: state.agent,
    incarnation: state.incarnation,
    status: status(state),
    turns_used: state.turns_used,
    max_turns: state.limits.max_turns,
    usage: state.usage,
    transcript: state.transcript,
    actions: list.append(state.history, current),
  )
}

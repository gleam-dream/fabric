//// Approval answers and recovery on the pure controller, event by event.

import fabric/internal/controller.{
  type Effect, type State, CallModel, Dispatch, StopTools,
}
import fabric/internal/invocation
import fabric/internal/registry
import fabric/model.{ToolRequest, ToolResultMessage, Usage}
import fabric/policy.{type Action}
import fabric/reviewer
import fabric/run.{ActionId, Requirement}
import fabric/support
import fabric/support/apps
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

// --- fixtures ----------------------------------------------------------------

/// The desk's current facts, as the application would load them when an
/// answer arrives.
type Desk {
  Desk(requirement_version: Int, frozen: Bool, outage: Bool)
}

fn desk() -> Desk {
  Desk(requirement_version: 1, frozen: False, outage: False)
}

fn desk_policy(desk: Desk, action: Action) -> Result(policy.Decision, String) {
  case action.tool, desk {
    "transfer_funds", Desk(outage: True, ..) -> Error("policy service down")
    "transfer_funds", Desk(frozen: True, ..) ->
      Ok(policy.Deny("account frozen"))
    "transfer_funds", Desk(requirement_version: version, ..) ->
      Ok(policy.RequireApproval(Requirement("transfer", version)))
    _, _ -> Ok(policy.Allow)
  }
}

fn env(desk: Desk) -> controller.Env(Desk) {
  let assert Ok(tools) =
    registry.new([apps.weather_tool(), apps.transfer_tool()])
  controller.Env(
    registry: tools,
    policy: desk_policy,
    context: desk,
    system: None,
    approval_expiry: None,
    clock: fn() { 0 },
  )
}

fn step(
  env: controller.Env(Desk),
  state: State,
  event: controller.Event,
) -> #(State, List(Effect)) {
  let assert Ok(next) = controller.step(env, state, event)
  next
}

fn transfer() -> model.ToolCall {
  model.tool_call(
    id: "t",
    name: "transfer_funds",
    arguments_json: "{\"to\":\"bob\",\"amount\":10}",
  )
}

fn weather() -> model.ToolCall {
  model.tool_call(
    id: "w",
    name: "lookup_weather",
    arguments_json: "{\"city\":\"Paris\"}",
  )
}

/// A run whose first batch asked for a transfer (awaiting approval) and a
/// weather lookup (done), so the run is suspended on the approval.
fn suspended() -> #(State, run.PendingApproval) {
  let env = env(desk())
  let #(state, _) =
    controller.start(
      env,
      "run-1",
      run.DefinitionId("desk", 1),
      controller.Limits(
        max_turns: 5,
        token_budget: None,
        max_children: 0,
        max_depth: 0,
      ),
      "pay bob",
      None,
      0,
    )
  let #(state, _) =
    step(
      env,
      state,
      controller.ModelReplied(
        1,
        ToolRequest(
          model.AssistantTurn("", [transfer(), weather()], None),
          Some(Usage(1, 1)),
        ),
      ),
    )
  let #(state, _) = step(env, state, controller.ToolStarting(ActionId(1, "w")))
  let #(state, _) =
    step(
      env,
      state,
      controller.ToolReported(
        ActionId(1, "w"),
        invocation.Returned("{\"summary\":\"sunny\"}"),
      ),
    )
  let assert run.Suspended([pending], []) = controller.status(state)
  #(state, pending)
}

fn answer(
  env: controller.Env(Desk),
  state: State,
  reference: run.ApprovalRef,
  answer: run.Answer,
) -> Result(#(State, List(Effect)), controller.Rejection) {
  controller.step(env, state, controller.Answer(reference, answer, None))
}

fn transfer_record(state: State) -> run.ActionRecord {
  let assert Ok(action) =
    controller.snapshot(state).actions
    |> list.find(fn(action) { action.id == ActionId(1, "t") })
  action
}

// --- answers -----------------------------------------------------------------

pub fn an_approval_queues_the_action_and_records_the_reviewer_test() {
  let #(state, pending) = suspended()
  pending.reference
  |> should.equal(run.ApprovalRef(
    support.id("run-1"),
    ActionId(1, "t"),
    Requirement("transfer", 1),
    1,
  ))
  let assert Ok(#(state, effects)) =
    controller.step(
      env(desk()),
      state,
      controller.Answer(
        pending.reference,
        run.Approve,
        Some(reviewer.new("alice")),
      ),
    )
  effects |> should.equal([Dispatch([#(ActionId(1, "t"), transfer())])])
  transfer_record(state)
  |> should.equal(run.ActionRecord(
    ActionId(1, "t"),
    transfer(),
    run.Queued,
    [
      run.Approval(
        Requirement("transfer", 1),
        1,
        run.Approve,
        Some(reviewer.new("alice")),
      ),
    ],
    None,
    0,
  ))
  controller.needs_runner(state) |> should.be_true
}

pub fn a_rejection_is_visible_to_the_model_and_nothing_runs_test() {
  let #(state, pending) = suspended()
  let assert Ok(#(state, [CallModel(2, request)])) =
    answer(env(desk()), state, pending.reference, run.Reject("too risky"))
  transfer_record(state).state |> should.equal(run.Rejected("too risky"))
  let assert [_, _, ToolResultMessage("t", rejected), ToolResultMessage("w", _)] =
    request.messages
  rejected |> should.equal("{\"error\":\"rejected\",\"detail\":\"too risky\"}")
}

pub fn a_current_denial_wins_over_an_approval_test() {
  let #(state, pending) = suspended()
  let now = Desk(..desk(), frozen: True)
  let assert Ok(#(state, [CallModel(2, _)])) =
    answer(env(now), state, pending.reference, run.Approve)
  let record = transfer_record(state)
  record.state |> should.equal(run.Denied("account frozen"))
  // The answer is still recorded as given.
  let assert [run.Approval(answer: run.Approve, ..)] = record.approvals
}

pub fn a_policy_failure_on_recheck_fails_closed_test() {
  let #(state, pending) = suspended()
  let now = Desk(..desk(), outage: True)
  let assert Ok(#(state, [])) =
    answer(env(now), state, pending.reference, run.Approve)
  controller.status(state)
  |> should.equal(
    run.Finished(
      run.Failed(run.PolicyFailed(ActionId(1, "t"), "policy service down")),
    ),
  )
  transfer_record(state).state |> should.equal(run.NotStarted)
}

pub fn a_changed_requirement_demands_a_new_answer_test() {
  let #(state, pending) = suspended()
  let now = Desk(..desk(), requirement_version: 2)
  let assert Ok(#(state, [])) =
    answer(env(now), state, pending.reference, run.Approve)
  let assert run.Suspended([again], []) = controller.status(state)
  again.reference
  |> should.equal(run.ApprovalRef(
    support.id("run-1"),
    ActionId(1, "t"),
    Requirement("transfer", 2),
    2,
  ))
  // The answer to the old request is kept for the audit trail but did not
  // authorize the action.
  transfer_record(state).approvals
  |> should.equal([
    run.Approval(Requirement("transfer", 1), 1, run.Approve, None),
  ])
  answer(env(now), state, pending.reference, run.Approve)
  |> should.equal(Error(controller.StaleReference))
  let assert Ok(#(state, [Dispatch(_)])) =
    answer(env(now), state, again.reference, run.Approve)
  transfer_record(state).state |> should.equal(run.Queued)
}

pub fn references_are_checked_against_the_record_test() {
  let #(state, pending) = suspended()
  let env = env(desk())
  let reference = pending.reference
  answer(
    env,
    state,
    run.ApprovalRef(..reference, run: support.id("run-2")),
    run.Approve,
  )
  |> should.equal(Error(controller.WrongReference))
  answer(
    env,
    state,
    run.ApprovalRef(..reference, id: ActionId(1, "ghost")),
    run.Approve,
  )
  |> should.equal(Error(controller.WrongReference))
  // The weather lookup never needed an approval.
  answer(
    env,
    state,
    run.ApprovalRef(..reference, id: ActionId(1, "w")),
    run.Approve,
  )
  |> should.equal(Error(controller.WrongReference))
  answer(env, state, run.ApprovalRef(..reference, revision: 7), run.Approve)
  |> should.equal(Error(controller.StaleReference))
  answer(
    env,
    state,
    run.ApprovalRef(..reference, requirement: Requirement("transfer", 9)),
    run.Approve,
  )
  |> should.equal(Error(controller.StaleReference))
}

/// Anti-oracle B4: a refused answer leaves the pause intact, and the next
/// valid answer applies on its first attempt.
pub fn a_refused_answer_does_not_consume_the_pause_test() {
  let #(state, pending) = suspended()
  let env = env(desk())
  let assert Error(controller.StaleReference) =
    answer(
      env,
      state,
      run.ApprovalRef(..pending.reference, revision: 3),
      run.Approve,
    )
  controller.status(state) |> should.equal(run.Suspended([pending], []))
  let assert Ok(#(_, [Dispatch(_)])) =
    answer(env, state, pending.reference, run.Approve)
}

/// Anti-oracle B2: a repeated answer is refused, before and after the run
/// moved on, and after the run ended.
pub fn repeated_and_late_answers_are_refused_test() {
  let #(state, pending) = suspended()
  let env = env(desk())
  let assert Ok(#(approved, _)) =
    answer(env, state, pending.reference, run.Approve)
  answer(env, approved, pending.reference, run.Approve)
  |> should.equal(Error(controller.AlreadyAnswered))
  // Once the tool reports, the batch settles and the model is called; the
  // action is history now.
  let #(later, _) =
    step(env, approved, controller.ToolStarting(ActionId(1, "t")))
  let assert #(later, [CallModel(2, _)]) =
    step(
      env,
      later,
      controller.ToolReported(ActionId(1, "t"), invocation.Returned("{}")),
    )
  answer(env, later, pending.reference, run.Reject("late"))
  |> should.equal(Error(controller.AlreadyAnswered))
  let #(cancelled, _) = step(env, state, controller.Cancel)
  answer(env, cancelled, pending.reference, run.Approve)
  |> should.equal(Error(controller.RunEnded))
  // Cancelling voided the request.
  transfer_record(cancelled).state |> should.equal(run.NotStarted)
}

// --- recovery ------------------------------------------------------------------

fn batch(calls: List(model.ToolCall)) -> State {
  let env = env(desk())
  let #(state, _) =
    controller.start(
      env,
      "run-1",
      run.DefinitionId("desk", 1),
      controller.Limits(
        max_turns: 3,
        token_budget: None,
        max_children: 0,
        max_depth: 0,
      ),
      "go",
      None,
      0,
    )
  let #(state, _) =
    step(
      env,
      state,
      controller.ModelReplied(
        1,
        ToolRequest(model.AssistantTurn("", calls, None), Some(Usage(1, 1))),
      ),
    )
  state
}

fn lookup(id: String) -> model.ToolCall {
  model.tool_call(
    id: id,
    name: "lookup_weather",
    arguments_json: "{\"city\":\"Paris\"}",
  )
}

pub fn recovery_marks_running_tools_uncertain_and_redispatches_queued_ones_test() {
  let env = env(desk())
  let state = batch([lookup("a"), lookup("b"), lookup("c")])
  // a finished, b started, c never started.
  let #(state, _) = step(env, state, controller.ToolStarting(ActionId(1, "a")))
  let #(state, _) =
    step(
      env,
      state,
      controller.ToolReported(ActionId(1, "a"), invocation.Returned("{}")),
    )
  let #(state, _) = step(env, state, controller.ToolStarting(ActionId(1, "b")))
  let #(state, effects) = controller.recover(env, state)
  effects |> should.equal([Dispatch([#(ActionId(1, "c"), lookup("c"))])])
  let snapshot = controller.snapshot(state)
  snapshot.incarnation |> should.equal(2)
  let assert [run.Succeeded(_), run.Uncertain(_), run.Queued] =
    list.map(snapshot.actions, fn(action) { action.state })
}

pub fn recovery_issues_a_lost_model_call_again_against_the_budget_test() {
  let env = env(desk())
  let #(state, _) =
    controller.start(
      env,
      "run-1",
      run.DefinitionId("desk", 1),
      controller.Limits(
        max_turns: 2,
        token_budget: None,
        max_children: 0,
        max_depth: 0,
      ),
      "go",
      None,
      0,
    )
  let assert #(state, [CallModel(2, _)]) = controller.recover(env, state)
  controller.snapshot(state).turns_used |> should.equal(2)
  let assert #(state, []) = controller.recover(env, state)
  controller.status(state)
  |> should.equal(run.Finished(run.BudgetExhausted(run.TurnLimit(2))))
}

pub fn recovery_completes_a_stop_in_progress_test() {
  let env = env(desk())
  let state = batch([lookup("a"), lookup("b")])
  let #(state, _) = step(env, state, controller.ToolStarting(ActionId(1, "a")))
  let assert #(state, [StopTools]) = step(env, state, controller.Cancel)
  let #(state, effects) = controller.recover(env, state)
  effects |> should.equal([])
  controller.status(state) |> should.equal(run.Finished(run.Cancelled))
  let assert [run.Uncertain(_), run.NotStarted] =
    controller.snapshot(state).actions |> list.map(fn(action) { action.state })
}

pub fn a_finished_run_is_left_unchanged_by_recovery_except_its_incarnation_test() {
  let env = env(desk())
  let state = batch([lookup("a")])
  let #(state, _) = step(env, state, controller.Cancel)
  let #(recovered, effects) = controller.recover(env, state)
  effects |> should.equal([])
  controller.status(recovered) |> should.equal(controller.status(state))
}

pub fn an_abandoned_run_can_be_cancelled_without_starting_anything_test() {
  let env = env(desk())
  let state = batch([lookup("a"), lookup("b")])
  let #(state, _) = step(env, state, controller.ToolStarting(ActionId(1, "a")))
  let assert Ok(#(state, [])) =
    controller.step(env, controller.abandon(state), controller.Cancel)
  controller.status(state) |> should.equal(run.Finished(run.Cancelled))
  let assert [run.Uncertain(_), run.NotStarted] =
    controller.snapshot(state).actions |> list.map(fn(action) { action.state })
}

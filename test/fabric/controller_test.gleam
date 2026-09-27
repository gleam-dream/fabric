//// The pure controller, driven event by event without processes.

import fabric/internal/controller.{
  type Effect, type State, CallModel, Dispatch, StopTools,
}
import fabric/internal/invocation
import fabric/internal/registry
import fabric/model.{
  AssistantMessage, FinalAnswer, ToolCall, ToolRequest, ToolResultMessage, Usage,
  UserMessage,
}
import fabric/policy.{type Action, ActionId}
import fabric/run
import fabric/support/apps
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

// --- fixtures ----------------------------------------------------------------

/// Transfers of 50 or more need approval, transfers to mallory are denied,
/// a transfer to "outage" makes the policy itself fail.
fn bank_policy(
  _context: Nil,
  action: Action,
) -> Result(policy.Decision, String) {
  case action.tool {
    "transfer_funds" ->
      case
        string.contains(action.arguments_json, "mallory"),
        string.contains(action.arguments_json, "outage"),
        string.contains(action.arguments_json, "\"amount\":5")
      {
        True, _, _ -> Ok(policy.Deny("recipient is blocked"))
        _, True, _ -> Error("policy service unavailable")
        _, _, True ->
          Ok(policy.RequireApproval(policy.Requirement("large-transfer", 1)))
        _, _, _ -> Ok(policy.Allow)
      }
    _ -> Ok(policy.Allow)
  }
}

fn env_with(policy: policy.Policy(Nil)) -> controller.Env(Nil) {
  let assert Ok(tools) =
    registry.new([apps.weather_tool(), apps.transfer_tool()])
  controller.Env(registry: tools, policy:, context: Nil, system: None)
}

fn env() -> controller.Env(Nil) {
  env_with(bank_policy)
}

fn limits() -> controller.Limits {
  controller.Limits(max_turns: 5, token_budget: None)
}

fn begin(env: controller.Env(Nil), limits: controller.Limits) -> State {
  let #(state, effects) = controller.start(env, "run-1", limits, "hello")
  let assert [CallModel(1, _)] = effects
  state
}

fn call(id: String, name: String, args: String) -> model.ToolCall {
  ToolCall(id, name, args, None, None)
}

fn weather(id: String, city: String) -> model.ToolCall {
  call(id, "lookup_weather", "{\"city\":\"" <> city <> "\"}")
}

fn transfer(id: String, to: String, amount: String) -> model.ToolCall {
  call(
    id,
    "transfer_funds",
    "{\"to\":\"" <> to <> "\",\"amount\":" <> amount <> "}",
  )
}

fn usage(total: Int) -> option.Option(model.Usage) {
  Some(Usage(input_tokens: total - 1, output_tokens: 1))
}

fn step(
  env: controller.Env(Nil),
  state: State,
  event: controller.Event,
) -> #(State, List(Effect)) {
  let assert Ok(next) = controller.step(env, state, event)
  next
}

fn tools_requested(
  env: controller.Env(Nil),
  state: State,
  calls: List(model.ToolCall),
) -> #(State, List(Effect)) {
  step(
    env,
    state,
    controller.ModelReplied(1, ToolRequest("", calls, usage(10))),
  )
}

fn run_tool(
  env: controller.Env(Nil),
  state: State,
  id: policy.ActionId,
  outcome: invocation.Outcome,
) -> #(State, List(Effect)) {
  let assert #(state, []) = step(env, state, controller.ToolStarting(id))
  step(env, state, controller.ToolReported(id, outcome))
}

fn states(state: State) -> List(run.ActionState) {
  controller.snapshot(state).actions |> list.map(fn(a) { a.state })
}

// --- tests -------------------------------------------------------------------

pub fn start_requests_the_first_turn_with_declarations_test() {
  let #(_, effects) = controller.start(env(), "run-1", limits(), "hello")
  let assert [CallModel(1, request)] = effects
  request.messages |> should.equal([UserMessage("hello")])
  request.tools
  |> list.map(fn(spec) { spec.name })
  |> should.equal(["lookup_weather", "transfer_funds"])
}

pub fn final_answer_completes_the_run_test() {
  let state = begin(env(), limits())
  let #(state, effects) =
    step(
      env(),
      state,
      controller.ModelReplied(1, FinalAnswer("done", usage(3))),
    )
  effects |> should.equal([])
  controller.status(state) |> should.equal(run.Finished(run.Completed("done")))
  controller.needs_runner(state) |> should.be_false
}

pub fn two_calls_are_correlated_and_fed_back_in_call_order_test() {
  let env = env()
  let state = begin(env, limits())
  let calls = [weather("c1", "Paris"), transfer("c2", "bob", "10")]
  let #(state, effects) = tools_requested(env, state, calls)
  let c1 = ActionId(1, "c1")
  let c2 = ActionId(1, "c2")
  effects
  |> should.equal([
    Dispatch([#(c1, weather("c1", "Paris")), #(c2, transfer("c2", "bob", "10"))]),
  ])
  // Reports arrive in the opposite order.
  let assert #(state, []) =
    run_tool(env, state, c2, invocation.Returned("{\"receipt\":\"r-bob\"}"))
  let #(state, effects) =
    run_tool(env, state, c1, invocation.Returned("{\"summary\":\"sunny\"}"))
  let assert [CallModel(2, request)] = effects
  request.messages
  |> should.equal([
    UserMessage("hello"),
    AssistantMessage("", calls),
    ToolResultMessage("c1", "{\"summary\":\"sunny\"}"),
    ToolResultMessage("c2", "{\"receipt\":\"r-bob\"}"),
  ])
  controller.snapshot(state).turns_used |> should.equal(2)
}

pub fn unknown_tools_and_malformed_arguments_never_reach_policy_test() {
  let panicking = fn(_, _) { panic as "policy must not see this action" }
  let env = env_with(panicking)
  let state = begin(env, limits())
  let #(state, effects) =
    tools_requested(env, state, [
      call("g", "ghost", "{}"),
      call("m", "lookup_weather", "{\"town\":1}"),
    ])
  let assert [CallModel(2, request)] = effects
  let assert [_, _, ToolResultMessage("g", ghost), ToolResultMessage("m", bad)] =
    request.messages
  ghost |> should.equal("{\"error\":\"unknown_tool\"}")
  string.starts_with(bad, "{\"error\":\"invalid_arguments\"") |> should.be_true
  let assert [run.UnknownTool, run.InvalidArguments(_)] = states(state)
}

pub fn policy_denies_and_requires_approval_test() {
  let env = env()
  let state = begin(env, limits())
  let #(state, effects) =
    tools_requested(env, state, [
      transfer("d", "mallory", "1"),
      transfer("a", "bob", "500"),
      weather("w", "Paris"),
    ])
  effects
  |> should.equal([Dispatch([#(ActionId(1, "w"), weather("w", "Paris"))])])
  let #(state, effects) =
    run_tool(env, state, ActionId(1, "w"), invocation.Returned("{}"))
  // The approval blocks the next turn; nothing is in flight.
  effects |> should.equal([])
  controller.needs_runner(state) |> should.be_false
  let requirement = policy.Requirement("large-transfer", 1)
  controller.status(state)
  |> should.equal(
    run.Suspended(
      [
        run.PendingApproval(
          ActionId(1, "a"),
          "transfer_funds",
          "{\"to\":\"bob\",\"amount\":500}",
          requirement,
          1,
        ),
      ],
      [],
    ),
  )
  let assert [
    run.Denied("recipient is blocked"),
    run.AwaitingApproval(_, 1),
    run.Succeeded(_),
  ] = states(state)
}

pub fn policy_error_fails_closed_test() {
  let env = env()
  let state = begin(env, limits())
  let #(state, effects) =
    tools_requested(env, state, [
      weather("w", "Paris"),
      transfer("x", "outage", "1"),
    ])
  effects |> should.equal([])
  controller.status(state)
  |> should.equal(
    run.Finished(
      run.Failed(run.PolicyFailed(
        ActionId(1, "x"),
        "policy service unavailable",
      )),
    ),
  )
  states(state) |> should.equal([run.NotStarted, run.NotStarted])
}

pub fn foreign_and_duplicate_reports_are_rejected_test() {
  let env = env()
  let state = begin(env, limits())
  let #(state, _) =
    tools_requested(env, state, [weather("c1", "Paris"), weather("c2", "Rome")])
  let c1 = ActionId(1, "c1")
  // Not started yet: a report is premature.
  controller.step(
    env,
    state,
    controller.ToolReported(c1, invocation.Returned("{}")),
  )
  |> should.equal(Error(controller.ReportNotExpected(c1)))
  let #(state, _) = run_tool(env, state, c1, invocation.Returned("{}"))
  controller.step(
    env,
    state,
    controller.ToolReported(c1, invocation.Returned("{}")),
  )
  |> should.equal(Error(controller.ReportNotExpected(c1)))
  // The same call id on another turn is a different action.
  let foreign = ActionId(2, "c2")
  controller.step(
    env,
    state,
    controller.ToolReported(foreign, invocation.Returned("{}")),
  )
  |> should.equal(Error(controller.UnknownAction(foreign)))
}

pub fn uncertain_effect_blocks_until_reconciled_test() {
  let env = env()
  let state = begin(env, limits())
  let #(state, _) =
    tools_requested(env, state, [
      transfer("t", "bob", "2000"),
      weather("w", "Paris"),
    ])
  let t = ActionId(1, "t")
  let assert #(state, []) =
    run_tool(env, state, t, invocation.EffectUncertain("gateway timed out"))
  let #(state, effects) =
    run_tool(env, state, ActionId(1, "w"), invocation.Returned("{}"))
  effects |> should.equal([])
  controller.status(state)
  |> should.equal(
    run.Suspended([], [
      run.UncertainAction(t, "transfer_funds", "gateway timed out"),
    ]),
  )
  controller.step(env, state, controller.Reconcile(ActionId(1, "w"), "x"))
  |> should.equal(Error(controller.NotReconcilable(ActionId(1, "w"))))
  let #(state, effects) =
    step(env, state, controller.Reconcile(t, "{\"receipt\":\"checked\"}"))
  let assert [CallModel(2, request)] = effects
  let assert [_, _, ToolResultMessage("t", "{\"receipt\":\"checked\"}"), _] =
    request.messages
  // Reconciliation itself does not consume a model turn.
  controller.snapshot(state).turns_used |> should.equal(2)
}

pub fn turn_limit_prevents_effects_that_cannot_be_continued_test() {
  let env = env()
  let state = begin(env, controller.Limits(max_turns: 1, token_budget: None))
  let #(state, effects) = tools_requested(env, state, [weather("w", "Paris")])
  effects |> should.equal([])
  controller.status(state)
  |> should.equal(run.Finished(run.BudgetExhausted(run.TurnLimit(1))))
  states(state) |> should.equal([run.NotStarted])
  // The outstanding call is retained in the transcript.
  let assert [_, AssistantMessage(_, [_])] =
    controller.snapshot(state).transcript
}

pub fn every_model_attempt_counts_against_the_turn_limit_test() {
  let env = env()
  let state = begin(env, controller.Limits(max_turns: 2, token_budget: None))
  let flaky = model.ModelError("connection reset", retryable: True)
  let #(state, effects) = step(env, state, controller.ModelFailed(1, flaky))
  let assert [CallModel(2, _)] = effects
  let #(state, effects) = step(env, state, controller.ModelFailed(2, flaky))
  effects |> should.equal([])
  controller.status(state)
  |> should.equal(run.Finished(run.Failed(run.ModelFailed(flaky))))
  controller.snapshot(state).turns_used |> should.equal(2)
}

pub fn non_retryable_model_failure_ends_the_run_test() {
  let env = env()
  let state = begin(env, limits())
  let fatal = model.ModelError("401 unauthorized", retryable: False)
  let assert #(state, []) = step(env, state, controller.ModelFailed(1, fatal))
  controller.status(state)
  |> should.equal(run.Finished(run.Failed(run.ModelFailed(fatal))))
}

pub fn token_budget_uses_observed_usage_test() {
  let env = env()
  let state =
    begin(env, controller.Limits(max_turns: 5, token_budget: Some(10)))
  let #(state, effects) =
    step(
      env,
      state,
      controller.ModelReplied(
        1,
        ToolRequest("", [weather("w", "Paris")], usage(12)),
      ),
    )
  effects |> should.equal([])
  controller.status(state)
  |> should.equal(run.Finished(run.BudgetExhausted(run.TokenLimit(10, 12))))
}

pub fn missing_usage_under_a_token_budget_is_reported_test() {
  let env = env()
  let state =
    begin(env, controller.Limits(max_turns: 5, token_budget: Some(100)))
  let assert #(state, []) =
    step(
      env,
      state,
      controller.ModelReplied(1, ToolRequest("", [weather("w", "Paris")], None)),
    )
  controller.status(state)
  |> should.equal(run.Finished(run.BudgetUnverifiable(1)))
  controller.snapshot(state).usage
  |> should.equal(run.TokenUsage(0, 0, unreported_replies: 1))
}

pub fn missing_usage_without_a_budget_is_counted_test() {
  let env = env()
  let state = begin(env, limits())
  let #(state, _) =
    step(env, state, controller.ModelReplied(1, FinalAnswer("ok", None)))
  controller.snapshot(state).usage
  |> should.equal(run.TokenUsage(0, 0, unreported_replies: 1))
}

pub fn malformed_tool_batches_are_protocol_violations_test() {
  let env = env()
  let empty = begin(env, limits())
  let assert #(empty, []) =
    step(env, empty, controller.ModelReplied(1, ToolRequest("", [], usage(1))))
  let assert run.Finished(run.Failed(run.ModelProtocolViolation(_))) =
    controller.status(empty)
  let dup = begin(env, limits())
  let assert #(dup, []) =
    tools_requested(env, dup, [weather("x", "Paris"), weather("x", "Rome")])
  let assert run.Finished(run.Failed(run.ModelProtocolViolation(_))) =
    controller.status(dup)
}

pub fn cancel_stops_running_tools_and_withdraws_queued_ones_test() {
  let env = env()
  let state = begin(env, limits())
  let #(state, _) =
    tools_requested(env, state, [
      weather("r", "Paris"),
      weather("q", "Rome"),
      transfer("a", "bob", "500"),
    ])
  let assert #(state, []) =
    step(env, state, controller.ToolStarting(ActionId(1, "r")))
  let #(state, effects) = step(env, state, controller.Cancel)
  effects |> should.equal([StopTools])
  controller.status(state) |> should.equal(run.Working)
  // A late fence for a withdrawn action is refused: its body never runs.
  controller.step(env, state, controller.ToolStarting(ActionId(1, "q")))
  |> should.equal(Error(controller.StaleEvent))
  let assert #(state, []) = step(env, state, controller.ToolsStopped)
  controller.status(state) |> should.equal(run.Finished(run.Cancelled))
  let assert [run.Uncertain(_), run.NotStarted, run.NotStarted] = states(state)
  controller.step(env, state, controller.Cancel)
  |> should.equal(Error(controller.RunEnded))
}

pub fn cancel_of_a_suspended_run_needs_no_process_test() {
  let env = env()
  let state = begin(env, limits())
  let #(state, _) = tools_requested(env, state, [transfer("a", "bob", "500")])
  controller.needs_runner(state) |> should.be_false
  let #(state, effects) = step(env, state, controller.Cancel)
  effects |> should.equal([])
  controller.status(state) |> should.equal(run.Finished(run.Cancelled))
  states(state) |> should.equal([run.NotStarted])
}

pub fn cancel_while_the_model_is_called_abandons_the_reply_test() {
  let env = env()
  let state = begin(env, limits())
  let #(state, effects) = step(env, state, controller.Cancel)
  effects |> should.equal([controller.AbortModel])
  controller.step(
    env,
    state,
    controller.ModelReplied(1, FinalAnswer("late", None)),
  )
  |> should.equal(Error(controller.RunEnded))
}

pub fn unencodable_output_stops_the_run_as_a_host_failure_test() {
  let env = env()
  let state = begin(env, limits())
  let #(state, _) =
    tools_requested(env, state, [weather("b", "Paris"), weather("r", "Rome")])
  let assert #(state, []) =
    step(env, state, controller.ToolStarting(ActionId(1, "r")))
  let #(state, effects) =
    run_tool(env, state, ActionId(1, "b"), invocation.OutputUnencodable("no"))
  effects |> should.equal([StopTools])
  let assert #(state, []) = step(env, state, controller.ToolsStopped)
  controller.status(state)
  |> should.equal(
    run.Finished(run.Failed(run.OutputEncodingFailed(ActionId(1, "b"), "no"))),
  )
  let assert [run.Faulted("no"), run.Uncertain(_)] = states(state)
}

pub fn lost_task_is_an_uncertain_effect_test() {
  let env = env()
  let state = begin(env, limits())
  let #(state, _) = tools_requested(env, state, [weather("w", "Paris")])
  let w = ActionId(1, "w")
  let assert #(state, []) = step(env, state, controller.ToolStarting(w))
  let assert #(state, []) = step(env, state, controller.ToolLost(w, "killed"))
  let assert [run.Uncertain(_)] = states(state)
}

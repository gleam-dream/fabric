//// The versioned run record codec.

import fabric/internal/controller.{type State}
import fabric/internal/record
import fabric/internal/registry
import fabric/model.{ToolCall}
import fabric/policy.{ActionId, Requirement}
import fabric/run
import fabric/support/apps
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn call(id: String, name: String) -> model.ToolCall {
  ToolCall(
    id,
    name,
    "{\"city\":\"Paris\"}",
    provider_id: Some("fc_" <> id),
    provider_state: Some("signature-" <> id),
  )
}

fn action(id: String, state: run.ActionState) -> run.ActionRecord {
  run.ActionRecord(ActionId(1, id), call(id, "lookup_weather"), state, [])
}

/// Every action state, both answers, with and without a reviewer.
fn every_action() -> List(run.ActionRecord) {
  let requirement = Requirement("transfer", 2)
  [
    action("a", run.Queued),
    action("b", run.Running),
    action("c", run.AwaitingApproval(requirement, 3)),
    action("d", run.Succeeded("{\"summary\":\"sunny\"}")),
    action("e", run.ToolFailed("{\"error\":\"nope\"}")),
    action("f", run.Denied("blocked")),
    action("g", run.Rejected("too risky")),
    action("h", run.InvalidArguments("$.city: expected a string")),
    action("i", run.UnknownTool),
    action("j", run.Uncertain("gateway timed out")),
    action("k", run.Reconciled("{\"receipt\":\"r\"}")),
    action("l", run.NotStarted),
    action("m", run.Faulted("cannot encode")),
    run.ActionRecord(ActionId(2, "a"), call("a", "transfer_funds"), run.Queued, [
      run.Approval(requirement, 1, run.Approve, Some("alice")),
      run.Approval(requirement, 2, run.Reject("no \"quotes\" \u{1F600}"), None),
    ]),
  ]
}

fn base() -> State {
  controller.State(
    run: "run-0123",
    agent: run.Identity("desk", 3),
    incarnation: 4,
    limits: controller.Limits(max_turns: 8, token_budget: Some(20_000)),
    turns_used: 2,
    usage: run.TokenUsage(120, 40, 1),
    transcript: [
      model.UserMessage("pay bob\nplease"),
      model.AssistantMessage("", [call("a", "lookup_weather")]),
      model.ToolResultMessage("a", "{\"summary\":\"sunny\"}"),
      model.AssistantMessage("thinking", [call("b", "transfer_funds")]),
    ],
    history: every_action(),
    approvals_issued: 3,
    phase: controller.AwaitingModel(3),
  )
}

fn phases() -> List(controller.Phase) {
  let failures = [
    run.PolicyFailed(ActionId(1, "a"), "down"),
    run.OutputEncodingFailed(ActionId(1, "b"), "bad"),
    run.ToolChanged(ActionId(1, "c"), "tool is not registered"),
    run.ModelFailed(model.ModelError("reset", retryable: True)),
    run.ModelProtocolViolation("empty batch"),
  ]
  let outcomes = [
    run.Completed("done"),
    run.Refused("no"),
    run.OutputLimited("partial"),
    run.BudgetExhausted(run.TurnLimit(8)),
    run.BudgetExhausted(run.TokenLimit(100, 120)),
    run.BudgetUnverifiable(2),
    run.Cancelled,
    ..list.map(failures, run.Failed)
  ]
  list.flatten([
    [
      controller.AwaitingModel(1),
      controller.Acting(2, every_action()),
      controller.Stopping(2, every_action(), controller.CancelRequested),
    ],
    list.map(failures, fn(failure) {
      controller.Stopping(1, [], controller.HostFault(failure))
    }),
    list.map(outcomes, controller.Ended),
  ])
}

pub fn every_record_shape_survives_a_round_trip_test() {
  let base = base()
  let states = [
    base,
    controller.State(
      ..base,
      limits: controller.Limits(max_turns: 1, token_budget: None),
    ),
    ..list.map(phases(), fn(phase) { controller.State(..base, phase:) })
  ]
  list.each(states, fn(state) {
    record.decode(record.encode(state)) |> should.equal(Ok(state))
  })
}

pub fn the_record_is_versioned_json_test() {
  let encoded = record.encode(base())
  string.starts_with(encoded, "{\"format\":\"fabric.run\",\"version\":1,")
  |> should.be_true
}

pub fn another_version_is_unsupported_test() {
  let encoded =
    record.encode(base())
    |> string.replace("\"version\":1,", "\"version\":2,")
  record.decode(encoded) |> should.equal(Error(record.UnsupportedVersion(2)))
}

pub fn unreadable_records_are_corrupt_test() {
  let encoded = record.encode(base())
  let corrupt = [
    "",
    "not json",
    "{}",
    "{\"format\":\"other\",\"version\":1}",
    string.drop_end(encoded, 5),
    string.replace(
      encoded,
      "\"tag\":\"awaiting_model\"",
      "\"tag\":\"dreaming\"",
    ),
    string.replace(encoded, "\"turns_used\":2", "\"turns_used\":\"two\""),
  ]
  list.each(corrupt, fn(text) {
    let assert Error(record.Corrupt(detail)) = record.decode(text)
    detail |> should.not_equal("")
  })
}

pub fn a_record_continues_only_under_its_agent_and_tools_test() {
  let assert Ok(weather_only) = registry.new([apps.weather_tool()])
  let waiting =
    controller.State(
      ..base(),
      agent: run.Identity("desk", 3),
      phase: controller.Acting(2, [
        action("w", run.Queued),
        run.ActionRecord(
          ActionId(2, "t"),
          ToolCall(
            ..call("t", "transfer_funds"),
            arguments_json: "{\"to\":\"bob\",\"amount\":10}",
          ),
          run.AwaitingApproval(Requirement("transfer", 1), 1),
          [],
        ),
        run.ActionRecord(
          ActionId(2, "old"),
          call("old", "retired_tool"),
          run.Succeeded("{}"),
          [],
        ),
      ]),
    )
  record.check(waiting, run.Identity("desk", 3), weather_only)
  |> should.equal(
    Error([run.ToolNotRegistered(ActionId(2, "t"), "transfer_funds")]),
  )
  record.check(waiting, run.Identity("desk", 4), weather_only)
  |> should.equal(
    Error([
      run.OtherAgent(run.Identity("desk", 3)),
      run.ToolNotRegistered(ActionId(2, "t"), "transfer_funds"),
    ]),
  )
  let assert Ok(both) =
    registry.new([apps.weather_tool(), apps.transfer_tool()])
  record.check(waiting, run.Identity("desk", 3), both)
  |> should.equal(Ok(waiting))
}

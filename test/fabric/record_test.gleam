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
  run.ActionRecord(ActionId(1, id), call(id, "lookup_weather"), state, [], None)
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
    run.ActionRecord(..action("n", run.Delegated), child: Some("run-01-3-1")),
    run.ActionRecord(
      ..action("o", run.Succeeded("{}")),
      child: Some("run-01-3-2"),
    ),
    action("p", run.LimitReached(run.ChildLimit(2))),
    action("q", run.LimitReached(run.DepthLimit(1))),
    run.ActionRecord(
      ActionId(2, "a"),
      call("a", "transfer_funds"),
      run.Queued,
      [
        run.Approval(requirement, 1, run.Approve, Some("alice")),
        run.Approval(
          requirement,
          2,
          run.Reject("no \"quotes\" \u{1F600}"),
          None,
        ),
      ],
      None,
    ),
  ]
}

fn base() -> State {
  controller.State(
    run: "run-01-3",
    agent: run.Identity("desk", 3),
    incarnation: 4,
    parent: Some(run.Parent("run-01", ActionId(3, "delegate"))),
    depth: 1,
    limits: controller.Limits(
      max_turns: 8,
      token_budget: Some(20_000),
      max_children: 3,
      max_depth: 2,
    ),
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
      controller.Stopping(2, every_action(), controller.CancelRequested, True),
    ],
    list.map(failures, fn(failure) {
      controller.Stopping(1, [], controller.HostFault(failure), False)
    }),
    list.map(outcomes, controller.Ended),
    [controller.NeverStarted],
  ])
}

pub fn every_record_shape_survives_a_round_trip_test() {
  let base = base()
  let states = [
    base,
    controller.State(
      ..base,
      parent: None,
      depth: 0,
      limits: controller.Limits(
        max_turns: 1,
        token_budget: None,
        max_children: 0,
        max_depth: 0,
      ),
    ),
    ..list.map(phases(), fn(phase) { controller.State(..base, phase:) })
  ]
  list.each(states, fn(state) {
    record.decode(record.encode(state)) |> should.equal(Ok(state))
  })
}

pub fn the_record_is_versioned_json_test() {
  let encoded = record.encode(base())
  string.starts_with(encoded, "{\"format\":\"fabric.run\",\"version\":3,")
  |> should.be_true
}

pub fn another_version_is_unsupported_test() {
  let encoded =
    record.encode(base())
    |> string.replace("\"version\":3,", "\"version\":4,")
  record.decode(encoded) |> should.equal(Error(record.UnsupportedVersion(4)))
}

/// A version 1 record (written before sub-agents) is read as a root run
/// that may start no sub-agents and whose actions started none.
pub fn a_version_1_record_is_read_as_a_root_run_without_sub_agents_test() {
  let version_1 =
    "{\"format\":\"fabric.run\",\"version\":1,\"run\":\"run-old\","
    <> "\"agent\":{\"name\":\"desk\",\"version\":1},\"incarnation\":1,"
    <> "\"limits\":{\"max_turns\":8,\"token_budget\":null},\"turns_used\":1,"
    <> "\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"unreported_replies\":0},"
    <> "\"transcript\":[{\"tag\":\"user\",\"text\":\"pay\"}],\"history\":[],"
    <> "\"approvals_issued\":1,\"phase\":{\"tag\":\"acting\",\"turn\":1,\"actions\":["
    <> "{\"id\":{\"turn\":1,\"call_id\":\"t\"},\"call\":{\"id\":\"t\","
    <> "\"name\":\"transfer_funds\",\"arguments\":\"{}\",\"provider_id\":null,"
    <> "\"provider_state\":null},\"state\":{\"tag\":\"awaiting_approval\","
    <> "\"requirement\":{\"name\":\"transfer\",\"version\":1},\"revision\":1},"
    <> "\"approvals\":[]}]}}"
  let transfer = ToolCall("t", "transfer_funds", "{}", None, None)
  let expected =
    controller.State(
      run: "run-old",
      agent: run.Identity("desk", 1),
      incarnation: 1,
      parent: None,
      depth: 0,
      limits: controller.Limits(
        max_turns: 8,
        token_budget: None,
        max_children: 0,
        max_depth: 0,
      ),
      turns_used: 1,
      usage: run.TokenUsage(0, 0, 0),
      transcript: [model.UserMessage("pay")],
      history: [],
      approvals_issued: 1,
      phase: controller.Acting(1, [
        run.ActionRecord(
          ActionId(1, "t"),
          transfer,
          run.AwaitingApproval(Requirement("transfer", 1), 1),
          [],
          None,
        ),
      ]),
    )
  record.decode(version_1) |> should.equal(Ok(expected))
  // It is written back as version 2.
  record.decode(record.encode(expected)) |> should.equal(Ok(expected))
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

/// A child run's id extends its parent's with a sequence number. A record
/// whose parent or child links break that rule is corrupt, so a corrupt or
/// cyclic link can never send a family walk around forever.
pub fn family_links_must_extend_the_run_id_test() {
  let encoded = record.encode(base())
  let corrupt = [
    string.replace(encoded, "\"run-01-3-1\"", "\"run-01-3\""),
    string.replace(encoded, "\"run-01-3-2\"", "\"run-01\""),
    string.replace(encoded, "\"run-01-3-2\"", "\"run-01-3-x\""),
    string.replace(encoded, "\"run\":\"run-01\"", "\"run\":\"run-01-3\""),
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
          None,
        ),
        run.ActionRecord(
          ActionId(2, "old"),
          call("old", "retired_tool"),
          run.Succeeded("{}"),
          [],
          None,
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

/// A child cancelled before it started is its own phase. A version 2
/// record stored it as an ended, cancelled run with no transcript, and is
/// read as never started; a run's end is otherwise never inferred from its
/// transcript.
pub fn a_child_that_never_started_is_explicit_test() {
  let base = base()
  let tombstone =
    controller.State(
      ..base,
      transcript: [],
      history: [],
      phase: controller.Ended(run.Cancelled),
    )
  let version_2 =
    record.encode(tombstone)
    |> string.replace("\"version\":3,", "\"version\":2,")
  let assert Ok(read) = record.decode(version_2)
  read.phase |> should.equal(controller.NeverStarted)
  controller.child_result(read) |> should.equal(Ok(controller.ChildMissing))

  // In the current version the phase says it, not the transcript.
  let assert Ok(current) = record.decode(record.encode(tombstone))
  current.phase |> should.equal(controller.Ended(run.Cancelled))
  controller.child_result(current)
  |> should.equal(Ok(controller.ChildFinished(run.Cancelled, False)))
  controller.status(controller.State(..base, phase: controller.NeverStarted))
  |> should.equal(run.Finished(run.Cancelled))
}

/// The tag `budget_exhausted`, which wraps a budget, is still read.
pub fn a_wrapped_budget_is_still_read_test() {
  let ended =
    controller.State(
      ..base(),
      phase: controller.Ended(run.BudgetExhausted(run.TurnLimit(8))),
    )
  let wrapped =
    record.encode(ended)
    |> string.replace(
      "{\"tag\":\"turn_limit\",\"limit\":8}",
      "{\"tag\":\"budget_exhausted\",\"budget\":{\"tag\":\"turn_limit\",\"limit\":8}}",
    )
  wrapped |> string.contains("budget_exhausted") |> should.be_true
  record.decode(wrapped) |> should.equal(Ok(ended))
}

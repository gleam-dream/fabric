//// The public tool accessors, typed reconciliation and settlement actions,
//// the typed reviewer and its stored form, total run ids, the one
//// `fabric.Error`, and records written before these existed.

import fabric
import fabric/agent
import fabric/internal/controller
import fabric/internal/executor
import fabric/internal/record
import fabric/model
import fabric/policy
import fabric/reviewer
import fabric/run.{Requirement}
import fabric/store/discovery
import fabric/support
import fabric/support/apps
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

// --- tools ---------------------------------------------------------------------

pub fn a_definition_exposes_what_another_runtime_needs_test() {
  let definition = apps.weather_definition()
  tool.name(definition) |> should.equal("lookup_weather")
  { tool.description(definition) != "" } |> should.be_true
  let assert Ok(city) =
    codec.decode_json(tool.input_codec(definition), "{\"city\":\"Paris\"}")
  codec.encode_json(tool.input_codec(definition), city)
  |> should.equal(Ok("{\"city\":\"Paris\"}"))
  let assert Ok(_) = codec.schema(tool.output_codec(definition))
}

/// `tool.reconciliation` writes the content a handler's result would have
/// been, so a person reconciles with a typed value instead of JSON.
pub fn a_reconciliation_is_encoded_with_the_tools_codec_test() {
  let definition = apps.transfer_definition()
  tool.reconciliation(definition, Ok(apps.Receipt("r-1")))
  |> should.equal(codec.encode_json(
    tool.output_codec(definition),
    apps.Receipt("r-1"),
  ))
  tool.reconciliation(definition, Error("declined"))
  |> should.equal(Ok("{\"error\":\"declined\"}"))
}

/// A person who cannot yet say what happened reconciles the effect as
/// unconfirmed: the model sees why, and the action leaves the uncertain
/// effects.
pub fn an_unconfirmed_reconciliation_tells_the_model_test() {
  tool.unconfirmed_reconciliation("finance is checking")
  |> should.equal("{\"unconfirmed\":\"finance is checking\"}")
  let settling =
    tool.bind_settling(
      apps.weather_definition(),
      fn(_, _call, _city, _settlement) { Error(Nil) },
      fn(_) { tool.Uncertain("unknown") },
      settle_within: duration.seconds(1),
    )
  let desk =
    agent.new(
      "unconfirmed",
      scripted.plan([
        scripted.call("w", "lookup_weather", "{\"city\":\"Paris\"}"),
      ]),
      [settling],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(handle, within: duration.seconds(5))
  let assert Ok(_) =
    fabric.reconcile(
      handle,
      uncertain.reference,
      tool.unconfirmed_reconciliation("finance is checking"),
    )
  let assert Ok(run.Finished(run.Completed(answer))) =
    fabric.await(handle, within: duration.seconds(5))
  string.contains(answer, "finance is checking") |> should.be_true
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [action] = snapshot.actions
  action.state
  |> should.equal(run.Reconciled("{\"unconfirmed\":\"finance is checking\"}"))
}

/// A settlement names its action: the reference `fabric.reconcile` takes.
pub fn a_settlement_names_its_action_test() {
  let actions = process.new_subject()
  let settling =
    tool.bind_settling(
      apps.weather_definition(),
      fn(_, _call, _city, settlement) {
        process.send(actions, tool.action(settlement))
        Error(Nil)
      },
      fn(_) { tool.Uncertain("unknown") },
      settle_within: duration.seconds(1),
    )
  let desk =
    agent.new(
      "settling",
      scripted.plan([
        scripted.call("w", "lookup_weather", "{\"city\":\"Paris\"}"),
      ]),
      [settling],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(action) = process.receive(actions, 30_000)
  action |> should.equal(run.ActionRef(fabric.id(handle), run.ActionId(1, "w")))
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(handle, within: duration.seconds(5))
  uncertain.reference |> should.equal(action)
  let assert Ok(content) =
    tool.reconciliation(apps.weather_definition(), Ok(apps.Forecast("sunny")))
  let assert Ok(_) = fabric.reconcile(handle, action, content)
  let assert Ok(run.Finished(run.Completed(answer))) =
    fabric.await(handle, within: duration.seconds(5))
  string.contains(answer, "sunny") |> should.be_true
}

// --- reviewers -----------------------------------------------------------------

fn approval_desk(probe: probe.Probe) -> agent.Agent(Nil, String) {
  agent.new(
    "reviewed",
    scripted.plan([
      scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}"),
    ]),
    [apps.transfer_tool()],
    fn(_, action: policy.Action) {
      probe.record(probe, action.name)
      Ok(policy.RequireApproval(Requirement("transfer", 1)))
    },
  )
  |> support.agent
}

pub fn an_answer_records_its_typed_reviewer_test() {
  let runs = support.store()
  let desk = approval_desk(probe.new())
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "pay",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(handle, within: duration.seconds(5))
  let assert Ok(alice) =
    support.reviewer("alice") |> reviewer.with_issuer("https://id.example")
  let assert Ok(_) =
    fabric.approve(handle, pending.reference, reviewer: alice, context: Nil)
  let assert Ok(run.Finished(_)) =
    fabric.await(handle, within: duration.seconds(5))
  // Opened from the store: the reviewer was stored, issuer included.
  let assert Ok(opened) = fabric.open(runs, desk, Nil, fabric.id(handle))
  let assert Ok(snapshot) = fabric.snapshot(opened)
  let assert [run.ActionRecord(approvals: [approval], ..)] = snapshot.actions
  approval.reviewer |> should.equal(Some(alice))
  let assert Some(stored) = approval.reviewer
  reviewer.subject(stored) |> should.equal("alice")
  reviewer.issuer(stored) |> should.equal(Some("https://id.example"))
}

// --- records written before wave 5 ---------------------------------------------

fn fixture(name: String) -> String {
  let assert Ok(text) = restart.read_file("test/fixtures/records/" <> name)
  text
}

/// A suspended run stored before reviewers were typed and requests had
/// deadlines: its string reviewer and missing one read, and its pending
/// request never expires.
pub fn a_pre_wave_5_suspended_record_reads_test() {
  let assert Ok(state) = record.decode(fixture("pre-wave-5-suspended.json"))
  let snapshot = controller.snapshot(state)
  let assert [waiting, rejected] = snapshot.actions
  waiting.state
  |> should.equal(run.AwaitingApproval(Requirement("transfer", 1), 2, None))
  waiting.replays |> should.equal(0)
  let assert [run.Approval(answer: run.Approve, reviewer: Some(alice), ..)] =
    waiting.approvals
  reviewer.subject(alice) |> should.equal("alice")
  reviewer.issuer(alice) |> should.equal(None)
  let assert [run.Approval(answer: run.Reject("no"), reviewer: None, ..)] =
    rejected.approvals
  let assert run.Suspended([pending], []) = snapshot.status
  pending.expires |> should.equal(None)
  // No deadline: the sweeper has nothing to wake it for.
  discovery.inspect(fixture("pre-wave-5-suspended.json"))
  |> should.equal(Ok(None))
}

/// A model failure stored before kinds reads with the kind its
/// retryability implies.
pub fn a_pre_wave_5_model_failure_reads_test() {
  let assert Ok(state) = record.decode(fixture("pre-wave-5-model-failed.json"))
  let assert run.Finished(run.Failed(run.ModelFailed(error))) =
    controller.snapshot(state).status
  model.error_kind(error) |> should.equal(model.Overloaded)
  model.error_detail(error) |> should.equal("HTTP status 503")
  model.retry_after(error) |> should.equal(None)
}

// --- run ids -------------------------------------------------------------------

pub fn ids_from_known_parts_are_total_and_stable_test() {
  run.id_from_parts("research", ["42", "1"])
  |> run.id_to_string
  |> should.equal("research-42-1")
  run.id_from_parts("ticket", []) |> run.id_to_string |> should.equal("ticket")
  // Parts that are not id characters are hashed, the same way every time.
  let hashed = run.id_from_parts("ticket", ["Order #42 / EU"])
  hashed |> should.equal(run.id_from_parts("ticket", ["Order #42 / EU"]))
  let text = run.id_to_string(hashed)
  string.starts_with(text, "ticket_") |> should.be_true
  string.length(text) |> should.equal(7 + 64)
  run.parse_id(text) |> should.equal(Ok(hashed))
  // Too long for an id: hashed too.
  let long = run.id_from_parts("job", [string.repeat("a", 200)])
  string.length(run.id_to_string(long)) |> should.equal(4 + 64)
  // A prefix written in source that is not letters and digits is a bug.
  executor.rescue(fn() { run.id_from_parts("bad-prefix", []) })
  |> result_is_error
  |> should.be_true
}

fn result_is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

// --- the one error -------------------------------------------------------------

pub fn a_second_start_says_whether_its_input_matches_test() {
  let runs = support.store()
  let desk = approval_desk(probe.new())
  let id = run.new_id()
  let start = fn(prompt) {
    fabric.start(runs, desk, id:, context: Nil, prompt:, correlation: None)
  }
  let assert Ok(_) = start("pay")
  let assert Error(fabric.AlreadyStarted(found, same_input: True)) =
    start("pay")
  found |> should.equal(id)
  let assert Error(fabric.AlreadyStarted(_, same_input: False)) =
    start("pay twice")
}

pub fn every_error_has_a_kind_and_a_description_test() {
  let id = run.new_id()
  [
    #(fabric.AlreadyStarted(id, True), fabric.Refused),
    #(fabric.StartUnconfirmed(id, "lost"), fabric.Unavailable),
    #(fabric.FamilyBudgetUnsupported, fabric.Incompatible),
    #(fabric.RunNotFound, fabric.NotFound),
    #(fabric.StoreUnavailable("down"), fabric.Unavailable),
    #(fabric.UnsupportedVersion(99), fabric.Incompatible),
    #(fabric.CorruptRecord("bad"), fabric.Incompatible),
    #(fabric.IncompatibleAgent([]), fabric.Incompatible),
    #(fabric.RunEnded, fabric.Refused),
    #(fabric.RunNotFinished, fabric.Refused),
    #(fabric.WrongReference, fabric.NotFound),
    #(fabric.StaleReference, fabric.Refused),
    #(fabric.AlreadyAnswered, fabric.Refused),
    #(fabric.ApprovalExpired, fabric.Refused),
    #(fabric.NotReconcilable, fabric.Refused),
    #(fabric.RunUnattended, fabric.Unavailable),
    #(fabric.RunnerBusy, fabric.Retry),
    #(fabric.Contended, fabric.Retry),
  ]
  |> list.each(fn(case_) {
    let #(error, kind) = case_
    fabric.error_kind(error) |> should.equal(kind)
    { fabric.describe_error(error) != "" } |> should.be_true
  })
}

pub fn a_reviewer_from_a_token_is_checked_test() {
  reviewer.new("") |> should.equal(Error(reviewer.Empty(reviewer.Subject)))
  let long = string.repeat("é", 129)
  reviewer.new(long)
  |> should.equal(Error(reviewer.TooLong(reviewer.Subject, 258, 256)))
  let assert Ok(at_limit) = reviewer.new(string.repeat("a", 256))
  reviewer.subject(at_limit) |> should.equal(string.repeat("a", 256))
  reviewer.with_issuer(at_limit, "")
  |> should.equal(Error(reviewer.Empty(reviewer.Issuer)))
  reviewer.with_issuer(at_limit, string.repeat("i", 257))
  |> should.equal(Error(reviewer.TooLong(reviewer.Issuer, 257, 256)))
  reviewer.describe_error(reviewer.TooLong(reviewer.Subject, 258, 256))
  |> should.equal("the reviewer's subject is 258 bytes, longer than 256")
}

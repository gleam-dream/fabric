//// A policy can hand an action over to another system (`policy.HandOver`):
//// the run ends `run.HandedOver` at once, with no further model turn,
//// without running the action's tool and with no approval left to answer
//// or expire. The issue that asked for it is gleam-dream/fabric issue 5;
//// its first example is the pair of tests at the top.

import fabric
import fabric/agent
import fabric/history
import fabric/input
import fabric/internal/controller
import fabric/internal/record
import fabric/internal/runner
import fabric/internal/store as store_core
import fabric/invoke
import fabric/model
import fabric/policy
import fabric/run.{type ActionId, ActionId, ActionRef, Requirement}
import fabric/store
import fabric/store/backend
import fabric/store/conformance
import fabric/support
import fabric/support/codecs
import fabric/support/nodes
import fabric/support/probe.{type Probe}
import fabric/support/restart
import fabric/support/scripted
import fabric/sweeper
import fabric/telemetry as o
import fabric/tool
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import sinal

// --- the support agent of the issue's example ---------------------------------

const refund_arguments = "{\"amount\":80.0}"

const reason = "refunds are decided by finance"

/// The model of the issue's example. It reads the fee history, then calls
/// `refund_fee(80.00)`; given that call's result, whatever it is, it tells
/// Ana the refund is done. Every call is recorded as `model`. When `hold`
/// is set, its first attempt at the second turn waits at the barrier
/// `model` (so a test can kill its runner there).
fn support_model(calls: Probe, hold: Bool) -> model.Model {
  model.new(fn(request: model.Request) {
    probe.record(calls, "model")
    Ok(case scripted.results(request.messages) {
      [] -> ask([scripted.call("c1", "fee_history", "{\"customer\":\"ana\"}")])
      [_] -> {
        case hold && probe.count(calls, "held") == 0 {
          True -> {
            probe.record(calls, "held")
            probe.gate(calls, "model")
          }
          False -> Nil
        }
        ask([scripted.call("c2", "refund_fee", refund_arguments)])
      }
      _ -> model.FinalAnswer("Pronto, Ana: estornei os 80.00.", None)
    })
  })
}

fn ask(calls: List(model.ToolCall)) -> model.Reply {
  model.ToolRequest(model.AssistantTurn("", calls, None), None)
}

fn fee_history(effects: Probe) -> tool.Tool(context) {
  tool.define(
    "fee_history",
    "The fees charged to a customer.",
    codecs.one_field("customer", codec.string()),
    codec.string(),
  )
  |> tool.bind(
    fn(_, _, customer: String) -> Result(String, Nil) {
      probe.record(effects, "fee_history")
      Ok("late fee 80.00 charged to " <> customer)
    },
    fn(_) { tool.Explain("unreadable") },
  )
}

fn refund_definition() -> tool.Definition(Float, String) {
  tool.define(
    "refund_fee",
    "Refunds a fee, or part of one, to the customer.",
    codecs.one_field("amount", codec.float()),
    codec.string(),
  )
}

/// The gated tool. Its body records `refund`: a handover never runs it.
fn refund_fee(effects: Probe) -> tool.Tool(context) {
  tool.bind(
    refund_definition(),
    fn(_, _, amount: Float) -> Result(String, Nil) {
      probe.record(effects, "refund")
      Ok("refunded " <> string.inspect(amount))
    },
    fn(_) { tool.Explain("refund failed") },
  )
}

/// `refund_fee` gets `decision`; every other action is allowed.
fn gate(decision: policy.Decision) -> policy.Policy(context) {
  fn(_, action: policy.Action) {
    case action.name {
      "refund_fee" -> Ok(decision)
      _ -> Ok(policy.Allow)
    }
  }
}

fn support_agent(
  calls: Probe,
  effects: Probe,
  decision: policy.Decision,
) -> agent.Agent(Nil, String) {
  agent.new(
    "support",
    support_model(calls, False),
    [fee_history(effects), refund_fee(effects)],
    gate(decision),
  )
  |> agent.with_approval_expiry(run.After(duration.milliseconds(50)))
  |> support.agent
}

fn start(runs: store.Store, desk: agent.Agent(Nil, String), id: String) {
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk,
      id: support.id(id),
      context: Nil,
      prompt: "Handle this complaint from ana: refund my late fee.",
      correlation: None,
    )
  handle
}

fn handed_over(id: String) -> run.Status(String) {
  run.Finished(run.HandedOver(
    action: ActionRef(support.id(id), ActionId(2, "c2")),
    tool: "refund_fee",
    arguments_json: refund_arguments,
    reason:,
  ))
}

fn states(
  snapshot: run.Snapshot(answer),
) -> List(#(ActionId, run.ActionState)) {
  list.map(snapshot.actions, fn(action) { #(action.id, action.state) })
}

// --- the issue's first example -------------------------------------------------

/// The failing shape, as the issue reports it: the run parks on an
/// approval nobody can give, the approval expires, and the model takes a
/// third turn and tells Ana the refund is done although it never ran.
pub fn a_parked_run_continues_when_its_approval_expires_test() {
  let calls = probe.new()
  let effects = probe.new()
  let desk =
    support_agent(
      calls,
      effects,
      policy.RequireApproval(Requirement("decision-point", 1)),
    )
  let handle = start(support.store(), desk, "parked")
  let assert Ok(run.Suspended([_], [])) =
    fabric.await(handle, within: duration.seconds(5))
  probe.count(calls, "model") |> should.equal(2)

  process.sleep(100)
  fabric.await(handle, within: duration.seconds(5))
  |> should.equal(
    Ok(run.Finished(run.Completed("Pronto, Ana: estornei os 80.00."))),
  )
  probe.count(calls, "model") |> should.equal(3)
  probe.count(effects, "refund") |> should.equal(0)
}

/// The same model and the same gated tool, with the policy handing the
/// call over: the run ends at the handover, the approval expiry passes
/// with nothing to expire, no third model call happens and no answer is
/// produced. The record keeps the call and its outcome.
pub fn a_handed_over_call_ends_the_run_with_no_further_turn_test() {
  let calls = probe.new()
  let effects = probe.new()
  let runs = support.store()
  let desk = support_agent(calls, effects, policy.HandOver(reason))
  let handle = start(runs, desk, "handed-over")

  fabric.await(handle, within: duration.seconds(5))
  |> should.equal(Ok(handed_over("handed-over")))
  probe.count(calls, "model") |> should.equal(2)
  fabric.pending(handle) |> should.equal(Ok([]))

  process.sleep(100)
  fabric.await(handle, within: duration.seconds(5))
  |> should.equal(Ok(handed_over("handed-over")))
  probe.count(calls, "model") |> should.equal(2)
  probe.entries(effects) |> should.equal(["fee_history"])

  // The snapshot keeps the handed-over call with its arguments as the
  // model sent them, and tells this ending from a completion.
  let assert Ok(snapshot) = fabric.snapshot(handle)
  snapshot.status |> should.equal(handed_over("handed-over"))
  states(snapshot)
  |> should.equal([
    #(ActionId(1, "c1"), run.Succeeded("\"late fee 80.00 charged to ana\"")),
    #(ActionId(2, "c2"), run.Handover(reason)),
  ])
  let assert Ok(last) = list.last(snapshot.actions)
  last.call.arguments_json |> should.equal(refund_arguments)
  run.action_state_kind(last.state) |> should.equal(run.Ended)
  run.describe_outcome(run.HandedOver(
    action: ActionRef(support.id("handed-over"), ActionId(2, "c2")),
    tool: "refund_fee",
    arguments_json: refund_arguments,
    reason:,
  ))
  |> should.equal(
    "the run handed its call of refund_fee over: refunds are decided by finance",
  )

  // The transcript ends with the model's call, and no result follows it;
  // the history codec keeps it exactly.
  let assert Ok(model.AssistantMessage(turn)) = list.last(snapshot.transcript)
  list.map(turn.calls, fn(call) { call.name }) |> should.equal(["refund_fee"])
  let assert Ok(encoded) =
    codec.encode_json(history.codec(), snapshot.transcript)
  codec.decode_json(history.codec(), encoded)
  |> should.equal(Ok(snapshot.transcript))

  // The stored record holds the handover in the current format.
  let assert Ok(#(_, state)) = runner.load(runs, "handed-over")
  let encoded = record.encode(state)
  string.contains(encoded, "\"handed_over\"") |> should.be_true
  record.decode(encoded) |> should.equal(Ok(state))
  let assert controller.Ended(run.HandedOver(..)) = state.phase
}

// --- what stays true after the handover ---------------------------------------

/// The other calls of the reply that held the handover never start: an
/// allowed call is withdrawn, a call that needed an approval is withdrawn
/// with no request left to answer, and a call after the handover is not
/// shown to the policy at all.
pub fn the_other_calls_of_the_reply_are_withdrawn_test() {
  let calls = probe.new()
  let effects = probe.new()
  let asked = probe.new()
  let desk =
    agent.new(
      "support",
      model.new(fn(request: model.Request) {
        probe.record(calls, "model")
        Ok(case scripted.results(request.messages) {
          [] ->
            ask([
              scripted.call("a", "fee_history", "{\"customer\":\"ana\"}"),
              scripted.call("b", "refund_fee", "{\"amount\":20.0}"),
              scripted.call("c", "refund_fee", refund_arguments),
              scripted.call("d", "fee_history", "{\"customer\":\"bia\"}"),
            ])
          _ -> model.FinalAnswer("done", None)
        })
      }),
      [fee_history(effects), refund_fee(effects)],
      fn(_, action: policy.Action) {
        probe.record(asked, action.name <> ":" <> action.arguments_json)
        case action.name, action.arguments_json {
          "refund_fee", "{\"amount\":20.0}" ->
            Ok(policy.RequireApproval(Requirement("finance", 1)))
          "refund_fee", _ -> Ok(policy.HandOver(reason))
          _, _ -> Ok(policy.Allow)
        }
      },
    )
    |> support.agent
  let handle = start(support.store(), desk, "siblings")
  let assert Ok(run.Finished(run.HandedOver(action:, ..))) =
    fabric.await(handle, within: duration.seconds(5))
  action |> should.equal(ActionRef(support.id("siblings"), ActionId(1, "c")))

  let assert Ok(snapshot) = fabric.snapshot(handle)
  states(snapshot)
  |> should.equal([
    #(ActionId(1, "a"), run.NotStarted),
    #(ActionId(1, "b"), run.NotStarted),
    #(ActionId(1, "c"), run.Handover(reason)),
    #(ActionId(1, "d"), run.NotStarted),
  ])
  probe.entries(asked)
  |> should.equal([
    "fee_history:{\"customer\":\"ana\"}",
    "refund_fee:{\"amount\":20.0}",
    "refund_fee:" <> refund_arguments,
  ])
  probe.entries(effects) |> should.equal([])
  probe.count(calls, "model") |> should.equal(1)

  // The request issued for `b` before the handover was voided with it.
  fabric.pending(handle) |> should.equal(Ok([]))
  let voided =
    run.ApprovalRef(
      support.id("siblings"),
      ActionId(1, "b"),
      Requirement("finance", 1),
      1,
    )
  fabric.approve(
    handle,
    voided,
    proof: support.proof(Requirement("finance", 1), support.reviewer("bia")),
    context: Nil,
  )
  |> should.equal(Error(fabric.RunEnded))
  fabric.reject(
    handle,
    voided,
    reason: "no",
    proof: support.proof(Requirement("finance", 1), support.reviewer("bia")),
  )
  |> should.equal(Error(fabric.RunEnded))
  probe.entries(effects) |> should.equal([])
  probe.count(calls, "model") |> should.equal(1)
}

/// A slow sibling for the tests whose handover arrives while it runs. Its
/// body records `start:<x>` and waits at the barrier `x`. When `settling`,
/// it settles late (`tool.bind_settling`), so a stopped run waits for its
/// settlement, up to a minute: long enough to kill the runner in that
/// window.
fn slow_tool(effects: Probe, settling: Bool) -> tool.Tool(context) {
  let definition =
    tool.define(
      "slow",
      "Waits for the test.",
      codecs.one_field("x", codec.string()),
      codec.string(),
    )
  let body = fn(x: String) -> Result(String, Nil) {
    probe.record(effects, "start:" <> x)
    probe.gate(effects, x)
    Ok(x)
  }
  case settling {
    True ->
      tool.bind_settling(
        definition,
        fn(_, _, x, _settlement) { body(x) },
        fn(_) { tool.Explain("failed") },
        settle_within: duration.seconds(60),
      )
    False ->
      tool.bind(definition, fn(_, _, x) { body(x) }, fn(_) {
        tool.Explain("failed")
      })
  }
}

/// One reply calls `slow` (allowed) and `refund_fee`, which waits for an
/// approval. The policy hands the refund over when its context says so:
/// an approval answered under that context hands the call over instead.
fn deciding_agent(
  effects: Probe,
  settling: Bool,
) -> agent.Agent(String, String) {
  agent.new(
    "deciding",
    scripted.plan([
      scripted.call("s", "slow", "{\"x\":\"s\"}"),
      scripted.call("r", "refund_fee", refund_arguments),
    ]),
    [slow_tool(effects, settling), refund_fee(effects)],
    fn(context: String, action: policy.Action) {
      case action.name, context {
        "refund_fee", "hand over" -> Ok(policy.HandOver(reason))
        "refund_fee", _ -> Ok(policy.RequireApproval(Requirement("finance", 1)))
        _, _ -> Ok(policy.Allow)
      }
    },
  )
  |> support.agent
}

/// Starts the deciding agent, waits until `slow` runs, and answers the
/// refund's approval under a context the policy hands it over under.
fn hand_over_on_answer(
  runs: store.Store,
  effects: Probe,
  settling: Bool,
  id: String,
) -> fabric.Run(String, String) {
  let assert Ok(handle) =
    fabric.start(
      runs,
      deciding_agent(effects, settling),
      id: support.id(id),
      context: "ask",
      prompt: "go",
      correlation: None,
    )
  let arrival = probe.arrival(effects)
  arrival.name |> should.equal("s")
  let assert Ok([pending]) = fabric.pending(handle)
  let assert Ok(_) =
    fabric.approve(
      handle,
      pending.reference,
      proof: support.proof(Requirement("finance", 1), support.reviewer("bia")),
      context: "hand over",
    )
  handle
}

/// A handover decided by an approval's recheck while a sibling's body is
/// in flight stops that body as a cancellation does, and the run ends
/// `HandedOver`: the stopped sibling is an uncertain effect, kept for
/// reconciliation, and the answered approval authorizes nothing.
pub fn a_handover_on_an_answer_stops_the_running_sibling_test() {
  let effects = probe.new()
  let runs = support.store()
  let handle = hand_over_on_answer(runs, effects, False, "answered")
  let assert Ok(run.Finished(run.HandedOver(action:, ..))) =
    fabric.await(handle, within: duration.seconds(5))
  action |> should.equal(ActionRef(support.id("answered"), ActionId(1, "r")))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [sibling, handed] = snapshot.actions
  let assert run.Uncertain(_) = sibling.state
  handed.state |> should.equal(run.Handover(reason))
  let assert [run.Approval(answer: run.Approve, ..)] = handed.approvals
  probe.count(effects, "start:s") |> should.equal(1)
  probe.count(effects, "refund") |> should.equal(0)

  // The uncertain sibling is reconciled on the ended run as evidence; the
  // run does not continue.
  let assert Ok(reconciled) =
    fabric.reconcile_stored(
      runs,
      ActionRef(support.id("answered"), ActionId(1, "s")),
      "\"s\"",
    )
  let assert run.Finished(run.HandedOver(..)) = reconciled.status
  let assert [run.ActionRecord(state: run.Reconciled(_), ..), _] =
    reconciled.actions
}

// --- recovery around the handover ---------------------------------------------

/// The runner is killed while the model is computing the reply that holds
/// the handover: nothing of the reply was recorded. Recovery asks the
/// model again, and the run ends at the same handover; no tool body ran.
pub fn a_runner_killed_before_the_handover_is_recorded_test() {
  let calls = probe.new()
  let effects = probe.new()
  let runs = support.store()
  let desk =
    agent.new(
      "support",
      support_model(calls, True),
      [fee_history(effects), refund_fee(effects)],
      gate(policy.HandOver(reason)),
    )
    |> support.agent
  let handle = start(runs, desk, "killed-before")
  let held = probe.arrival(calls)
  held.name |> should.equal("model")
  let assert Ok(runner) = restart.runner(runs, support.id("killed-before"))
  restart.kill(runner)
  fabric.await(handle, within: duration.seconds(5))
  |> should.equal(Ok(run.Unattended))

  let assert Ok(recovered) =
    fabric.recover(runs, desk, Nil, support.id("killed-before"))
  // The lost attempt counted: the reply that hands over is attempt 3.
  fabric.await(recovered, within: duration.seconds(5))
  |> should.equal(
    Ok(
      run.Finished(run.HandedOver(
        action: ActionRef(support.id("killed-before"), ActionId(3, "c2")),
        tool: "refund_fee",
        arguments_json: refund_arguments,
        reason:,
      )),
    ),
  )
  probe.count(calls, "model") |> should.equal(3)
  probe.entries(effects) |> should.equal(["fee_history"])
}

/// The handover is recorded while a sibling's body was stopped and its
/// settlement is awaited; the runner is killed then. Recovery completes
/// the stop into the same ending: the sibling is an uncertain effect,
/// never started again, and the handed-over tool never ran.
pub fn a_runner_killed_after_the_handover_is_recorded_test() {
  let effects = probe.new()
  let runs = support.store()
  let _ = hand_over_on_answer(runs, effects, True, "killed-after")
  let assert Ok(#(_, state)) = runner.load(runs, "killed-after")
  let assert controller.Stopping(reason: controller.HandedOver(..), ..) =
    state.phase
  let assert Ok(runner) = restart.runner(runs, support.id("killed-after"))
  restart.kill(runner)

  let assert Ok(recovered) =
    fabric.recover(
      runs,
      deciding_agent(effects, True),
      "ask",
      support.id("killed-after"),
    )
  let assert Ok(run.Finished(run.HandedOver(action:, tool:, ..))) =
    fabric.await(recovered, within: duration.seconds(5))
  action
  |> should.equal(ActionRef(support.id("killed-after"), ActionId(1, "r")))
  tool |> should.equal("refund_fee")
  let assert Ok(snapshot) = fabric.snapshot(recovered)
  let assert [#(_, run.Uncertain(_)), #(_, run.Handover(handed_reason))] =
    states(snapshot)
  handed_reason |> should.equal(reason)
  probe.count(effects, "start:s") |> should.equal(1)
  probe.count(effects, "refund") |> should.equal(0)

  // Recovering the ended run again changes nothing.
  let assert Ok(again) =
    fabric.recover(
      runs,
      deciding_agent(effects, True),
      "ask",
      support.id("killed-after"),
    )
  let assert Ok(run.Finished(run.HandedOver(..))) =
    fabric.await(again, within: duration.seconds(1))
  probe.count(effects, "start:s") |> should.equal(1)
}

// --- sub-agents ---------------------------------------------------------------

/// A sub-agent run that hands one of its calls over ends its parent the
/// same way, with no further turn of the parent's model: the parent's
/// outcome names the child's action, and its delegation is handed over.
pub fn a_sub_agents_handover_ends_its_parent_test() {
  let calls = probe.new()
  let effects = probe.new()
  let child =
    agent.new(
      "finance",
      scripted.plan([scripted.call("c", "refund_fee", refund_arguments)]),
      [refund_fee(effects)],
      gate(policy.HandOver(reason)),
    )
    |> support.agent
  let parent =
    agent.new(
      "front",
      model.new(fn(request: model.Request) {
        probe.record(calls, "parent")
        Ok(case scripted.results(request.messages) {
          [] -> ask([scripted.call("d", "ask_finance", "{\"x\":\"refund\"}")])
          _ -> model.FinalAnswer("done", None)
        })
      }),
      [],
      policy.always_allow(),
    )
    |> agent.with_sub_agent(
      tool.define(
        "ask_finance",
        "Asks finance.",
        codecs.one_field("x", codec.string()),
        codec.string(),
      ),
      to: child,
      prompt: fn(x) { x },
    )
    |> support.agent
  let handle = start(support.store(), parent, "parent")
  let assert Ok(run.Finished(run.HandedOver(action:, tool:, arguments_json:, ..))) =
    fabric.await(handle, within: duration.seconds(5))
  tool |> should.equal("refund_fee")
  arguments_json |> should.equal(refund_arguments)
  action.id |> should.equal(ActionId(1, "c"))
  action.run |> should.not_equal(support.id("parent"))
  probe.count(calls, "parent") |> should.equal(1)
  probe.entries(effects) |> should.equal([])

  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [delegation] = snapshot.actions
  delegation.state |> should.equal(run.Handover(reason))
  delegation.child |> should.equal(Some(action.run))
  let assert Ok(child_run) = fabric.child(handle, action.run)
  let assert Ok(child_snapshot) = fabric.snapshot(child_run)
  child_snapshot.status |> should.equal(snapshot.status)
}

// --- record versions ----------------------------------------------------------

/// A store that writes a record version before 10 cannot hold a
/// handover: the policy's handover fails the run closed instead, and the
/// tool still never runs.
pub fn an_older_writer_fails_a_handover_closed_test() {
  let calls = probe.new()
  let effects = probe.new()
  let assert Ok(runs) =
    store.in_memory(process.new_name("handover-v9"))
    |> store.with_record_version(9)
  let runs = support.started(runs)
  let handle =
    start(runs, support_agent(calls, effects, policy.HandOver(reason)), "v9")
  let assert Ok(run.Finished(run.Failed(run.PolicyFailed(id:, reason: why)))) =
    fabric.await(handle, within: duration.seconds(5))
  id |> should.equal(ActionId(2, "c2"))
  string.contains(why, "version") |> should.be_true
  probe.count(calls, "model") |> should.equal(2)
  probe.entries(effects) |> should.equal(["fee_history"])
}

/// Only version 10 writes a handover; a version 9 record that claims one
/// is corrupt, and the frozen readers of earlier versions never see one.
pub fn a_handover_is_written_only_in_version_10_test() {
  let effects = probe.new()
  let runs = support.store()
  let handle =
    start(
      runs,
      support_agent(probe.new(), effects, policy.HandOver(reason)),
      "versions",
    )
  let assert Ok(run.Finished(run.HandedOver(..))) =
    fabric.await(handle, within: duration.seconds(5))
  let assert Ok(#(_, state)) = runner.load(runs, "versions")
  list.each(
    [
      record.V2,
      record.V3,
      record.V4,
      record.V5,
      record.V6,
      record.V7,
      record.V8,
      record.V9,
    ],
    fn(version) {
      let assert Error(record.Unrepresentable(_, detail)) =
        record.encode_as(state, version)
      detail |> should.equal("a handover requires version 10")
    },
  )
  let assert Ok(encoded) = record.encode_as(state, record.V10)
  record.decode(encoded) |> should.equal(Ok(state))
  let assert Error(record.Corrupt(_)) =
    record.decode(string.replace(encoded, "\"version\":10", "\"version\":9"))
}

// --- records written by the published format ----------------------------------

/// `test/fixtures/records/published-0.2.0-parked.json` was written by the
/// published fabric 0.2.0 (record version 9, commit d4e2969) through a
/// directory store: the issue's support agent parked on an approval that
/// never expires. The current reader reads it, and cancelling it (with no
/// model turn) is how an application ends such a parked run: the request
/// is voided and nobody can answer it later.
pub fn a_run_parked_by_the_published_format_reads_and_cancels_test() {
  let assert Ok(text) =
    restart.read_file("test/fixtures/records/published-0.2.0-parked.json")
  string.contains(text, "\"version\":9,") |> should.be_true
  let calls = probe.new()
  let effects = probe.new()
  let runs = support.store()
  let assert Ok(_) =
    store_core.insert(
      runs,
      "run-published-parked",
      text,
      store_core.Detached(in_flight: False, seize: False),
    )
  let desk =
    agent.new(
      "support",
      support_model(calls, False),
      [fee_history(effects), published_refund(effects)],
      gate(policy.RequireApproval(Requirement("decision-point", 1))),
    )
    |> agent.with_approval_expiry(run.Infinity)
    |> support.agent
  let assert Ok(handle) =
    fabric.open(runs, desk, Nil, support.id("run-published-parked"))
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(handle, within: duration.milliseconds(0))
  pending.tool |> should.equal("transfer_funds")
  pending.arguments_json |> should.equal("{\"to\":\"ana\",\"amount\":80}")
  pending.expires |> should.equal(None)

  fabric.cancel(handle) |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  states(snapshot)
  |> should.equal([
    #(ActionId(1, "c1"), run.Succeeded("\"late fee 80.00 for ana\"")),
    #(ActionId(2, "c2"), run.NotStarted),
  ])
  fabric.approve(
    handle,
    pending.reference,
    proof: support.proof(pending.reference.requirement, support.reviewer("bia")),
    context: Nil,
  )
  |> should.equal(Error(fabric.RunEnded))
  probe.count(calls, "model") |> should.equal(0)
  probe.entries(effects) |> should.equal([])
}

/// The fixture's gated tool, as the published run named it.
fn published_refund(effects: Probe) -> tool.Tool(context) {
  tool.define(
    "transfer_funds",
    "Transfer an amount to a recipient.",
    {
      use to <- codec.field("to", codec.string(), get: fn(t: #(String, Int)) {
        t.0
      })
      use amount <- codec.field(
        "amount",
        codec.int(),
        get: fn(t: #(String, Int)) { t.1 },
      )
      codec.success(#(to, amount))
    },
    codec.string(),
  )
  |> tool.bind(
    fn(_, _, _transfer) -> Result(String, Nil) {
      probe.record(effects, "transfer")
      Ok("sent")
    },
    fn(_) { tool.Explain("failed") },
  )
}

/// Cancellation already ends a run parked on an approval without a model
/// turn: once cancelled, the approval's expiry passes and nothing wakes
/// the run. No second mechanism is needed for a parked run.
pub fn cancelling_a_parked_run_outlasts_its_approval_expiry_test() {
  let calls = probe.new()
  let effects = probe.new()
  let desk =
    support_agent(
      calls,
      effects,
      policy.RequireApproval(Requirement("decision-point", 1)),
    )
  let handle = start(support.store(), desk, "cancelled-parked")
  let assert Ok(run.Suspended([_], [])) =
    fabric.await(handle, within: duration.seconds(5))
  fabric.cancel(handle) |> should.equal(Ok(run.Finished(run.Cancelled)))
  process.sleep(100)
  fabric.await(handle, within: duration.seconds(5))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  probe.count(calls, "model") |> should.equal(2)
  probe.count(effects, "refund") |> should.equal(0)
}

// --- continuing elsewhere -----------------------------------------------------

/// The application continues the handed-over conversation in a follow-on
/// run: the history answers the handed-over call with what the other
/// system decided, and the follow-on model reads it as the call's result.
/// The handed-over run itself stays ended.
pub fn a_follow_on_run_continues_from_the_handover_history_test() {
  let calls = probe.new()
  let effects = probe.new()
  let runs = support.store()
  let desk = support_agent(calls, effects, policy.HandOver(reason))
  let handle = start(runs, desk, "first")
  let assert Ok(run.Finished(run.HandedOver(..))) =
    fabric.await(handle, within: duration.seconds(5))
  let assert Ok(snapshot) = fabric.snapshot(handle)

  let assert Ok(decided) =
    tool.reconciliation(refund_definition(), Ok("refunded 60.00"))
  let assert Ok(history) = fabric.handover_history(snapshot, result: decided)
  let assert Ok(model.ToolResultMessage("c2", content)) = list.last(history)
  content |> should.equal(json.to_string(json.string("refunded 60.00")))
  let assert Ok(follow) = input.new(history, "Tell Ana what was decided.")
  let assert Ok(next) =
    fabric.start_with_input(
      runs,
      desk,
      id: support.id("follow-on"),
      context: Nil,
      input: follow,
      correlation: None,
    )
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(next, within: duration.seconds(5))
  probe.count(effects, "refund") |> should.equal(0)

  fabric.handover_history(
    run.Snapshot(..snapshot, status: run.Finished(run.Cancelled)),
    result: decided,
  )
  |> should.equal(Error(fabric.NotHandedOver))
  fabric.await(handle, within: duration.milliseconds(0))
  |> should.equal(Ok(handed_over("first")))
}

// --- recovery's recheck, the sweeper, the directory store ---------------------

/// One reply calls `slow` and `refund_fee`, both allowed while the context
/// is "allow"; one tool body runs at a time, so the refund waits queued
/// behind `slow`. Under the context "hand over" the policy hands the refund
/// over.
fn queueing_agent(effects: Probe) -> agent.Agent(String, String) {
  agent.new(
    "queueing",
    scripted.plan([
      scripted.call("s", "slow", "{\"x\":\"s\"}"),
      scripted.call("r", "refund_fee", refund_arguments),
    ]),
    [slow_tool(effects, False), refund_fee(effects)],
    fn(context: String, action: policy.Action) {
      case action.name, context {
        "refund_fee", "hand over" -> Ok(policy.HandOver(reason))
        _, _ -> Ok(policy.Allow)
      }
    },
  )
  |> agent.with_max_concurrency(1)
  |> support.agent
}

/// The runner is lost while `slow` runs and the refund waits queued.
/// Recovery passes the queued refund through the policy again with the
/// recovering context, which hands it over: the run ends `HandedOver`, the
/// interrupted `slow` is an uncertain effect, and the refund never ran. A
/// second recovery changes nothing.
pub fn a_handover_on_recoverys_recheck_ends_the_run_test() {
  let effects = probe.new()
  let runs = support.store()
  let id = support.id("rechecked")
  let assert Ok(_) =
    fabric.start(
      runs,
      queueing_agent(effects),
      id:,
      context: "allow",
      prompt: "go",
      correlation: None,
    )
  probe.arrival(effects).name |> should.equal("s")
  let assert Ok(#(_, before)) = runner.load(runs, "rechecked")
  let assert controller.Acting(
    _,
    [
      run.ActionRecord(state: run.Running, ..),
      run.ActionRecord(state: run.Queued, ..),
    ],
  ) = before.phase
  let assert Ok(runner) = restart.runner(runs, id)
  restart.kill(runner)

  let assert Ok(recovered) =
    fabric.recover(runs, queueing_agent(effects), "hand over", id)
  let expected =
    run.Finished(run.HandedOver(
      action: ActionRef(id, ActionId(1, "r")),
      tool: "refund_fee",
      arguments_json: refund_arguments,
      reason:,
    ))
  fabric.await(recovered, within: duration.seconds(5))
  |> should.equal(Ok(expected))
  let assert Ok(snapshot) = fabric.snapshot(recovered)
  let assert [#(_, run.Uncertain(_)), #(_, run.Handover(handed))] =
    states(snapshot)
  handed |> should.equal(reason)
  probe.count(effects, "start:s") |> should.equal(1)
  probe.count(effects, "refund") |> should.equal(0)

  let assert Ok(again) =
    fabric.recover(runs, queueing_agent(effects), "hand over", id)
  fabric.await(again, within: duration.seconds(1))
  |> should.equal(Ok(expected))
  let assert Ok(unchanged) = fabric.snapshot(again)
  unchanged.actions |> should.equal(snapshot.actions)
  unchanged.incarnation |> should.equal(snapshot.incarnation)
  probe.count(effects, "start:s") |> should.equal(1)
  probe.count(effects, "refund") |> should.equal(0)
}

/// On a leased store, the runner of a run stopping for a handover (its
/// sibling's settlement awaited) is lost and its lease expires. The
/// sweeper recovers the run into the same `HandedOver` ending, with the
/// stopped sibling an uncertain effect.
pub fn the_sweeper_completes_a_handover_whose_runner_was_lost_test() {
  let effects = probe.new()
  let memory = conformance.leased_memory()
  let runs = nodes.node(memory.backend, "a", nodes.long)
  let handle = hand_over_on_answer(runs, effects, True, "swept")
  let id = support.id("swept")
  let assert Ok(#(_, state)) = runner.load(runs, "swept")
  let assert controller.Stopping(reason: controller.HandedOver(..), ..) =
    state.phase
  let assert Ok(runner) = restart.runner(runs, id)
  restart.kill(runner)
  let assert backend.Held(owner, True) = nodes.holder(memory.backend, id)
  let assert Ok(_) = memory.backend.renew(owner, [run.id_to_string(id)], 0)

  let assert Ok(sweeping) =
    sweeper.start(
      runs,
      [sweeper.agent(deciding_agent(effects, True), fn(_) { "ask" })],
      every: duration.milliseconds(10),
    )
  let assert run.Finished(run.HandedOver(action:, ..)) = ended(handle, 500)
  process.unlink(sweeping)
  restart.kill(sweeping)
  action |> should.equal(ActionRef(id, ActionId(1, "r")))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [#(_, run.Uncertain(_)), #(_, run.Handover(_))] = states(snapshot)
  probe.count(effects, "start:s") |> should.equal(1)
  probe.count(effects, "refund") |> should.equal(0)
}

/// The run's status once it has ended, read again while it has not.
fn ended(handle: fabric.Run(c, a), tries: Int) -> run.Status(a) {
  let assert Ok(status) =
    fabric.await(handle, within: duration.milliseconds(20))
  case status {
    run.Finished(_) -> status
    _ if tries > 0 -> ended(handle, tries - 1)
    other -> panic as { "the run did not end: " <> string.inspect(other) }
  }
}

/// A handed-over run written by a directory store reads back the same
/// after the store stops and a new store opens the same directory: its
/// outcome, its snapshot and its follow-on history.
pub fn a_directory_store_reads_a_handover_back_after_a_restart_test() {
  let dir = restart.temp_dir()
  let calls = probe.new()
  let effects = probe.new()
  let desk = support_agent(calls, effects, policy.HandOver(reason))
  let first = support.directory(dir)
  let handle = start(first, desk, "on-disk")
  fabric.await(handle, within: duration.seconds(5))
  |> should.equal(Ok(handed_over("on-disk")))
  let assert Ok(written) = fabric.snapshot(handle)
  let assert Ok(Nil) = store.stop(first)

  let second = support.directory(dir)
  let assert Ok(opened) = fabric.open(second, desk, Nil, support.id("on-disk"))
  fabric.await(opened, within: duration.milliseconds(0))
  |> should.equal(Ok(handed_over("on-disk")))
  let assert Ok(read) = fabric.snapshot(opened)
  read |> should.equal(written)
  let assert Ok(history) = fabric.handover_history(read, result: "\"decided\"")
  let assert Ok(model.ToolResultMessage("c2", "\"decided\"")) =
    list.last(history)
  probe.count(calls, "model") |> should.equal(2)
  let assert Ok(Nil) = store.stop(second)
  restart.remove_dir(dir)
}

// --- invocation and telemetry --------------------------------------------------

/// An invocation that meets a handover reports the run as ended, with the
/// code `handed_over`, and no answer.
pub fn an_invocation_reports_a_handover_as_ended_test() {
  let desk = support_agent(probe.new(), probe.new(), policy.HandOver(reason))
  let service = invoke.agent("desk", support.store(), desk)
  let response =
    invoke.call(service, invoke.request(Nil, "Refund Ana's late fee."))
  invoke.response_kind(response) |> should.equal(invoke.Ended)
  invoke.code(response) |> should.equal("handed_over")
  invoke.answer(response) |> should.equal(None)
  string.contains(invoke.describe_response(response), "refund_fee")
  |> should.be_true
}

/// `run_finished` events whose run belongs to the family rooted at `root`,
/// as (run, outcome kind), within `wait` milliseconds each.
fn finished_events(
  events: process.Subject(#(String, String, o.OutcomeKind)),
  root: String,
  wait: Int,
) -> List(#(String, o.OutcomeKind)) {
  case process.receive(events, wait) {
    Ok(#(run, event_root, kind)) if event_root == root -> [
      #(run, kind),
      ..finished_events(events, root, wait)
    ]
    Ok(_) -> finished_events(events, root, wait)
    Error(Nil) -> []
  }
}

/// A handover is observed once per run as the outcome kind `HandedOver`.
/// A parent ended by its sub-agent's handover reports its own
/// `run_finished` with `HandedOver` too, beside its child's: each run of
/// the family reports how it ended, once. The handed-over delegation emits
/// no `child_settled`, as a refused one does not: no result reached the
/// parent's model.
pub fn telemetry_reports_handed_over_once_per_run_test() {
  let events = process.new_subject()
  let attachment =
    sinal.observe(o.run_finished(), fn(_totals, finished: o.RunFinished) {
      process.send(events, #(finished.run, finished.root, finished.outcome))
    })

  let alone =
    start(
      support.store(),
      support_agent(probe.new(), probe.new(), policy.HandOver(reason)),
      "observed",
    )
  let assert Ok(run.Finished(run.HandedOver(..))) =
    fabric.await(alone, within: duration.seconds(5))
  finished_events(events, "observed", 200)
  |> should.equal([#("observed", o.HandedOver)])

  let parent =
    start(support.store(), delegating_parent(probe.new()), "observed-parent")
  let assert Ok(run.Finished(run.HandedOver(action:, ..))) =
    fabric.await(parent, within: duration.seconds(5))
  // Parent and child report from their own processes, in no fixed order.
  let family = finished_events(events, "observed-parent", 200)
  list.length(family) |> should.equal(2)
  list.contains(family, #(run.id_to_string(action.run), o.HandedOver))
  |> should.be_true
  list.contains(family, #("observed-parent", o.HandedOver)) |> should.be_true
  let _ = sinal.detach(attachment)
  Nil
}

/// A parent that delegates once to a `finance` child whose policy hands
/// `refund_fee` over.
fn delegating_parent(effects: Probe) -> agent.Agent(Nil, String) {
  let child =
    agent.new(
      "finance",
      scripted.plan([scripted.call("c", "refund_fee", refund_arguments)]),
      [refund_fee(effects)],
      gate(policy.HandOver(reason)),
    )
    |> support.agent
  agent.new(
    "front",
    scripted.plan([scripted.call("d", "ask_finance", "{\"x\":\"refund\"}")]),
    [],
    policy.always_allow(),
  )
  |> agent.with_sub_agent(
    tool.define(
      "ask_finance",
      "Asks finance.",
      codecs.one_field("x", codec.string()),
      codec.string(),
    ),
    to: child,
    prompt: fn(x) { x },
  )
  |> support.agent
}

// --- the follow-on history -----------------------------------------------------

/// Every call of the reply that ended the run gets a result in the history:
/// a refused call its refusal as the model would have seen it, a withdrawn
/// call an error saying it never ran, and the handed-over call the
/// decision. The history is therefore accepted as original input, which
/// checks that every call has a result.
pub fn the_handover_history_answers_every_call_of_the_reply_test() {
  let effects = probe.new()
  let desk =
    agent.new(
      "support",
      scripted.plan([
        scripted.call("u", "no_such_tool", "{}"),
        scripted.call("a", "fee_history", "{\"customer\":\"ana\"}"),
        scripted.call("c", "refund_fee", refund_arguments),
        scripted.call("d", "fee_history", "{\"customer\":\"bia\"}"),
      ]),
      [fee_history(effects), refund_fee(effects)],
      gate(policy.HandOver(reason)),
    )
    |> support.agent
  let handle = start(support.store(), desk, "every-call")
  let assert Ok(run.Finished(run.HandedOver(..))) =
    fabric.await(handle, within: duration.seconds(5))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert Ok(history) = fabric.handover_history(snapshot, result: "\"60\"")
  let not_started =
    "{\"error\":\"not_started\",\"detail\":\"the run was handed over before this call started\"}"
  list.drop(history, list.length(snapshot.transcript))
  |> should.equal([
    model.ToolResultMessage("u", "{\"error\":\"unknown_tool\"}"),
    model.ToolResultMessage("a", not_started),
    model.ToolResultMessage("c", "\"60\""),
    model.ToolResultMessage("d", not_started),
  ])
  let assert Ok(_) = input.new(history, "Finance decided.")
  probe.entries(effects) |> should.equal([])
}

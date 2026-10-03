//// THROWAWAY (workflow composition experiment). Variant C: the whole loop
//// as one Saga workflow on Saga's shipped API. Tests named `..._breaks_...`
//// pass by demonstrating where the composition fails.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import saga
import saga/execution
import wc/app
import wc/probe.{type Probe}
import wc/variant_c.{ApprovalRequest, HoldForApproval, WaitInStep}

const lisbon = "{\"city\":\"Lisbon\",\"celsius\":21}"

fn config() -> execution.Config {
  execution.config() |> execution.with_settle_timeout(50)
}

fn workflow(probe: Probe, mode: variant_c.ApprovalMode, max_turns: Int) {
  let assert Ok(workflow) =
    variant_c.define(
      app.scripted(probe),
      app.all_tools(probe),
      app.policy,
      mode,
      max_turns,
    )
  workflow
}

fn model_calls(probe: Probe) -> List(String) {
  list.filter(probe.entries(probe), string.starts_with(_, "model:"))
}

/// Rows 1, 2, 4 pass while everything stays in one process lifetime.
pub fn c_row1_2_4_in_process_approval_completes_test() {
  let probe = probe.new()
  let approver = process.new_subject()
  let assert Ok(run) =
    execution.start(
      workflow(probe, WaitInStep(approver), 3),
      variant_c.begin("weather and transfer"),
      config(),
    )
  let assert Ok(ApprovalRequest(call, reply)) = process.receive(approver, 5000)
  let assert "transfer_funds" = call.name
  process.send(reply, True)
  let assert Ok(execution.Completed(conversation)) =
    execution.await(run, timeout: 5000)
  assert conversation.answer
    == Some("c1=" <> lisbon <> ";c2={\"receipt\":\"rcpt-acct-b\"}")
}

/// Row 3 breaks: the pause lives in a blocked step process. Losing the owner
/// loses it; nothing is stored, so the only recovery is to start over, which
/// repeats the model call and the lookup's effect.
pub fn c_row3_restart_breaks_pause_and_repeats_effects_test() {
  let probe = probe.new()
  let approver = process.new_subject()
  let wf = workflow(probe, WaitInStep(approver), 3)
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(run) =
        execution.start(wf, variant_c.begin("weather and transfer"), config())
      execution.await(run, timeout: 60_000)
    })
  let assert Ok(ApprovalRequest(_, _)) = process.receive(approver, 5000)
  process.kill(owner)

  let assert Ok(run) =
    execution.start(wf, variant_c.begin("weather and transfer"), config())
  let assert Ok(ApprovalRequest(_, reply)) = process.receive(approver, 5000)
  process.send(reply, True)
  let assert Ok(execution.Completed(_)) = execution.await(run, timeout: 5000)
  let assert 2 = probe.count(probe, "weather:start:Lisbon")
  let assert ["model:1", "model:1", "model:4"] = model_calls(probe)
}

/// Row 3 breaks differently with `Hold`: the pause is a terminal
/// `Unresolved`. No API delivers an answer into it; running again repeats
/// every completed effect before pausing again.
pub fn c_row3_hold_breaks_resume_test() {
  let probe = probe.new()
  let wf = workflow(probe, HoldForApproval, 3)
  let assert Ok(execution.Unresolved(step, variant_c.NeedsApproval([call]), _)) =
    execution.run(wf, variant_c.begin("weather and transfer"), config())
  let assert "tools-1" = step.name
  let assert "c2" = call.id
  let assert Ok(execution.Unresolved(..)) =
    execution.run(wf, variant_c.begin("weather and transfer"), config())
  let assert 2 = probe.count(probe, "weather:start:Lisbon")
  let assert 0 = probe.count(probe, "transfer:start:acct-b")
}

/// Row 5 passes only at step granularity: cancellation reports the whole
/// tool batch as one interrupted step, not which call's effect is unknown.
pub fn c_row5_cancel_reports_batch_not_call_test() {
  let probe = probe.new()
  let approver = process.new_subject()
  let assert Ok(run) =
    execution.start(
      workflow(probe, WaitInStep(approver), 3),
      variant_c.begin("gated weather and transfer"),
      config(),
    )
  let arrival = probe.arrival(probe)
  let assert "gated-Lisbon" = arrival.name
  execution.cancel(run)
  let assert Ok(execution.Cancelled(execution.CancelRequested, settlement)) =
    execution.await(run, timeout: 5000)
  let assert ["tools-1"] = list.map(settlement.interrupted, fn(a) { a.name })
  let assert 0 = probe.count(probe, "weather:end:gated-Lisbon")
}

/// Row 6 breaks: an uncertain effect can only `Hold`, which ends the run.
/// There is no reconcile-then-continue.
pub fn c_row6_uncertain_effect_breaks_continuation_test() {
  let probe = probe.new()
  let approver = process.new_subject()
  let assert Ok(run) =
    execution.start(
      workflow(probe, WaitInStep(approver), 3),
      variant_c.begin("failures"),
      config(),
    )
  let assert Ok(ApprovalRequest(_, reply)) = process.receive(approver, 5000)
  process.send(reply, True)
  let assert Ok(execution.Unresolved(
    step,
    variant_c.UncertainEffect(call, _),
    _,
  )) = execution.await(run, timeout: 5000)
  let assert "tools-1" = step.name
  let assert "c2" = call.id
  let assert ["model:1"] = model_calls(probe)
}

/// Row 7b passes by unrolling: the turn budget is the graph's size.
pub fn c_row7_turn_budget_by_unrolling_test() {
  let probe = probe.new()
  let wf = workflow(probe, HoldForApproval, 1)
  let assert Ok(execution.Completed(conversation)) =
    execution.run(wf, variant_c.begin("weather"), config())
  let assert None = conversation.answer
  let assert 2 = list.length(saga.describe(wf))
  let assert ["model:1"] = model_calls(probe)
}

/// Row 8 passes in process: the Saga tool runs as a nested run inside the
/// batch step, and a sub-agent start waits for approval before it begins.
pub fn c_row8_saga_tool_and_delegate_in_process_test() {
  let probe = probe.new()
  let approver = process.new_subject()
  let wf = workflow(probe, WaitInStep(approver), 3)
  let assert Ok(execution.Completed(trip)) =
    execution.run(wf, variant_c.begin("trip Atlantis"), config())
  let assert Some(answer) = trip.answer
  assert string.contains(answer, "\"undone\":[\"reserve_flight\"]")

  let assert Ok(run) =
    execution.start(wf, variant_c.begin("delegate"), config())
  let assert Ok(ApprovalRequest(call, reply)) = process.receive(approver, 5000)
  let assert "delegate" = call.name
  let assert 0 = probe.count(probe, "child-model")
  process.send(reply, True)
  let assert Ok(execution.Completed(_)) = execution.await(run, timeout: 5000)
  let assert 2 = probe.count(probe, "child-model")
}

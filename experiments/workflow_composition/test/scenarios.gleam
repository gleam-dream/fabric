//// THROWAWAY (workflow composition experiment). The scripted scenario rows
//// 1-8, written once and executed against variant A and variant B. Each
//// function reads as the call site an application author would write.

import gleam/erlang/process
import gleam/list
import gleam/string
import support.{type Variant}
import wc/agent.{ActionId, ApprovalRef}
import wc/probe
import wc/runtime

const lisbon = "{\"city\":\"Lisbon\",\"celsius\":21}"

/// Rows 1-4: two typed calls, a policy-gated transfer, a durable pause that
/// survives a restart, strict approval references, exact call identities.
pub fn durable_pause_and_resume(variant: Variant) -> Nil {
  let h = support.harness(variant, 2)
  let rt = runtime.start(h.env)
  let assert Ok(Nil) =
    runtime.start_run(rt, "r1", "weather and gated transfer", 3)

  // Row 2: the allowed lookup ran; the transfer waits for a human.
  let assert agent.WaitingForApproval([pending]) =
    support.await_status(h, "r1", support.waiting)
  let assert "transfer_funds" = pending.name
  let assert ActionId(1, "c2") = pending.ref.action

  // Row 3: no process holds the paused run; it is a stored record only.
  support.await_released(h, "r1")
  let assert False = runtime.is_live(rt, "r1")
  let assert Ok(#(_, stored)) = runtime.load(h.store, "r1")
  let assert agent.Acting([lookup, transfer]) = stored.phase
  let assert agent.Answered(content, agent.Succeeded) = lookup.status
  assert content == lisbon
  let assert agent.AwaitingApproval(1) = transfer.status

  // Restart: every runtime process dies; only the store remains.
  runtime.kill(rt)
  let rt = runtime.start(h.env)
  let stale = ApprovalRef(pending.ref.action, pending.ref.revision + 1)
  let assert Error(runtime.Rejected(agent.StaleApproval(1))) =
    runtime.answer(rt, "r1", stale, agent.Approve)
  let wrong = ApprovalRef(ActionId(1, "c9"), pending.ref.revision)
  let assert Error(runtime.Rejected(agent.WrongAction(ActionId(1, "c9")))) =
    runtime.answer(rt, "r1", wrong, agent.Approve)
  let assert Ok(agent.Working) =
    runtime.answer(rt, "r1", pending.ref, agent.Approve)

  // The approved transfer is running (held at its barrier): a duplicate
  // answer is rejected instead of executing it again.
  let transfer_arrival = probe.arrival(h.probe)
  let assert "gated-bank" = transfer_arrival.name
  let assert Error(runtime.Rejected(agent.AlreadyAnswered)) =
    runtime.answer(rt, "r1", pending.ref, agent.Approve)
  probe.release(transfer_arrival)

  // Row 4: the second model turn sees both results under their call ids.
  let assert agent.Finished(agent.Answer(answer)) =
    support.await_status(h, "r1", support.finished)
  assert answer == "c1=" <> lisbon <> ";c2={\"receipt\":\"rcpt-gated-bank\"}"
  let assert 1 = probe.count(h.probe, "transfer:start:gated-bank")
  let assert 1 = probe.count(h.probe, "weather:start:Lisbon")
  let assert ["model:1", "model:4"] =
    list.filter(probe.entries(h.probe), string.starts_with(_, "model:"))
  let assert Error(runtime.Rejected(agent.RunEnded)) =
    runtime.answer(rt, "r1", pending.ref, agent.Approve)
  runtime.kill(rt)
}

/// Row 3: two runtimes (two incarnations sharing one store) answer the same
/// approval at once. Compare-and-set lets exactly one win.
pub fn concurrent_answers(variant: Variant) -> Nil {
  let h = support.harness(variant, 2)
  let rt1 = runtime.start(h.env)
  let assert Ok(Nil) =
    runtime.start_run(rt1, "r2", "weather and gated transfer", 3)
  let assert agent.WaitingForApproval([pending]) =
    support.await_status(h, "r2", support.waiting)
  support.await_released(h, "r2")
  let rt2 = runtime.start(h.env)

  let replies = process.new_subject()
  list.each([rt1, rt2], fn(rt) {
    process.spawn(fn() {
      process.send(
        replies,
        runtime.answer(rt, "r2", pending.ref, agent.Approve),
      )
    })
  })
  let assert Ok(first) = process.receive(replies, 5000)
  let assert Ok(second) = process.receive(replies, 5000)
  let outcomes = [first, second]
  assert list.contains(outcomes, Ok(agent.Working))
  assert list.contains(outcomes, Error(runtime.Rejected(agent.AlreadyAnswered)))

  let arrival = probe.arrival(h.probe)
  probe.release(arrival)
  let assert agent.Finished(agent.Answer(_)) =
    support.await_status(h, "r2", support.finished)
  let assert 1 = probe.count(h.probe, "transfer:start:gated-bank")
  runtime.kill(rt1)
  runtime.kill(rt2)
}

/// Row 5a: cancel while a tool is blocked mid-effect. The in-flight tool is
/// reported as an unknown effect and is never retried.
pub fn cancel_while_running(variant: Variant) -> Nil {
  let h = support.harness(variant, 2)
  let rt = runtime.start(h.env)
  let assert Ok(Nil) =
    runtime.start_run(rt, "r3", "gated weather and transfer", 3)
  let arrival = probe.arrival(h.probe)
  let assert "gated-Lisbon" = arrival.name

  let assert Ok(_) = runtime.cancel(rt, "r3")
  let assert agent.Finished(agent.Cancelled([ActionId(1, "c1")])) =
    support.await_status(h, "r3", support.finished)
  support.await_released(h, "r3")
  let assert 0 = probe.count(h.probe, "weather:end:gated-Lisbon")
  let assert 0 = probe.count(h.probe, "transfer:start:acct-b")
  let assert Error(runtime.Rejected(agent.RunEnded)) = runtime.recover(rt, "r3")
  let assert Error(runtime.Rejected(agent.RunEnded)) =
    runtime.answer(rt, "r3", ApprovalRef(ActionId(1, "c2"), 1), agent.Approve)
  let assert 1 = probe.count(h.probe, "weather:start:gated-Lisbon")
  runtime.kill(rt)
}

/// Row 5b: cancel a paused run after a restart: no process to stop, the
/// pending approval is withdrawn and can no longer be answered.
pub fn cancel_while_paused(variant: Variant) -> Nil {
  let h = support.harness(variant, 2)
  let rt = runtime.start(h.env)
  let assert Ok(Nil) = runtime.start_run(rt, "r4", "weather and transfer", 3)
  let assert agent.WaitingForApproval([pending]) =
    support.await_status(h, "r4", support.waiting)
  support.await_released(h, "r4")
  runtime.kill(rt)

  let rt = runtime.start(h.env)
  let assert Ok(agent.Finished(agent.Cancelled([]))) = runtime.cancel(rt, "r4")
  let assert Error(runtime.Rejected(agent.RunEnded)) =
    runtime.answer(rt, "r4", pending.ref, agent.Approve)
  let assert 0 = probe.count(h.probe, "transfer:start:acct-b")
  let assert False = runtime.is_live(rt, "r4")
  runtime.kill(rt)
}

/// Row 6: a typed failure is model-visible; an uncertain effect blocks the
/// next model turn until explicit reconciliation, and is never retried.
pub fn failure_and_uncertain_effect(variant: Variant) -> Nil {
  let h = support.harness(variant, 2)
  let rt = runtime.start(h.env)
  let assert Ok(Nil) = runtime.start_run(rt, "r5", "failures", 3)
  let assert agent.WaitingForApproval([pending]) =
    support.await_status(h, "r5", support.waiting)
  let assert Ok(_) = runtime.answer(rt, "r5", pending.ref, agent.Approve)
  let assert agent.NeedsReconciliation([ActionId(1, "c2")]) =
    support.await_status(h, "r5", support.reconciling)
  support.await_released(h, "r5")

  // Restart and recover: the uncertain transfer is not re-run.
  runtime.kill(rt)
  let rt = runtime.start(h.env)
  let assert Ok(agent.NeedsReconciliation(_)) = runtime.recover(rt, "r5")
  let assert ["model:1"] =
    list.filter(probe.entries(h.probe), string.starts_with(_, "model:"))
  let assert Error(runtime.Rejected(agent.NotReconcilable)) =
    runtime.reconcile(rt, "r5", ActionId(1, "c1"), "x")
  let assert Ok(_) =
    runtime.reconcile(rt, "r5", ActionId(1, "c2"), "{\"receipt\":\"checked\"}")
  let assert agent.Finished(agent.Answer(answer)) =
    support.await_status(h, "r5", support.finished)
  assert answer
    == "c1={\"error\":{\"unknown_city\":\"Atlantis\"}};c2={\"receipt\":\"checked\"}"
  let assert 1 = probe.count(h.probe, "transfer:start:flaky-bank")
  runtime.kill(rt)
}

/// Row 7a: three concurrent lookups share a budget of two tools in flight.
pub fn concurrency_budget(variant: Variant) -> Nil {
  let h = support.harness(variant, 2)
  let rt = runtime.start(h.env)
  let assert Ok(Nil) = runtime.start_run(rt, "r6", "three gated lookups", 3)
  let first = probe.arrival(h.probe)
  let second = probe.arrival(h.probe)
  probe.release(first)
  let third = probe.arrival(h.probe)
  probe.release(second)
  probe.release(third)
  let assert agent.Finished(agent.Answer(_)) =
    support.await_status(h, "r6", support.finished)
  let assert 2 = support.max_overlap(probe.entries(h.probe))
  runtime.kill(rt)
}

/// Row 7b: the model-turn budget counts every model call.
pub fn turn_budget(variant: Variant) -> Nil {
  let h = support.harness(variant, 2)
  let rt = runtime.start(h.env)
  let assert Ok(Nil) = runtime.start_run(rt, "r7", "weather", 1)
  let assert agent.Finished(agent.BudgetExhausted) =
    support.await_status(h, "r7", support.finished)
  let assert 1 = probe.count(h.probe, "weather:end:Lisbon")
  let assert ["model:1"] =
    list.filter(probe.entries(h.probe), string.starts_with(_, "model:"))
  let assert Error(runtime.InvalidRun(_)) = runtime.start_run(rt, "r8", "x", 0)
  runtime.kill(rt)
}

/// Row 7c: with a budget of one, an action approved while another tool runs
/// must wait for it. Returns the peak overlap actually observed.
pub fn budget_across_batches(variant: Variant) -> Int {
  let h = support.harness(variant, 1)
  let rt = runtime.start(h.env)
  let assert Ok(Nil) =
    runtime.start_run(rt, "r9", "gated weather and gated transfer", 3)
  let lookup = probe.arrival(h.probe)
  let assert agent.WaitingForApproval([pending]) =
    support.await_status(h, "r9", support.waiting)
  let assert Ok(_) = runtime.answer(rt, "r9", pending.ref, agent.Approve)
  let next = case variant {
    // Plain executor: one budget per run, so the transfer is still queued.
    support.A -> {
      probe.release(lookup)
      let transfer = probe.arrival(h.probe)
      let assert "gated-bank" = transfer.name
      transfer
    }
    // Saga executor: the approval starts a second Saga run whose own
    // max_concurrency admits the transfer while the lookup still runs.
    support.B -> {
      let transfer = probe.arrival(h.probe)
      let assert "gated-bank" = transfer.name
      probe.release(lookup)
      transfer
    }
  }
  probe.release(next)
  let assert agent.Finished(agent.Answer(_)) =
    support.await_status(h, "r9", support.finished)
  runtime.kill(rt)
  support.max_overlap(probe.entries(h.probe))
}

/// Restart recovery mid-batch: the first lookup finished, the second is
/// blocked when every runtime process dies. Returns the actions left
/// uncertain after `recover`.
pub fn restart_mid_batch(variant: Variant) -> List(agent.ActionId) {
  let h = support.harness(variant, 1)
  let rt = runtime.start(h.env)
  let assert Ok(Nil) = runtime.start_run(rt, "r10", "fast and gated", 3)
  let arrival = probe.arrival(h.probe)
  let assert "gated-Faro" = arrival.name
  let assert 1 = probe.count(h.probe, "weather:end:Lisbon")
  runtime.kill(rt)

  let rt = runtime.start(h.env)
  let assert Ok(agent.NeedsReconciliation(unknown)) = runtime.recover(rt, "r10")
  let assert 1 = probe.count(h.probe, "weather:start:Lisbon")
  let assert 1 = probe.count(h.probe, "weather:start:gated-Faro")
  runtime.kill(rt)
  unknown
}

/// Row 8a: a real Saga workflow with dependencies and compensation, used as
/// one typed tool from the agent.
pub fn saga_workflow_as_tool(variant: Variant) -> Nil {
  let h = support.harness(variant, 2)
  let rt = runtime.start(h.env)
  let assert Ok(Nil) = runtime.start_run(rt, "t1", "trip Porto", 3)
  let assert agent.Finished(agent.Answer(ok)) =
    support.await_status(h, "t1", support.finished)
  assert ok
    == "c1={\"flight\":\"FL-Porto\",\"hotel\":\"HT-Porto\",\"charge\":\"CH-1\"}"

  let assert Ok(Nil) = runtime.start_run(rt, "t2", "trip Atlantis", 3)
  let assert agent.Finished(agent.Answer(failed)) =
    support.await_status(h, "t2", support.finished)
  assert failed
    == "c1={\"error\":{\"failure\":{\"no_hotel\":\"Atlantis\"},\"undone\":[\"reserve_flight\"]}}"
  assert list.contains(probe.entries(h.probe), "flight:release:FL-Atlantis")
  let assert 1 = probe.count(h.probe, "charge")
  runtime.kill(rt)
}

/// Row 8b: starting a sub-agent is gated by a durable approval; the child
/// never starts before it, even across a restart.
pub fn delegate_needs_durable_approval(variant: Variant) -> Nil {
  let h = support.harness(variant, 2)
  let rt = runtime.start(h.env)
  let assert Ok(Nil) = runtime.start_run(rt, "d1", "delegate", 3)
  let assert agent.WaitingForApproval([pending]) =
    support.await_status(h, "d1", support.waiting)
  let assert "delegate" = pending.name
  support.await_released(h, "d1")
  runtime.kill(rt)
  let assert 0 = probe.count(h.probe, "child-model")
  let assert 0 = probe.count(h.probe, "delegate:start")

  let rt = runtime.start(h.env)
  let assert Ok(_) = runtime.answer(rt, "d1", pending.ref, agent.Approve)
  let assert agent.Finished(agent.Answer(answer)) =
    support.await_status(h, "d1", support.finished)
  assert answer
    == "c1={\"answer\":\"child:k1={\\\"city\\\":\\\"Oslo\\\",\\\"celsius\\\":21}\"}"
  let assert 2 = probe.count(h.probe, "child-model")
  runtime.kill(rt)
}

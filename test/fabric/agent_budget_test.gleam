import fabric
import fabric/agent
import fabric/budget
import fabric/internal/budget/ledger
import fabric/internal/budget/model as reservations
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/flaky
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import gleam/list
import gleam/option.{None}
import gleeunit/should

fn worker(model) {
  agent.new("worker", model, [], policy.always_allow())
  |> agent.with_limits(
    agent.Limits(..agent.default_limits(), model_retry_delay: 1),
  )
  |> support.agent
}

fn exhausted(limit) {
  run.Finished(run.BudgetExhausted(run.FamilyLimit(budget.WorkLimit(limit))))
}

pub fn model_attempts_spend_family_capacity_including_retryable_failures_test() {
  let calls = probe.new()
  let worker =
    worker(
      model.new(fn(_) {
        probe.record(calls, "model")
        Error(model.ModelError("retry", True))
      }),
    )
  let runs = support.store()
  let assert Ok(zero) =
    fabric.start_with_budget(runs, worker, Nil, "go", budget.Limits(0, 0, 0))
  fabric.await(zero, 5000) |> should.equal(Ok(exhausted(0)))
  probe.entries(calls) |> should.equal([])
  let assert Ok(handle) =
    fabric.start_with_budget(runs, worker, Nil, "go", budget.Limits(2, 0, 0))
  fabric.await(handle, 5000) |> should.equal(Ok(exhausted(2)))
  probe.entries(calls) |> should.equal(["model", "model"])
}

pub fn a_lost_model_attempt_keeps_its_charge_across_directory_restart_test() {
  let dir = restart.temp_dir()
  let calls = probe.new()
  let blocking =
    worker(
      model.new(fn(_) {
        probe.record(calls, "model")
        probe.gate(calls, "model")
        Ok(model.FinalAnswer("lost", None))
      }),
    )
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let assert Ok(handle) =
        fabric.start_with_budget(
          runs,
          blocking,
          Nil,
          "go",
          budget.Limits(1, 0, 0),
        )
      #(runs, handle)
    })
  let _ = probe.arrival(calls)
  restart.crash(owner, runs)
  let next =
    worker(
      scripted.model(fn(_) {
        probe.record(calls, "again")
        model.FinalAnswer("done", None)
      }),
    )
  let assert Ok(recovered) =
    fabric.recover(support.directory(dir), next, Nil, fabric.id(handle))
  fabric.await(recovered, 5000) |> should.equal(Ok(exhausted(1)))
  probe.entries(calls) |> should.equal(["model"])
  restart.remove_dir(dir)
}

pub fn tool_bodies_are_reserved_before_start_and_unstarted_calls_are_withdrawn_test() {
  let calls = probe.new()
  let worker =
    agent.new(
      "worker",
      scripted.plan([
        scripted.slow("one", "one"),
        scripted.slow("two", "two"),
        scripted.slow("three", "three"),
      ]),
      [scripted.gated_tool(calls)],
      policy.always_allow(),
    )
    |> agent.with_limits(
      agent.Limits(..agent.default_limits(), max_concurrency: 1),
    )
    |> support.agent
  let runs = support.store()
  let assert Ok(handle) =
    fabric.start_with_budget(runs, worker, Nil, "go", budget.Limits(3, 0, 0))
  probe.arrival(calls) |> probe.release
  probe.arrival(calls) |> probe.release
  fabric.await(handle, 5000) |> should.equal(Ok(exhausted(3)))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [run.Succeeded(_), run.Succeeded(_), run.NotStarted] =
    list.map(snapshot.actions, fn(action) { action.state })
  probe.entries(calls)
  |> should.equal(["start:one", "end:one", "start:two", "end:two"])
  let assert Ok(#(_, saved)) =
    ledger.read(runs, run.id_to_string(fabric.id(handle)))
  reservations.usage(saved) |> should.equal(budget.Usage(3, 0))
}

pub fn budget_refusal_stops_running_effects_without_claiming_they_did_not_happen_test() {
  let calls = probe.new()
  let worker =
    agent.new(
      "worker",
      scripted.plan([scripted.slow("one", "one"), scripted.slow("two", "two")]),
      [scripted.gated_tool(calls)],
      fn(_: Nil, action) {
        case action.id.call_id {
          "one" -> Ok(policy.Allow)
          _ -> Ok(policy.RequireApproval(run.Requirement("review", 1)))
        }
      },
    )
    |> support.agent
  let assert Ok(handle) =
    fabric.start_with_budget(
      support.store(),
      worker,
      Nil,
      "go",
      budget.Limits(2, 0, 0),
    )
  let _ = probe.arrival(calls)
  let assert Ok([pending]) = fabric.pending(handle)
  let assert Ok(_) =
    fabric.approve(handle, pending.reference, reviewer: None, context: Nil)
  fabric.await(handle, 5000) |> should.equal(Ok(exhausted(2)))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [run.Uncertain(_), run.NotStarted] =
    list.map(snapshot.actions, fn(action) { action.state })
  probe.entries(calls) |> should.equal(["start:one"])
}

pub fn a_lost_reservation_acknowledgement_never_duplicates_a_model_call_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let calls = probe.new()
  let worker =
    worker(
      scripted.model(fn(_) {
        probe.record(calls, "model")
        model.FinalAnswer("done", None)
      }),
    )
  // Root insert, ledger insert, initialized marker, then the model grant.
  flaky.arm(backend, [flaky.Pass, flaky.Pass, flaky.Pass, flaky.FailAfter])
  let assert Ok(handle) =
    fabric.start_with_budget(runs, worker, Nil, "go", budget.Limits(1, 0, 0))
  fabric.await(handle, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("done"))))
  probe.entries(calls) |> should.equal(["model"])
  let assert Ok(#(_, saved)) =
    ledger.read(runs, run.id_to_string(fabric.id(handle)))
  reservations.usage(saved) |> should.equal(budget.Usage(1, 0))
}

pub fn invalid_limits_and_incapable_writers_are_refused_before_start_test() {
  let calls = probe.new()
  let worker =
    worker(
      scripted.model(fn(_) {
        probe.record(calls, "model")
        model.FinalAnswer("done", None)
      }),
    )
  let runs = support.store()
  let assert Error(fabric.StartRefused(_)) =
    fabric.start_with_budget(runs, worker, Nil, "go", budget.Limits(-1, 0, 0))
  let assert Ok(old) = store.with_record_version(runs, 6)
  let assert Error(fabric.StartRefused(_)) =
    fabric.start_with_budget(old, worker, Nil, "go", budget.Limits(1, 0, 0))
  probe.entries(calls) |> should.equal([])
}

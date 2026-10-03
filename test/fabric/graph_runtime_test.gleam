import fabric/budget
import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/internal/store as store_core
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/backend
import fabric/store/conformance
import fabric/support
import fabric/support/flaky
import fabric/support/nodes
import fabric/support/probe
import fabric/support/restart
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn id(name: String) -> definition.NodeId {
  let assert Ok(id) = definition.node_id(name)
  id
}

fn run_id(name: String) -> run.RunId {
  let assert Ok(id) = run.parse_id(name)
  id
}

fn no_error(_error: Nil) -> operation.Failure {
  operation.DefiniteFailure("cannot fail")
}

fn loop(
  perform: fn(Nil, operation.Invocation, Int) -> Result(Int, Nil),
) -> definition.Definition(Nil, Int, Int) {
  let generate =
    definition.node(
      id("generate"),
      operation.new(
        run.DefinitionId("generate", 1),
        codec.int(),
        codec.int(),
        perform,
        no_error,
      ),
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Continue(n, id("review"))) },
      [id("review")],
    )
  let review =
    definition.node(
      id("review"),
      operation.new(
        run.DefinitionId("review", 1),
        codec.int(),
        codec.bool(),
        fn(_, _, n) { Ok(n >= 3) },
        no_error,
      ),
      fn(n) { Ok(n) },
      fn(n, accepted) {
        case accepted {
          True -> Ok(definition.Finish(n, n))
          False -> Ok(definition.Continue(n, id("generate")))
        }
      },
      [id("generate")],
    )
  let assert Ok(definition) =
    definition.build(definition.Spec(
      run.DefinitionId("review-loop", 1),
      id("generate"),
      [generate, review],
      codec.int(),
      codec.int(),
      6,
    ))
  definition
}

pub fn public_runtime_executes_a_typed_bounded_generation_review_loop_test() {
  let runtime =
    graph.new(
      loop(fn(_, _, n) { Ok(n + 1) }),
      support.store(),
      fn() { Nil },
      fn(_, _) { Ok(policy.Allow) },
    )
  let assert Ok(handle) = graph.start(runtime, run_id("loop"), 0)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.value |> should.equal(3)
  done.status |> should.equal(graph.Completed(3))
  list.map(done.receipts, fn(receipt) { receipt.activation })
  |> should.equal([1, 2, 3, 4, 5, 6])
  list.map(done.receipts, fn(receipt) { receipt.output_json })
  |> should.equal(["1", "false", "2", "false", "3", "true"])
}

pub fn a_shared_work_budget_bounds_graph_cycles_before_the_next_body_test() {
  let calls = probe.new()
  let runtime =
    graph.new(
      loop(fn(_, _, n) {
        probe.record(calls, "generate")
        Ok(n + 1)
      }),
      support.store(),
      fn() { Nil },
      fn(_, _) { Ok(policy.Allow) },
    )
  let assert Ok(handle) =
    graph.start_with_budget(
      runtime,
      run_id("bounded-loop"),
      0,
      budget.Limits(3, 0, 0),
    )
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status
  |> should.equal(graph.Failed(graph.FamilyBudget(budget.WorkLimit(3))))
  done.value |> should.equal(2)
  list.length(done.receipts) |> should.equal(3)
  probe.entries(calls) |> should.equal(["generate", "generate"])
  let assert Ok(zero) =
    graph.start_with_budget(
      runtime,
      run_id("zero-work"),
      0,
      budget.Limits(0, 0, 0),
    )
  let assert Ok(stopped) =
    graph.await(zero, within: duration.milliseconds(5000))
  stopped.status
  |> should.equal(graph.Failed(graph.FamilyBudget(budget.WorkLimit(0))))
  probe.entries(calls) |> should.equal(["generate", "generate"])
}

pub fn graph_approval_after_restart_reuses_its_reserved_work_unit_test() {
  let dir = restart.temp_dir()
  let calls = probe.new()
  let spec =
    loop(fn(_, _, n) {
      probe.record(calls, "generate")
      Ok(n + 1)
    })
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let runtime =
        graph.new(spec, runs, fn() { Nil }, fn(_, _) {
          Ok(policy.RequireApproval(run.Requirement("review", 1)))
        })
      let assert Ok(handle) =
        graph.start_with_budget(
          runtime,
          run_id("budget-approval"),
          0,
          budget.Limits(1, 0, 0),
        )
      #(runs, handle)
    })
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingApproval(approval) = waiting.status
  restart.crash(owner, runs)
  let runtime =
    graph.new(spec, support.directory(dir), fn() { Nil }, fn(_, _) {
      Ok(policy.Allow)
    })
  let handle = graph.attach(runtime, run_id("budget-approval"))
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(_) = graph.approve(handle, approval)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status
  |> should.equal(graph.Failed(graph.FamilyBudget(budget.WorkLimit(1))))
  probe.entries(calls) |> should.equal(["generate"])
  restart.remove_dir(dir)
}

pub fn a_saved_decision_survives_process_loss_without_repeating_its_body_test() {
  let dir = restart.temp_dir()
  let ledger = probe.new()
  let spec =
    loop(fn(_, _, n) {
      probe.record(ledger, "generate")
      Ok(n + 1)
    })
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let runtime =
        graph.new(spec, runs, fn() { Nil }, fn(_, action) {
          case action.node {
            "review" -> Ok(policy.RequireApproval(run.Requirement("review", 1)))
            _ -> Ok(policy.Allow)
          }
        })
      let assert Ok(handle) = graph.start(runtime, run_id("saved-decision"), 0)
      #(runs, handle)
    })
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingApproval(approval) = waiting.status
  let assert Some(action) = waiting.current
  action.node |> should.equal("review")
  action.input_json |> should.equal("1")
  waiting.value |> should.equal(1)
  restart.crash(owner, runs)
  let runtime =
    graph.new(spec, support.directory(dir), fn() { Nil }, fn(_, _) {
      Ok(policy.Allow)
    })
  let handle = graph.attach(runtime, run_id("saved-decision"))
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(_) = graph.approve(handle, approval)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(3))
  probe.entries(ledger) |> list.length |> should.equal(3)
  restart.remove_dir(dir)
}

pub fn an_interrupted_effect_blocks_recovery_until_reconciled_test() {
  let dir = restart.temp_dir()
  let ledger = probe.new()
  let spec =
    loop(fn(_, _, n) {
      probe.record(ledger, "effect")
      probe.gate(ledger, "hold")
      Ok(n + 1)
    })
  let #(owner, #(runs, _handle)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let runtime =
        graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
      let assert Ok(handle) = graph.start(runtime, run_id("interrupted"), 2)
      #(runs, handle)
    })
  let _ = probe.arrival(ledger)
  restart.crash(owner, runs)
  let runtime =
    graph.new(spec, support.directory(dir), fn() { Nil }, fn(_, _) {
      Ok(policy.Allow)
    })
  let handle = graph.attach(runtime, run_id("interrupted"))
  let assert Ok(blocked) = graph.recover(handle)
  let assert graph.Blocked(reference, _) = blocked.status
  probe.entries(ledger) |> should.equal(["effect"])
  let assert Ok(_) = graph.reconcile(handle, reference, "3")
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(3))
  probe.entries(ledger) |> should.equal(["effect"])
  restart.remove_dir(dir)
}

pub fn approval_uses_fresh_context_and_passes_it_to_the_admitted_body_test() {
  let context = probe.new()
  let body = probe.new()
  let op =
    operation.new(
      run.DefinitionId("publish", 1),
      codec.int(),
      codec.int(),
      fn(role, _, n) {
        probe.record(body, role)
        Ok(n + 1)
      },
      no_error,
    )
  let node =
    definition.node(
      id("publish"),
      op,
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId("publish", 1),
      id("publish"),
      [node],
      codec.int(),
      codec.int(),
      1,
    ))
  let runtime =
    graph.new(
      spec,
      support.store(),
      fn() {
        case probe.entries(context) {
          [] -> "reviewer"
          _ -> "publisher"
        }
      },
      fn(_, _) { Ok(policy.RequireApproval(run.Requirement("publish", 1))) },
    )
  let assert Ok(handle) = graph.start(runtime, run_id("approval-context"), 0)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingApproval(approval) = waiting.status
  probe.record(context, "promoted")
  let assert Ok(_) = graph.approve(handle, approval)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(1))
  probe.entries(body) |> should.equal(["publisher"])
}

pub fn cancel_stops_a_started_body_and_preserves_uncertainty_test() {
  let worker = process.new_subject()
  let spec =
    loop(fn(_, _, n) {
      process.send(worker, process.self())
      process.sleep_forever()
      Ok(n + 1)
    })
  let runtime =
    graph.new(spec, support.store(), fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) = graph.start(runtime, run_id("cancel"), 0)
  let assert Ok(pid) = process.receive(worker, 1000)
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Cancelled(graph.Unresolved(_, _)) = done.status
  restart.gone(pid)
  done.receipts |> should.equal([])
  Nil
}

fn one(
  op: operation.Operation(context, Int, Int),
) -> definition.Definition(context, Int, Int) {
  let node =
    definition.node(
      id("only"),
      op,
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId("single", 1),
      id("only"),
      [node],
      codec.int(),
      codec.int(),
      1,
    ))
  spec
}

fn effect(ledger: probe.Probe) -> definition.Definition(context, Int, Int) {
  one(operation.new(
    run.DefinitionId("effect", 1),
    codec.int(),
    codec.int(),
    fn(_, _, n) {
      probe.record(ledger, "effect")
      Ok(n + 1)
    },
    no_error,
  ))
}

pub fn denial_and_a_crashed_policy_never_enter_the_operation_test() {
  let ledger = probe.new()
  let denied =
    graph.new(effect(ledger), support.store(), fn() { Nil }, fn(_, _) {
      Ok(policy.Deny("no permission"))
    })
  let assert Ok(handle) = graph.start(denied, run_id("denied"), 0)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(1000))
  done.status |> should.equal(graph.Failed(graph.Denied("no permission")))
  let broken =
    graph.new(effect(ledger), support.store(), fn() { Nil }, fn(_, _) {
      panic as "policy crashed"
    })
  let assert Ok(handle) = graph.start(broken, run_id("policy-crashed"), 0)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(1000))
  let assert graph.Failed(graph.PolicyFailed(_)) = done.status
  probe.entries(ledger) |> should.equal([])
}

pub fn runtime_stops_cycles_at_the_saved_activation_bound_test() {
  let ledger = probe.new()
  let spec =
    loop(fn(_, _, n) {
      probe.record(ledger, "generate")
      Ok(n + 1)
    })
  let runtime =
    graph.new(spec, support.store(), fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) = graph.start(runtime, run_id("bounded"), -1)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Exhausted)
  done.receipts |> list.length |> should.equal(6)
  probe.entries(ledger) |> list.length |> should.equal(3)
  let assert Ok(restored) = graph.recover(handle)
  restored |> should.equal(done)
}

pub fn an_unconfirmed_start_fence_never_releases_the_body_test() {
  let backend = flaky.new()
  let ledger = probe.new()
  flaky.arm(backend, [flaky.Pass, flaky.Pass, flaky.FailBefore])
  let runtime =
    graph.new(effect(ledger), flaky.store(backend), fn() { Nil }, fn(_, _) {
      Ok(policy.Allow)
    })
  let assert Ok(handle) = graph.start(runtime, run_id("fence-refused"), 0)
  let assert Ok(stopped) =
    graph.await(handle, within: duration.milliseconds(1000))
  stopped.status |> should.equal(graph.Unattended)
  probe.entries(ledger) |> should.equal([])
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(1000))
  done.status |> should.equal(graph.Completed(1))
  probe.entries(ledger) |> should.equal(["effect"])
}

pub fn lost_write_acknowledgements_do_not_repeat_an_effect_test() {
  let backend = flaky.new()
  let ledger = probe.new()
  flaky.arm(backend, list.repeat(flaky.FailAfter, 4))
  let runtime =
    graph.new(effect(ledger), flaky.store(backend), fn() { Nil }, fn(_, _) {
      Ok(policy.Allow)
    })
  let assert Ok(handle) = graph.start(runtime, run_id("lost-ack"), 0)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(1000))
  done.status |> should.equal(graph.Completed(1))
  probe.entries(ledger) |> should.equal(["effect"])
}

pub fn cancellation_during_a_held_policy_withdraws_the_pending_command_test() {
  let ledger = probe.new()
  let gate = probe.new()
  let runtime =
    graph.new(effect(ledger), support.store(), fn() { Nil }, fn(_, _) {
      probe.gate(gate, "policy held")
      Ok(policy.Allow)
    })
  let assert Ok(runtime) =
    graph.with_timeouts(
      runtime,
      callbacks: duration.milliseconds(5000),
      operations: duration.milliseconds(5000),
      commands: duration.milliseconds(10),
    )
  let assert Ok(handle) = graph.start(runtime, run_id("held-policy"), 0)
  let held = probe.arrival(gate)
  graph.cancel(handle) |> should.equal(Ok(Nil))
  probe.release(held)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(1000))
  done.status |> should.equal(graph.Cancelled(graph.BeforeStart))
  probe.entries(ledger) |> should.equal([])
}

pub fn operation_timeout_blocks_with_uncertainty_and_kills_the_body_test() {
  let started = process.new_subject()
  let spec =
    one(operation.new(
      run.DefinitionId("slow", 1),
      codec.int(),
      codec.int(),
      fn(_, _, n) {
        process.send(started, process.self())
        process.sleep_forever()
        Ok(n)
      },
      no_error,
    ))
  let runtime =
    graph.new(spec, support.store(), fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(runtime) =
    graph.with_timeouts(
      runtime,
      callbacks: duration.milliseconds(1000),
      operations: duration.milliseconds(20),
      commands: duration.milliseconds(1000),
    )
  let assert Ok(handle) = graph.start(runtime, run_id("timeout"), 0)
  let assert Ok(body) = process.receive(started, 1000)
  let assert Ok(blocked) =
    graph.await(handle, within: duration.milliseconds(1000))
  let assert graph.Blocked(_, graph.EffectUncertain(_)) = blocked.status
  restart.gone(body)
}

pub fn cancelled_reconciliation_retains_output_without_calling_a_broken_route_test() {
  let op =
    operation.new(
      run.DefinitionId("body", 1),
      codec.int(),
      codec.int(),
      fn(_, _, n) { Ok(n + 1) },
      no_error,
    )
  let node =
    definition.node(
      id("broken-route"),
      op,
      fn(n) { Ok(n) },
      fn(_, _) { Error("routing unavailable") },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId("broken-route", 1),
      id("broken-route"),
      [node],
      codec.int(),
      codec.int(),
      1,
    ))
  let runtime =
    graph.new(spec, support.store(), fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) = graph.start(runtime, run_id("bad-result"), 0)
  let assert Ok(blocked) =
    graph.await(handle, within: duration.milliseconds(1000))
  let assert graph.Blocked(_, graph.InvalidResult("1", _)) = blocked.status
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(cancelled) = graph.read(handle)
  let assert graph.Cancelled(graph.Unresolved(reference, _)) = cancelled.status
  let assert Ok(done) = graph.reconcile(handle, reference, "1")
  done.status |> should.equal(graph.Cancelled(graph.AfterResult))
  done.value |> should.equal(0)
  let assert [receipt] = done.receipts
  receipt.output_json |> should.equal("1")
  receipt.route |> should.equal(graph.Stopped)
}

pub fn replay_after_process_loss_is_bounded_and_keeps_the_logical_identity_test() {
  let dir = restart.temp_dir()
  let gate = probe.new()
  let op =
    operation.new(
      run.DefinitionId("replayable", 1),
      codec.int(),
      codec.int(),
      fn(_, invocation, n) {
        probe.record(
          gate,
          int.to_string(invocation.activation)
            <> ":"
            <> int.to_string(invocation.attempt),
        )
        probe.gate(gate, "held")
        Ok(n + 1)
      },
      no_error,
    )
  let assert Ok(op) = operation.with_replay(op, 2)
  let spec = one(op)
  let #(first, runs) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let runtime =
        graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
      let assert Ok(_) = graph.start(runtime, run_id("replay"), 0)
      runs
    })
  let _ = probe.arrival(gate)
  restart.crash(first, runs)
  let #(second, runs) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let runtime =
        graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
      let assert Ok(_) = graph.recover(graph.attach(runtime, run_id("replay")))
      runs
    })
  let _ = probe.arrival(gate)
  restart.crash(second, runs)
  let runtime =
    graph.new(spec, support.directory(dir), fn() { Nil }, fn(_, _) {
      Ok(policy.Allow)
    })
  let assert Ok(blocked) =
    graph.recover(graph.attach(runtime, run_id("replay")))
  let assert graph.Blocked(_, graph.EffectUncertain(_)) = blocked.status
  probe.entries(gate) |> should.equal(["1:1", "1:2"])
  restart.remove_dir(dir)
}

pub fn a_draining_graph_finishes_its_body_and_hands_off_the_saved_successor_test() {
  let dir = restart.temp_dir()
  let ledger = probe.new()
  let spec =
    loop(fn(_, invocation, n) {
      probe.record(ledger, "generate")
      case invocation.activation {
        1 -> probe.gate(ledger, "first")
        _ -> Nil
      }
      Ok(n + 1)
    })
  let runs = store.directory(process.new_name("graph-drain"), dir)
  let application = restart.application(runs)
  let runtime =
    graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) = graph.start(runtime, run_id("drain"), 0)
  let held = probe.arrival(ledger)
  restart.begin_stop(application)
  restart.draining(runs)
  probe.release(held)
  restart.stopped(application)
  let runtime =
    graph.new(spec, support.directory(dir), fn() { Nil }, fn(_, _) {
      Ok(policy.Allow)
    })
  let handle = graph.attach(runtime, graph.id(handle))
  let assert Ok(saved) = graph.read(handle)
  saved.status |> should.equal(graph.Unattended)
  saved.value |> should.equal(1)
  saved.receipts |> list.length |> should.equal(1)
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(3))
  probe.entries(ledger) |> list.length |> should.equal(3)
  restart.remove_dir(dir)
}

pub fn a_live_foreign_lease_is_not_taken_by_graph_recovery_test() {
  let memory = conformance.leased_memory()
  let first = nodes.node(memory.backend, "graph-a", nodes.long)
  let second = nodes.node(memory.backend, "graph-b", nodes.long)
  let ledger = probe.new()
  let spec =
    one(operation.new(
      run.DefinitionId("held", 1),
      codec.int(),
      codec.int(),
      fn(_, _, n) {
        probe.record(ledger, "body")
        probe.gate(ledger, "held")
        Ok(n + 1)
      },
      no_error,
    ))
  let runtime =
    graph.new(spec, first, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) = graph.start(runtime, run_id("leased"), 0)
  let held = probe.arrival(ledger)
  let revision = nodes.revision(memory.backend, graph.id(handle))
  let elsewhere =
    graph.attach(
      graph.new(spec, second, fn() { Nil }, fn(_, _) { Ok(policy.Allow) }),
      graph.id(handle),
    )
  let assert Ok(snapshot) = graph.recover(elsewhere)
  snapshot.status |> should.equal(graph.Working)
  nodes.revision(memory.backend, graph.id(handle)) |> should.equal(revision)
  probe.release(held)
  let assert Ok(done) =
    graph.await(elsewhere, within: duration.milliseconds(1000))
  done.status |> should.equal(graph.Completed(1))
  probe.entries(ledger) |> should.equal(["body"])
}

pub fn a_start_fence_that_lands_late_is_reconciled_without_running_the_body_test() {
  let backend = flaky.new()
  let ledger = probe.new()
  flaky.arm(backend, [flaky.Pass, flaky.Pass, flaky.FailLate])
  let runtime =
    graph.new(effect(ledger), flaky.store(backend), fn() { Nil }, fn(_, _) {
      Ok(policy.Allow)
    })
  let assert Ok(handle) = graph.start(runtime, run_id("late-fence"), 0)
  let assert Ok(stopped) =
    graph.await(handle, within: duration.milliseconds(1000))
  stopped.status |> should.equal(graph.Unattended)
  let assert Ok(recovered) = graph.recover(handle)
  let assert graph.Blocked(_, graph.EffectUncertain(_)) = recovered.status
  probe.entries(ledger) |> should.equal([])
}

pub fn a_changed_approval_requirement_needs_a_new_answer_test() {
  let requirements = probe.new()
  let ledger = probe.new()
  let runtime =
    graph.new(
      effect(ledger),
      support.store(),
      fn() { list.length(probe.entries(requirements)) },
      fn(version, _) {
        Ok(policy.RequireApproval(run.Requirement("publish", version + 1)))
      },
    )
  let assert Ok(handle) = graph.start(runtime, run_id("new-requirement"), 0)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(1000))
  let assert graph.AwaitingApproval(first) = waiting.status
  probe.record(requirements, "changed")
  let assert Ok(changed) = graph.approve(handle, first)
  let assert graph.AwaitingApproval(second) = changed.status
  second.requirement
  |> should.equal(run.Requirement("publish", 2))
  let assert Error(graph.CommandRefused(_)) = graph.approve(handle, first)
  probe.entries(ledger) |> should.equal([])
  let assert Ok(_) = graph.approve(handle, second)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(1000))
  done.status |> should.equal(graph.Completed(1))
  probe.entries(ledger) |> should.equal(["effect"])
}

pub fn incompatible_definitions_are_refused_but_do_not_prevent_cancellation_test() {
  let ledger = probe.new()
  let runs = support.store()
  let original =
    graph.new(effect(ledger), runs, fn() { Nil }, fn(_, _) {
      Ok(policy.RequireApproval(run.Requirement("publish", 1)))
    })
  let assert Ok(handle) = graph.start(original, run_id("versioned"), 0)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(1000))
  let changed =
    one(operation.new(
      run.DefinitionId("effect", 2),
      codec.int(),
      codec.int(),
      fn(_, _, n) {
        probe.record(ledger, "must not run")
        Ok(n + 1)
      },
      no_error,
    ))
  let changed =
    graph.attach(
      graph.new(changed, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) }),
      graph.id(handle),
    )
  graph.recover(changed)
  |> should.equal(Error(graph.DefinitionRejected(definition.DefinitionChanged)))
  graph.cancel(changed) |> should.equal(Ok(Nil))
  let assert Ok(cancelled) = graph.read(handle)
  cancelled.status |> should.equal(graph.Cancelled(graph.BeforeStart))
  probe.entries(ledger) |> should.equal([])
}

pub fn losing_a_lease_kills_the_graph_body_before_recovery_test() {
  let memory = conformance.leased_memory()
  let first = nodes.node(memory.backend, "lease-a", nodes.long)
  let started = process.new_subject()
  let spec =
    one(operation.new(
      run.DefinitionId("held", 1),
      codec.int(),
      codec.int(),
      fn(_, _, n) {
        process.send(started, process.self())
        process.sleep_forever()
        Ok(n)
      },
      no_error,
    ))
  let runtime =
    graph.new(spec, first, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) = graph.start(runtime, run_id("lease-loss"), 0)
  let assert Ok(body) = process.receive(started, 1000)
  let assert Ok(current) = memory.backend.get("lease-loss")
  memory.backend.compare_and_set(
    "lease-loss",
    current.revision,
    current.record,
    backend.Seize("another", nodes.long),
  )
  |> should.equal(Ok(Nil))
  store_core.renew_now(first)
  restart.gone(body)
  memory.advance(nodes.long + 1)
  let second = nodes.node(memory.backend, "lease-b", nodes.long)
  let handle =
    graph.attach(
      graph.new(spec, second, fn() { Nil }, fn(_, _) { Ok(policy.Allow) }),
      graph.id(handle),
    )
  let assert Ok(blocked) = graph.recover(handle)
  let assert graph.Blocked(_, graph.EffectUncertain(_)) = blocked.status
  Nil
}

pub fn concurrent_starts_of_one_identity_release_one_body_test() {
  let ledger = probe.new()
  let runtime =
    graph.new(effect(ledger), support.store(), fn() { Nil }, fn(_, _) {
      Ok(policy.Allow)
    })
  let answers = process.new_subject()
  list.each(list.repeat(Nil, 8), fn(_) {
    process.spawn(fn() {
      process.send(answers, graph.start(runtime, run_id("same-run"), 0))
    })
  })
  let results =
    list.map(list.repeat(Nil, 8), fn(_) { process.receive_forever(answers) })
  list.count(results, fn(result) {
    case result {
      Ok(_) -> True
      Error(_) -> False
    }
  })
  |> should.equal(1)
  let handle = graph.attach(runtime, run_id("same-run"))
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(1000))
  done.status |> should.equal(graph.Completed(1))
  probe.entries(ledger) |> should.equal(["effect"])
}

pub fn an_uncommitted_routing_decision_does_not_admit_its_successor_test() {
  let backend = flaky.new()
  let ledger = probe.new()
  let admissions = probe.new()
  let spec =
    loop(fn(_, _, n) {
      probe.record(ledger, "generate")
      Ok(n + 1)
    })
  flaky.arm(backend, [flaky.Pass, flaky.Pass, flaky.Pass, flaky.FailBefore])
  let runtime =
    graph.new(spec, flaky.store(backend), fn() { Nil }, fn(_, action) {
      probe.record(admissions, action.node)
      Ok(policy.Allow)
    })
  let assert Ok(handle) = graph.start(runtime, run_id("completion-refused"), 0)
  let assert Ok(stopped) =
    graph.await(handle, within: duration.milliseconds(1000))
  stopped.status |> should.equal(graph.Unattended)
  stopped.value |> should.equal(0)
  stopped.receipts |> should.equal([])
  probe.entries(admissions) |> should.equal(["generate"])
  let assert Ok(blocked) = graph.recover(handle)
  let assert graph.Blocked(reference, _) = blocked.status
  let assert Ok(_) = graph.reconcile(handle, reference, "1")
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(1000))
  done.status |> should.equal(graph.Completed(3))
  probe.entries(ledger) |> list.length |> should.equal(3)
}

pub fn restart_uses_the_saved_branch_even_when_the_decision_producer_changes_its_answer_test() {
  let dir = restart.temp_dir()
  let decisions = probe.new()
  let changed = probe.new()
  let branches = probe.new()
  let choose =
    operation.new(
      run.DefinitionId("choose", 1),
      codec.string(),
      codec.bool(),
      fn(_, _, _) {
        probe.record(decisions, "called")
        Ok(!list.is_empty(probe.entries(changed)))
      },
      no_error,
    )
  let chooser =
    definition.node(
      id("choose"),
      choose,
      fn(state) { Ok(state) },
      fn(state, right) {
        Ok(
          definition.Continue(state, case right {
            True -> id("right")
            False -> id("left")
          }),
        )
      },
      [id("left"), id("right")],
    )
  let branch = fn(name) {
    let op =
      operation.new(
        run.DefinitionId(name, 1),
        codec.string(),
        codec.string(),
        fn(_, _, _) {
          probe.record(branches, name)
          Ok(name)
        },
        no_error,
      )
    definition.node(
      id(name),
      op,
      fn(state) { Ok(state) },
      fn(_, name) { Ok(definition.Finish(name, name)) },
      [],
    )
  }
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId("choice", 1),
      id("choose"),
      [chooser, branch("left"), branch("right")],
      codec.string(),
      codec.string(),
      2,
    ))
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let runtime =
        graph.new(spec, runs, fn() { Nil }, fn(_, action) {
          case action.node {
            "left" -> Ok(policy.RequireApproval(run.Requirement("branch", 1)))
            _ -> Ok(policy.Allow)
          }
        })
      let assert Ok(handle) =
        graph.start(runtime, run_id("saved-branch"), "pending")
      #(runs, handle)
    })
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(1000))
  let assert graph.AwaitingApproval(approval) = waiting.status
  let assert [choice] = waiting.receipts
  choice.output_json |> should.equal("false")
  choice.route |> should.equal(graph.Next("left"))
  restart.crash(owner, runs)
  probe.record(changed, "choose right now")
  let runtime =
    graph.new(spec, support.directory(dir), fn() { Nil }, fn(_, _) {
      Ok(policy.Allow)
    })
  let handle = graph.attach(runtime, graph.id(handle))
  let assert Ok(_) = graph.approve(handle, approval)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(1000))
  done.status |> should.equal(graph.Completed("left"))
  probe.entries(decisions) |> should.equal(["called"])
  probe.entries(branches) |> should.equal(["left"])
  restart.remove_dir(dir)
}

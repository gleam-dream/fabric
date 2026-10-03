import fabric/graph
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/operation
import fabric/graph/signal
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/backend
import fabric/support
import fabric/support/flaky
import fabric/support/probe
import fabric/support/restart
import gleam/erlang/process
import gleam/list
import gleam/string
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

fn child(runs: store.Store) -> graph.Runtime(Nil, Int, Int) {
  child_with(runs, fn(_, _, n) { Ok(n + 1) }, fn(_, _) { Ok(policy.Allow) })
}

fn child_with(
  runs: store.Store,
  perform: fn(Nil, operation.Invocation, Int) -> Result(Int, Nil),
  policy: graph.Policy(Nil),
) -> graph.Runtime(Nil, Int, Int) {
  let node =
    definition.node(
      id("increment"),
      operation.new(
        run.DefinitionId("increment", 1),
        codec.int(),
        codec.int(),
        perform,
        fn(_error: Nil) { operation.DefiniteFailure("cannot fail") },
      ),
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId("child", 1),
      id("increment"),
      [node],
      codec.int(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, policy)
}

fn parent(
  runs: store.Store,
  child: graph.Runtime(Nil, Int, Int),
) -> graph.Runtime(Nil, Int, Int) {
  parent_with(runs, child, fn(_, n) { Ok(definition.Finish(n, n)) })
}

fn parent_with(
  runs: store.Store,
  child: graph.Runtime(Nil, Int, Int),
  accept: fn(Int, Int) -> Result(definition.Command(Int, Int), String),
) -> graph.Runtime(Nil, Int, Int) {
  let node =
    definition.node(
      id("child"),
      graph.as_subgraph(child),
      fn(n) { Ok(n) },
      accept,
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId("parent", 1),
      id("child"),
      [node],
      codec.int(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

pub fn a_managed_subgraph_returns_a_native_answer_with_a_retained_child_record_test() {
  let runs = support.store()
  let child = child(runs)
  let assert Ok(handle) = graph.start(parent(runs, child), run_id("parent"), 41)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(42))
  let assert [receipt] = done.receipts
  let assert Ok(child_handle) = graph.child(handle, receipt.activation, child)
  let assert Ok(child_done) = graph.read(child_handle)
  child_done.status |> should.equal(graph.Completed(42))
  list.length(child_done.receipts) |> should.equal(1)
}

pub fn nested_subgraphs_complete_with_the_default_callback_bound_test() {
  let runs = support.store()
  let runtime =
    list.fold(list.repeat(Nil, 8), child(runs), fn(runtime, _) {
      parent(runs, runtime)
    })
  let assert Ok(handle) = graph.start(runtime, run_id("nested-answer"), 41)
  let assert Ok(done) =
    graph.await(handle, within: duration.milliseconds(10_000))
  done.status |> should.equal(graph.Completed(42))
}

pub fn a_child_approval_survives_restart_and_continues_the_same_attachment_test() {
  let dir = restart.temp_dir()
  let policy = fn(_, _) {
    Ok(policy.RequireApproval(run.Requirement("child-increment", 1)))
  }
  let #(owner, #(runs, child, handle)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let child = child_with(runs, fn(_, _, n) { Ok(n + 1) }, policy)
      let assert Ok(handle) =
        graph.start(parent(runs, child), run_id("parent-restart"), 41)
      #(runs, child, handle)
    })
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(reference, child.Approval(_)) = waiting.status
  let assert Ok(child_handle) = graph.child(handle, reference.activation, child)
  let assert Ok(child_waiting) = graph.read(child_handle)
  let assert graph.AwaitingApproval(approval) = child_waiting.status
  restart.crash(owner, runs)
  let runs = support.directory(dir)
  let child = child_with(runs, fn(_, _, n) { Ok(n + 1) }, policy)
  let handle = graph.attach(parent(runs, child), run_id("parent-restart"))
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(child_handle) = graph.child(handle, reference.activation, child)
  graph.id(child_handle) |> should.equal(reference.child)
  let assert Ok(_) = graph.approve(child_handle, approval)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(42))
  restart.remove_dir(dir)
}

pub fn an_idle_parent_releases_its_runner_and_wakes_when_its_child_is_approved_test() {
  let runs = support.store()
  let child =
    child_with(runs, fn(_, _, n) { Ok(n + 1) }, fn(_, _) {
      Ok(policy.RequireApproval(run.Requirement("child-start", 1)))
    })
  let assert Ok(handle) =
    graph.start(parent(runs, child), run_id("idle-parent"), 41)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(reference, child.Approval(_)) = waiting.status
  idle(runs, graph.id(handle), 100) |> should.be_true
  let assert Ok(child_handle) = graph.child(handle, reference.activation, child)
  let assert Ok(waiting) = graph.read(child_handle)
  let assert graph.AwaitingApproval(approval) = waiting.status
  restart.runner(runs, graph.id(child_handle)) |> should.equal(Error(Nil))
  let assert Ok(_) = graph.approve(child_handle, approval)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(42))
}

fn idle(runs: store.Store, id: run.RunId, left: Int) -> Bool {
  case restart.runner(runs, id) {
    Error(Nil) -> True
    Ok(_) if left > 0 -> {
      process.sleep(10)
      idle(runs, id, left - 1)
    }
    Ok(_) -> False
  }
}

fn signal_child(
  runs: store.Store,
  policy: graph.Policy(Nil),
) -> graph.Runtime(Nil, Int, Int) {
  let node =
    definition.node(
      id("answer"),
      operation.await_signal(
        codec.int(),
        signal.new(run.DefinitionId("answer", 1), codec.int()),
      ),
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId("signal-child", 1),
      id("answer"),
      [node],
      codec.int(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, policy)
}

pub fn nested_approval_and_signal_waits_release_every_runner_and_keep_each_route_test() {
  let runs = support.store()
  let leaf =
    signal_child(runs, fn(_, _) {
      Ok(policy.RequireApproval(run.Requirement("publish-answer", 1)))
    })
  let middle =
    parent_with(runs, leaf, fn(_, n) { Ok(definition.Finish(n + 10, n + 10)) })
  let root =
    parent_with(runs, middle, fn(_, n) {
      Ok(definition.Finish(n + 100, n + 100))
    })
  let assert Ok(handle) = graph.start(root, run_id("nested-signal"), 41)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(_, child.Approval(_)) = waiting.status
  let assert Ok(middle_handle) = graph.child(handle, 1, middle)
  let assert Ok(leaf_handle) = graph.child(middle_handle, 1, leaf)
  idle(runs, graph.id(handle), 100) |> should.be_true
  idle(runs, graph.id(middle_handle), 100) |> should.be_true
  let assert Ok(waiting) = graph.read(leaf_handle)
  let assert graph.AwaitingApproval(approval) = waiting.status
  let assert Ok(waiting) = graph.approve(leaf_handle, approval)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(_, child.Signal(run.DefinitionId("answer", 1))) =
    waiting.status
  idle(runs, graph.id(handle), 100) |> should.be_true
  idle(runs, graph.id(middle_handle), 100) |> should.be_true
  idle(runs, graph.id(leaf_handle), 100) |> should.be_true
  let response = signal.new(run.DefinitionId("answer", 1), codec.int())
  let assert Ok(_) = graph.deliver(leaf_handle, reference, response, 42)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(152))
  let assert Ok(middle_done) = graph.read(middle_handle)
  middle_done.status |> should.equal(graph.Completed(52))
  let assert Ok(_) = graph.deliver(leaf_handle, reference, response, 42)
  graph.read(handle) |> should.equal(Ok(done))
}

pub fn recovery_repairs_a_child_completion_notification_lost_with_the_store_test() {
  let dir = restart.temp_dir()
  let #(owner, runs) = restart.owned(fn() { support.directory(dir) })
  let leaf = signal_child(runs, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) =
    graph.start(parent(runs, leaf), run_id("missed-child-wake"), 41)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(_, child.Signal(_)) = waiting.status
  idle(runs, graph.id(handle), 100) |> should.be_true
  let wrong_child = signal_child(support.store(), fn(_, _) { Ok(policy.Allow) })
  let wrong_parent = graph.attach(parent(runs, wrong_child), graph.id(handle))
  graph.read(wrong_parent) |> should.be_error
  let assert Ok(leaf_handle) = graph.child(handle, 1, leaf)
  let assert Ok(waiting) = graph.read(leaf_handle)
  let assert graph.AwaitingSignal(reference) = waiting.status
  restart.crash(owner, runs)
  let runs = support.directory(dir)
  let leaf = signal_child(runs, fn(_, _) { Ok(policy.Allow) })
  let handle = graph.attach(parent(runs, leaf), graph.id(handle))
  let assert Ok(leaf_handle) = graph.child(handle, 1, leaf)
  let assert Ok(_) =
    graph.deliver(
      leaf_handle,
      reference,
      signal.new(run.DefinitionId("answer", 1), codec.int()),
      42,
    )
  let assert Ok(before) = graph.read(handle)
  before.receipts |> should.equal([])
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(42))
  restart.remove_dir(dir)
}

pub fn parking_checks_a_child_that_completed_before_wakeup_registration_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let probe = probe.new()
  let child =
    child_with(
      runs,
      fn(_, _, n) {
        probe.record(probe, "effect")
        Ok(n + 1)
      },
      fn(_, _) {
        probe.gate(probe, "before approval")
        Ok(policy.RequireApproval(run.Requirement("child-start", 1)))
      },
    )
  let assert Ok(handle) =
    graph.start(parent(runs, child), run_id("park-race"), 41)
  let arrival = probe.arrival(probe)
  let held =
    flaky.hold(backend, fn(id) { id == run.id_to_string(graph.id(handle)) })
  probe.release(arrival)
  let assert Ok(_) = process.receive(held, 5000)
  let other_runs = flaky.store(backend)
  let other_child =
    child_with(
      other_runs,
      fn(_, _, n) {
        probe.record(probe, "effect")
        Ok(n + 1)
      },
      fn(_, _) { Ok(policy.Allow) },
    )
  let other_parent =
    graph.attach(parent(other_runs, other_child), graph.id(handle))
  let assert Ok(child_handle) = graph.child(other_parent, 1, other_child)
  let assert Ok(waiting) = graph.read(child_handle)
  let assert graph.AwaitingApproval(approval) = waiting.status
  let assert Ok(_) = graph.approve(child_handle, approval)
  let assert Ok(child_done) =
    graph.await(child_handle, within: duration.milliseconds(5000))
  child_done.status |> should.equal(graph.Completed(42))
  flaky.release_held(backend)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(42))
  probe.entries(probe) |> should.equal(["effect"])
}

pub fn cancellation_wins_over_a_delayed_idle_parent_wakeup_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let leaf = signal_child(runs, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) =
    graph.start(parent(runs, leaf), run_id("cancel-idle-wake"), 41)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(reference, child.Signal(_)) = waiting.status
  idle(runs, graph.id(handle), 100) |> should.be_true
  let assert Ok(leaf_handle) = graph.child(handle, 1, leaf)
  let assert Ok(waiting) = graph.read(leaf_handle)
  let assert graph.AwaitingSignal(signal_reference) = waiting.status
  let held =
    flaky.hold(backend, fn(id) { id == run.id_to_string(graph.id(handle)) })
  let assert Ok(_) =
    graph.deliver(
      leaf_handle,
      signal_reference,
      signal.new(run.DefinitionId("answer", 1), codec.int()),
      42,
    )
  let assert Ok(_) = process.receive(held, 5000)
  let other_runs = flaky.store(backend)
  let leaf = signal_child(other_runs, fn(_, _) { Ok(policy.Allow) })
  let canceller = graph.attach(parent(other_runs, leaf), graph.id(handle))
  graph.cancel(canceller) |> should.equal(Ok(Nil))
  let assert Ok(cancelled) =
    graph.await(canceller, within: duration.milliseconds(5000))
  cancelled.status
  |> should.equal(graph.Cancelled(graph.ChildSettled(reference)))
  flaky.release_held(backend)
  let assert Ok(after) = graph.read(handle)
  after |> should.equal(cancelled)
  after.value |> should.equal(41)
  after.receipts |> should.equal([])
}

pub fn lost_child_start_and_parent_completion_acknowledgements_do_not_repeat_a_child_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let calls = process.new_subject()
  let probe = probe.new()
  let child =
    child_with(
      runs,
      fn(_, _, n) {
        process.send(calls, n)
        probe.gate(probe, "child-start-confirmed")
        Ok(n + 1)
      },
      fn(_, _) { Ok(policy.Allow) },
    )
  flaky.arm_where(backend, fn(id) { string.starts_with(id, "graph-") }, [
    flaky.FailAfter,
  ])
  let assert Ok(handle) =
    graph.start(parent(runs, child), run_id("parent-ack"), 41)
  let arrival = probe.arrival(probe)
  flaky.arm_run(backend, graph.id(handle), [flaky.FailAfter])
  probe.release(arrival)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(42))
  process.receive(calls, 1000) |> should.equal(Ok(41))
  process.receive(calls, 0) |> should.equal(Error(Nil))
}

pub fn canceling_a_parent_stops_a_started_child_and_retains_its_uncertainty_test() {
  let runs = support.store()
  let probe = probe.new()
  let child =
    child_with(
      runs,
      fn(_, _, n) {
        probe.gate(probe, "started")
        Ok(n + 1)
      },
      fn(_, _) { Ok(policy.Allow) },
    )
  let assert Ok(handle) =
    graph.start(parent(runs, child), run_id("parent-cancel"), 41)
  let arrival = probe.arrival(probe)
  let assert Ok(pid) = process.subject_owner(arrival.release)
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Cancelled(graph.ChildUnresolved(_, _)) = done.status
  process.is_alive(pid) |> should.be_false
  let assert Ok(child_handle) = graph.child(handle, 1, child)
  let assert Ok(child_done) = graph.read(child_handle)
  let assert graph.Cancelled(graph.Unresolved(_, _)) = child_done.status
}

pub fn a_child_must_use_the_parent_store_and_mismatches_are_observable_test() {
  let runs = support.store()
  let child = child(support.store())
  let assert Ok(handle) =
    graph.start(parent(runs, child), run_id("wrong-store"), 41)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Failed(graph.PolicyFailed(reason)) = waiting.status
  string.contains(reason, "parent's store") |> should.be_true
}

pub fn reconciling_a_cancelled_child_settles_its_parent_without_routing_test() {
  let runs = support.store()
  let probe = probe.new()
  let child =
    child_with(
      runs,
      fn(_, _, n) {
        probe.record(probe, "child effect")
        probe.gate(probe, "child started")
        Ok(n + 1)
      },
      fn(_, _) { Ok(policy.Allow) },
    )
  let assert Ok(handle) =
    graph.start(parent(runs, child), run_id("settle-cancelled"), 41)
  let _arrival = probe.arrival(probe)
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(cancelled) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Cancelled(graph.ChildUnresolved(_, _)) = cancelled.status
  graph.reconcile(handle, graph.Reconciliation(graph.id(handle), 1, 1), "42")
  |> should.be_error
  let assert Ok(child_handle) = graph.child(handle, 1, child)
  let assert Ok(child_cancelled) = graph.read(child_handle)
  let assert graph.Cancelled(graph.Unresolved(reference, _)) =
    child_cancelled.status
  let assert Ok(still_uncertain) = graph.recover(handle)
  still_uncertain |> should.equal(cancelled)
  let assert Ok(settled_child) = graph.reconcile(child_handle, reference, "42")
  settled_child.status |> should.equal(graph.Cancelled(graph.AfterResult))
  let assert Ok(settled) = graph.recover(handle)
  let reference = child.Reference(graph.id(handle), 1, graph.id(child_handle))
  settled.status |> should.equal(graph.Cancelled(graph.ChildSettled(reference)))
  settled.value |> should.equal(41)
  settled.receipts |> should.equal([])
  probe.entries(probe) |> should.equal(["child effect"])
  graph.recover(handle) |> should.equal(Ok(settled))
}

pub fn nested_cancelled_children_settle_from_the_leaf_after_store_restart_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let leaf = fn(runs) {
    child_with(
      runs,
      fn(_, _, _) {
        probe.record(probe, "leaf effect")
        panic as "external effect has no saved result"
      },
      fn(_, _) { Ok(policy.Allow) },
    )
  }
  let #(owner, #(runs, handle, middle_handle, leaf_handle)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let leaf = leaf(runs)
      let middle = parent(runs, leaf)
      let assert Ok(handle) =
        graph.start(parent(runs, middle), run_id("nested-cancel"), 41)
      let assert Ok(middle_handle) = wait_for_child(handle, middle, 100)
      let assert Ok(leaf_handle) = wait_for_child(middle_handle, leaf, 100)
      let assert Ok(uncertain) =
        graph.await(leaf_handle, within: duration.milliseconds(5000))
      let assert graph.Blocked(_, _) = uncertain.status
      graph.cancel(handle) |> should.equal(Ok(Nil))
      let assert Ok(cancelled) =
        graph.await(handle, within: duration.milliseconds(5000))
      let assert graph.Cancelled(graph.ChildUnresolved(_, _)) = cancelled.status
      #(runs, handle, middle_handle, leaf_handle)
    })
  restart.crash(owner, runs)
  let runs = support.directory(dir)
  let leaf = leaf(runs)
  let middle = parent(runs, leaf)
  let root = graph.attach(parent(runs, middle), graph.id(handle))
  let middle_handle = graph.attach(middle, graph.id(middle_handle))
  let leaf_handle = graph.attach(leaf, graph.id(leaf_handle))
  let assert Ok(leaf_cancelled) = graph.read(leaf_handle)
  let assert graph.Cancelled(graph.Unresolved(reference, _)) =
    leaf_cancelled.status
  let assert Ok(_) = graph.reconcile(leaf_handle, reference, "42")
  let assert Ok(root_unsettled) = graph.recover(root)
  let assert graph.Cancelled(graph.ChildUnresolved(_, _)) =
    root_unsettled.status
  let assert Ok(middle_settled) = graph.recover(middle_handle)
  let assert graph.Cancelled(graph.ChildSettled(_)) = middle_settled.status
  let assert Ok(root_settled) = graph.recover(root)
  let assert graph.Cancelled(graph.ChildSettled(_)) = root_settled.status
  root_settled.value |> should.equal(41)
  root_settled.receipts |> should.equal([])
  middle_settled.receipts |> should.equal([])
  probe.entries(probe) |> should.equal(["leaf effect"])
  restart.remove_dir(dir)
}

fn wait_for_child(
  handle: graph.Handle(Nil, Int, Int),
  runtime: graph.Runtime(Nil, Int, Int),
  left: Int,
) -> Result(graph.Handle(Nil, Int, Int), graph.Error) {
  case graph.child(handle, 1, runtime) {
    Error(graph.StoreFailed(backend.NotFound)) if left > 0 -> {
      process.sleep(10)
      wait_for_child(handle, runtime, left - 1)
    }
    result -> result
  }
}

fn cancelled_pair(
  runs: store.Store,
) -> #(
  graph.Handle(Nil, Int, Int),
  graph.Handle(Nil, Int, Int),
  graph.Runtime(Nil, Int, Int),
) {
  let child =
    child_with(runs, fn(_, _, _) { panic as "uncertain child" }, fn(_, _) {
      Ok(policy.Allow)
    })
  let runtime = parent(runs, child)
  let assert Ok(handle) =
    graph.start(runtime, run_id("cancel-settlement-race"), 41)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(_, child.Uncertain(_)) = waiting.status
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(cancelled) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Cancelled(graph.ChildUnresolved(_, _)) = cancelled.status
  let assert Ok(child_handle) = graph.child(handle, 1, child)
  let assert Ok(child_cancelled) = graph.read(child_handle)
  let assert graph.Cancelled(graph.Unresolved(reference, _)) =
    child_cancelled.status
  let assert Ok(_) = graph.reconcile(child_handle, reference, "42")
  #(handle, child_handle, runtime)
}

pub fn failed_and_lost_settlement_commits_preserve_terminal_cancellation_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let #(handle, _, _) = cancelled_pair(runs)
  let assert Ok(before) = graph.read(handle)
  flaky.arm_run(backend, graph.id(handle), [flaky.FailBefore])
  graph.recover(handle) |> should.be_error
  graph.read(handle) |> should.equal(Ok(before))
  flaky.arm_run(backend, graph.id(handle), [flaky.FailAfter])
  let assert Ok(after) = graph.recover(handle)
  let assert graph.Cancelled(graph.ChildSettled(_)) = after.status
  after.value |> should.equal(before.value)
  after.receipts |> should.equal(before.receipts)
  graph.recover(handle) |> should.equal(Ok(after))
}

pub fn competing_settlement_commands_acknowledge_the_same_cancelled_record_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let #(handle, _, _) = cancelled_pair(runs)
  let held =
    flaky.hold(backend, fn(id) { id == run.id_to_string(graph.id(handle)) })
  let replies = process.new_subject()
  process.spawn_unlinked(fn() { process.send(replies, graph.recover(handle)) })
  let assert Ok(_) = process.receive(held, 5000)
  let other_runs = flaky.store(backend)
  let other =
    graph.attach(parent(other_runs, child(other_runs)), graph.id(handle))
  let assert Ok(settled) = graph.recover(other)
  let assert graph.Cancelled(graph.ChildSettled(_)) = settled.status
  flaky.release_held(backend)
  process.receive(replies, 5000) |> should.equal(Ok(Ok(settled)))
  graph.read(handle) |> should.equal(Ok(settled))
}

pub fn cancellation_settlement_cannot_read_a_child_in_a_different_store_test() {
  let runs = support.store()
  let #(handle, _, _) = cancelled_pair(runs)
  let assert Ok(before) = graph.read(handle)
  let other_runs = support.store()
  let wrong = graph.attach(parent(runs, child(other_runs)), graph.id(handle))
  graph.recover(wrong) |> should.be_error
  graph.read(handle) |> should.equal(Ok(before))
}

pub fn a_child_uncertainty_is_reconciled_in_the_child_before_parent_continuation_test() {
  let runs = support.store()
  let calls = process.new_subject()
  let child =
    child_with(
      runs,
      fn(_, _, _) {
        process.send(calls, Nil)
        panic as "receipt lost after an effect"
      },
      fn(_, _) { Ok(policy.Allow) },
    )
  let assert Ok(handle) =
    graph.start(parent(runs, child), run_id("parent-uncertain"), 41)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(reference, child.Uncertain(_)) = waiting.status
  let assert Ok(child_handle) = graph.child(handle, reference.activation, child)
  let assert Ok(child_waiting) = graph.read(child_handle)
  let assert graph.Blocked(reconciliation, _) = child_waiting.status
  let assert Ok(_) = graph.reconcile(child_handle, reconciliation, "42")
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(42))
  process.receive(calls, 1000) |> should.equal(Ok(Nil))
  process.receive(calls, 0) |> should.equal(Error(Nil))
}

pub fn a_saved_child_result_survives_a_lost_parent_completion_commit_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let probe = probe.new()
  let child =
    child_with(
      runs,
      fn(_, _, n) {
        probe.record(probe, "effect")
        probe.gate(probe, "child")
        Ok(n + 1)
      },
      fn(_, _) { Ok(policy.Allow) },
    )
  let assert Ok(handle) =
    graph.start(parent(runs, child), run_id("parent-completion-lost"), 41)
  let arrival = probe.arrival(probe)
  flaky.arm_run(backend, graph.id(handle), [flaky.FailBefore])
  probe.release(arrival)
  let assert Ok(unattended) =
    graph.await(handle, within: duration.milliseconds(5000))
  unattended.status |> should.equal(graph.Unattended)
  let assert Ok(child_handle) = graph.child(handle, 1, child)
  let assert Ok(child_done) = graph.read(child_handle)
  child_done.status |> should.equal(graph.Completed(42))
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(42))
  probe.entries(probe) |> should.equal(["effect"])
}

pub fn canceling_a_child_approval_records_settlement_without_starting_its_body_test() {
  let runs = support.store()
  let calls = process.new_subject()
  let child =
    child_with(
      runs,
      fn(_, _, n) {
        process.send(calls, Nil)
        Ok(n + 1)
      },
      fn(_, _) { Ok(policy.RequireApproval(run.Requirement("child-start", 1))) },
    )
  let assert Ok(handle) =
    graph.start(parent(runs, child), run_id("parent-cancel-approval"), 41)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(reference, child.Approval(_)) = waiting.status
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Cancelled(graph.ChildSettled(reference)))
  let assert Ok(child_handle) = graph.child(handle, 1, child)
  let assert Ok(child_done) = graph.read(child_handle)
  child_done.status |> should.equal(graph.Cancelled(graph.BeforeStart))
  process.receive(calls, 0) |> should.equal(Error(Nil))
}

pub fn parent_cancellation_buries_a_child_before_a_delayed_start_can_land_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let calls = process.new_subject()
  let perform = fn(_, _, n) {
    process.send(calls, Nil)
    Ok(n + 1)
  }
  let policy = fn(_, _) { Ok(policy.Allow) }
  let child = child_with(runs, perform, policy)
  let held = flaky.hold(backend, fn(id) { string.starts_with(id, "graph-") })
  let assert Ok(handle) =
    graph.start(parent(runs, child), run_id("parent-delayed-child"), 41)
  let assert Ok(child_id) = process.receive(held, 5000)
  let other_runs = flaky.store(backend)
  let other_child = child_with(other_runs, perform, policy)
  let canceller =
    graph.attach(parent(other_runs, other_child), graph.id(handle))
  graph.cancel(canceller) |> should.equal(Ok(Nil))
  let assert Ok(done) =
    graph.await(canceller, within: duration.milliseconds(5000))
  let assert graph.Cancelled(graph.ChildSettled(reference)) = done.status
  run.id_to_string(reference.child) |> should.equal(child_id)
  flaky.release_held(backend)
  let assert Ok(child_handle) = graph.child(canceller, 1, other_child)
  let assert Ok(child_done) = graph.read(child_handle)
  child_done.status |> should.equal(graph.Cancelled(graph.BeforeStart))
  process.receive(calls, 0) |> should.equal(Error(Nil))
}

pub fn child_handles_cannot_cross_stores_that_reuse_the_same_run_id_test() {
  let a = support.store()
  let b = support.store()
  let child_a = child(a)
  let child_b = child(b)
  let assert Ok(parent_a) =
    graph.start(parent(a, child_a), run_id("same-name"), 1)
  let assert Ok(parent_b) =
    graph.start(parent(b, child_b), run_id("same-name"), 100)
  let assert Ok(done_a) =
    graph.await(parent_a, within: duration.milliseconds(5000))
  let assert Ok(done_b) =
    graph.await(parent_b, within: duration.milliseconds(5000))
  done_a.status |> should.equal(graph.Completed(2))
  done_b.status |> should.equal(graph.Completed(101))
  let assert Error(graph.CommandRefused(_)) = graph.child(parent_a, 1, child_b)
  let assert Ok(there) = graph.child(parent_a, 1, child_a)
  let assert Ok(done) = graph.read(there)
  done.status |> should.equal(graph.Completed(2))
}

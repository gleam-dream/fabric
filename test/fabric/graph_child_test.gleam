import fabric/graph
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/operation
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/flaky
import fabric/support/probe
import fabric/support/restart
import gleam/erlang/process
import gleam/list
import gleam/string
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
        run.Identity("increment", 1),
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
      run.Identity("child", 1),
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
  let node =
    definition.node(
      id("child"),
      graph.as_subgraph(child),
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("parent", 1),
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
  let assert Ok(done) = graph.await(handle, 5000)
  done.status |> should.equal(graph.Completed(42))
  let assert [receipt] = done.receipts
  let assert Ok(child_handle) = graph.child(handle, receipt.activation, child)
  let assert Ok(child_done) = graph.read(child_handle)
  child_done.status |> should.equal(graph.Completed(42))
  list.length(child_done.receipts) |> should.equal(1)
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
  let assert Ok(waiting) = graph.await(handle, 5000)
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
  let assert Ok(done) = graph.await(handle, 5000)
  done.status |> should.equal(graph.Completed(42))
  restart.remove_dir(dir)
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
  let assert Ok(done) = graph.await(handle, 5000)
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
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Cancelled(graph.Unresolved(_, _)) = done.status
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
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.Failed(graph.PolicyFailed(reason)) = waiting.status
  string.contains(reason, "parent's store") |> should.be_true
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
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.Child(reference, child.Uncertain(_)) = waiting.status
  let assert Ok(child_handle) = graph.child(handle, reference.activation, child)
  let assert Ok(child_waiting) = graph.read(child_handle)
  let assert graph.Blocked(reconciliation, _) = child_waiting.status
  let assert Ok(_) = graph.reconcile(child_handle, reconciliation, "42")
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(done) = graph.await(handle, 5000)
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
  let assert Ok(unattended) = graph.await(handle, 5000)
  unattended.status |> should.equal(graph.Unattended)
  let assert Ok(child_handle) = graph.child(handle, 1, child)
  let assert Ok(child_done) = graph.read(child_handle)
  child_done.status |> should.equal(graph.Completed(42))
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(done) = graph.await(handle, 5000)
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
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.Child(reference, child.Approval(_)) = waiting.status
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(done) = graph.await(handle, 5000)
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
  let assert Ok(done) = graph.await(canceller, 5000)
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
  let assert Ok(done_a) = graph.await(parent_a, 5000)
  let assert Ok(done_b) = graph.await(parent_b, 5000)
  done_a.status |> should.equal(graph.Completed(2))
  done_b.status |> should.equal(graph.Completed(101))
  let assert Error(graph.CommandRefused(_)) = graph.child(parent_a, 1, child_b)
  let assert Ok(there) = graph.child(parent_a, 1, child_a)
  let assert Ok(done) = graph.read(there)
  done.status |> should.equal(graph.Completed(2))
}

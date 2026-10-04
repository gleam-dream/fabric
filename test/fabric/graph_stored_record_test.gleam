//// Graph records written before wave 5 slice F5 (version 14: no reviewers,
//// no approval deadlines, waits without deadlines, no correlation) still
//// read, recover and finish. The fixtures were written by that code; the
//// definitions below are the ones that wrote them.

import fabric/graph
import fabric/graph/definition
import fabric/graph/job
import fabric/graph/operation
import fabric/graph/signal
import fabric/internal/graph/attachment
import fabric/internal/store as store_core
import fabric/policy
import fabric/reviewer
import fabric/run
import fabric/store
import fabric/store/conformance
import fabric/store/discovery
import fabric/support
import fabric/support/nodes
import fabric/support/restart
import fabric/tool
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn fixture(name: String) -> String {
  let assert Ok(text) = restart.read_file("test/fixtures/records/" <> name)
  text
}

/// A started store holding the fixture `name` as the record of run `id`.
fn holding(runs: store.Store, id: String, name: String) -> store.Store {
  let assert Ok(_) =
    store_core.insert(
      runs,
      id,
      fixture(name),
      store_core.Detached(False, False),
    )
  runs
}

fn node(name: String) -> definition.NodeId {
  let id = definition.node_id(name)
  id
}

fn activity(runs: store.Store, gate) -> graph.Runtime(Nil, Int, Int) {
  let op =
    operation.new(
      run.DefinitionId("fixture-review", 1),
      codec.int(),
      codec.int(),
      fn(_, _, n) { Ok(n * 2) },
      fn(_: Nil) { tool.Explain("unreachable") },
    )
  let n =
    definition.node(
      node("review"),
      op,
      fn(n) { Ok(n) },
      fn(state, out) { Ok(definition.Finish(state, out)) },
      [],
    )
  let assert Ok(d) =
    definition.build(
      definition.new(
        run.DefinitionId("fixture-approval", 1),
        entry: node("review"),
        nodes: [n],
        state: codec.int(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(3),
    )
  graph.new(d, runs, fn(_) { Nil }, gate)
}

fn ready() -> signal.Signal(Bool) {
  signal.new(run.DefinitionId("fixture-ready", 1), codec.bool())
}

fn signal_runtime(runs: store.Store) -> graph.Runtime(Nil, Int, Int) {
  let n =
    definition.node(
      node("wait"),
      operation.await_signal(codec.int(), ready()),
      fn(n) { Ok(n) },
      fn(state, _) { Ok(definition.Finish(state, state)) },
      [],
    )
  let assert Ok(d) =
    definition.build(
      definition.new(
        run.DefinitionId("fixture-signal", 1),
        entry: node("wait"),
        nodes: [n],
        state: codec.int(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(3),
    )
  graph.new(d, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn allow(_: Nil, _) {
  Ok(policy.Allow)
}

/// A leased store over a backend whose clock the test moves.
fn clocked() -> #(store.Store, fn(Int) -> Nil) {
  let memory = conformance.leased_memory()
  #(nodes.node(memory.backend, "fixtures", nodes.long), memory.advance)
}

const days_8 = 691_200_000

pub fn a_stored_approval_without_a_deadline_is_answered_and_never_expires_test() {
  let #(runs, advance) = clocked()
  let runs = holding(runs, "graph-approval", "graph-awaiting-approval.json")
  discovery.inspect(fixture("graph-awaiting-approval.json"))
  |> should.equal(Ok(None))
  // Longer than the 7-day default: a request stored without a deadline
  // keeps none.
  advance(days_8)
  let runtime =
    activity(runs, fn(_, _) {
      Ok(policy.RequireApproval(run.Requirement("publish", 1)))
    })
  let handle = support.open_graph(runtime, support.id("graph-approval"))
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(recovered) = graph.snapshot(handle)
  let assert graph.AwaitingApproval(reference) = recovered.status
  recovered.deadline |> should.equal(None)
  reference.requirement |> should.equal(run.Requirement("publish", 1))
  let assert Ok(_) =
    graph.approve(
      handle,
      reference,
      reviewer: support.reviewer("reviewer"),
      context: Nil,
    )
  let assert Ok(_) = graph.await(handle, within: duration.seconds(5))
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Completed(42))
  // The answer is stored with its reviewer in the new format.
  let assert [receipt] = done.receipts
  let assert [run.Approval(answer: run.Approve, reviewer: Some(who), ..)] =
    receipt.approvals
  reviewer.subject(who) |> should.equal("reviewer")
}

pub fn a_stored_completed_run_reads_test() {
  let runs = holding(support.store(), "graph-completed", "graph-completed.json")
  let handle =
    support.open_graph(activity(runs, allow), support.id("graph-completed"))
  let assert Ok(snapshot) = graph.snapshot(handle)
  snapshot.status |> should.equal(graph.Completed(10))
  let assert [receipt] = snapshot.receipts
  receipt.output_json |> should.equal("10")
}

pub fn a_stored_signal_wait_without_a_deadline_recovers_and_keeps_none_test() {
  let #(runs, advance) = clocked()
  let runs = holding(runs, "graph-signal", "graph-waiting-signal.json")
  discovery.inspect(fixture("graph-waiting-signal.json"))
  |> should.equal(Ok(None))
  // Waits now default to 7 days; one stored without a deadline keeps none.
  advance(days_8)
  let handle =
    support.open_graph(signal_runtime(runs), support.id("graph-signal"))
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(recovered) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(reference) = recovered.status
  recovered.deadline |> should.equal(None)
  let assert Ok(done) = graph.deliver(handle, reference, ready(), True)
  done |> should.equal(graph.Completed(7))
}

pub fn a_stored_child_wait_recovers_and_its_child_finishes_test() {
  let runs =
    support.store()
    |> holding("graph-parent", "graph-waiting-child.json")
    |> holding(
      attachment.reserved_id("graph-parent", 1),
      "graph-waiting-child-child.json",
    )
  let child = signal_runtime(runs)
  let n =
    definition.node(
      node("delegate"),
      graph.as_subgraph(child),
      fn(n) { Ok(n) },
      fn(state, out) { Ok(definition.Finish(state, out + 1)) },
      [],
    )
  let assert Ok(d) =
    definition.build(
      definition.new(
        run.DefinitionId("fixture-parent", 1),
        entry: node("delegate"),
        nodes: [n],
        state: codec.int(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(3),
    )
  let parent =
    support.open_graph(
      graph.new(d, runs, fn(_) { Nil }, allow),
      support.id("graph-parent"),
    )
  let assert Ok(_) = graph.recover(parent)
  let assert Ok(_) = graph.await(parent, within: duration.seconds(5))
  let assert Ok(waiting) = graph.snapshot(parent)
  let assert graph.Child(_, _) = waiting.status
  waiting.deadline |> should.equal(None)
  let assert Ok(handle) = graph.child(parent, 1, child)
  let assert Ok(child_snapshot) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(reference) = child_snapshot.status
  child_snapshot.deadline |> should.equal(None)
  let assert Ok(_) = graph.deliver(handle, reference, ready(), True)
  let assert Ok(done) = await_finished(parent, 50)
  done.status |> should.equal(graph.Completed(5))
}

fn await_finished(handle, tries: Int) {
  let assert Ok(_) = graph.await(handle, within: duration.seconds(5))
  let assert Ok(snapshot) = graph.snapshot(handle)
  case snapshot.status, tries {
    graph.Completed(_), _ | _, 0 -> Ok(snapshot)
    _, _ -> {
      let _ = graph.recover(handle)
      await_finished(handle, tries - 1)
    }
  }
}

pub fn a_stored_job_wait_without_a_deadline_is_polled_to_completion_test() {
  let runs = holding(support.store(), "graph-job", "graph-waiting-job.json")
  let observer =
    job.observe(
      run.DefinitionId("fixture-job-read", 1),
      codec.string(),
      codec.int(),
      fn(_, receipt) {
        receipt |> should.equal("receipt-3")
        Ok(job.Completed(11))
      },
    )
  let n =
    definition.node(
      node("poll"),
      operation.await_job(observer),
      fn(n) { Ok("receipt-" <> int.to_string(n)) },
      fn(state, out) { Ok(definition.Finish(state, out)) },
      [],
    )
  let assert Ok(d) =
    definition.build(
      definition.new(
        run.DefinitionId("fixture-job", 1),
        entry: node("poll"),
        nodes: [n],
        state: codec.int(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(3),
    )
  let handle =
    support.open_graph(
      graph.new(d, runs, fn(_) { Nil }, allow),
      support.id("graph-job"),
    )
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingJob(reference) = waiting.status
  waiting.deadline |> should.equal(None)
  let assert Ok(done) = graph.poll_job(handle, reference)
  done |> should.equal(graph.Completed(11))
}

pub fn a_stored_uncertain_effect_is_reconciled_test() {
  let runs = holding(support.store(), "graph-blocked", "graph-blocked.json")
  let op =
    operation.new(
      run.DefinitionId("fixture-charge", 1),
      codec.int(),
      codec.int(),
      fn(_, _, _) { Error(Nil) },
      fn(_: Nil) { tool.Uncertain("gateway timeout") },
    )
  let n =
    definition.node(
      node("charge"),
      op,
      fn(n) { Ok(n) },
      fn(state, out) { Ok(definition.Finish(state, out)) },
      [],
    )
  let assert Ok(d) =
    definition.build(
      definition.new(
        run.DefinitionId("fixture-uncertain", 1),
        entry: node("charge"),
        nodes: [n],
        state: codec.int(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(3),
    )
  let handle =
    support.open_graph(
      graph.new(d, runs, fn(_) { Nil }, allow),
      support.id("graph-blocked"),
    )
  let assert Ok(blocked) = graph.snapshot(handle)
  let assert graph.Blocked(reference, graph.EffectUncertain("gateway timeout")) =
    blocked.status
  let assert Ok(_) = graph.reconcile(handle, reference, "18")
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Completed(18))
  list.length(done.receipts) |> should.equal(1)
}

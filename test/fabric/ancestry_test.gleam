//// Cross-runtime ancestry is checked against saved reservations. These
//// fixtures install committed states directly; agent execution and commands
//// then use their ordinary runner and public handles.

import fabric
import fabric/agent
import fabric/graph/child
import fabric/graph/operation
import fabric/internal/ancestry
import fabric/internal/controller
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record as graph_record
import fabric/internal/runner
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/probe
import fabric/support/scripted
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

fn graph_parent(runs: store.Store) -> #(graph.State, String) {
  let assert Ok(#(state, _)) =
    graph.start(
      "graph-parent",
      graph.Definition(run.Identity("parent", 1), "parent-v1", 2),
      "0",
      graph.Prepared(
        "delegate",
        run.Identity("child", 1),
        "0",
        operation.RequireReconciliation,
        operation.Subgraph,
      ),
    )
  let assert graph.Ready(a) = state.phase
  let assert Ok(#(state, _)) =
    graph.step(
      state,
      graph.Inspected(graph.reference(state, a), Ok(policy.Allow)),
    )
  let assert Ok(encoded) = graph_record.encode(state)
  let assert Ok(_) =
    store.insert(
      runs,
      state.run,
      encoded,
      store.Detached(in_flight: False, seize: False),
    )
  #(state, child.reserved_id(state.run, a.id))
}

fn stop_parent(runs: store.Store, state: graph.State) {
  let assert Ok(#(stopping, _)) = graph.step(state, graph.Cancel)
  let assert Ok(encoded) = graph_record.encode(stopping)
  let assert Ok(entry) = store.get(runs, state.run)
  let assert Ok(_) =
    store.commit(
      runs,
      state.run,
      entry.revision,
      encoded,
      store.Detached(in_flight: False, seize: False),
    )
  Nil
}

fn worker(model: model.Model) -> agent.Agent(Nil) {
  agent.new("child", model, [], policy.always_allow()) |> support.agent
}

fn child_state(runs, worker, id) {
  let setup = runner.setup(runs, agent.admitted(worker), Nil, None)
  let #(state, effects) = runner.root_state(setup, id, "go")
  #(
    setup,
    controller.State(
      ..state,
      parent: Some(run.GraphParent(support.id("graph-parent"), 1)),
    ),
    effects,
  )
}

pub fn ancestry_follows_mixed_parents_and_checks_both_sides_of_each_link_test() {
  let runs = support.store()
  let #(parent, id) = graph_parent(runs)
  let worker = worker(scripted.model(fn(_) { model.FinalAnswer("done", None) }))
  let #(_, state, _) = child_state(runs, worker, id)
  let action = run.ActionId(1, "delegate")
  let descendant = id <> "-1"
  let state =
    controller.State(
      ..state,
      phase: controller.Acting(1, [
        run.ActionRecord(
          action,
          scripted.call("delegate", "child", "{}"),
          run.Delegated,
          [],
          Some(support.id(descendant)),
        ),
      ]),
    )
  let assert Ok(encoded) = store.encode(runs, state)
  let assert Ok(_) =
    store.insert(
      runs,
      id,
      encoded,
      store.Detached(in_flight: False, seize: False),
    )
  let link = Some(run.AgentParent(support.id(id), action))
  ancestry.read(runs, descendant, link, 64) |> should.equal(Ok(True))
  ancestry.read(runs, id <> "-2", link, 64) |> should.equal(Ok(False))
  ancestry.read(
    runs,
    descendant,
    Some(run.AgentParent(support.id(id), run.ActionId(2, "delegate"))),
    64,
  )
  |> should.equal(Ok(False))
  ancestry.read(runs, descendant, link, 1) |> should.be_error
  stop_parent(runs, parent)
  ancestry.read(runs, descendant, link, 64) |> should.equal(Ok(False))
}

pub fn a_stopped_graph_parent_prevents_the_agents_first_model_call_test() {
  let runs = support.store()
  let #(parent, id) = graph_parent(runs)
  let calls = probe.new()
  let worker =
    worker(
      scripted.model(fn(_) {
        probe.record(calls, "called")
        model.FinalAnswer("done", None)
      }),
    )
  let #(setup, state, effects) = child_state(runs, worker, id)
  stop_parent(runs, parent)
  let assert Ok(_) = runner.launch_new(setup, state, effects)
  let assert Ok(handle) = fabric.open(runs, worker, Nil, support.id(id))
  fabric.await(handle, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
  probe.entries(calls) |> should.equal([])
}

pub fn graph_cancellation_prevents_a_model_retry_test() {
  let runs = support.store()
  let #(parent, id) = graph_parent(runs)
  let calls = probe.new()
  let worker =
    worker(
      model.new(fn(_) {
        probe.record(calls, "called")
        probe.gate(calls, "reply")
        Error(model.ModelError("retry", retryable: True))
      }),
    )
  let #(setup, state, effects) = child_state(runs, worker, id)
  let assert Ok(_) = runner.launch_new(setup, state, effects)
  let first_call = probe.arrival(calls)
  stop_parent(runs, parent)
  probe.release(first_call)
  let assert Ok(handle) = fabric.open(runs, worker, Nil, support.id(id))
  fabric.await(handle, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
  probe.entries(calls) |> should.equal(["called"])
}

pub fn graph_cancellation_refuses_agent_approval_without_starting_its_tool_test() {
  let runs = support.store()
  let #(parent, id) = graph_parent(runs)
  let body = probe.new()
  let worker =
    agent.new(
      "child",
      scripted.plan([scripted.slow("work", "x")]),
      [scripted.gated_tool(body)],
      fn(_: Nil, _) { Ok(policy.RequireApproval(run.Requirement("review", 1))) },
    )
    |> support.agent
  let #(setup, state, effects) = child_state(runs, worker, id)
  let assert Ok(_) = runner.launch_new(setup, state, effects)
  let assert Ok(handle) = fabric.open(runs, worker, Nil, support.id(id))
  let assert Ok(run.Suspended([approval], [])) = fabric.await(handle, 5000)
  stop_parent(runs, parent)
  fabric.approve(handle, approval.reference, None, Nil) |> should.be_error
  probe.entries(body) |> should.equal([])
}

pub fn legacy_writer_refuses_a_graph_attachment_before_inserting_or_calling_test() {
  let runs = support.store()
  let #(_, id) = graph_parent(runs)
  let calls = probe.new()
  let worker =
    worker(
      scripted.model(fn(_) {
        probe.record(calls, "called")
        model.FinalAnswer("done", None)
      }),
    )
  list.each([2, 3, 4], fn(version) {
    let assert Ok(legacy) = store.with_record_version(runs, version)
    let #(setup, state, effects) = child_state(legacy, worker, id)
    runner.launch_new(setup, state, effects) |> should.be_error
    store.get(runs, id) |> should.equal(Error(store.NotFound))
  })
  probe.entries(calls) |> should.equal([])
}

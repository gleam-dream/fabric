//// Cross-runtime ancestry is checked against saved reservations. These
//// fixtures install committed states directly; agent execution and commands
//// then use their ordinary runner and public handles.

import fabric/budget as quota
import fabric/internal/checked_agent
import fabric/internal/graph/attachment

import fabric
import fabric/agent
import fabric/graph/operation
import fabric/internal/ancestry
import fabric/internal/budget/model as budget
import fabric/internal/controller
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record as graph_record
import fabric/internal/runner
import fabric/internal/store as store_core
import fabric/model
import fabric/policy
import fabric/reviewer
import fabric/run
import fabric/store
import fabric/store/backend
import fabric/support
import fabric/support/probe
import fabric/support/scripted
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import sinal/correlation

fn graph_parent(runs: store.Store) -> #(graph.State, String) {
  let assert Ok(#(state, _)) =
    graph.start(
      "graph-parent",
      graph.Definition(run.DefinitionId("parent", 1), "parent-v1", 2),
      "0",
      graph.Prepared(
        "delegate",
        run.DefinitionId("child", 1),
        "0",
        operation.RequireReconciliation,
        operation.Subgraph,
        deadline: None,
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
    store_core.insert(
      runs,
      state.run,
      encoded,
      store_core.Detached(in_flight: False, seize: False),
    )
  #(state, attachment.reserved_id(state.run, a.id))
}

fn stop_parent(runs: store.Store, state: graph.State) {
  let assert Ok(#(stopping, _)) = graph.step(state, graph.Cancel)
  let assert Ok(encoded) = graph_record.encode(stopping)
  let assert Ok(entry) = store_core.get(runs, state.run)
  let assert Ok(_) =
    store_core.commit(
      runs,
      state.run,
      entry.revision,
      encoded,
      store_core.Detached(in_flight: False, seize: False),
    )
  Nil
}

fn worker(model: model.Model) -> agent.Agent(Nil) {
  agent.new("child", model, [], policy.always_allow()) |> support.agent
}

fn child_state(runs, worker, id) {
  let setup = runner.setup(runs, checked_agent.admitted(worker), Nil, None)
  let #(state, effects) =
    runner.root_state(setup, id, "go", correlation.from_key(id))
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
          0,
        ),
      ]),
    )
  let assert Ok(encoded) = store_core.encode(runs, state)
  let assert Ok(_) =
    store_core.insert(
      runs,
      id,
      encoded,
      store_core.Detached(in_flight: False, seize: False),
    )
  let link = Some(run.AgentParent(support.id(id), action))
  ancestry.read(runs, descendant, link, 64) |> should.equal(Ok(True))
  ancestry.family(runs, descendant, link, None, 64)
  |> should.equal(Ok(Some(ancestry.Family(parent.run, 2, None))))
  // This agent's local depth is zero. Family depth still includes its graph
  // attachment, and only the root supplies a declaration.
  let limits =
    quota.limits(work: 8) |> quota.with_children(3) |> quota.with_depth(2)
  let parent =
    graph.State(..parent, family_budget: Some(budget.Declaration(limits, True)))
  let assert Ok(encoded) = graph_record.encode(parent)
  let assert Ok(entry) = store_core.get(runs, parent.run)
  let assert Ok(_) =
    store_core.commit(
      runs,
      parent.run,
      entry.revision,
      encoded,
      store_core.Keep,
    )
  ancestry.family(runs, descendant, link, None, 64)
  |> should.equal(Ok(Some(ancestry.Family(parent.run, 2, Some(limits)))))
  ancestry.family(
    runs,
    descendant,
    link,
    Some(budget.Declaration(limits, True)),
    64,
  )
  |> should.be_error
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
  fabric.await(handle, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
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
        Error(model.error(model.Overloaded, "retry"))
      }),
    )
  let #(setup, state, effects) = child_state(runs, worker, id)
  let assert Ok(_) = runner.launch_new(setup, state, effects)
  let first_call = probe.arrival(calls)
  stop_parent(runs, parent)
  probe.release(first_call)
  let assert Ok(handle) = fabric.open(runs, worker, Nil, support.id(id))
  fabric.await(handle, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
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
  let assert Ok(run.Suspended([approval], [])) =
    fabric.await(handle, within: duration.milliseconds(5000))
  stop_parent(runs, parent)
  fabric.approve(handle, approval.reference, reviewer.new("reviewer"), Nil)
  |> should.be_error
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
    store_core.get(runs, id) |> should.equal(Error(backend.NotFound))
  })
  probe.entries(calls) |> should.equal([])
}

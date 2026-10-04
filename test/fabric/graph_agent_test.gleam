import fabric
import fabric/agent
import fabric/budget
import fabric/graph
import fabric/graph/agent as node
import fabric/graph/child
import fabric/graph/definition
import fabric/internal/graph/attachment
import fabric/internal/store as store_core
import fabric/model
import fabric/policy
import fabric/run
import fabric/store/backend
import fabric/support
import fabric/support/flaky
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn runtime(runs, worker) {
  let assert Ok(runtime) =
    node.new(
      run.DefinitionId("integer-agent", 1),
      worker,
      input: codec.int(),
      prompt: fn(n) { "number: " <> int.to_string(n) },
    )
    |> node.runtime(runs, context: fn(_) { Nil })
  runtime
}

fn parent(runs, runtime) {
  let id = definition.node_id("agent")
  let node =
    definition.node(
      id,
      node.as_operation(runtime),
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let assert Ok(definition) =
    definition.build(
      definition.new(
        run.DefinitionId("parent", 1),
        entry: id,
        nodes: [node],
        state: codec.int(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(1),
    )
  graph.new(definition, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn fixed(text, calls) {
  agent.new(
    "worker",
    scripted.model(fn(_) {
      probe.record(calls, "model")
      model.FinalAnswer(text, None)
    }),
    [],
    policy.always_allow(),
  )
  |> agent.with_answer(codec.int())
  |> support.agent
}

pub fn graph_and_managed_agent_share_one_work_and_child_budget_test() {
  let runs = support.store()
  let calls = probe.new()
  let runtime = runtime(runs, fixed("42", calls))
  let assert Ok(handle) =
    graph.start(
      graph.with_family_budget(
        parent(runs, runtime),
        budget.limits(work: 2)
          |> budget.with_children(1)
          |> budget.with_depth(1),
      ),
      support.id("shared-budget"),
      41,
      correlation: None,
    )
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done |> should.equal(graph.Completed(42))
  probe.entries(calls) |> should.equal(["model"])
  let assert Ok(blocked) =
    graph.start(
      graph.with_family_budget(
        parent(runs, runtime),
        budget.limits(work: 1)
          |> budget.with_children(1)
          |> budget.with_depth(1),
      ),
      support.id("shared-exhausted"),
      41,
      correlation: None,
    )
  let assert Ok(_) = graph.await(blocked, within: duration.milliseconds(5000))
  let assert Ok(agent) = node.child(blocked, 1, runtime)
  let assert Ok(snapshot) = fabric.snapshot(agent)
  snapshot.status
  |> should.equal(
    run.Finished(run.BudgetExhausted(run.FamilyLimit(budget.WorkLimit(1)))),
  )
  probe.entries(calls) |> should.equal(["model"])
}

pub fn a_zero_child_budget_refuses_a_managed_agent_before_creating_it_test() {
  let runs = support.store()
  let calls = probe.new()
  let runtime = runtime(runs, fixed("42", calls))
  let assert Ok(handle) =
    graph.start(
      graph.with_family_budget(
        parent(runs, runtime),
        budget.limits(work: 10)
          |> budget.with_children(0)
          |> budget.with_depth(3),
      ),
      support.id("no-children"),
      41,
      correlation: None,
    )
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done
  |> should.equal(graph.Failed(graph.FamilyBudget(budget.ChildLimit(0))))
  store_core.get(runs, attachment.reserved_id("no-children", 1))
  |> should.equal(Error(backend.NotFound))
  probe.entries(calls) |> should.equal([])
}

pub fn a_graph_owned_agents_delegation_cannot_reset_family_depth_test() {
  let runs = support.store()
  let calls = probe.new()
  let worker = delegating(fixed("42", calls), 3, 3)
  let runtime = runtime(runs, worker)
  let assert Ok(handle) =
    graph.start(
      graph.with_family_budget(
        parent(runs, runtime),
        budget.limits(work: 10)
          |> budget.with_children(3)
          |> budget.with_depth(1),
      ),
      support.id("shared-depth"),
      41,
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(agent) = node.child(handle, 1, runtime)
  let assert Ok(snapshot) = fabric.snapshot(agent)
  snapshot.status
  |> should.equal(
    run.Finished(run.BudgetExhausted(run.FamilyLimit(budget.DepthLimit(1, 2)))),
  )
  let assert [action] = snapshot.actions
  action.state |> should.equal(run.NotStarted)
  let assert Some(child_id) = action.child
  // Cancellation records definite never-started evidence for the refused child.
  store_core.get(runs, run.id_to_string(child_id)) |> should.be_ok
  probe.entries(calls) |> should.equal([])
}

fn reviewed(body) {
  agent.new(
    "worker",
    scripted.model(fn(messages) {
      case scripted.results(messages) {
        [] ->
          model.ToolRequest(
            model.AssistantTurn(
              "",
              [scripted.slow("one", "one"), scripted.slow("two", "two")],
              None,
            ),
            None,
          )
        _ -> model.FinalAnswer("42", None)
      }
    }),
    [scripted.gated_tool(body)],
    fn(_: Nil, _) { Ok(policy.RequireApproval(run.Requirement("review", 1))) },
  )
  |> agent.with_answer(codec.int())
  |> support.agent
}

fn idle(runs, id, left) {
  case restart.runner(runs, id) {
    Error(Nil) -> True
    Ok(_) if left > 0 -> {
      process.sleep(10)
      idle(runs, id, left - 1)
    }
    _ -> False
  }
}

pub fn a_graph_owns_an_ordinary_agent_and_accepts_its_typed_reply_test() {
  let runs = support.store()
  let calls = probe.new()
  let runtime = runtime(runs, fixed("42", calls))
  let assert Ok(handle) =
    graph.start(
      parent(runs, runtime),
      support.id("agent-parent"),
      41,
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Completed(42))
  let assert [receipt] = done.receipts
  receipt.output_json |> should.equal("42")
  let assert Ok(agent) = node.child(handle, receipt.activation, runtime)
  let assert Ok(snapshot) = fabric.snapshot(agent)
  snapshot.parent
  |> should.equal(Some(run.GraphParent(graph.id(handle), receipt.activation)))
  snapshot.transcript
  |> should.equal([
    model.UserMessage("number: 41"),
    model.AssistantMessage(model.AssistantTurn("42", [], None)),
  ])
  let assert Ok(_) = graph.recover(handle)
  probe.entries(calls) |> should.equal(["model"])
}

pub fn every_agent_approval_is_visible_and_wakes_an_idle_graph_test() {
  let runs = support.store()
  let body = probe.new()
  let runtime = runtime(runs, reviewed(body))
  let assert Ok(handle) =
    graph.start(
      parent(runs, runtime),
      support.id("approvals"),
      41,
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(reference, child.AgentInput(approvals, [])) = waiting
  list.length(approvals) |> should.equal(2)
  idle(runs, graph.id(handle), 100) |> should.be_true
  let assert Ok(agent) = node.child(handle, reference.activation, runtime)
  fabric.id(agent) |> should.equal(reference.child)
  list.each(approvals, fn(approval) {
    let assert Ok(_) =
      fabric.approve(
        agent,
        approval.reference,
        support.reviewer("reviewer"),
        Nil,
      )
  })
  probe.release(probe.arrival(body))
  probe.release(probe.arrival(body))
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done |> should.equal(graph.Completed(42))
}

pub fn agent_approval_and_attachment_survive_store_restart_test() {
  let dir = restart.temp_dir()
  let body = probe.new()
  let worker = reviewed(body)
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let runtime = runtime(runs, worker)
      let assert Ok(handle) =
        graph.start(
          parent(runs, runtime),
          support.id("restart-agent"),
          41,
          correlation: None,
        )
      #(runs, handle)
    })
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(reference, child.AgentInput(approvals, [])) = waiting
  idle(runs, graph.id(handle), 100) |> should.be_true
  restart.crash(owner, runs)
  let runs = support.directory(dir)
  let runtime = runtime(runs, worker)
  let handle =
    support.open_graph(parent(runs, runtime), support.id("restart-agent"))
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(agent) = node.child(handle, reference.activation, runtime)
  fabric.id(agent) |> should.equal(reference.child)
  list.each(approvals, fn(approval) {
    let assert Ok(_) =
      fabric.approve(
        agent,
        approval.reference,
        support.reviewer("reviewer"),
        Nil,
      )
  })
  probe.release(probe.arrival(body))
  probe.release(probe.arrival(body))
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done |> should.equal(graph.Completed(42))
  let assert Ok(snapshot) = fabric.snapshot(agent)
  snapshot.turns_used |> should.equal(2)
  restart.remove_dir(dir)
}

pub fn canceling_an_agent_approval_starts_no_tool_and_settles_the_graph_test() {
  let runs = support.store()
  let body = probe.new()
  let runtime = runtime(runs, reviewed(body))
  let assert Ok(handle) =
    graph.start(
      parent(runs, runtime),
      support.id("cancel-agent"),
      41,
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(reference, child.AgentInput(approvals, [])) = waiting
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Cancelled(graph.ChildSettled(reference)))
  let assert Ok(agent) = node.child(handle, reference.activation, runtime)
  fabric.await(agent, within: duration.milliseconds(1000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  list.each(approvals, fn(approval) {
    fabric.approve(agent, approval.reference, support.reviewer("reviewer"), Nil)
    |> should.be_error
  })
  probe.entries(body) |> should.equal([])
  done.receipts |> should.equal([])
}

pub fn an_invalid_agent_reply_is_retained_without_repeating_its_model_test() {
  let runs = support.store()
  let calls = probe.new()
  let runtime = runtime(runs, fixed("not an integer", calls))
  let assert Ok(handle) =
    graph.start(
      parent(runs, runtime),
      support.id("invalid-agent"),
      41,
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(blocked) = graph.snapshot(handle)
  let assert graph.Blocked(_, graph.InvalidResult(output, _)) = blocked.status
  output |> should.equal("not an integer")
  blocked.receipts |> should.equal([])
  let assert Ok(agent) = node.child(handle, 1, runtime)
  // The agent's own run ends on its invalid answer, keeping the text.
  let assert Ok(run.Finished(run.AnswerInvalid(raw: "not an integer", ..))) =
    fabric.await(agent, within: duration.milliseconds(1000))
  let assert Ok(_) = graph.recover(handle)
  probe.entries(calls) |> should.equal(["model"])
}

pub fn agent_handles_and_dispatch_refuse_a_different_store_test() {
  let runs = support.store()
  let other = support.store()
  let calls = probe.new()
  let worker = fixed("42", calls)
  let runtime = runtime(other, worker)
  let assert Ok(handle) =
    graph.start(
      parent(runs, runtime),
      support.id("other-store"),
      41,
      correlation: None,
    )
  let assert Ok(stopped) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Failed(graph.PolicyFailed(_)) = stopped
  probe.entries(calls) |> should.equal([])
  node.child(handle, 1, runtime) |> should.be_error
}

pub fn canceling_a_running_agent_retains_uncertain_tool_effects_test() {
  let runs = support.store()
  let body = probe.new()
  let worker =
    agent.new(
      "worker",
      scripted.plan([scripted.slow("effect", "charge")]),
      [scripted.gated_tool(body)],
      policy.always_allow(),
    )
    |> agent.with_answer(codec.int())
    |> support.agent
  let runtime = runtime(runs, worker)
  let assert Ok(handle) =
    graph.start(
      parent(runs, runtime),
      support.id("cancel-running-agent"),
      41,
      correlation: None,
    )
  let _started = probe.arrival(body)
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(done) = graph.snapshot(handle)
  let assert graph.Cancelled(graph.ChildUnresolved(reference, _)) = done.status
  done.receipts |> should.equal([])
  let assert Ok(agent) = node.child(handle, reference.activation, runtime)
  let assert Ok(snapshot) = fabric.snapshot(agent)
  snapshot.status |> should.equal(run.Finished(run.Cancelled))
  let assert [action] = snapshot.actions
  let assert run.Uncertain(_) = action.state
  probe.entries(body) |> should.equal(["start:charge"])
  let assert Ok(still_cancelled) = graph.recover(handle)
  still_cancelled |> should.equal(done.status)
  // Inspect through the actual store as well: the parent's result is not a
  // manufactured success while the child owns an uncertain operation.
  let assert Ok(_) = store_core.get(runs, run.id_to_string(reference.child))
  let before = snapshot
  let assert Ok(_) =
    fabric.reconcile_stored(
      runs,
      run.ActionRef(reference.child, action.id),
      "charge confirmed",
    )
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(settled) = graph.snapshot(handle)
  settled.status |> should.equal(graph.Cancelled(graph.ChildSettled(reference)))
  settled.value |> should.equal(done.value)
  settled.receipts |> should.equal(done.receipts)
  let assert Ok(after) = fabric.snapshot(agent)
  after.status |> should.equal(before.status)
  after.transcript |> should.equal(before.transcript)
  after.usage |> should.equal(before.usage)
  after.turns_used |> should.equal(before.turns_used)
  probe.entries(body) |> should.equal(["start:charge"])
}

pub fn agent_uncertainty_is_reconciled_in_the_child_before_graph_routing_test() {
  let runs = support.store()
  let effects = probe.new()
  let worker =
    agent.new(
      "worker",
      scripted.model(fn(messages) {
        case scripted.results(messages) {
          [] ->
            model.ToolRequest(
              model.AssistantTurn(
                "",
                [scripted.call("effect", "crash", "{\"x\":\"charge\"}")],
                None,
              ),
              None,
            )
          _ -> model.FinalAnswer("42", None)
        }
      }),
      [scripted.crashing_tool(effects)],
      policy.always_allow(),
    )
    |> agent.with_answer(codec.int())
    |> support.agent
  let runtime = runtime(runs, worker)
  let assert Ok(handle) =
    graph.start(
      parent(runs, runtime),
      support.id("uncertain-agent"),
      41,
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.Child(reference, child.AgentInput([], [uncertain])) =
    waiting.status
  waiting.receipts |> should.equal([])
  let assert Ok(agent) = node.child(handle, reference.activation, runtime)
  let assert Ok(_) = fabric.reconcile(agent, uncertain.reference, "42")
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done |> should.equal(graph.Completed(42))
  probe.entries(effects) |> should.equal(["crash:charge"])
}

fn delegating(child, children, depth) {
  agent.new(
    "delegator",
    scripted.model(fn(messages) {
      case scripted.results(messages) {
        [] ->
          model.ToolRequest(
            model.AssistantTurn(
              "",
              [scripted.call("delegate", "delegate", "41")],
              None,
            ),
            None,
          )
        _ -> model.FinalAnswer("42", None)
      }
    }),
    [],
    policy.always_allow(),
  )
  |> agent.with_sub_agent(
    tool.define("delegate", "Delegate", codec.int(), codec.int()),
    child,
    fn(n) { int.to_string(n) },
  )
  |> agent.with_max_children(children)
  |> agent.with_max_depth(depth)
  |> agent.with_answer(codec.int())
  |> support.agent
}

pub fn canceled_delegated_agent_evidence_survives_restart_and_settles_outward_test() {
  let dir = restart.temp_dir()
  let body = probe.new()
  let leaf =
    agent.new(
      "leaf",
      scripted.plan([scripted.slow("effect", "charge")]),
      [scripted.gated_tool(body)],
      policy.always_allow(),
    )
    |> agent.with_answer(codec.int())
    |> support.agent
  let worker = delegating(delegating(leaf, 1, 2), 1, 2)
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let runtime = runtime(runs, worker)
      let assert Ok(handle) =
        graph.start(
          parent(runs, runtime),
          support.id("cancel-family"),
          41,
          correlation: None,
        )
      #(runs, handle)
    })
  let _started = probe.arrival(body)
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(before) = graph.snapshot(handle)
  let assert graph.Cancelled(graph.ChildUnresolved(reference, _)) =
    before.status
  let leaf_id = support.child_id(support.child_id(reference.child, 1), 1)
  restart.crash(owner, runs)
  let runs = support.directory(dir)
  let runtime = runtime(runs, worker)
  let handle =
    support.open_graph(parent(runs, runtime), support.id("cancel-family"))
  let assert Ok(root) = node.child(handle, reference.activation, runtime)
  let assert Ok(leaf) = fabric.child(root, leaf_id)
  let assert Ok(leaf_before) = fabric.snapshot(leaf)
  let assert [action] = leaf_before.actions
  let assert Ok(_) =
    fabric.reconcile_stored(
      runs,
      run.ActionRef(leaf_id, action.id),
      "charge confirmed",
    )
  // The parent must observe each saved child; a leaf write alone does not
  // claim that the entire family is already settled.
  let assert Ok(unresolved) = graph.recover(handle)
  unresolved |> should.equal(before.status)
  let assert Ok(_) = fabric.settle_stored(runs, reference.child)
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(after) = graph.snapshot(handle)
  after.status |> should.equal(graph.Cancelled(graph.ChildSettled(reference)))
  after.value |> should.equal(before.value)
  after.receipts |> should.equal(before.receipts)
  let assert Ok(root_after) = fabric.snapshot(root)
  root_after.status |> should.equal(run.Finished(run.Cancelled))
  let assert [delegation] = root_after.actions
  delegation.state |> should.equal(run.ChildSettled(run.Cancelled))
  let assert Ok(leaf_after) = fabric.snapshot(leaf)
  leaf_after.transcript |> should.equal(leaf_before.transcript)
  leaf_after.usage |> should.equal(leaf_before.usage)
  leaf_after.turns_used |> should.equal(leaf_before.turns_used)
  probe.entries(body) |> should.equal(["start:charge"])
  restart.remove_dir(dir)
}

fn wrap(runs, inner) {
  let id = definition.node_id("nested")
  let node =
    definition.node(
      id,
      graph.as_subgraph(inner),
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n + 100, n + 100)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("outer", 1),
        entry: id,
        nodes: [node],
        state: codec.int(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(1),
    )
  graph.new(spec, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
}

pub fn nested_graphs_observe_an_agents_own_delegated_family_test() {
  let runs = support.store()
  let body = probe.new()
  let runtime = runtime(runs, delegating(reviewed(body), 1, 1))
  let inner = parent(runs, runtime)
  let assert Ok(handle) =
    graph.start(
      wrap(runs, inner),
      support.id("nested-agent"),
      41,
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(_, child.AgentInput(approvals, [])) = waiting
  list.length(approvals) |> should.equal(2)
  idle(runs, graph.id(handle), 100) |> should.be_true
  let assert Ok(inner_handle) = graph.child(handle, 1, inner)
  idle(runs, graph.id(inner_handle), 100) |> should.be_true
  let assert Ok(agent) = node.child(inner_handle, 1, runtime)
  list.each(approvals, fn(approval) {
    { approval.reference.run != fabric.id(agent) } |> should.be_true
    let assert Ok(_) =
      fabric.approve(
        agent,
        approval.reference,
        support.reviewer("reviewer"),
        Nil,
      )
  })
  probe.release(probe.arrival(body))
  probe.release(probe.arrival(body))
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done |> should.equal(graph.Completed(142))
}

pub fn lost_start_and_completion_acknowledgements_reuse_the_agent_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let calls = probe.new()
  let worker =
    agent.new(
      "worker",
      scripted.model(fn(_) {
        probe.record(calls, "model")
        probe.gate(calls, "reply")
        model.FinalAnswer("42", None)
      }),
      [],
      policy.always_allow(),
    )
    |> agent.with_answer(codec.int())
    |> support.agent
  let runtime = runtime(runs, worker)
  let id = support.id("lost-agent-ack")
  flaky.arm_run(
    backend,
    support.id(attachment.reserved_id(run.id_to_string(id), 1)),
    [flaky.FailAfter],
  )
  let assert Ok(handle) =
    graph.start(parent(runs, runtime), id, 41, correlation: None)
  let reply = probe.arrival(calls)
  flaky.arm_run(backend, id, [flaky.FailAfter])
  probe.release(reply)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Completed(42))
  list.length(done.receipts) |> should.equal(1)
  probe.entries(calls) |> should.equal(["model"])
}

pub fn cancellation_buries_a_reserved_agent_without_calling_prompt_or_context_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let calls = probe.new()
  let worker = fixed("42", calls)
  let runtime = runtime(runs, worker)
  let id = support.id("bury-agent")
  let child_id = attachment.reserved_id(run.id_to_string(id), 1)
  let held = flaky.hold(backend, fn(id) { id == child_id })
  let assert Ok(handle) =
    graph.start(parent(runs, runtime), id, 41, correlation: None)
  let assert Ok(_) = process.receive(held, 5000)
  let other = flaky.store(backend)
  let assert Ok(cancel_runtime) =
    node.new(
      run.DefinitionId("integer-agent", 1),
      worker,
      input: codec.int(),
      prompt: fn(_) { panic as "cancellation called prompt" },
    )
    |> node.runtime(other, context: fn(_) {
      panic as "cancellation called context"
    })
  let canceller = support.open_graph(parent(other, cancel_runtime), id)
  let assert Ok(_) = graph.cancel(canceller)
  let assert Ok(done) =
    graph.await(canceller, within: duration.milliseconds(5000))
  let assert graph.Cancelled(graph.ChildSettled(_)) = done
  flaky.release_held(backend)
  let assert Ok(agent) = node.child(handle, 1, runtime)
  fabric.await(agent, within: duration.milliseconds(1000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  probe.entries(calls) |> should.equal([])
}

pub fn agent_descendants_must_fit_ids_below_a_graph_reservation_test() {
  let runs = support.store()
  let calls = probe.new()
  let leaf = fixed("42", calls)
  let deep =
    list.fold(list.repeat(Nil, 16), leaf, fn(child, _) {
      delegating(child, 999, 16)
    })
  node.new(
    run.DefinitionId("deep", 1),
    deep,
    input: codec.int(),
    prompt: int.to_string,
  )
  |> node.runtime(runs, context: fn(_) { Nil })
  |> should.equal(Error(node.ChildIdsTooLong(134, 128)))
  let narrow =
    list.fold(list.repeat(Nil, 16), leaf, fn(child, _) {
      delegating(child, 1, 16)
    })
  node.new(
    run.DefinitionId("narrow", 1),
    narrow,
    input: codec.int(),
    prompt: int.to_string,
  )
  |> node.runtime(runs, context: fn(_) { Nil })
  |> should.be_ok
}

pub fn canceled_agent_settlement_does_not_call_the_reply_adapter_test() {
  let runs = support.store()
  let calls = probe.new()
  let worker = fixed("not an integer", calls)
  let runtime = runtime(runs, worker)
  let assert Ok(handle) =
    graph.start(
      parent(runs, runtime),
      support.id("settle-invalid-agent"),
      41,
      correlation: None,
    )
  let assert Ok(blocked) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Blocked(_, graph.InvalidResult(_, _)) = blocked
  let assert Ok(cancel_runtime) =
    node.new(
      run.DefinitionId("integer-agent", 1),
      worker,
      input: codec.int(),
      prompt: int.to_string,
    )
    |> node.runtime(runs, context: fn(_) { panic as "settlement called context" })
  let canceller =
    support.open_graph(parent(runs, cancel_runtime), graph.id(handle))
  let assert Ok(_) = graph.cancel(canceller)
  let assert Ok(_) = graph.recover(canceller)
  let assert Ok(done) = graph.snapshot(canceller)
  let assert graph.Cancelled(graph.ChildSettled(_)) = done.status
  done.receipts |> should.equal([])
  done.value |> should.equal(41)
  probe.entries(calls) |> should.equal(["model"])
}

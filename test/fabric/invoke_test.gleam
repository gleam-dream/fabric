import fabric
import fabric/agent
import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/invoke
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/probe
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import json/blueprint/value
import sinal/correlation

fn desk(delay: Int) {
  let model =
    model.new(fn(request) {
      process.sleep(delay)
      let assert [model.UserMessage(prompt), ..] = request.messages
      Ok(model.FinalAnswer(prompt, None))
    })
  agent.new("invoke-desk", model, [], fn(_, _) { Ok(policy.Allow) })
  |> agent.build
  |> should.be_ok
}

fn request(input) {
  invoke.request(Nil, input)
  |> invoke.with_key(Some("order"))
  |> invoke.with_principal("ada")
}

pub fn native_agent_answer_and_retries_keep_first_correlation_test() {
  let runs = support.store()
  let desk = desk(0)
  let service = invoke.agent("desk", runs, desk)
  let first =
    invoke.call(
      service,
      request("hello") |> invoke.with_correlation(correlation.from_key("first")),
    )
  invoke.answer(first) |> should.equal(Some("hello"))
  invoke.response_kind(first) |> should.equal(invoke.Answered)
  let second =
    invoke.call(
      service,
      request("hello") |> invoke.with_correlation(correlation.from_key("retry")),
    )
  invoke.id(second) |> should.equal(invoke.id(first))
  invoke.answer(second) |> should.equal(Some("hello"))
  let handle = fabric.open(runs, desk, Nil, invoke.id(first)) |> should.be_ok
  fabric.snapshot(handle) |> should.be_ok
  fabric.start(
    runs,
    desk,
    id: invoke.id(first),
    context: Nil,
    prompt: "hello",
    correlation: Some(correlation.from_key("first")),
  )
  |> should.equal(Error(fabric.AlreadyStarted(invoke.id(first), True)))
  invoke.call(service, request("different"))
  |> invoke.code
  |> should.equal("key_reused")
}

pub fn principal_and_key_parts_cannot_alias_through_separators_test() {
  let service = invoke.agent("desk", support.store(), desk(0))
  invoke.keyed_id(service, "ada-bob", "order")
  |> should.not_equal(invoke.keyed_id(service, "ada", "bob-order"))
  invoke.keyed_id(service, "ada", "order")
  |> should.not_equal(invoke.keyed_id(service, "bob", "order"))
  invoke.keyed_id(service, "ada\u{0}bob", "order")
  |> should.not_equal(invoke.keyed_id(service, "ada", "bob\u{0}order"))
}

pub fn invalid_bounds_start_no_run_test() {
  let runs = support.store()
  let desk = desk(0)
  let service =
    invoke.agent("desk", runs, desk)
    |> invoke.with_wait(duration.milliseconds(0))
  invoke.check(service)
  |> should.equal(Error(invoke.InvalidWait(0, 1, 4_294_967_295)))
  let response = invoke.call(service, request("hello"))
  invoke.code(response) |> should.equal("invalid_config")
  fabric.open(runs, desk, Nil, invoke.id(response))
  |> should.equal(Error(fabric.RunNotFound))
}

pub fn unkeyed_timeout_commits_cancellation_test() {
  let runs = support.store()
  let desk = desk(200)
  let service =
    invoke.agent("desk", runs, desk)
    |> invoke.with_wait(duration.milliseconds(10))
  let response = invoke.call(service, invoke.request(Nil, "hello"))
  invoke.code(response) |> should.equal("timed_out")
  let handle = fabric.open(runs, desk, Nil, invoke.id(response)) |> should.be_ok
  fabric.await(handle, duration.seconds(1))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
}

pub fn unkeyed_disconnect_cancels_but_keyed_disconnect_preserves_run_test() {
  let runs = support.store()
  let desk = desk(200)
  let service = invoke.agent("desk", runs, desk)
  let gone = process.new_subject()
  process.send(gone, Nil)
  let ending = process.new_selector() |> process.select(gone)
  let response =
    invoke.call(
      service,
      invoke.request(Nil, "hello") |> invoke.with_cancelled(ending),
    )
  invoke.code(response) |> should.equal("cancelled")
  process.send(gone, Nil)
  let response =
    invoke.call(service, request("hello") |> invoke.with_cancelled(ending))
  invoke.answer(response) |> should.equal(Some("hello"))
  process.receive(gone, 0) |> should.equal(Ok(Nil))
}

pub fn keyed_working_retries_complete_the_same_run_test() {
  let service = invoke.agent("desk", support.store(), desk(100))
  let first =
    invoke.call(
      service |> invoke.with_wait(duration.milliseconds(10)),
      request("hello"),
    )
  invoke.code(first) |> should.equal("working")
  let second = invoke.call(service, request("hello"))
  invoke.id(second) |> should.equal(invoke.id(first))
  invoke.answer(second) |> should.equal(Some("hello"))
}

fn runtime(delay: Int, policy) {
  let node = definition.node_id("add")
  let operation =
    operation.new(
      run.DefinitionId("add", 1),
      codec.int(),
      codec.int(),
      fn(_, _, n) {
        process.sleep(delay)
        Ok(n + 1)
      },
      fn(_: Nil) { tool.Explain("impossible") },
    )
  let node =
    definition.node(
      node,
      operation,
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let definition =
    definition.new(
      run.DefinitionId("invoke-graph", 1),
      definition.node_id("add"),
      [node],
      codec.int(),
      codec.int(),
    )
    |> definition.build
    |> should.be_ok
  graph.new(definition, support.store(), fn(_) { Nil }, policy)
  |> graph.build
  |> should.be_ok
}

pub fn graph_native_answer_and_retry_compare_initial_not_current_state_test() {
  let runtime = runtime(0, fn(_, _) { Ok(policy.Allow) })
  let service = invoke.graph("add", runtime)
  let first =
    invoke.call(
      service,
      request(1) |> invoke.with_correlation(correlation.from_key("first")),
    )
  invoke.answer(first) |> should.equal(Some(2))
  let second =
    invoke.call(
      service,
      request(1) |> invoke.with_correlation(correlation.from_key("retry")),
    )
  invoke.id(second) |> should.equal(invoke.id(first))
  invoke.answer(second) |> should.equal(Some(2))
  invoke.call(service, request(2)) |> invoke.code |> should.equal("key_reused")
}

pub fn graph_unkeyed_disconnect_cancels_test() {
  let runtime = runtime(200, fn(_, _) { Ok(policy.Allow) })
  let service = invoke.graph("add", runtime)
  let gone = process.new_subject()
  process.send(gone, Nil)
  let ending = process.new_selector() |> process.select(gone)
  let response =
    invoke.call(
      service,
      invoke.request(Nil, 1) |> invoke.with_cancelled(ending),
    )
  let handle = graph.open(runtime, invoke.id(response)) |> should.be_ok
  let status = graph.await(handle, duration.seconds(1)) |> should.be_ok
  graph.status_kind(status) |> should.equal(graph.Ended)
  case invoke.response_kind(response) {
    invoke.OutcomeUnknown -> {
      let assert graph.Cancelled(graph.Unresolved(_, _)) = status
      Nil
    }
    _ -> invoke.code(response) |> should.equal("cancelled")
  }
}

pub fn graph_keyed_working_then_retry_test() {
  let service = invoke.graph("add", runtime(100, fn(_, _) { Ok(policy.Allow) }))
  let first =
    invoke.call(
      service |> invoke.with_wait(duration.milliseconds(10)),
      request(1),
    )
  invoke.code(first) |> should.equal("working")
  let second = invoke.call(service, request(1))
  invoke.answer(second) |> should.equal(Some(2))
  invoke.id(second) |> should.equal(invoke.id(first))
}

pub fn graph_policy_failure_is_an_ended_response_test() {
  let service =
    invoke.graph("add", runtime(0, fn(_, _) { Ok(policy.Deny("no")) }))
  invoke.call(service, request(1))
  |> invoke.response_kind
  |> should.equal(invoke.Ended)
}

pub fn logical_action_keys_frame_parts_and_ignore_retry_context_test() {
  let call =
    tool.Call(
      support.id("r-1"),
      run.ActionId(2, "c"),
      correlation.from_key("first"),
    )
  let alias =
    tool.Call(
      support.id("r"),
      run.ActionId(1, "2-c"),
      correlation.from_key("first"),
    )
  tool.idempotency_key(call) |> should.not_equal(tool.idempotency_key(alias))
  tool.idempotency_key(call)
  |> should.equal(tool.idempotency_key(
    tool.Call(..call, correlation: correlation.from_key("retry")),
  ))
  let invocation =
    operation.Invocation(support.id("r"), 1, 1, correlation.from_key("first"))
  operation.idempotency_key(invocation)
  |> should.equal(operation.idempotency_key(
    operation.Invocation(..invocation, attempt: 2),
  ))
}

fn operation_runtime(runs, name, operation) {
  let node =
    definition.node(
      definition.node_id("effect"),
      operation,
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let spec =
    definition.new(
      run.DefinitionId(name, 1),
      definition.node_id("effect"),
      [node],
      codec.int(),
      codec.int(),
    )
    |> definition.build
    |> should.be_ok
  graph.new(spec, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
  |> graph.build
  |> should.be_ok
}

fn held_operation(barrier) {
  operation.new(
    run.DefinitionId("held-effect", 1),
    codec.int(),
    codec.int(),
    fn(_, _, n) {
      probe.gate(barrier, "started")
      Ok(n)
    },
    fn(_: Nil) { tool.Explain("impossible") },
  )
}

pub fn cancelled_graph_reopen_preserves_unresolved_evidence_test() {
  let barrier = probe.new()
  let runtime =
    operation_runtime(support.store(), "held", held_operation(barrier))
  let service = invoke.graph("held", runtime)
  let id = invoke.keyed_id(service, "ada", "order")
  let handle = graph.start(runtime, id, 1, correlation: None) |> should.be_ok
  let _ = probe.arrival(barrier)
  graph.cancel(handle) |> should.be_ok
  let assert graph.Cancelled(graph.Unresolved(
    _,
    graph.EffectUncertain(evidence),
  )) = graph.await(handle, duration.seconds(5)) |> should.be_ok
  let response = invoke.call(service, request(1))
  invoke.response_kind(response) |> should.equal(invoke.OutcomeUnknown)
  let assert value.Object(fields) = invoke.details(response)
  list.key_find(fields, "evidence") |> should.equal(Ok(value.String(evidence)))
}

pub fn child_cancellation_reopen_preserves_reconciliation_evidence_test() {
  let runs = support.store()
  let barrier = probe.new()
  let child = operation_runtime(runs, "child", held_operation(barrier))
  let runtime = operation_runtime(runs, "parent", graph.as_subgraph(child))
  let service = invoke.graph("parent", runtime)
  let handle =
    graph.start(
      runtime,
      invoke.keyed_id(service, "ada", "order"),
      1,
      correlation: None,
    )
    |> should.be_ok
  let _ = probe.arrival(barrier)
  graph.cancel(handle) |> should.be_ok
  let assert graph.Cancelled(graph.ChildUnresolved(reference, _)) =
    graph.await(handle, duration.seconds(5)) |> should.be_ok
  let response = invoke.call(service, request(1))
  invoke.response_kind(response) |> should.equal(invoke.OutcomeUnknown)
  let assert value.Object(fields) = invoke.details(response)
  list.key_find(fields, "child_run_id")
  |> should.equal(Ok(value.String(run.id_to_string(reference.child))))
  list.key_find(fields, "termination")
  |> should.equal(Ok(value.String("cancelled")))
}

pub fn expired_child_reopen_preserves_reconciliation_evidence_test() {
  let runs = support.store()
  let barrier = probe.new()
  let child = operation_runtime(runs, "child", held_operation(barrier))
  let runtime =
    operation_runtime(
      runs,
      "parent",
      graph.as_subgraph(child)
        |> operation.with_deadline(run.After(duration.milliseconds(500))),
    )
  let service = invoke.graph("parent", runtime)
  let handle =
    graph.start(
      runtime,
      invoke.keyed_id(service, "ada", "order"),
      1,
      correlation: None,
    )
    |> should.be_ok
  let _ = probe.arrival(barrier)
  let assert graph.Expired(_, graph.ChildUnresolved(reference, _)) =
    graph.await(handle, duration.seconds(5)) |> should.be_ok
  let response = invoke.call(service, request(1))
  invoke.response_kind(response) |> should.equal(invoke.OutcomeUnknown)
  let assert value.Object(fields) = invoke.details(response)
  list.key_find(fields, "child_run_id")
  |> should.equal(Ok(value.String(run.id_to_string(reference.child))))
  list.key_find(fields, "termination")
  |> should.equal(Ok(value.String("expired")))
}

pub fn settled_graph_cancellation_reopen_remains_ended_test() {
  let runtime =
    runtime(0, fn(_, _) {
      Ok(policy.RequireApproval(run.Requirement("permission", 1)))
    })
  let service = invoke.graph("approval", runtime)
  let handle =
    graph.start(
      runtime,
      invoke.keyed_id(service, "ada", "order"),
      1,
      correlation: None,
    )
    |> should.be_ok
  let assert graph.AwaitingApproval(_) =
    graph.await(handle, duration.seconds(5)) |> should.be_ok
  graph.cancel(handle) |> should.be_ok
  let response = invoke.call(service, request(1))
  invoke.response_kind(response) |> should.equal(invoke.Ended)
  invoke.code(response) |> should.equal("cancelled")
}

pub fn completion_between_disconnect_and_cancellation_retains_the_answer_test() {
  let disconnected = process.new_subject()
  let operation =
    operation.new(
      run.DefinitionId("racing-answer", 1),
      codec.int(),
      codec.int(),
      fn(_, call: operation.Invocation, n) {
        let finish = process.new_subject()
        process.send(disconnected, #(call.run, finish))
        let assert Ok(Nil) = process.receive(finish, 5000)
        Ok(n + 1)
      },
      fn(_: Nil) { tool.Explain("impossible") },
    )
  let runtime = operation_runtime(support.store(), "race", operation)
  let cancelled =
    process.new_selector()
    |> process.select_map(disconnected, fn(message) {
      let #(id, finish) = message
      process.send(finish, Nil)
      let handle = graph.open(runtime, id) |> should.be_ok
      graph.await(handle, duration.seconds(5))
      |> should.equal(Ok(graph.Completed(2)))
      Nil
    })
  let response =
    invoke.call(
      invoke.graph("race", runtime),
      invoke.request(Nil, 1) |> invoke.with_cancelled(cancelled),
    )
  invoke.response_kind(response) |> should.equal(invoke.Answered)
  invoke.answer(response) |> should.equal(Some(2))
}

pub fn cancelled_agent_reopen_preserves_unresolved_effects_test() {
  let runs = support.store()
  let worker =
    agent.new(
      "uncertain-agent",
      scripted.plan([scripted.call("charge", "crash", "{\"x\":\"charge\"}")]),
      [scripted.crashing_tool(probe.new())],
      fn(_, _) { Ok(policy.Allow) },
    )
    |> agent.build
    |> should.be_ok
  let service = invoke.agent("uncertain", runs, worker)
  let id = invoke.keyed_id(service, "ada", "order")
  let handle =
    fabric.start(runs, worker, id, Nil, "charge", correlation: None)
    |> should.be_ok
  let assert run.Suspended([], [_]) =
    fabric.await(handle, duration.seconds(5)) |> should.be_ok
  fabric.cancel(handle) |> should.be_ok
  let response = invoke.call(service, request("charge"))
  invoke.response_kind(response) |> should.equal(invoke.OutcomeUnknown)
  let assert value.Object(fields) = invoke.details(response)
  let assert Ok(value.Array([value.Object(effect)])) =
    list.key_find(fields, "uncertain")
  list.key_find(effect, "tool") |> should.equal(Ok(value.String("crash")))
}

pub fn agent_completion_between_disconnect_and_cancellation_retains_the_answer_test() {
  let disconnected = process.new_subject()
  let worker =
    agent.new(
      "race-agent",
      model.new(fn(call) {
        let finish = process.new_subject()
        process.send(disconnected, #(call.run, finish))
        let assert Ok(Nil) = process.receive(finish, 5000)
        Ok(model.FinalAnswer("done", None))
      }),
      [],
      fn(_, _) { Ok(policy.Allow) },
    )
    |> agent.build
    |> should.be_ok
  let runs = support.store()
  let cancelled =
    process.new_selector()
    |> process.select_map(disconnected, fn(message) {
      let #(id, finish) = message
      process.send(finish, Nil)
      let handle = fabric.open(runs, worker, Nil, id) |> should.be_ok
      fabric.await(handle, duration.seconds(5))
      |> should.equal(Ok(run.Finished(run.Completed("done"))))
      Nil
    })
  let response =
    invoke.call(
      invoke.agent("race", runs, worker),
      invoke.request(Nil, "go") |> invoke.with_cancelled(cancelled),
    )
  invoke.response_kind(response) |> should.equal(invoke.Answered)
  invoke.answer(response) |> should.equal(Some("done"))
}

pub fn direct_graph_cancellation_retains_acknowledged_uncertainty_test() {
  let disconnected = process.new_subject()
  let evidence = "the remote effect may have committed before disconnect"
  let operation =
    operation.new(
      run.DefinitionId("uncertain-on-disconnect", 1),
      codec.int(),
      codec.int(),
      fn(_, call: operation.Invocation, _) {
        let finish = process.new_subject()
        process.send(disconnected, #(call.run, finish))
        let assert Ok(Nil) = process.receive(finish, 5000)
        Error(evidence)
      },
      tool.Uncertain,
    )
  let runtime = operation_runtime(support.store(), "direct-cancel", operation)
  let cancelled =
    process.new_selector()
    |> process.select_map(disconnected, fn(message) {
      let #(id, finish) = message
      // Disconnect arrives while the operation is in flight. Its uncertainty
      // commits before cancellation, so the native cancellation is settled.
      process.send(finish, Nil)
      let handle = graph.open(runtime, id) |> should.be_ok
      let assert graph.Blocked(_, graph.EffectUncertain(saved)) =
        graph.await(handle, duration.seconds(5)) |> should.be_ok
      saved |> should.equal(evidence)
      Nil
    })
  let response =
    invoke.call(
      invoke.graph("direct", runtime),
      invoke.request(Nil, 1) |> invoke.with_cancelled(cancelled),
    )
  invoke.response_kind(response) |> should.equal(invoke.OutcomeUnknown)
  let assert value.Object(fields) = invoke.details(response)
  list.key_find(fields, "evidence") |> should.equal(Ok(value.String(evidence)))
  list.key_find(fields, "termination")
  |> should.equal(Ok(value.String("cancelled")))
  let handle = graph.open(runtime, invoke.id(response)) |> should.be_ok
  let assert graph.Cancelled(graph.Unresolved(_, graph.EffectUncertain(saved))) =
    graph.await(handle, duration.seconds(5)) |> should.be_ok
  saved |> should.equal(evidence)
}

pub fn completed_agent_keeps_its_answer_after_historical_reconciliation_test() {
  let runs = support.store()
  let worker =
    agent.new(
      "reconciled-agent",
      scripted.plan([scripted.call("charge", "crash", "{\"x\":\"charge\"}")]),
      [scripted.crashing_tool(probe.new())],
      fn(_, _) { Ok(policy.Allow) },
    )
    |> agent.build
    |> should.be_ok
  let service = invoke.agent("reconciled", runs, worker)
  let id = invoke.keyed_id(service, "ada", "order")
  let handle =
    fabric.start(runs, worker, id, Nil, "charge", correlation: None)
    |> should.be_ok
  let assert run.Suspended([], [effect]) =
    fabric.await(handle, duration.seconds(5)) |> should.be_ok
  fabric.reconcile(handle, effect.reference, "confirmed") |> should.be_ok
  fabric.await(handle, duration.seconds(5))
  |> should.equal(Ok(run.Finished(run.Completed("final: confirmed"))))
  let snapshot = fabric.snapshot(handle) |> should.be_ok
  let assert [action] = snapshot.actions
  action.state |> should.equal(run.Reconciled("confirmed"))
  let response = invoke.call(service, request("charge"))
  invoke.response_kind(response) |> should.equal(invoke.Answered)
  invoke.answer(response) |> should.equal(Some("final: confirmed"))
}

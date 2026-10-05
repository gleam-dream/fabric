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
import fabric/tool
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
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
  invoke.code(response) |> should.equal("cancelled")
  let handle = graph.open(runtime, invoke.id(response)) |> should.be_ok
  let status = graph.await(handle, duration.seconds(1)) |> should.be_ok
  graph.status_kind(status) |> should.equal(graph.Ended)
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

import fabric/graph
import fabric/graph/definition
import fabric/graph/llm
import fabric/graph/operation
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/restart
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import llm_wire/config
import llm_wire/provider/openai
import llm_wire/testing
import llm_wire/types

fn decision_codec() -> codec.Codec(Bool) {
  codec.field("approve", codec.bool())
}

fn runtime(
  runs: store.Store,
  script: testing.Script,
) -> graph.Runtime(Nil, String, llm.Receipt(Bool)) {
  runtime_with(runs, decision(testing.config(script)), fn(_, _) {
    Ok(policy.Allow)
  })
}

fn decision(
  settings: config.Config,
) -> operation.Operation(Nil, String, llm.Receipt(Bool)) {
  let assert Ok(model) = types.model_id("review-model")
  llm.new(
    run.Identity("structured-review", 1),
    codec.string(),
    decision_codec(),
    "review",
    fn(_, text) {
      #(settings, types.new_request(model, [types.UserMessage(text)]))
    },
  )
}

fn runtime_with(
  runs: store.Store,
  op: operation.Operation(Nil, String, llm.Receipt(Bool)),
  policy: graph.Policy(Nil),
) -> graph.Runtime(Nil, String, llm.Receipt(Bool)) {
  let assert Ok(id) = definition.node_id("review")
  let node =
    definition.node(
      id,
      op,
      fn(text) { Ok(text) },
      fn(state, receipt) { Ok(definition.Finish(state, receipt)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("decision-graph", 1),
      id,
      [node],
      codec.string(),
      llm.receipt_codec(decision_codec()),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, policy)
}

pub fn a_structured_decision_retains_native_answer_raw_output_and_usage_test() {
  let raw = "{\"approve\": true}"
  let usage = types.Usage(7, 3, 10)
  let script = testing.start([testing.text(raw) |> testing.with_usage(usage)])
  let runtime = runtime(support.store(), script)
  let assert Ok(handle) =
    graph.start(runtime, support.id("decision"), "review this")
  let assert Ok(done) = graph.await(handle, 5000)
  done.status
  |> should.equal(
    graph.Completed(llm.Receipt(
      "review-model",
      llm.Answer(True, raw),
      Some(usage),
    )),
  )
  let assert [saved] = done.receipts
  codec.decode_json(llm.receipt_codec(decision_codec()), saved.output_json)
  |> should.equal(
    Ok(llm.Receipt("review-model", llm.Answer(True, raw), Some(usage))),
  )
  let assert [sent] = testing.requests(script)
  sent.request.messages |> should.equal([types.UserMessage("review this")])
  testing.remaining(script) |> should.equal(0)
}

pub fn saved_structured_receipt_is_reused_after_store_process_loss_test() {
  let dir = restart.temp_dir()
  let script = testing.start([testing.text("{\"approve\":false}")])
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let assert Ok(handle) =
        graph.start(
          runtime(runs, script),
          support.id("saved-decision"),
          "draft",
        )
      #(runs, handle)
    })
  let assert Ok(before) = graph.await(handle, 5000)
  let assert graph.Completed(_) = before.status
  restart.crash(owner, runs)
  let restored =
    graph.attach(
      runtime(support.directory(dir), script),
      support.id("saved-decision"),
    )
  let assert Ok(after) = graph.recover(restored)
  after.status |> should.equal(before.status)
  after.receipts |> should.equal(before.receipts)
  list.length(testing.requests(script)) |> should.equal(1)
  restart.remove_dir(dir)
}

pub fn policy_approval_precedes_the_provider_request_test() {
  let script = testing.start([testing.text("{\"approve\":true}")])
  let runtime =
    runtime_with(
      support.store(),
      decision(testing.config(script)),
      fn(_, action) {
        action.operation |> should.equal(run.Identity("structured-review", 1))
        Ok(policy.RequireApproval(run.Requirement("external-model", 1)))
      },
    )
  let assert Ok(handle) =
    graph.start(runtime, support.id("approval-decision"), "draft")
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingApproval(approval) = waiting.status
  testing.requests(script) |> should.equal([])
  graph.approve(handle, approval) |> should.be_ok
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Completed(_) = done.status
  list.length(testing.requests(script)) |> should.equal(1)
}

pub fn refusal_and_output_limit_are_distinct_from_a_valid_answer_test() {
  let usage = types.Usage(5, 2, 7)
  [
    #(
      testing.refusal("cannot review") |> testing.with_usage(usage),
      llm.Refusal("cannot review"),
      Some(usage),
    ),
    #(
      testing.output_limited("{\"approve\":"),
      llm.OutputLimited("{\"approve\":"),
      None,
    ),
  ]
  |> list.each(fn(example) {
    let script = testing.start([example.0])
    let assert Ok(handle) =
      graph.start(
        runtime(support.store(), script),
        support.id("non-answer"),
        "draft",
      )
    let assert Ok(done) = graph.await(handle, 5000)
    done.status
    |> should.equal(
      graph.Completed(llm.Receipt("review-model", example.1, example.2)),
    )
    let assert [saved] = done.receipts
    codec.decode_json(llm.receipt_codec(decision_codec()), saved.output_json)
    |> should.equal(Ok(llm.Receipt("review-model", example.1, example.2)))
  })
}

pub fn invalid_output_interrupted_transport_and_http_failures_never_route_or_retry_test() {
  [
    #(testing.text("{\"approve\":\"yes\"}"), "OutputValidationError"),
    #(testing.Interrupted([]), "TransportError"),
    #(testing.Status(429, "private response body"), "HTTP status 429"),
  ]
  |> list.each(fn(example) {
    let script = testing.start([example.0, testing.text("{\"approve\":true}")])
    let assert Ok(handle) =
      graph.start(
        runtime(support.store(), script),
        support.id("invalid-decision"),
        "draft",
      )
    let assert Ok(blocked) = graph.await(handle, 5000)
    let assert graph.Blocked(_, graph.EffectUncertain(detail)) = blocked.status
    string.contains(detail, example.1) |> should.be_true
    string.contains(detail, "private response body") |> should.be_false
    blocked.receipts |> should.equal([])
    graph.recover(handle) |> should.be_ok
    list.length(testing.requests(script)) |> should.equal(1)
    testing.remaining(script) |> should.equal(1)
  })
}

pub fn tool_catalog_is_rejected_before_network_io_test() {
  let script = testing.start([testing.text("{\"approve\":true}")])
  let assert Ok(model) = types.model_id("review-model")
  let assert Ok(name) = types.tool_name("lookup")
  let assert Ok(tool) =
    types.tool_from_codec(name, "lookup", codec.field("query", codec.string()))
  let op =
    llm.new(
      run.Identity("structured-review", 1),
      codec.string(),
      decision_codec(),
      "review",
      fn(_, text) {
        #(
          testing.config(script),
          types.new_request(model, [types.UserMessage(text)])
            |> types.with_tools([tool]),
        )
      },
    )
  let runtime = runtime_with(support.store(), op, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) =
    graph.start(runtime, support.id("tools-decision"), "draft")
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Failed(graph.OperationFailed(detail)) = done.status
  string.contains(detail, "cannot declare tools") |> should.be_true
  done.receipts |> should.equal([])
  testing.requests(script) |> should.equal([])
}

pub fn preparation_and_proven_unsent_failures_are_definite_test() {
  let script = testing.start([])
  let invalid =
    config.with_deadlines(testing.config(script), types.Deadlines(0, 1, 1))
  [invalid, testing.config(script)]
  |> list.each(fn(settings) {
    let runtime =
      runtime_with(support.store(), decision(settings), fn(_, _) {
        Ok(policy.Allow)
      })
    let assert Ok(handle) =
      graph.start(runtime, support.id("unsent-decision"), "draft")
    let assert Ok(done) = graph.await(handle, 5000)
    let assert graph.Failed(graph.OperationFailed(_)) = done.status
    done.receipts |> should.equal([])
  })
  // The second request reached the script but no transport was opened.
  list.length(testing.requests(script)) |> should.equal(1)
}

pub fn receipt_codec_rejects_changed_contracts_corruption_and_mismatched_native_values_test() {
  let codec = llm.receipt_codec(decision_codec())
  let good =
    llm.Receipt(
      "review-model",
      llm.Answer(True, "{\"approve\":true}"),
      Some(types.Usage(2, 1, 3)),
    )
  let assert Ok(saved) = codec.encode_json(codec, good)
  codec.encode_json(
    codec,
    llm.Receipt(..good, outcome: llm.Answer(False, "{\"approve\":true}")),
  )
  |> should.be_error
  codec.encode_json(codec, llm.Receipt(..good, model: "")) |> should.be_error
  codec.encode_json(
    codec,
    llm.Receipt(..good, usage: Some(types.Usage(-1, 1, 0))),
  )
  |> should.be_error
  codec.decode_json(
    codec,
    string.replace(saved, "fabric.graph.llm.v1", "fabric.graph.llm.v2"),
  )
  |> should.be_error
  codec.decode_json(
    codec,
    string.replace(saved, "\"answer\"", "\"unexpected\""),
  )
  |> should.be_error
  codec.decode_json(codec, string.replace(saved, "[2,[1,3]]", "[-1,[1,3]]"))
  |> should.be_error
  codec.decode_json(
    llm.receipt_codec(codec.field("approve", codec.string())),
    saved,
  )
  |> should.be_error
}

pub fn openai_projection_uses_the_output_schema_and_preserves_actual_sse_usage_test() {
  let script =
    testing.start([
      testing.Events([
        "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"msg\",\"type\":\"message\"}}\n\n"
        <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"msg\",\"delta\":\"{\\\"approve\\\":true}\"}\n\n"
        <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"msg\",\"type\":\"message\"}}\n\n"
        <> "event: response.completed\ndata: {\"response\":{\"id\":\"r1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":4,\"total_tokens\":14}}}\n\n",
      ]),
    ])
  let assert Ok(key) = types.api_key("sk-scripted")
  let settings =
    config.openai(openai.options(key)) |> testing.with_script(script)
  let runtime =
    runtime_with(support.store(), decision(settings), fn(_, _) {
      Ok(policy.Allow)
    })
  let assert Ok(handle) =
    graph.start(runtime, support.id("openai-decision"), "draft")
  let assert Ok(done) = graph.await(handle, 5000)
  done.status
  |> should.equal(
    graph.Completed(llm.Receipt(
      "review-model",
      llm.Answer(True, "{\"approve\":true}"),
      Some(types.Usage(10, 4, 14)),
    )),
  )
  let assert [sent] = testing.requests(script)
  string.contains(sent.body, "json_schema") |> should.be_true
  string.contains(sent.body, "\"approve\"") |> should.be_true
  string.contains(sent.body, "fabric.graph.llm") |> should.be_false
}

import fabric/graph
import fabric/graph/definition
import fabric/graph/llm
import fabric/graph/operation
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/codecs
import fabric/support/fake_provider
import fabric/support/restart
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/config as http_config
import http_gun/testing as http_testing
import json/blueprint/codec
import llm_wire
import llm_wire/message
import llm_wire/testing
import llm_wire/tool

fn decision_codec() -> codec.Codec(Bool) {
  codecs.one_field("approve", codec.bool())
}

fn runtime(
  runs: store.Store,
  fake: fake_provider.Fake,
) -> graph.Runtime(Nil, String, llm.Receipt(Bool)) {
  runtime_with(
    runs,
    decision(fake.client, fake_provider.scripted(fake)),
    fn(_, _) { Ok(policy.Allow) },
  )
}

fn decision(
  client: http_gun.Client,
  settings: llm_wire.Config,
) -> operation.Operation(Nil, String, llm.Receipt(Bool)) {
  llm.decision(
    run.DefinitionId("structured-review", 1),
    input: codec.string(),
    output: decision_codec(),
    name: "review",
    call: fn(_, text) {
      llm.call(
        client: client,
        config: settings,
        request: llm_wire.request("review-model", [llm_wire.user(text)]),
      )
    },
  )
}

/// The (role, content) pairs a scripted request carries.
fn messages(body: String) -> List(#(String, String)) {
  let message = {
    use role <- decode.field("role", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(#(role, content))
  }
  let assert Ok(messages) =
    json.parse(body, decode.at(["messages"], decode.list(message)))
  messages
}

fn runtime_with(
  runs: store.Store,
  op: operation.Operation(Nil, String, llm.Receipt(Bool)),
  policy: policy.Policy(Nil),
) -> graph.Runtime(Nil, String, llm.Receipt(Bool)) {
  let id = definition.node_id("review")
  let node =
    definition.node(
      id,
      op,
      fn(text) { Ok(text) },
      fn(state, receipt) { Ok(definition.Finish(state, receipt)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("decision-graph", 1),
        entry: id,
        nodes: [node],
        state: codec.string(),
        answer: llm.receipt_codec(decision_codec()),
      )
      |> definition.with_max_activations(1),
    )
  graph.new(spec, runs, fn(_) { Nil }, policy)
}

pub fn a_structured_decision_retains_native_answer_raw_output_and_usage_test() {
  let raw = "{\"approve\": true}"
  let usage = message.Usage(7, 3, 10)
  let fake =
    fake_provider.start([testing.text(raw) |> testing.with_usage(usage)])
  let runtime = runtime(support.store(), fake)
  let assert Ok(handle) =
    graph.start(
      runtime,
      support.id("decision"),
      "review this",
      correlation: None,
    )
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
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
  let assert [sent] = fake_provider.bodies(fake)
  messages(sent) |> should.equal([#("user", "review this")])
  fake_provider.remaining(fake) |> should.equal(0)
  fake_provider.stop(fake)
}

pub fn saved_structured_receipt_is_reused_after_store_process_loss_test() {
  let dir = restart.temp_dir()
  let fake = fake_provider.start([testing.text("{\"approve\":false}")])
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let assert Ok(handle) =
        graph.start(
          runtime(runs, fake),
          support.id("saved-decision"),
          "draft",
          correlation: None,
        )
      #(runs, handle)
    })
  let assert Ok(before) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Completed(_) = before.status
  restart.crash(owner, runs)
  let restored =
    support.open_graph(
      runtime(support.directory(dir), fake),
      support.id("saved-decision"),
    )
  let assert Ok(after) = graph.recover(restored)
  after.status |> should.equal(before.status)
  after.receipts |> should.equal(before.receipts)
  list.length(fake_provider.bodies(fake)) |> should.equal(1)
  fake_provider.stop(fake)
  restart.remove_dir(dir)
}

pub fn policy_approval_precedes_the_provider_request_test() {
  let fake = fake_provider.start([testing.text("{\"approve\":true}")])
  let runtime =
    runtime_with(
      support.store(),
      decision(fake.client, fake_provider.scripted(fake)),
      fn(_, action) {
        support.operation(action)
        |> should.equal(run.DefinitionId("structured-review", 1))
        Ok(policy.RequireApproval(run.Requirement("external-model", 1)))
      },
    )
  let assert Ok(handle) =
    graph.start(
      runtime,
      support.id("approval-decision"),
      "draft",
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingApproval(approval) = waiting.status
  fake_provider.bodies(fake) |> should.equal([])
  graph.approve(
    handle,
    approval,
    reviewer: support.reviewer("reviewer"),
    context: Nil,
  )
  |> should.be_ok
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Completed(_) = done.status
  list.length(fake_provider.bodies(fake)) |> should.equal(1)
  fake_provider.stop(fake)
}

pub fn refusal_and_output_limit_are_distinct_from_a_valid_answer_test() {
  let usage = message.Usage(5, 2, 7)
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
    let fake = fake_provider.start([example.0])
    let assert Ok(handle) =
      graph.start(
        runtime(support.store(), fake),
        support.id("non-answer"),
        "draft",
        correlation: None,
      )
    let assert Ok(done) =
      graph.await(handle, within: duration.milliseconds(5000))
    done.status
    |> should.equal(
      graph.Completed(llm.Receipt("review-model", example.1, example.2)),
    )
    let assert [saved] = done.receipts
    codec.decode_json(llm.receipt_codec(decision_codec()), saved.output_json)
    |> should.equal(Ok(llm.Receipt("review-model", example.1, example.2)))
    fake_provider.stop(fake)
  })
}

pub fn invalid_output_interrupted_transport_and_http_failures_never_route_or_retry_test() {
  [
    #(testing.text("{\"approve\":\"yes\"}"), "Invalid structured output"),
    #(testing.Interrupted([]), "HTTP failure: Request failed"),
    #(testing.Status(429, "private response body"), "HTTP status 429"),
  ]
  |> list.each(fn(example) {
    let fake =
      fake_provider.start([example.0, testing.text("{\"approve\":true}")])
    let assert Ok(handle) =
      graph.start(
        runtime(support.store(), fake),
        support.id("invalid-decision"),
        "draft",
        correlation: None,
      )
    let assert Ok(blocked) =
      graph.await(handle, within: duration.milliseconds(5000))
    let assert graph.Blocked(_, graph.EffectUncertain(detail)) = blocked.status
    string.contains(detail, example.1) |> should.be_true
    string.contains(detail, "private response body") |> should.be_false
    blocked.receipts |> should.equal([])
    graph.recover(handle) |> should.be_ok
    list.length(fake_provider.bodies(fake)) |> should.equal(1)
    fake_provider.remaining(fake) |> should.equal(1)
    fake_provider.stop(fake)
  })
}

pub fn tool_catalog_is_rejected_before_network_io_test() {
  let fake = fake_provider.start([testing.text("{\"approve\":true}")])
  let tool =
    tool.new("lookup", "lookup", codecs.one_field("query", codec.string()))
  let op =
    llm.decision(
      run.DefinitionId("structured-review", 1),
      input: codec.string(),
      output: decision_codec(),
      name: "review",
      call: fn(_, text) {
        llm.call(
          client: fake.client,
          config: fake_provider.scripted(fake),
          request: llm_wire.request("review-model", [llm_wire.user(text)])
            |> llm_wire.with_tools([tool]),
        )
      },
    )
  let runtime = runtime_with(support.store(), op, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) =
    graph.start(
      runtime,
      support.id("tools-decision"),
      "draft",
      correlation: None,
    )
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Failed(graph.OperationFailed(detail)) = done.status
  string.contains(detail, "cannot declare tools") |> should.be_true
  done.receipts |> should.equal([])
  fake_provider.bodies(fake) |> should.equal([])
  fake_provider.stop(fake)
}

pub fn preparation_and_proven_unsent_failures_are_definite_test() {
  // Offline playback with no exchanges proves the second request unsent.
  let assert Ok(client) =
    http_testing.playback(http_testing.script([]), http_config.default())
  let invalid =
    llm_wire.with_call_timeout(
      testing.config(),
      llm_wire.After(duration.milliseconds(0)),
    )
  [invalid, testing.config()]
  |> list.each(fn(settings) {
    let runtime =
      runtime_with(support.store(), decision(client, settings), fn(_, _) {
        Ok(policy.Allow)
      })
    let assert Ok(handle) =
      graph.start(
        runtime,
        support.id("unsent-decision"),
        "draft",
        correlation: None,
      )
    let assert Ok(done) =
      graph.await(handle, within: duration.milliseconds(5000))
    let assert graph.Failed(graph.OperationFailed(_)) = done.status
    done.receipts |> should.equal([])
  })
  http_gun.stop(client)
}

pub fn receipt_codec_rejects_changed_contracts_corruption_and_mismatched_native_values_test() {
  let codec = llm.receipt_codec(decision_codec())
  let good =
    llm.Receipt(
      "review-model",
      llm.Answer(True, "{\"approve\":true}"),
      Some(message.Usage(2, 1, 3)),
    )
  let assert Ok(saved) = codec.encode_json(codec, good)
  saved
  |> should.equal(
    "{\"format\":\"fabric.graph.llm.v2\",\"model\":\"review-model\","
    <> "\"outcome\":{\"tag\":\"answer\",\"value\":\"{\\\"approve\\\":true}\"},"
    <> "\"usage\":{\"input_tokens\":2,\"output_tokens\":1,\"total_tokens\":3}}",
  )
  codec.decode_json(codec, saved) |> should.equal(Ok(good))
  codec.encode_json(
    codec,
    llm.Receipt(..good, outcome: llm.Answer(False, "{\"approve\":true}")),
  )
  |> should.be_error
  codec.encode_json(codec, llm.Receipt(..good, model: "")) |> should.be_error
  codec.encode_json(
    codec,
    llm.Receipt(..good, usage: Some(message.Usage(-1, 1, 0))),
  )
  |> should.be_error
  codec.decode_json(
    codec,
    string.replace(saved, "fabric.graph.llm.v2", "fabric.graph.llm.v3"),
  )
  |> should.be_error
  codec.decode_json(
    codec,
    string.replace(saved, "\"answer\"", "\"unexpected\""),
  )
  |> should.be_error
  codec.decode_json(
    codec,
    string.replace(saved, "\"input_tokens\":2", "\"input_tokens\":-1"),
  )
  |> should.be_error
  codec.decode_json(
    llm.receipt_codec(codecs.one_field("approve", codec.string())),
    saved,
  )
  |> should.be_error
}

/// Receipts an earlier release stored as `fabric.graph.llm.v1` nested
/// arrays still decode, with the same checks.
pub fn receipt_codec_reads_v1_receipts_test() {
  let codec = llm.receipt_codec(decision_codec())
  let answer =
    "[\"fabric.graph.llm.v1\",[\"review-model\","
    <> "[[\"answer\",\"{\\\"approve\\\":true}\"],[2,[1,3]]]]]"
  codec.decode_json(codec, answer)
  |> should.equal(
    Ok(llm.Receipt(
      "review-model",
      llm.Answer(True, "{\"approve\":true}"),
      Some(message.Usage(2, 1, 3)),
    )),
  )
  codec.decode_json(
    codec,
    "[\"fabric.graph.llm.v1\",[\"review-model\",[[\"refusal\",\"no\"],null]]]",
  )
  |> should.equal(Ok(llm.Receipt("review-model", llm.Refusal("no"), None)))
  codec.decode_json(
    codec,
    "[\"fabric.graph.llm.v1\",[\"review-model\",[[\"output_limited\",\"par\"],null]]]",
  )
  |> should.equal(
    Ok(llm.Receipt("review-model", llm.OutputLimited("par"), None)),
  )
  codec.decode_json(
    codec,
    string.replace(answer, "fabric.graph.llm.v1", "fabric.graph.llm.v2"),
  )
  |> should.be_error
  codec.decode_json(
    codec,
    string.replace(answer, "\"answer\"", "\"unexpected\""),
  )
  |> should.be_error
  codec.decode_json(codec, string.replace(answer, "[2,[1,3]]", "[-1,[1,3]]"))
  |> should.be_error
  codec.decode_json(codec, string.replace(answer, "true", "false"))
  |> should.equal(
    Ok(llm.Receipt(
      "review-model",
      llm.Answer(False, "{\"approve\":false}"),
      Some(message.Usage(2, 1, 3)),
    )),
  )
  codec.decode_json(
    llm.receipt_codec(codecs.one_field("approve", codec.string())),
    answer,
  )
  |> should.be_error
}

pub fn openai_projection_uses_the_output_schema_and_preserves_actual_sse_usage_test() {
  let fake =
    fake_provider.start([
      testing.text("{\"approve\":true}")
      |> testing.with_usage(message.Usage(10, 4, 14))
      |> testing.events_for(message.OpenAI, _),
    ])
  let runtime =
    runtime_with(
      support.store(),
      decision(fake.client, fake_provider.openai(fake)),
      fn(_, _) { Ok(policy.Allow) },
    )
  let assert Ok(handle) =
    graph.start(
      runtime,
      support.id("openai-decision"),
      "draft",
      correlation: None,
    )
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status
  |> should.equal(
    graph.Completed(llm.Receipt(
      "review-model",
      llm.Answer(True, "{\"approve\":true}"),
      Some(message.Usage(10, 4, 14)),
    )),
  )
  let assert [sent] = fake_provider.bodies(fake)
  string.contains(sent, "json_schema") |> should.be_true
  string.contains(sent, "\"approve\"") |> should.be_true
  string.contains(sent, "fabric.graph.llm") |> should.be_false
  fake_provider.stop(fake)
}

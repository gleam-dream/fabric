//// The llm_wire adapter over a caller-owned HTTP Gun client and a loopback
//// fake provider: OpenAI Responses and Anthropic SSE bytes routed through
//// real provider configurations, and llm_wire's scripted reply builders. No
//// external service is contacted.

import fabric
import fabric/agent
import fabric/llm
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/apps
import fabric/support/fake_provider
import fabric/support/scripted
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import llm_wire/testing
import llm_wire/types

/// A model whose OpenAI requests the fake provider answers.
fn openai_model(fake: fake_provider.Fake) -> model.Model {
  llm.model(fake.client, fake_provider.openai(fake), model_id())
}

/// A model whose scripted requests the fake provider answers.
fn scripted_model(fake: fake_provider.Fake) -> model.Model {
  llm.model(fake.client, fake_provider.scripted(fake), model_id())
}

fn model_id() -> types.ModelId {
  let assert Ok(model_id) = types.model_id("gpt-scripted")
  model_id
}

fn event(name: String, data: String) -> String {
  "event: " <> name <> "\ndata: " <> data <> "\n\n"
}

fn function_call(
  index: Int,
  call_id: String,
  name: String,
  args: String,
) -> String {
  let item = "item_" <> int.to_string(index)
  let at = "\"output_index\":" <> int.to_string(index)
  event(
    "response.output_item.added",
    "{"
      <> at
      <> ",\"item\":{\"id\":\""
      <> item
      <> "\",\"type\":\"function_call\",\"call_id\":\""
      <> call_id
      <> "\",\"name\":\""
      <> name
      <> "\"}}",
  )
  <> event(
    "response.function_call_arguments.delta",
    "{"
      <> at
      <> ",\"item_id\":\""
      <> item
      <> "\",\"delta\":"
      <> json.to_string(json.string(args))
      <> "}",
  )
  <> event(
    "response.output_item.done",
    "{" <> at <> ",\"item\":{\"id\":\"" <> item <> "\"}}",
  )
}

fn completed(id: String, input: Int, output: Int) -> String {
  event(
    "response.completed",
    "{\"response\":{\"id\":\""
      <> id
      <> "\",\"status\":\"completed\",\"usage\":{"
      <> "\"input_tokens\":"
      <> int.to_string(input)
      <> ",\"output_tokens\":"
      <> int.to_string(output)
      <> ",\"total_tokens\":"
      <> int.to_string(input + output)
      <> "}}}",
  )
}

fn text(id: String, content: String) -> String {
  event(
    "response.output_item.added",
    "{\"output_index\":0,\"item\":{\"id\":\""
      <> id
      <> "\",\"type\":\"message\"}}",
  )
  <> event(
    "response.output_text.delta",
    "{\"output_index\":0,\"item_id\":\""
      <> id
      <> "\",\"delta\":"
      <> json.to_string(json.string(content))
      <> "}",
  )
  <> event(
    "response.output_item.done",
    "{\"output_index\":0,\"item\":{\"id\":\""
      <> id
      <> "\",\"type\":\"message\"}}",
  )
}

/// The `input` items of a Responses request, as (type, call id or role).
fn input_items(body: String) -> List(#(String, String)) {
  let item = {
    use kind <- decode.optional_field("type", "message", decode.string)
    use call_id <- decode.optional_field("call_id", "", decode.string)
    use role <- decode.optional_field("role", "", decode.string)
    decode.success(
      #(kind, case call_id {
        "" -> role
        _ -> call_id
      }),
    )
  }
  let assert Ok(items) =
    json.parse(body, decode.at(["input"], decode.list(item)))
  items
}

fn function_output(body: String, call_id: String) -> String {
  let item = {
    use kind <- decode.optional_field("type", "", decode.string)
    use id <- decode.optional_field("call_id", "", decode.string)
    use output <- decode.optional_field("output", "", decode.string)
    decode.success(#(kind, id, output))
  }
  let assert Ok(items) =
    json.parse(body, decode.at(["input"], decode.list(item)))
  let assert [#(_, _, output), ..] =
    items
    |> list.filter(fn(i) { i.0 == "function_call_output" && i.1 == call_id })
  output
}

pub fn two_tool_calls_round_trip_through_llm_wire_test() {
  let fake =
    fake_provider.start([
      testing.Events([
        function_call(0, "call_a", "lookup_weather", "{\"city\":\"Paris\"}")
        <> function_call(
          1,
          "call_b",
          "transfer_funds",
          "{\"to\":\"bob\",\"amount\":10}",
        )
        <> completed("resp_1", 11, 7),
      ]),
      testing.Events([
        text("msg_1", "Sunny in Paris; bob is paid.")
        <> completed("resp_2", 30, 9),
      ]),
    ])
  let agent =
    agent.new(
      "agent",
      openai_model(fake),
      [apps.weather_tool(), apps.transfer_tool()],
      policy.always_allow(),
    )
    |> agent.with_system_prompt("You are a careful assistant.")
    |> agent.with_limits(
      agent.Limits(..agent.default_limits(), token_budget: Some(1000)),
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(support.store(), agent, Nil, "weather, then pay bob")
  fabric.await(run, 10_000)
  |> should.equal(
    Ok(run.Finished(run.Completed("Sunny in Paris; bob is paid."))),
  )

  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.usage |> should.equal(run.TokenUsage(41, 16, 0))
  let assert [
    _,
    model.AssistantMessage(model.AssistantTurn("", [first, second], _)),
    ..
  ] = snapshot.transcript
  #(first.id, first.name, first.provider_id)
  |> should.equal(#("call_a", "lookup_weather", Some("call_a")))
  #(second.id, second.name) |> should.equal(#("call_b", "transfer_funds"))

  // The second request replays the whole transcript, results in call order.
  let assert [first_request, second_request] = fake_provider.bodies(fake)
  input_items(first_request)
  |> should.equal([#("message", "system"), #("message", "user")])
  input_items(second_request)
  |> should.equal([
    #("message", "system"),
    #("message", "user"),
    #("function_call", "call_a"),
    #("function_call", "call_b"),
    #("function_call_output", "call_a"),
    #("function_call_output", "call_b"),
  ])
  function_output(second_request, "call_a")
  |> should.equal("{\"summary\":\"sunny\"}")
  function_output(second_request, "call_b")
  |> should.equal("{\"receipt\":\"r-bob\"}")
  fake_provider.stop(fake)
}

pub fn unsupported_or_corrupt_stored_adapter_data_stops_before_provider_io_test() {
  list.each(
    [
      model.ProviderData("future.format", "{}"),
      model.ProviderData("llm_wire.turn.v1", "{"),
      model.ProviderData(
        "llm_wire.turn.v1",
        "{\"provider\":{\"kind\":\"unknown\"},\"response_id\":null,\"provider_data\":null,\"issues\":[]}",
      ),
    ],
    fn(data) {
      let policy = fn(_: Nil, _: policy.Action) {
        Ok(policy.RequireApproval(run.Requirement("review", 1)))
      }
      let calls = [scripted.call("w", "lookup_weather", "{\"city\":\"Paris\"}")]
      let original =
        agent.new(
          "metadata",
          scripted.model(fn(_) {
            model.ToolRequest(model.AssistantTurn("", calls, Some(data)), None)
          }),
          [apps.weather_tool()],
          policy,
        )
        |> support.agent
      let runs = support.store()
      let assert Ok(started) = fabric.start(runs, original, Nil, "weather")
      let assert Ok(run.Suspended([pending], [])) = fabric.await(started, 5000)
      let fake =
        fake_provider.start([
          testing.Events([text("answer", "unused") <> completed("r", 1, 1)]),
        ])
      let resumed_agent =
        agent.new("metadata", openai_model(fake), [apps.weather_tool()], policy)
        |> support.agent
      let assert Ok(opened) =
        fabric.open(runs, resumed_agent, Nil, fabric.id(started))
      let assert Ok(_) =
        fabric.approve(opened, pending.reference, reviewer: None, context: Nil)
      let assert Ok(run.Finished(run.Failed(run.ModelFailed(error)))) =
        fabric.await(opened, 5000)
      error.retryable |> should.be_false
      fake_provider.bodies(fake) |> should.equal([])
      fake_provider.remaining(fake) |> should.equal(1)
      fake_provider.stop(fake)
    },
  )
}

/// llm_wire reports invalid calls instead of failing the turn, so Fabric's
/// registry gives the model per-call feedback: invalid arguments and an
/// unknown tool are answered, and the model continues.
pub fn invalid_calls_through_llm_wire_get_per_call_feedback_test() {
  let fake =
    fake_provider.start([
      testing.tool_calls("", [
        testing.ScriptedCall("call_a", "lookup_weather", "{\"town\":\"Paris\"}"),
        testing.ScriptedCall("call_b", "ghost", "{}"),
      ]),
      testing.text("I will ask properly."),
    ])
  let agent =
    agent.new(
      "agent",
      scripted_model(fake),
      [apps.weather_tool()],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(run) = fabric.start(support.store(), agent, Nil, "weather")
  fabric.await(run, 10_000)
  |> should.equal(Ok(run.Finished(run.Completed("I will ask properly."))))
  let assert Ok(snapshot) = fabric.snapshot(run)
  let assert [
    run.ActionRecord(state: run.InvalidArguments(_), ..),
    run.ActionRecord(state: run.UnknownTool, ..),
  ] = snapshot.actions
  let assert [_, _, model.ToolResultMessage("call_a", invalid), ..] =
    snapshot.transcript
  invalid
  |> string.starts_with("{\"error\":\"invalid_arguments\"")
  |> should.be_true
  // The stored turn keeps llm_wire's issues for the replayed request.
  let assert [
    _,
    model.AssistantMessage(model.AssistantTurn(
      _,
      _,
      Some(model.ProviderData("llm_wire.turn.v1", data)),
    )),
    ..
  ] = snapshot.transcript
  let issue = {
    use id <- decode.field("call_id", decode.string)
    use reason <- decode.field("reason", decode.optional(decode.string))
    decode.success(#(id, option.is_some(reason)))
  }
  json.parse(data, decode.at(["issues"], decode.list(issue)))
  |> should.equal(Ok([#("call_a", True), #("call_b", False)]))
  let assert [_, continued] = fake_provider.bodies(fake)
  let call_ids = {
    use calls <- decode.optional_field(
      "calls",
      [],
      decode.list(decode.at(["id"], decode.string)),
    )
    decode.success(calls)
  }
  json.parse(continued, decode.at(["messages"], decode.list(call_ids)))
  |> should.equal(Ok([[], ["call_a", "call_b"], [], []]))
  fake_provider.stop(fake)
}

pub fn refusal_and_truncation_through_llm_wire_end_the_run_test() {
  let fake =
    fake_provider.start([
      testing.refusal("not allowed") |> testing.with_usage(types.Usage(3, 1, 4)),
      testing.output_limited("partial ans"),
    ])
  let agent =
    agent.new("agent", scripted_model(fake), [], policy.always_allow())
    |> support.agent
  let assert Ok(refused) = fabric.start(support.store(), agent, Nil, "a")
  fabric.await(refused, 10_000)
  |> should.equal(Ok(run.Finished(run.Refused("not allowed"))))
  let assert Ok(snapshot) = fabric.snapshot(refused)
  snapshot.usage |> should.equal(run.TokenUsage(3, 1, 0))
  let assert Ok(limited) = fabric.start(support.store(), agent, Nil, "b")
  fabric.await(limited, 10_000)
  |> should.equal(Ok(run.Finished(run.OutputLimited("partial ans"))))
  fake_provider.stop(fake)
}

/// A server error is retryable: the run retries after its backoff and the
/// next attempt succeeds. A client error is not retried.
pub fn http_statuses_through_llm_wire_are_classified_for_retry_test() {
  let fake =
    fake_provider.start([testing.Status(503, "busy"), testing.text("recovered")])
  let agent =
    agent.new("agent", scripted_model(fake), [], policy.always_allow())
    |> agent.with_limits(
      agent.Limits(..agent.default_limits(), model_retry_delay: 0),
    )
    |> support.agent
  let assert Ok(run) = fabric.start(support.store(), agent, Nil, "hi")
  fabric.await(run, 10_000)
  |> should.equal(Ok(run.Finished(run.Completed("recovered"))))
  fake_provider.stop(fake)

  let fake = fake_provider.start([testing.Status(400, "bad request")])
  let agent =
    agent.new("agent", scripted_model(fake), [], policy.always_allow())
    |> support.agent
  let assert Ok(run) = fabric.start(support.store(), agent, Nil, "hi")
  let assert Ok(run.Finished(run.Failed(run.ModelFailed(error)))) =
    fabric.await(run, 10_000)
  error.retryable |> should.be_false
  fake_provider.remaining(fake) |> should.equal(0)
  fake_provider.stop(fake)
}

fn sse(name: String, data: String) -> String {
  "event: " <> name <> "\ndata: " <> data <> "\n\n"
}

fn anthropic_message(blocks: String, stop_reason: String) -> String {
  sse(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"m\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}",
  )
  <> blocks
  <> sse(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\""
      <> stop_reason
      <> "\"},\"usage\":{\"output_tokens\":2}}",
  )
  <> sse("message_stop", "{\"type\":\"message_stop\"}")
}

fn anthropic_tool_use(
  id: String,
  name: String,
  partial_json: String,
) -> String {
  anthropic_message(
    sse(
      "content_block_start",
      "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\""
        <> id
        <> "\",\"name\":\""
        <> name
        <> "\"}}",
    )
      <> sse(
      "content_block_delta",
      "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":"
        <> json.to_string(json.string(partial_json))
        <> "}}",
    )
      <> sse(
      "content_block_stop",
      "{\"type\":\"content_block_stop\",\"index\":0}",
    ),
    "tool_use",
  )
}

fn anthropic_text(text: String) -> String {
  anthropic_message(
    sse(
      "content_block_start",
      "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
    )
      <> sse(
      "content_block_delta",
      "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":"
        <> json.to_string(json.string(text))
        <> "}}",
    )
      <> sse(
      "content_block_stop",
      "{\"type\":\"content_block_stop\",\"index\":0}",
    ),
    "end_turn",
  )
}

/// Anthropic requires a replayed `tool_use` input to be a JSON object. A
/// call whose arguments were not even JSON is answered with
/// `invalid_arguments`, and the next turn still reaches the model: the
/// arguments are replayed as an object that carries the original text,
/// which the record keeps unchanged.
pub fn unparseable_arguments_replay_to_anthropic_as_an_object_test() {
  let fake =
    fake_provider.start([
      testing.Events([
        anthropic_tool_use("toolu_1", "lookup_weather", "{\"city\": "),
      ]),
      testing.Events([anthropic_text("I will ask properly.")]),
    ])
  let agent =
    agent.new(
      "agent",
      llm.model(fake.client, fake_provider.anthropic(fake), model_id()),
      [apps.weather_tool()],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(run) = fabric.start(support.store(), agent, Nil, "weather")
  fabric.await(run, 10_000)
  |> should.equal(Ok(run.Finished(run.Completed("I will ask properly."))))

  let assert Ok(snapshot) = fabric.snapshot(run)
  let assert [run.ActionRecord(call:, state: run.InvalidArguments(_), ..)] =
    snapshot.actions
  call.arguments_json |> should.equal("{\"city\": ")

  let assert [_, second] = fake_provider.bodies(fake)
  let tool_use = {
    use kind <- decode.field("type", decode.string)
    use input <- decode.optional_field(
      "input",
      "",
      decode.at(["unparsed_arguments"], decode.string),
    )
    decode.success(#(kind, input))
  }
  let message = {
    use content <- decode.field(
      "content",
      decode.one_of(decode.list(tool_use), [decode.success([])]),
    )
    decode.success(content)
  }
  let assert Ok(messages) =
    json.parse(second, decode.at(["messages"], decode.list(message)))
  messages
  |> list.flatten
  |> list.filter(fn(block) { block.0 == "tool_use" })
  |> should.equal([#("tool_use", "{\"city\": ")])
  fake_provider.stop(fake)
}

/// OpenAI carries a call's arguments as a string, so a call whose arguments
/// were not JSON replays with the text the model sent, unwrapped.
pub fn unparseable_arguments_replay_to_openai_verbatim_test() {
  let fake =
    fake_provider.start([
      testing.Events([
        function_call(0, "call_a", "lookup_weather", "{\"city\": ")
        <> completed("resp_1", 3, 2),
      ]),
      testing.Events([
        text("msg_1", "I will ask properly.") <> completed("resp_2", 5, 3),
      ]),
    ])
  let agent =
    agent.new(
      "agent",
      openai_model(fake),
      [apps.weather_tool()],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(run) = fabric.start(support.store(), agent, Nil, "weather")
  fabric.await(run, 10_000)
  |> should.equal(Ok(run.Finished(run.Completed("I will ask properly."))))

  let assert [_, second] = fake_provider.bodies(fake)
  let item = {
    use kind <- decode.optional_field("type", "", decode.string)
    use arguments <- decode.optional_field("arguments", "", decode.string)
    decode.success(#(kind, arguments))
  }
  let assert Ok(items) =
    json.parse(second, decode.at(["input"], decode.list(item)))
  items
  |> list.filter(fn(item) { item.0 == "function_call" })
  |> should.equal([#("function_call", "{\"city\": ")])
  fake_provider.stop(fake)
}

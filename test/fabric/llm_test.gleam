//// The llm_wire adapter against a deterministic local OpenAI Responses SSE
//// stub on 127.0.0.1. No real or paid service is contacted.

import fabric
import fabric/agent
import fabric/llm
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/support/apps
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit/should
import llm_wire/config
import llm_wire/provider/openai
import llm_wire/types

@external(erlang, "fabric_stub_ffi", "start")
fn start_stub(responses: List(String)) -> #(Int, Pid)

@external(erlang, "fabric_stub_ffi", "requests")
fn stub_requests(stub: Pid) -> List(String)

fn settings(port: Int) -> config.Config {
  let assert Ok(key) = types.api_key("sk-local-stub")
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(port) <> "/v1")
  config.openai(openai.options(key)) |> config.with_endpoint(endpoint)
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
  let #(port, stub) =
    start_stub([
      function_call(0, "call_a", "lookup_weather", "{\"city\":\"Paris\"}")
        <> function_call(
        1,
        "call_b",
        "transfer_funds",
        "{\"to\":\"bob\",\"amount\":10}",
      )
        <> completed("resp_1", 11, 7),
      text("msg_1", "Sunny in Paris; bob is paid.")
        <> completed("resp_2", 30, 9),
    ])
  let assert Ok(model_id) = types.model_id("gpt-local")
  let agent =
    agent.new(
      llm.model(settings(port), model_id),
      [apps.weather_tool(), apps.transfer_tool()],
      policy.always_allow(),
    )
    |> agent.with_system_prompt("You are a careful assistant.")
    |> agent.with_token_budget(1000)
  let assert Ok(run) =
    fabric.start(store.in_memory(), agent, Nil, "weather, then pay bob")
  fabric.await(run, 10_000)
  |> should.equal(
    Ok(run.Finished(run.Completed("Sunny in Paris; bob is paid."))),
  )

  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.usage |> should.equal(run.TokenUsage(41, 16, 0))
  let assert [_, model.AssistantMessage("", [first, second]), ..] =
    snapshot.transcript
  #(first.id, first.name, first.provider_id)
  |> should.equal(#("call_a", "lookup_weather", Some("call_a")))
  #(second.id, second.name) |> should.equal(#("call_b", "transfer_funds"))

  // The second request replays the whole transcript, results in call order.
  let assert [first_request, second_request] = stub_requests(stub)
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
}

pub fn malformed_arguments_through_llm_wire_fail_the_model_call_test() {
  // llm_wire checks arguments against the declared schema while reading the
  // response; Fabric sees a failed model call, not a per-call outcome.
  let #(port, _stub) =
    start_stub([
      function_call(0, "call_a", "lookup_weather", "{\"town\":\"Paris\"}")
      <> completed("resp_1", 5, 5),
    ])
  let assert Ok(model_id) = types.model_id("gpt-local")
  let agent =
    agent.new(
      llm.model(settings(port), model_id),
      [apps.weather_tool()],
      policy.always_allow(),
    )
  let assert Ok(run) = fabric.start(store.in_memory(), agent, Nil, "weather")
  let assert Ok(run.Finished(run.Failed(run.ModelFailed(error)))) =
    fabric.await(run, 10_000)
  error.retryable |> should.be_false
  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.actions |> should.equal([])
}

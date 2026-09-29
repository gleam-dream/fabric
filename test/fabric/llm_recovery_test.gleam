//// Public Fabric flows against local provider transports. Conversation
//// persistence belongs to Fabric; every resumed turn uses a fresh request.

import fabric
import fabric/agent
import fabric/llm
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/probe
import fabric/support/restart
import fabric/tool
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import json/blueprint/codec
import llm_wire/cassette
import llm_wire/config
import llm_wire/provider/google
import llm_wire/provider/openai
import llm_wire/testing
import llm_wire/types

fn model_id() -> types.ModelId {
  let assert Ok(id) = types.model_id("cassette-model")
  id
}

fn google_settings(script: testing.Script, key: String) -> config.Config {
  let assert Ok(key) = types.api_key(key)
  config.google(google.options(key)) |> testing.with_script(script)
}

fn openai_settings(script: testing.Script) -> config.Config {
  let assert Ok(key) = types.api_key("local-script-key")
  config.openai(openai.options(key)) |> testing.with_script(script)
}

fn calculation(
  name: String,
  multiplier: Int,
  ledger: probe.Probe,
) -> tool.Tool(Nil) {
  let input =
    codec.field("x", codec.describe(codec.int(), "Integer to calculate with"))
    |> codec.describe("A calculation request")
  tool.define(name, "Calculate a number", input, codec.int())
  |> tool.bind(
    fn(_: Nil, value: Int) -> Result(Int, String) {
      probe.record(ledger, name <> ":" <> int.to_string(value))
      Ok(value * multiplier)
    },
    tool.Explain,
  )
}

fn calculating_agent(
  settings: config.Config,
  ledger: probe.Probe,
  policy: policy.Policy(Nil),
) -> agent.Agent(Nil) {
  agent.new(
    "calculator",
    llm.model(settings, model_id()),
    [calculation("calc", 2, ledger), calculation("lookup", 3, ledger)],
    policy,
  )
  |> support.agent
}

fn reviewed() -> policy.Policy(Nil) {
  fn(_: Nil, _: policy.Action) -> Result(policy.Decision, String) {
    Ok(policy.RequireApproval(run.Requirement("calculation", 1)))
  }
}

fn google_reply(parts: List(json.Json), response_id: String) -> testing.Reply {
  testing.Events([
    "data: "
    <> json.to_string(
      json.object([
        #("responseId", json.string(response_id)),
        #(
          "candidates",
          json.array(
            [
              json.object([
                #("finishReason", json.string("STOP")),
                #(
                  "content",
                  json.object([
                    #("role", json.string("model")),
                    #("parts", json.array(parts, fn(part) { part })),
                  ]),
                ),
              ]),
            ],
            fn(candidate) { candidate },
          ),
        ),
      ]),
    )
    <> "\n\n",
  ])
}

fn signed_text(text: String, signature: String) -> json.Json {
  json.object([
    #("text", json.string(text)),
    #("thoughtSignature", json.string(signature)),
    #("opaque", json.bool(True)),
  ])
}

fn signed_call(name: String, value: Int, signature: String) -> json.Json {
  json.object([
    #(
      "functionCall",
      json.object([
        #("name", json.string(name)),
        #("id", json.string("same-id")),
        #("args", json.object([#("x", json.int(value))])),
      ]),
    ),
    #("thoughtSignature", json.string(signature)),
  ])
}

fn google_final() -> testing.Reply {
  google_reply([json.object([#("text", json.string("finished"))])], "final")
}

fn contents(body: String) -> List(Dynamic) {
  let assert Ok(contents) =
    json.parse(body, decode.at(["contents"], decode.list(decode.dynamic)))
  contents
}

fn parts(content: Dynamic) -> List(Dynamic) {
  let assert Ok(parts) =
    decode.run(content, decode.at(["parts"], decode.list(decode.dynamic)))
  parts
}

fn field(value: Dynamic, path: List(String)) -> String {
  let assert Ok(value) = decode.run(value, decode.at(path, decode.string))
  value
}

fn result_part(content: Dynamic, name: String, output: String) -> Nil {
  let assert [result] = parts(content)
  field(result, ["functionResponse", "id"]) |> should.equal("same-id")
  field(result, ["functionResponse", "name"]) |> should.equal(name)
  field(result, ["functionResponse", "response", "output"])
  |> should.equal(output)
}

pub fn google_signed_parts_survive_approval_and_directory_restart_test() -> Nil {
  let directory = restart.temp_dir()
  let ledger = probe.new()
  let script =
    testing.start([
      google_reply(
        [
          signed_text("thinking", "text-signature"),
          json.object([
            #(
              "inlineData",
              json.object([
                #("mimeType", json.string("image/png")),
                #("data", json.string("c2lnbmVkLWJ5dGVz")),
              ]),
            ),
            #("thoughtSignature", json.string("image-signature")),
          ]),
          signed_call("calc", 7, "call-signature"),
        ],
        "signed-response",
      ),
      google_final(),
    ])
  let before =
    calculating_agent(google_settings(script, "first-key"), ledger, reviewed())
  let runs = store.directory(process.new_name("signed-restart"), directory)
  let #(owner, Nil) = restart.owned(fn() { store.start(runs) |> should.be_ok })
  let assert Ok(first_store_process) = store.pid(runs)
  let assert Ok(started) = fabric.start(runs, before, Nil, "calculate")
  let assert Ok(run.Suspended([approval], [])) = fabric.await(started, 5000)
  probe.entries(ledger) |> should.equal([])
  list.length(testing.requests(script)) |> should.equal(1)

  // The owner really exits; only disk state and the test transport survive.
  restart.crash(owner, runs)
  let #(owner, Nil) = restart.owned(fn() { store.start(runs) |> should.be_ok })
  let assert Ok(second_store_process) = store.pid(runs)
  { first_store_process == second_store_process } |> should.be_false
  let after =
    calculating_agent(
      google_settings(script, "rotated-key"),
      ledger,
      reviewed(),
    )
  let assert Ok(resumed) = fabric.recover(runs, after, Nil, fabric.id(started))
  fabric.await(resumed, 0) |> should.equal(Ok(run.Suspended([approval], [])))
  list.length(testing.requests(script)) |> should.equal(1)
  let assert Ok(_) =
    fabric.approve(resumed, approval.reference, reviewer: None, context: Nil)
  fabric.await(resumed, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("finished"))))
  probe.entries(ledger) |> should.equal(["calc:7"])
  let assert [_, replayed] = testing.requests(script)
  let assert [_, types.AssistantTurnMessage(stored_turn), _] =
    replayed.request.messages
  stored_turn.provider |> should.equal(types.Google)
  stored_turn.response_id |> should.equal(Some("signed-response"))
  let assert [stored_call] = stored_turn.calls
  stored_call.provider_id |> should.equal(Some("same-id"))
  stored_call.provider_state |> should.equal(Some("call-signature"))
  let assert [_, turn, result] = contents(replayed.body)
  let assert [text, image, call] = parts(turn)
  field(text, ["text"]) |> should.equal("thinking")
  field(text, ["thoughtSignature"]) |> should.equal("text-signature")
  decode.run(text, decode.at(["opaque"], decode.bool)) |> should.equal(Ok(True))
  field(image, ["thoughtSignature"]) |> should.equal("image-signature")
  field(image, ["inlineData", "mimeType"]) |> should.equal("image/png")
  field(image, ["inlineData", "data"]) |> should.equal("c2lnbmVkLWJ5dGVz")
  field(call, ["thoughtSignature"]) |> should.equal("call-signature")
  field(call, ["functionCall", "name"]) |> should.equal("calc")
  decode.run(call, decode.at(["functionCall", "args", "x"], decode.int))
  |> should.equal(Ok(7))
  result_part(result, "calc", "14")
  testing.remaining(script) |> should.equal(0)
  restart.crash(owner, runs)
  restart.remove_dir(directory)
}

pub fn repeated_provider_call_ids_remain_paired_with_their_own_round_test() -> Nil {
  let ledger = probe.new()
  let script =
    testing.start([
      google_reply(
        [
          signed_text("first", "text-first"),
          signed_call("calc", 1, "call-first"),
        ],
        "first-response",
      ),
      google_reply(
        [
          signed_text("second", "text-second"),
          signed_call("lookup", 2, "call-second"),
        ],
        "second-response",
      ),
      google_final(),
    ])
  let agent =
    calculating_agent(
      google_settings(script, "local-key"),
      ledger,
      policy.always_allow(),
    )
  let assert Ok(started) =
    fabric.start(support.store(), agent, Nil, "calculate")
  fabric.await(started, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("finished"))))
  probe.entries(ledger) |> should.equal(["calc:1", "lookup:2"])
  let assert [_, _, third] = testing.requests(script)
  let assert [_, first_turn, first_result, second_turn, second_result] =
    contents(third.body)
  list.each(
    [#(first_turn, "first", "calc", 1), #(second_turn, "second", "lookup", 2)],
    fn(round) {
      let assert [text, call] = parts(round.0)
      field(text, ["thoughtSignature"]) |> should.equal("text-" <> round.1)
      field(call, ["thoughtSignature"]) |> should.equal("call-" <> round.1)
      field(call, ["functionCall", "name"]) |> should.equal(round.2)
      field(call, ["functionCall", "id"]) |> should.equal("same-id")
      decode.run(call, decode.at(["functionCall", "args", "x"], decode.int))
      |> should.equal(Ok(round.3))
    },
  )
  result_part(first_result, "calc", "2")
  result_part(second_result, "lookup", "6")
  testing.remaining(script) |> should.equal(0)
}

fn text_agent(settings: config.Config, max_turns: Int) -> agent.Agent(Nil) {
  agent.new("text", llm.model(settings, model_id()), [], policy.always_allow())
  |> agent.with_limits(
    agent.Limits(..agent.default_limits(), max_turns:, model_retry_delay: 0),
  )
  |> support.agent
}

pub fn http_501_stops_without_retrying_the_unchanged_request_test() -> Nil {
  let script =
    testing.start([
      testing.Status(501, "not implemented"),
      testing.text("unused"),
    ])
  let assert Ok(started) =
    fabric.start(
      support.store(),
      text_agent(testing.config(script), 3),
      Nil,
      "Hello",
    )
  let assert Ok(run.Finished(run.Failed(run.ModelFailed(error)))) =
    fabric.await(started, 5000)
  error.retryable |> should.be_false
  let assert Ok(snapshot) = fabric.snapshot(started)
  snapshot.turns_used |> should.equal(1)
  list.length(testing.requests(script)) |> should.equal(1)
  testing.remaining(script) |> should.equal(1)
}

pub fn http_503_retries_only_within_the_existing_turn_budget_test() -> Nil {
  list.each([1, 2], fn(max_turns) {
    let script =
      testing.start([testing.Status(503, "busy"), testing.text("recovered")])
    let assert Ok(started) =
      fabric.start(
        support.store(),
        text_agent(testing.config(script), max_turns),
        Nil,
        "Hello",
      )
    let expected = case max_turns {
      1 -> run.BudgetExhausted(run.TurnLimit(1))
      _ -> run.Completed("recovered")
    }
    fabric.await(started, 5000) |> should.equal(Ok(run.Finished(expected)))
    let assert Ok(snapshot) = fabric.snapshot(started)
    snapshot.turns_used |> should.equal(max_turns)
    list.length(testing.requests(script)) |> should.equal(max_turns)
    testing.remaining(script) |> should.equal(2 - max_turns)
  })
}

fn openai_text(answer: String) -> testing.Reply {
  testing.Events([
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"text\",\"type\":\"message\"}}\n\n",
    "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"text\",\"delta\":"
      <> json.to_string(json.string(answer))
      <> "}\n\n",
    "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"text\",\"type\":\"message\"}}\n\n",
    "event: response.completed\ndata: {\"response\":{\"id\":\"final\",\"status\":\"completed\"}}\n\n",
  ])
}

pub fn blueprint_descriptions_reach_the_outgoing_provider_schema_test() -> Nil {
  let ledger = probe.new()
  let script = testing.start([openai_text("finished")])
  let agent =
    calculating_agent(openai_settings(script), ledger, policy.always_allow())
  let assert Ok(started) =
    fabric.start(support.store(), agent, Nil, "calculate")
  fabric.await(started, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("finished"))))
  let assert [request] = testing.requests(script)
  let assert Ok([first, second]) =
    json.parse(request.body, decode.at(["tools"], decode.list(decode.dynamic)))
  list.each([first, second], fn(declaration) {
    field(declaration, ["parameters", "description"])
    |> should.equal("A calculation request")
    field(declaration, ["parameters", "properties", "x", "description"])
    |> should.equal("Integer to calculate with")
  })
  probe.entries(ledger) |> should.equal([])
}

pub fn a_disk_cassette_runs_through_the_public_fabric_flow_test() -> Nil {
  let assert Ok(recording) =
    cassette.load("test/fixtures/llm/hello.json", 10_000)
  let script = cassette.start(recording)
  let assert Ok(started) =
    fabric.start(
      support.store(),
      text_agent(openai_settings(script), 2),
      Nil,
      "Hello",
    )
  fabric.await(started, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("from disk cassette"))))
  testing.remaining(script) |> should.equal(0)
  list.length(testing.requests(script)) |> should.equal(1)
}

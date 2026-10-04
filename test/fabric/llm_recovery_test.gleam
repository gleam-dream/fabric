//// Public Fabric flows against local provider transports. Conversation
//// persistence belongs to Fabric; every resumed turn uses a fresh request.

import fabric
import fabric/agent
import fabric/internal/store as store_core
import fabric/llm
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/codecs
import fabric/support/fake_provider
import fabric/support/probe
import fabric/support/restart
import fabric/tool
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/cassette
import http_gun/config as http_config
import http_gun/testing as http_testing
import json/blueprint/codec
import llm_wire
import llm_wire/message
import llm_wire/openai
import llm_wire/testing

fn model_id() -> String {
  "cassette-model"
}

fn calculation(
  name: String,
  multiplier: Int,
  ledger: probe.Probe,
) -> tool.Tool(Nil) {
  let input =
    codecs.one_field(
      "x",
      codec.describe(codec.int(), "Integer to calculate with"),
    )
    |> codec.describe("A calculation request")
  tool.define(name, "Calculate a number", input, codec.int())
  |> tool.bind(
    fn(_: Nil, _call, value: Int) -> Result(Int, String) {
      probe.record(ledger, name <> ":" <> int.to_string(value))
      Ok(value * multiplier)
    },
    tool.Explain,
  )
}

fn calculating_agent(
  client: http_gun.Client,
  settings: llm_wire.Config,
  ledger: probe.Probe,
  policy: policy.Policy(Nil),
) -> agent.Agent(Nil, String) {
  agent.new(
    "calculator",
    llm.model(client, settings, model_id()),
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

/// `testing.events_for` sends no `thoughtSignature`, so signed Gemini parts
/// are written here.
fn google_reply(parts: List(json.Json), response_id: String) -> testing.Reply {
  testing.events([
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
  testing.events_for(message.Google, testing.text("finished"))
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
  let fake =
    fake_provider.start([
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
    calculating_agent(
      fake.client,
      fake_provider.google(fake, "first-key"),
      ledger,
      reviewed(),
    )
  let runs = store.directory(process.new_name("signed-restart"), directory)
  let #(owner, Nil) = restart.owned(fn() { store.start(runs) |> should.be_ok })
  let assert Ok(first_store_process) = store_core.pid(runs)
  let assert Ok(started) =
    fabric.start(
      runs,
      before,
      id: run.new_id(),
      context: Nil,
      prompt: "calculate",
      correlation: None,
    )
  let assert Ok(run.Suspended([approval], [])) =
    fabric.await(started, within: duration.milliseconds(5000))
  probe.entries(ledger) |> should.equal([])
  list.length(fake_provider.bodies(fake)) |> should.equal(1)

  // The owner really exits; only disk state and the test transport survive.
  restart.crash(owner, runs)
  let #(owner, Nil) = restart.owned(fn() { store.start(runs) |> should.be_ok })
  let assert Ok(second_store_process) = store_core.pid(runs)
  { first_store_process == second_store_process } |> should.be_false
  let after =
    calculating_agent(
      fake.client,
      fake_provider.google(fake, "rotated-key"),
      ledger,
      reviewed(),
    )
  let assert Ok(resumed) = fabric.recover(runs, after, Nil, fabric.id(started))
  fabric.await(resumed, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Suspended([approval], [])))
  list.length(fake_provider.bodies(fake)) |> should.equal(1)
  let assert Ok(_) =
    fabric.approve(
      resumed,
      approval.reference,
      reviewer: support.reviewer("reviewer"),
      context: Nil,
    )
  fabric.await(resumed, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("finished"))))
  probe.entries(ledger) |> should.equal(["calc:7"])
  let assert [_, replayed] = fake_provider.bodies(fake)
  let assert [_, turn, result] = contents(replayed)
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
  fake_provider.remaining(fake) |> should.equal(0)
  fake_provider.stop(fake)
  restart.crash(owner, runs)
  restart.remove_dir(directory)
}

pub fn repeated_provider_call_ids_remain_paired_with_their_own_round_test() -> Nil {
  let ledger = probe.new()
  let fake =
    fake_provider.start([
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
      fake.client,
      fake_provider.google(fake, "local-key"),
      ledger,
      policy.always_allow(),
    )
  let assert Ok(started) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "calculate",
      correlation: None,
    )
  fabric.await(started, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("finished"))))
  probe.entries(ledger) |> should.equal(["calc:1", "lookup:2"])
  let assert [_, _, third] = fake_provider.bodies(fake)
  let assert [_, first_turn, first_result, second_turn, second_result] =
    contents(third)
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
  fake_provider.remaining(fake) |> should.equal(0)
  fake_provider.stop(fake)
}

fn text_agent(
  client: http_gun.Client,
  settings: llm_wire.Config,
  max_turns: Int,
) -> agent.Agent(Nil, String) {
  agent.new(
    "text",
    llm.model(client, settings, model_id()),
    [],
    policy.always_allow(),
  )
  |> agent.with_max_turns(max_turns)
  |> agent.with_model_retry_delay(duration.milliseconds(0))
  |> support.agent
}

pub fn http_501_stops_without_retrying_the_unchanged_request_test() -> Nil {
  let fake =
    fake_provider.start([
      testing.http_status(message.Custom("scripted"), 501, "not implemented"),
      testing.text("unused"),
    ])
  let assert Ok(started) =
    fabric.start(
      support.store(),
      text_agent(fake.client, fake_provider.scripted(fake), 3),
      id: run.new_id(),
      context: Nil,
      prompt: "Hello",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Failed(run.ModelFailed(error)))) =
    fabric.await(started, within: duration.milliseconds(5000))
  model.is_retryable(error) |> should.be_false
  let assert Ok(snapshot) = fabric.snapshot(started)
  snapshot.turns_used |> should.equal(1)
  list.length(fake_provider.bodies(fake)) |> should.equal(1)
  fake_provider.remaining(fake) |> should.equal(1)
  fake_provider.stop(fake)
}

pub fn http_503_retries_only_within_the_existing_turn_budget_test() -> Nil {
  list.each([1, 2], fn(max_turns) {
    let fake =
      fake_provider.start([
        testing.http_status(message.Custom("scripted"), 503, "busy"),
        testing.text("recovered"),
      ])
    let assert Ok(started) =
      fabric.start(
        support.store(),
        text_agent(fake.client, fake_provider.scripted(fake), max_turns),
        id: run.new_id(),
        context: Nil,
        prompt: "Hello",
        correlation: None,
      )
    let expected = case max_turns {
      1 -> run.BudgetExhausted(run.TurnLimit(1))
      _ -> run.Completed("recovered")
    }
    fabric.await(started, within: duration.milliseconds(5000))
    |> should.equal(Ok(run.Finished(expected)))
    let assert Ok(snapshot) = fabric.snapshot(started)
    snapshot.turns_used |> should.equal(max_turns)
    list.length(fake_provider.bodies(fake)) |> should.equal(max_turns)
    fake_provider.remaining(fake) |> should.equal(2 - max_turns)
    fake_provider.stop(fake)
  })
}

pub fn blueprint_descriptions_reach_the_outgoing_provider_schema_test() -> Nil {
  let ledger = probe.new()
  let fake =
    fake_provider.start([
      testing.events_for(message.OpenAI, testing.text("finished")),
    ])
  let agent =
    calculating_agent(
      fake.client,
      fake_provider.openai(fake),
      ledger,
      policy.always_allow(),
    )
  let assert Ok(started) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "calculate",
      correlation: None,
    )
  fabric.await(started, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("finished"))))
  let assert [request] = fake_provider.bodies(fake)
  let assert Ok([first, second]) =
    json.parse(request, decode.at(["tools"], decode.list(decode.dynamic)))
  list.each([first, second], fn(declaration) {
    field(declaration, ["parameters", "description"])
    |> should.equal("A calculation request")
    field(declaration, ["parameters", "properties", "x", "description"])
    |> should.equal("Integer to calculate with")
  })
  probe.entries(ledger) |> should.equal([])
  fake_provider.stop(fake)
}

pub fn a_disk_cassette_runs_through_the_public_fabric_flow_test() -> Nil {
  let assert Ok(tape) = cassette.load("test/fixtures/llm/hello.json", 10_000)
  // Offline playback: an unmatched or extra request fails; nothing is sent.
  let assert Ok(client) = http_testing.playback(tape, http_config.default())
  let settings = openai.new("local-script-key") |> openai.config
  let assert Ok(started) =
    fabric.start(
      support.store(),
      text_agent(client, settings, 2),
      id: run.new_id(),
      context: Nil,
      prompt: "Hello",
      correlation: None,
    )
  fabric.await(started, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("from disk cassette"))))
  http_gun.stop(client)
  Nil
}

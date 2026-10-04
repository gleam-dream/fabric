//// Stored `llm_wire.turn.v1` records from the release before llm_wire owned
//// the codec (Fabric 8eb5a16 over llm_wire 576482e). Each fixture is the
//// exact provider data that release stored, with the turn's text and calls,
//// and the part of that release's next request that replayed the turn. The
//// current adapter restores each record and replays the same JSON. It writes
//// the same bytes without the `issues` list, which Fabric answers per call
//// itself.

import fabric
import fabric/agent
import fabric/internal/model_port
import fabric/llm
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/apps
import fabric/support/codecs
import fabric/support/fake_provider
import fabric/tool
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import llm_wire
import llm_wire/message
import llm_wire/testing

type Fixture {
  Fixture(
    provider: message.Provider,
    text: String,
    calls: List(model.ToolCall),
    data: String,
    /// The replayed turn in the request the earlier release sent.
    replayed: String,
  )
}

const google_data = "{\"provider\":{\"kind\":\"google\",\"name\":null},\"response_id\":\"signed-response\",\"provider_data\":\"[\\\"{\\\\\\\"opaque\\\\\\\":true,\\\\\\\"text\\\\\\\":\\\\\\\"thinking\\\\\\\",\\\\\\\"thoughtSignature\\\\\\\":\\\\\\\"text-signature\\\\\\\"}\\\",\\\"{\\\\\\\"inlineData\\\\\\\":{\\\\\\\"data\\\\\\\":\\\\\\\"c2lnbmVkLWJ5dGVz\\\\\\\",\\\\\\\"mimeType\\\\\\\":\\\\\\\"image/png\\\\\\\"},\\\\\\\"thoughtSignature\\\\\\\":\\\\\\\"image-signature\\\\\\\"}\\\",\\\"{\\\\\\\"functionCall\\\\\\\":{\\\\\\\"args\\\\\\\":{\\\\\\\"x\\\\\\\":7},\\\\\\\"id\\\\\\\":\\\\\\\"same-id\\\\\\\",\\\\\\\"name\\\\\\\":\\\\\\\"calc\\\\\\\"},\\\\\\\"thoughtSignature\\\\\\\":\\\\\\\"call-signature\\\\\\\"}\\\"]\",\"issues\":[]}"

fn fixtures() -> List(Fixture) {
  [
    Fixture(
      provider: message.Google,
      text: "thinking",
      calls: [
        model.tool_call(
          id: "same-id",
          name: "calc",
          arguments_json: "{\"x\":7}",
        )
        |> model.with_provider_replay(
          id: Some("same-id"),
          state: Some("call-signature"),
        ),
      ],
      data: google_data,
      replayed: "{\"role\":\"model\",\"parts\":[{\"opaque\":true,\"text\":\"thinking\",\"thoughtSignature\":\"text-signature\"},{\"inlineData\":{\"data\":\"c2lnbmVkLWJ5dGVz\",\"mimeType\":\"image/png\"},\"thoughtSignature\":\"image-signature\"},{\"functionCall\":{\"args\":{\"x\":7},\"id\":\"same-id\",\"name\":\"calc\"},\"thoughtSignature\":\"call-signature\"}]}",
    ),
    Fixture(
      provider: message.OpenAI,
      text: "",
      calls: [
        model.tool_call(
          id: "call_a",
          name: "lookup_weather",
          arguments_json: "{\"city\":\"Paris\"}",
        )
          |> model.with_provider_replay(id: Some("call_a"), state: None),
        model.tool_call(
          id: "call_b",
          name: "transfer_funds",
          arguments_json: "{\"to\":\"bob\",\"amount\":10}",
        )
          |> model.with_provider_replay(id: Some("call_b"), state: None),
      ],
      data: "{\"provider\":{\"kind\":\"openai\",\"name\":null},\"response_id\":\"resp_1\",\"provider_data\":null,\"issues\":[]}",
      replayed: "[{\"type\":\"function_call\",\"call_id\":\"call_a\",\"name\":\"lookup_weather\",\"arguments\":\"{\\\"city\\\":\\\"Paris\\\"}\"},{\"type\":\"function_call\",\"call_id\":\"call_b\",\"name\":\"transfer_funds\",\"arguments\":\"{\\\"to\\\":\\\"bob\\\",\\\"amount\\\":10}\"}]",
    ),
    Fixture(
      provider: message.Anthropic,
      text: "",
      calls: [
        model.tool_call(
          id: "toolu_1",
          name: "lookup_weather",
          arguments_json: "{\"city\": ",
        )
        |> model.with_provider_replay(id: Some("toolu_1"), state: None),
      ],
      data: "{\"provider\":{\"kind\":\"anthropic\",\"name\":null},\"response_id\":\"msg_1\",\"provider_data\":null,\"issues\":[{\"call_id\":\"toolu_1\",\"reason\":\"Invalid JSON in tool call arguments\"}]}",
      replayed: "{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"lookup_weather\",\"input\":{\"unparsed_arguments\":\"{\\\"city\\\": \"}}]}",
    ),
    Fixture(
      provider: message.Custom("scripted"),
      text: "",
      calls: [
        model.tool_call(
          id: "call_a",
          name: "lookup_weather",
          arguments_json: "{\"town\":\"Paris\"}",
        ),
        model.tool_call(id: "call_b", name: "ghost", arguments_json: "{}"),
      ],
      data: "{\"provider\":{\"kind\":\"custom\",\"name\":\"scripted\"},\"response_id\":null,\"provider_data\":null,\"issues\":[{\"call_id\":\"call_a\",\"reason\":\"Tool call arguments failed schema validation: $: unknown field\"},{\"call_id\":\"call_b\",\"reason\":null}]}",
      replayed: "{\"role\":\"assistant\",\"content\":\"\",\"calls\":[{\"id\":\"call_a\",\"name\":\"lookup_weather\",\"arguments\":\"{\\\"town\\\":\\\"Paris\\\"}\"},{\"id\":\"call_b\",\"name\":\"ghost\",\"arguments\":\"{}\"}]}",
    ),
  ]
}

fn calc_tool() -> tool.Tool(Nil) {
  tool.define(
    "calc",
    "Calculate a number",
    codecs.one_field("x", codec.int()),
    codec.int(),
  )
  |> tool.bind(fn(_: Nil, _call, value: Int) { Ok(value * 2) }, tool.Explain)
}

fn config(
  fake: fake_provider.Fake,
  provider: message.Provider,
) -> llm_wire.Config {
  case provider {
    message.OpenAI -> fake_provider.openai(fake)
    message.Anthropic -> fake_provider.anthropic(fake)
    message.Google -> fake_provider.google(fake, "fixture-key")
    message.Custom(_) -> fake_provider.scripted(fake)
  }
}

/// Answers the first request with the stored turn and every later request
/// through llm_wire, so the next request replays the stored record.
fn replaying(fixture: Fixture, wire: model.Model) -> model.Model {
  let stored =
    model.AssistantTurn(
      fixture.text,
      fixture.calls,
      Some(model.ProviderData("llm_wire.turn.v1", fixture.data)),
    )
  model.new(fn(request: model.Request) {
    case list.any(request.messages, is_assistant) {
      False -> Ok(model.ToolRequest(stored, None))
      True -> model_port.call(wire, request)
    }
  })
}

fn is_assistant(message: model.Message) -> Bool {
  case message {
    model.AssistantMessage(_) -> True
    _ -> False
  }
}

/// The part of a request that carries the replayed turn.
fn replayed_turn(provider: message.Provider, body: String) -> Dynamic {
  let items = fn(path) {
    let assert Ok(items) =
      json.parse(body, decode.at(path, decode.list(decode.dynamic)))
    items
  }
  case provider {
    message.Google -> {
      let assert [_, turn, ..] = items(["contents"])
      turn
    }
    message.Anthropic | message.Custom(_) -> {
      let assert [_, turn, ..] = items(["messages"])
      turn
    }
    message.OpenAI ->
      items(["input"])
      |> list.filter(fn(item) {
        decode.run(item, decode.at(["type"], decode.string))
        == Ok("function_call")
      })
      |> dynamic.list
  }
}

pub fn records_from_the_earlier_release_replay_unchanged_test() {
  list.each(fixtures(), fn(fixture) {
    let fake =
      fake_provider.start([
        testing.events_for(fixture.provider, testing.text("done")),
      ])
    let wire = llm.model(fake.client, config(fake, fixture.provider), "m")
    let agent =
      agent.new(
        "fixture",
        replaying(fixture, wire),
        [apps.weather_tool(), apps.transfer_tool(), calc_tool()],
        policy.always_allow(),
      )
      |> support.agent
    let assert Ok(started) =
      fabric.start(
        support.store(),
        agent,
        id: run.new_id(),
        context: Nil,
        prompt: "go",
        correlation: None,
      )
    fabric.await(started, within: duration.milliseconds(10_000))
    |> should.equal(Ok(run.Finished(run.Completed("done"))))
    let assert [body] = fake_provider.bodies(fake)
    let assert Ok(expected) = json.parse(fixture.replayed, decode.dynamic)
    replayed_turn(fixture.provider, body) |> should.equal(expected)
    fake_provider.stop(fake)
  })
}

fn signed_reply() -> testing.Reply {
  let part = fn(fields) { json.object(fields) }
  testing.events([
    "data: "
    <> json.to_string(
      json.object([
        #("responseId", json.string("signed-response")),
        #(
          "candidates",
          json.preprocessed_array([
            json.object([
              #("finishReason", json.string("STOP")),
              #(
                "content",
                json.object([
                  #("role", json.string("model")),
                  #(
                    "parts",
                    json.preprocessed_array([
                      part([
                        #("text", json.string("thinking")),
                        #("thoughtSignature", json.string("text-signature")),
                        #("opaque", json.bool(True)),
                      ]),
                      part([
                        #(
                          "inlineData",
                          json.object([
                            #("mimeType", json.string("image/png")),
                            #("data", json.string("c2lnbmVkLWJ5dGVz")),
                          ]),
                        ),
                        #("thoughtSignature", json.string("image-signature")),
                      ]),
                      part([
                        #(
                          "functionCall",
                          json.object([
                            #("name", json.string("calc")),
                            #("id", json.string("same-id")),
                            #("args", json.object([#("x", json.int(7))])),
                          ]),
                        ),
                        #("thoughtSignature", json.string("call-signature")),
                      ]),
                    ]),
                  ),
                ]),
              ),
            ]),
          ]),
        ),
      ]),
    )
    <> "\n\n",
  ])
}

/// The response the earlier release stored as `google_data` is now stored as
/// the same bytes without `"issues":[]`.
pub fn new_records_are_the_earlier_bytes_without_issues_test() {
  let fake =
    fake_provider.start([
      signed_reply(),
      testing.events_for(message.Google, testing.text("finished")),
    ])
  let agent =
    agent.new(
      "fixture",
      llm.model(fake.client, fake_provider.google(fake, "fixture-key"), "m"),
      [calc_tool()],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(started) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  fabric.await(started, within: duration.milliseconds(10_000))
  |> should.equal(Ok(run.Finished(run.Completed("finished"))))
  let assert Ok(snapshot) = fabric.snapshot(started)
  let assert [
    _,
    model.AssistantMessage(model.AssistantTurn(
      "thinking",
      calls,
      Some(model.ProviderData("llm_wire.turn.v1", data)),
    )),
    ..
  ] = snapshot.transcript
  let assert [google] =
    fixtures()
    |> list.filter(fn(fixture) { fixture.provider == message.Google })
  calls |> should.equal(google.calls)
  data |> should.equal(string.replace(google_data, ",\"issues\":[]", ""))
  fake_provider.stop(fake)
}

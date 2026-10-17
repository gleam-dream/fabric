import fabric
import fabric/agent
import fabric/approvers
import fabric/history
import fabric/llm
import fabric/model
import fabric/policy
import fabric/reviewer
import fabric/run
import fabric/store
import fabric/testing as fabric_testing
import fabric/tool
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import http_gun
import http_gun/config as http_config
import http_gun/testing as http_testing
import json/blueprint/codec
import llm_wire
import llm_wire/anthropic
import llm_wire/generation
import llm_wire/google
import llm_wire/message
import llm_wire/openai
import llm_wire/testing
import simplifile

pub fn configured_model_applies_settings_and_preserves_native_answer_test() {
  let config = openai.new("fixture") |> openai.config
  let assert Ok(expected) =
    llm_wire.prepare(
      config,
      llm_wire.request("fixture", [llm_wire.user("answer")]),
    )
  let seen = process.new_subject()
  let script =
    http_testing.script([
      testing.exchange(expected, testing.text("{\"answer\":14}")),
    ])
    |> http_testing.matching(fn(expected, actual) {
      process.send(seen, actual.body)
      expected.method == actual.method && expected.path == actual.path
    })
  let assert Ok(client) = http_testing.playback(script, http_config.default())
  let settings =
    generation.default()
    |> generation.with_max_tokens(128)
    |> generation.with_temperature(0.2)
  let assert Ok(agent) =
    agent.new(
      "configured",
      llm.configured_model(client, config, "fixture", settings),
      [],
      policy.always_allow(),
    )
    |> agent.with_answer(codec.int())
    |> agent.build
  let runs = store.in_memory(process.new_name("generation-consumer"))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(handle) =
    fabric.start(runs, agent, run.new_id(), Nil, "answer", None)
  assert fabric.await(handle, duration.seconds(5))
    == Ok(run.Finished(run.Completed(14)))
  let assert Ok(body) = process.receive(seen, 1000)
  let assert Ok(body) = bit_array.to_string(body)
  assert json.parse(body, decode.at(["max_output_tokens"], decode.int))
    == Ok(128)
  assert json.parse(body, decode.at(["temperature"], decode.float)) == Ok(0.2)
  let assert Ok(Nil) = store.stop(runs)
  http_gun.stop(client)
}

// Caller-native input, context and answer remain outside the model settings.
type Amount {
  Amount(amount: Int)
}

type Tenant {
  Tenant(name: String, effects: process.Subject(Int))
}

fn amount_codec() {
  use amount <- codec.field("amount", codec.int(), get: fn(value: Amount) {
    value.amount
  })
  codec.success(Amount(amount))
}

fn doubling_tool() {
  tool.define("double", "Double an amount", amount_codec(), codec.int())
  |> tool.bind(
    fn(context: Tenant, _, amount) {
      assert context.name == "accounts"
      process.send(context.effects, amount.amount)
      Ok(amount.amount * 2)
    },
    tool.Explain,
  )
}

fn playback(config, replies) {
  let assert Ok(expected) =
    llm_wire.prepare(
      config,
      llm_wire.request("fixture", [llm_wire.user("answer")]),
    )
  let seen = process.new_subject()
  let script =
    list.map(replies, testing.exchange(expected, _))
    |> http_testing.script
    |> http_testing.matching(fn(expected, actual) {
      process.send(seen, actual.body)
      expected.method == actual.method && expected.path == actual.path
    })
  let assert Ok(client) = http_testing.playback(script, http_config.default())
  #(client, seen)
}

fn body(seen) {
  let assert Ok(bytes) = process.receive(seen, 1000)
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

fn memory() {
  let runs = store.in_memory(process.new_name("generation-consumer"))
  let assert Ok(Nil) = store.start(runs)
  runs
}

pub fn settings_apply_on_both_tool_turns_without_replacing_tools_or_output_test() {
  let config = openai.new("fixture") |> openai.config
  let #(client, seen) =
    playback(config, [
      testing.tool_calls("checking", [
        testing.tool_call("call1", "double", "{\"amount\":7}"),
      ]),
      testing.text("{\"amount\":14}"),
      testing.text("still usable"),
    ])
  let settings =
    generation.default()
    |> generation.with_max_tokens(128)
    |> generation.with_temperature(0.2)
    |> generation.with_top_p(0.8)
    |> generation.with_openai_prompt_cache_key("accounts-v1")
  let assert Ok(agent) =
    agent.new(
      "configured",
      llm.configured_model(client, config, "fixture", settings),
      [doubling_tool()],
      policy.always_allow(),
    )
    |> agent.with_system_prompt("Keep application policy")
    |> agent.with_answer(amount_codec())
    |> agent.build
  let context = Tenant("accounts", process.new_subject())
  let runs = memory()
  let assert Ok(handle) =
    fabric.start(runs, agent, run.new_id(), context, "answer", None)
  assert fabric.await(handle, duration.seconds(5))
    == Ok(run.Finished(run.Completed(Amount(14))))
  assert process.receive(context.effects, 1000) == Ok(7)
  let first = body(seen)
  let second = body(seen)
  list.each([first, second], fn(body) {
    assert json.parse(body, decode.at(["max_output_tokens"], decode.int))
      == Ok(128)
    assert json.parse(body, decode.at(["temperature"], decode.float)) == Ok(0.2)
    assert json.parse(body, decode.at(["top_p"], decode.float)) == Ok(0.8)
    assert json.parse(body, decode.at(["prompt_cache_key"], decode.string))
      == Ok("accounts-v1")
    assert json.parse(
        body,
        decode.at(
          ["tools"],
          decode.list(
            decode.field("name", decode.string, fn(x) { decode.success(x) }),
          ),
        ),
      )
      == Ok(["double"])
    assert json.parse(
        body,
        decode.at(
          ["text", "format", "schema", "properties", "amount", "type"],
          decode.string,
        ),
      )
      == Ok("integer")
  })
  let assert Ok(items) =
    json.parse(second, decode.at(["input"], decode.list(decode.dynamic)))
  assert list.length(items) == 5
  let assert [system, ..] = items
  assert decode.run(system, decode.at(["role"], decode.string)) == Ok("system")
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [
    model.UserMessage("answer"),
    model.AssistantMessage(turn),
    model.ToolResultMessage("call1", "14"),
    model.AssistantMessage(_),
  ] = snapshot.transcript
  let assert [call] = turn.calls
  assert call.arguments_json == "{\"amount\":7}"
  assert call.provider_id == Some("call1")
  let assert Ok(saved) = codec.encode_json(history.codec(), snapshot.transcript)
  assert codec.decode_json(history.codec(), saved) == Ok(snapshot.transcript)
  let assert Ok(Nil) = store.stop(runs)
  // Neither model nor store takes ownership of the borrowed HTTP client.
  let assert Ok(request) =
    llm_wire.prepare(
      config,
      llm_wire.request("fixture", [llm_wire.user("reuse")]),
    )
  let assert Ok(llm_wire.Answer(text: "still usable", ..)) =
    llm_wire.run(client, request)
  http_gun.stop(client)
}

pub fn reconstructed_model_keeps_google_cache_and_signed_tool_replay_test() {
  let config = google.new("fixture") |> google.config
  let signed =
    testing.events([
      "data: {\"responseId\":\"response1\",\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"id\":\"call1\",\"name\":\"double\",\"args\":{\"amount\":7}},\"thoughtSignature\":\"signed\"}]}}]}\n\n",
    ])
  let #(client, seen) =
    playback(config, [
      signed,
      testing.events_for(message.Google, testing.text("{\"answer\":14}")),
    ])
  let settings =
    generation.default()
    |> generation.with_max_tokens(96)
    |> generation.with_stop_sequences(["STOP"])
    |> generation.with_google_cached_content("cachedContents/accounts")
  let staff = fabric_testing.trusting_approvers()
  let build = fn() {
    let assert Ok(agent) =
      agent.new(
        "configured",
        llm.configured_model(client, config, "fixture", settings),
        [doubling_tool()],
        fn(_, _) { Ok(policy.RequireApproval(run.Requirement("review", 1))) },
      )
      |> agent.with_answer(codec.int())
      |> agent.with_approvers(staff)
      |> agent.build
    agent
  }
  let context = Tenant("accounts", process.new_subject())
  let directory =
    "/tmp/fabric-generation-" <> int.to_string(int.random(1_000_000_000))
  let old = store.directory(process.new_name("settings-old"), directory)
  let assert Ok(Nil) = store.start(old)
  let id = run.new_id()
  let assert Ok(handle) =
    fabric.start(old, build(), id, context, "answer", None)
  let assert Ok(run.Suspended([_], [])) =
    fabric.await(handle, duration.seconds(5))
  let first = body(seen)
  assert process.receive(context.effects, 0) == Error(Nil)
  let assert Ok(Nil) = store.stop(old)
  let restored = store.directory(process.new_name("settings-new"), directory)
  let assert Ok(Nil) = store.start(restored)
  let assert Ok(handle) = fabric.recover(restored, build(), context, id)
  let assert Ok([pending]) = fabric.pending(handle)
  let assert Ok(reviewer) = reviewer.new("reviewer")
  let assert Ok(proof) =
    approvers.check(staff, reviewer, pending.reference.requirement)
  let assert Ok(_) = fabric.approve(handle, pending.reference, proof, context)
  assert fabric.await(handle, duration.seconds(5))
    == Ok(run.Finished(run.Completed(14)))
  assert process.receive(context.effects, 1000) == Ok(7)
  let second = body(seen)
  list.each([first, second], fn(body) {
    assert json.parse(
        body,
        decode.at(["generationConfig", "maxOutputTokens"], decode.int),
      )
      == Ok(96)
    assert json.parse(
        body,
        decode.at(
          ["generationConfig", "stopSequences"],
          decode.list(decode.string),
        ),
      )
      == Ok(["STOP"])
    assert json.parse(body, decode.at(["cachedContent"], decode.string))
      == Ok("cachedContents/accounts")
    assert json.parse(
        body,
        decode.at(
          [
            "generationConfig",
            "responseJsonSchema",
            "properties",
            "answer",
            "type",
          ],
          decode.string,
        ),
      )
      == Ok("integer")
  })
  let assert Ok(contents) =
    json.parse(second, decode.at(["contents"], decode.list(decode.dynamic)))
  let assert [_, replay, result] = contents
  let assert Ok([part]) =
    decode.run(replay, decode.at(["parts"], decode.list(decode.dynamic)))
  assert decode.run(
      part,
      decode.field("thoughtSignature", decode.string, fn(x) {
        decode.success(x)
      }),
    )
    == Ok("signed")
  let assert Ok([result_part]) =
    decode.run(result, decode.at(["parts"], decode.list(decode.dynamic)))
  assert decode.run(
      result_part,
      decode.at(["functionResponse", "id"], decode.string),
    )
    == Ok("call1")
  let assert Ok(Nil) = store.stop(restored)
  let assert Ok(Nil) = simplifile.delete(directory)
  http_gun.stop(client)
}

pub fn invalid_generation_stops_before_http_and_default_constructor_still_works_test() {
  let config = openai.new("fixture") |> openai.config
  let #(client, seen) = playback(config, [testing.text("default answer")])
  let runs = memory()
  list.each(
    [
      #(config, generation.default() |> generation.with_max_tokens(0)),
      #(
        anthropic.new("fixture") |> anthropic.config,
        generation.default()
          |> generation.with_openai_prompt_cache_key("unsupported"),
      ),
    ],
    fn(example) {
      let assert Ok(agent) =
        agent.new(
          "invalid",
          llm.configured_model(client, example.0, "fixture", example.1),
          [],
          policy.always_allow(),
        )
        |> agent.build
      let assert Ok(handle) =
        fabric.start(runs, agent, run.new_id(), Nil, "answer", None)
      let assert Ok(run.Finished(run.Failed(run.ModelFailed(error)))) =
        fabric.await(handle, duration.seconds(5))
      assert model.error_kind(error) == model.InvalidRequest
      assert process.receive(seen, 0) == Error(Nil)
    },
  )
  let assert Ok(agent) =
    agent.new(
      "default",
      llm.model(client, config, "fixture"),
      [],
      policy.always_allow(),
    )
    |> agent.build
  let assert Ok(handle) =
    fabric.start(runs, agent, run.new_id(), Nil, "answer", None)
  assert fabric.await(handle, duration.seconds(5))
    == Ok(run.Finished(run.Completed("default answer")))
  let assert Error(_) =
    json.parse(body(seen), decode.at(["max_output_tokens"], decode.int))
  let assert Ok(Nil) = store.stop(runs)
  http_gun.stop(client)
}

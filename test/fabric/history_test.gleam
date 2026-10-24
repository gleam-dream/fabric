import fabric/history
import fabric/input
import fabric/model
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/codec

pub fn stored_history_restores_exact_message_values_test() {
  let messages = [
    model.UserMessage("Olá 雪\n\"quoted\" \\ path"),
    model.AssistantMessage(model.AssistantTurn(
      "first",
      [
        model.tool_call("a", "lookup", " { \"n\" : 1.00 } ")
          |> model.with_provider_replay(id: Some(""), state: None),
        model.tool_call("b", "lookup", "opaque, not JSON\n\\")
          |> model.with_provider_replay(id: None, state: Some("")),
        model.tool_call("c", "lookup", "null")
          |> model.with_provider_replay(
            id: Some("provider/雪"),
            state: Some("signature:\n\"opaque\""),
          ),
      ],
      Some(model.ProviderData("adapter.v9", "opaque\n\\ not JSON 雪")),
    )),
    model.ToolResultMessage("b", "second result"),
    model.ToolResultMessage("a", "first result"),
    model.ToolResultMessage("c", "third result"),
    model.AssistantMessage(model.AssistantTurn("answer", [], None)),
    model.AssistantMessage(model.AssistantTurn(
      "",
      [],
      Some(model.ProviderData("", "")),
    )),
  ]
  let assert Ok(encoded) = codec.encode_json(history.codec(), messages)
  codec.decode_json(history.codec(), encoded) |> should.equal(Ok(messages))
}

pub fn empty_and_partial_history_restore_without_admission_test() {
  let partial = [
    model.ToolResultMessage("unmatched", "retained suffix"),
    model.AssistantMessage(model.AssistantTurn(
      "pending",
      [model.tool_call("pending", "lookup", "{}")],
      None,
    )),
  ]
  list.each([[], partial], fn(messages) {
    let assert Ok(encoded) = codec.encode_json(history.codec(), messages)
    let assert Ok(restored) = codec.decode_json(history.codec(), encoded)
    restored |> should.equal(messages)
  })
  let assert Ok(encoded) = codec.encode_json(history.codec(), partial)
  let assert Ok(restored) = codec.decode_json(history.codec(), encoded)
  input.new(restored, "next") |> should.be_error
}

fn stored(messages: String) -> String {
  "{\"format\":\"fabric.history.v1\",\"messages\":" <> messages <> "}"
}

pub fn frozen_v1_history_restores_native_values_test() {
  codec.decode_json(
    history.codec(),
    stored(
      "[{\"tag\":\"user\",\"value\":\"question\"},{\"tag\":\"assistant\",\"value\":{\"text\":\"answer\",\"calls\":[],\"data\":null}}]",
    ),
  )
  |> should.equal(
    Ok([
      model.UserMessage("question"),
      model.AssistantMessage(model.AssistantTurn("answer", [], None)),
    ]),
  )
}

pub fn unreadable_history_refuses_restoration_test() {
  list.each(
    [
      "not JSON",
      "null",
      "[]",
      "{}",
      "{\"format\":\"fabric.history.v2\",\"messages\":[]}",
      "{\"format\":1,\"messages\":[]}",
      "{\"messages\":[]}",
      "{\"format\":\"fabric.history.v1\"}",
      "{\"format\":\"fabric.history.v1\",\"messages\":[],\"future\":true}",
      stored("{}"),
      stored("[null]"),
      stored("[{\"tag\":\"future\",\"value\":\"text\"}]"),
      stored("[{\"tag\":\"user\",\"value\":1}]"),
      stored("[{\"tag\":\"user\"}]"),
      stored("[{\"tag\":\"user\",\"value\":\"text\",\"future\":true}]"),
      stored("[{\"tag\":\"tool_result\",\"value\":{\"call_id\":\"a\"}}]"),
      stored(
        "[{\"tag\":\"tool_result\",\"value\":{\"call_id\":1,\"content\":\"text\"}}]",
      ),
      stored(
        "[{\"tag\":\"tool_result\",\"value\":{\"call_id\":\"a\",\"content\":\"text\",\"future\":true}}]",
      ),
    ],
    fn(encoded) {
      codec.decode_json(history.codec(), encoded) |> should.be_error
    },
  )
}

pub fn malformed_or_unknown_nested_replay_fields_refuse_restoration_test() {
  let valid =
    stored(
      "[{\"tag\":\"assistant\",\"value\":{\"text\":\"\",\"calls\":[{\"id\":\"a\",\"name\":\"lookup\",\"arguments_json\":\"opaque\",\"provider_id\":null,\"provider_state\":\"state\"}],\"data\":{\"format\":\"adapter.v1\",\"value\":\"opaque\"}}}]",
    )
  codec.decode_json(history.codec(), valid) |> should.be_ok
  list.each(
    [
      #("\"text\":\"\",", ""),
      #("\"text\":\"\"", "\"text\":null"),
      #("\"calls\":[", "\"future\":true,\"calls\":["),
      #("\"id\":\"a\",", ""),
      #("\"name\":\"lookup\",", ""),
      #("\"arguments_json\":\"opaque\",", ""),
      #("\"arguments_json\":\"opaque\"", "\"arguments_json\":{}"),
      #("\"provider_id\":null,", ""),
      #(
        "\"provider_id\":null",
        "\"future_call_metadata\":true,\"provider_id\":null",
      ),
      #("\"provider_id\":null", "\"provider_id\":[]"),
      #(",\"provider_state\":\"state\"", ""),
      #("\"provider_state\":\"state\"", "\"provider_state\":false"),
      #(
        "\"data\":{\"format\":\"adapter.v1\",\"value\":\"opaque\"}",
        "\"data\":false",
      ),
      #(",\"data\":{\"format\":\"adapter.v1\",\"value\":\"opaque\"}", ""),
      #("\"format\":\"adapter.v1\",", ""),
      #("\"format\":\"adapter.v1\"", "\"format\":null"),
      #(",\"value\":\"opaque\"", ""),
      #("\"value\":\"opaque\"", "\"value\":{}"),
      #("\"value\":\"opaque\"", "\"value\":\"opaque\",\"future_metadata\":true"),
    ],
    fn(change) {
      let malformed = string.replace(valid, change.0, change.1)
      malformed |> should.not_equal(valid)
      codec.decode_json(history.codec(), malformed) |> should.be_error
    },
  )
}

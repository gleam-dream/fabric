//// Scripted model port for the workflow composition experiment.
//// Maps a transcript to a deterministic reply in place of llm_wire's
//// HTTP/SSE transport.

import gleam/dynamic/decode
import gleam/json.{type Json}

pub type ToolCall {
  ToolCall(id: String, name: String, arguments: String)
}

pub type Message {
  User(text: String)
  Assistant(text: String)
  AssistantCalls(calls: List(ToolCall))
  ToolResult(call_id: String, content: String)
}

pub type Reply {
  Text(String)
  Calls(List(ToolCall))
}

/// The model port every variant consumes. `Error` is a provider failure.
pub type Model =
  fn(List(Message)) -> Result(Reply, String)

// --- persistence codec -----------------------------------------------------

pub fn encode_call(call: ToolCall) -> Json {
  json.object([
    #("id", json.string(call.id)),
    #("name", json.string(call.name)),
    #("arguments", json.string(call.arguments)),
  ])
}

pub fn call_decoder() -> decode.Decoder(ToolCall) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use arguments <- decode.field("arguments", decode.string)
  decode.success(ToolCall(id, name, arguments))
}

pub fn encode_message(message: Message) -> Json {
  case message {
    User(text) -> json.object([#("user", json.string(text))])
    Assistant(text) -> json.object([#("assistant", json.string(text))])
    AssistantCalls(calls) ->
      json.object([#("calls", json.array(calls, encode_call))])
    ToolResult(id, content) ->
      json.object([
        #("result", json.string(id)),
        #("content", json.string(content)),
      ])
  }
}

pub fn message_decoder() -> decode.Decoder(Message) {
  decode.one_of(
    {
      use text <- decode.field("user", decode.string)
      decode.success(User(text))
    },
    [
      {
        use text <- decode.field("assistant", decode.string)
        decode.success(Assistant(text))
      },
      {
        use calls <- decode.field("calls", decode.list(call_decoder()))
        decode.success(AssistantCalls(calls))
      },
      {
        use id <- decode.field("result", decode.string)
        use content <- decode.field("content", decode.string)
        decode.success(ToolResult(id, content))
      },
    ],
  )
}

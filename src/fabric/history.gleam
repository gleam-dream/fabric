//// Lossless JSON storage for application-owned message history.
////
//// Compose `codec()` into application records, or use Blueprint's
//// `encode_json` and `decode_json` directly. Storage and transaction ownership
//// remain with the application. This format is independent of Fabric's
//// execution records.

import fabric/internal/tool_call
import fabric/model
import json/blueprint/codec

/// Encodes any ordered message list, including empty lists and partial
/// generated suffixes, in a `fabric.history.v1` envelope. Decoding restores
/// every field without interpreting opaque strings or normalizing arguments.
/// `None` and `Some("")` remain distinct.
///
/// Objects are closed and all fields are required; absent replay metadata is
/// explicit `null`. Unknown fields, unsupported formats and malformed values
/// return Blueprint decoding errors. Blueprint's configurable JSON parsing
/// limits apply. Use `input.new` separately to validate restored history for
/// admission; restoration itself grants no execution authority.
pub fn codec() -> codec.Codec(List(model.Message)) {
  use _ <- codec.field(
    "format",
    codec.string_enum([#("fabric.history.v1", Nil)]),
    get: fn(_) { Nil },
  )
  use messages <- codec.field(
    "messages",
    codec.list(message_codec()),
    get: fn(messages) { messages },
  )
  codec.success(messages)
}

fn message_codec() -> codec.Codec(model.Message) {
  codec.union({
    use user <- codec.variant("user", codec.string(), model.UserMessage)
    use assistant <- codec.variant(
      "assistant",
      turn_codec(),
      model.AssistantMessage,
    )
    use tool_result <- codec.variant("tool_result", result_codec(), fn(r) {
      model.ToolResultMessage(r.0, r.1)
    })
    codec.match(fn(message) {
      case message {
        model.UserMessage(text) -> user(text)
        model.AssistantMessage(turn) -> assistant(turn)
        model.ToolResultMessage(id, content) -> tool_result(#(id, content))
      }
    })
  })
}

fn turn_codec() -> codec.Codec(model.AssistantTurn) {
  use text <- codec.field("text", codec.string(), get: fn(t) { t.text })
  use calls <- codec.field("calls", codec.list(call_codec()), get: fn(t) {
    t.calls
  })
  use data <- codec.field(
    "data",
    codec.nullable(provider_data_codec()),
    get: fn(t) { t.data },
  )
  codec.success(model.AssistantTurn(text, calls, data))
}

fn call_codec() -> codec.Codec(model.ToolCall) {
  use id <- codec.field("id", codec.string(), get: fn(c) { c.id })
  use name <- codec.field("name", codec.string(), get: fn(c) { c.name })
  use arguments_json <- codec.field(
    "arguments_json",
    codec.string(),
    get: fn(c) { c.arguments_json },
  )
  use provider_id <- codec.field(
    "provider_id",
    codec.nullable(codec.string()),
    get: fn(c) { c.provider_id },
  )
  use provider_state <- codec.field(
    "provider_state",
    codec.nullable(codec.string()),
    get: fn(c) { c.provider_state },
  )
  // Construct every field explicitly so model evolution requires a format review.
  codec.success(tool_call.ToolCall(
    id,
    name,
    arguments_json,
    provider_id,
    provider_state,
  ))
}

fn provider_data_codec() -> codec.Codec(model.ProviderData) {
  use format <- codec.field("format", codec.string(), get: fn(d) { d.format })
  use value <- codec.field("value", codec.string(), get: fn(d) { d.value })
  codec.success(model.ProviderData(format, value))
}

fn result_codec() -> codec.Codec(#(String, String)) {
  use id <- codec.field("call_id", codec.string(), get: fn(r) { r.0 })
  use content <- codec.field("content", codec.string(), get: fn(r) { r.1 })
  codec.success(#(id, content))
}

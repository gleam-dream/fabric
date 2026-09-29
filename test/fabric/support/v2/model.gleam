//// Frozen v2 types from Git 570502e928496b0203909f164a5e8fd021b8ddc8.
//// See README.md in this directory; do not adapt to current domain types.

import gleam/option.{type Option}

pub type ToolCall {
  ToolCall(
    id: String,
    name: String,
    arguments_json: String,
    provider_id: Option(String),
    provider_state: Option(String),
  )
}

pub type Message {
  UserMessage(text: String)
  /// `calls` is empty for a plain answer.
  AssistantMessage(text: String, calls: List(ToolCall))
  ToolResultMessage(call_id: String, content: String)
}

pub type ModelError {
  ModelError(reason: String, retryable: Bool)
}

//// The model port Fabric owns.
////
//// A `Model` is a function from a full `Request` to one `Reply`. Fabric keeps
//// the transcript itself and sends it whole on every turn, so a model never
//// needs hidden continuation state: a pure function of the request is a
//// complete, deterministic model, and `fabric/llm` adapts an llm_wire
//// provider to the same port.

import gleam/option.{type Option}
import json/blueprint/codec

/// A tool call as the provider issued it. `id` is unique only within one
/// model turn. `provider_id` and `provider_state` carry provider replay
/// metadata (for example a Google thought signature) that must be sent back
/// unchanged when the transcript is replayed.
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

/// A tool declaration derived from the tool's input codec.
pub type ToolSpec {
  ToolSpec(name: String, description: String, schema: codec.Schema)
}

pub type Request {
  Request(
    system: Option(String),
    messages: List(Message),
    tools: List(ToolSpec),
  )
}

/// Tokens a provider reported for one reply.
pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int)
}

/// `usage` is `None` when the provider did not report it; Fabric never treats
/// a missing report as zero.
pub type Reply {
  FinalAnswer(text: String, usage: Option(Usage))
  ToolRequest(text: String, calls: List(ToolCall), usage: Option(Usage))
  Refusal(reason: String, usage: Option(Usage))
  /// The provider stopped at its output limit. Partial tool calls are dropped.
  Truncated(partial_text: String, usage: Option(Usage))
}

/// A failed model call. `retryable` tells Fabric whether another attempt may
/// succeed; every attempt counts against the run's turn limit.
pub type ModelError {
  ModelError(reason: String, retryable: Bool)
}

pub opaque type Model {
  Model(call: fn(Request) -> Result(Reply, ModelError))
}

/// Wraps a model function. The function runs in a task owned by the run; a
/// crash is contained and reported as a non-retryable `ModelError`.
pub fn new(call: fn(Request) -> Result(Reply, ModelError)) -> Model {
  Model(call)
}

@internal
pub fn call(model: Model, request: Request) -> Result(Reply, ModelError) {
  model.call(request)
}

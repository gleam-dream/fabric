//// Deterministic models: each reply is a pure function of the transcript,
//// so replaying a transcript always yields the same reply.

import fabric/model.{
  type Message, type Model, type Reply, type ToolCall, FinalAnswer, ToolRequest,
  ToolResultMessage, Usage,
}
import fabric/support/codecs
import fabric/support/probe.{type Probe}
import fabric/tool
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import json/blueprint/codec

pub fn model(reply: fn(List(Message)) -> Reply) -> Model {
  model.new(fn(request: model.Request) { Ok(reply(request.messages)) })
}

pub fn call(id: String, name: String, arguments: String) -> ToolCall {
  model.tool_call(id: id, name: name, arguments_json: arguments)
}

/// The contents of every tool result the model has seen, in order.
pub fn results(messages: List(Message)) -> List(String) {
  list.filter_map(messages, fn(message) {
    case message {
      ToolResultMessage(_, content) -> Ok(content)
      _ -> Error(Nil)
    }
  })
}

/// Requests `calls` first; once results arrive, answers with all of them.
pub fn plan(calls: List(ToolCall)) -> Model {
  model(fn(messages) {
    case results(messages) {
      [] ->
        ToolRequest(model.AssistantTurn("", calls, None), Some(Usage(10, 5)))
      seen ->
        FinalAnswer("final: " <> string.join(seen, " | "), Some(Usage(20, 5)))
    }
  })
}

/// A tool `slow` whose body records `start:<x>`, waits at a barrier named
/// `x`, then records `end:<x>` and returns `x`.
pub fn gated_tool(probe: Probe) -> tool.Tool(ctx) {
  tool.define(
    "slow",
    "Waits for the test.",
    codecs.one_field("x", codec.string()),
    codec.string(),
  )
  |> tool.bind(
    fn(_context, _call, x: String) -> Result(String, Nil) {
      probe.record(probe, "start:" <> x)
      probe.gate(probe, x)
      probe.record(probe, "end:" <> x)
      Ok(x)
    },
    fn(_) { tool.Explain("failed") },
  )
}

pub fn slow(id: String, x: String) -> ToolCall {
  call(id, "slow", "{\"x\":\"" <> x <> "\"}")
}

/// A tool `crash` whose body records `crash:<x>` and then panics.
pub fn crashing_tool(probe: Probe) -> tool.Tool(ctx) {
  tool.define(
    "crash",
    "Crashes after its effect.",
    codecs.one_field("x", codec.string()),
    codec.string(),
  )
  |> tool.bind(
    fn(_context, _call, x: String) -> Result(String, Nil) {
      probe.record(probe, "crash:" <> x)
      panic as "the tool body crashed after its effect"
    },
    fn(_) { tool.Explain("failed") },
  )
}

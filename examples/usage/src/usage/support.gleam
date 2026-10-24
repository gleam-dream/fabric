//// Scripted models shared by the usage examples. A real application builds
//// its model with `fabric/llm.model`; these answer from the transcript so
//// each example runs offline and deterministically.

import fabric/model.{
  type Message, type Model, FinalAnswer, ToolRequest, ToolResultMessage, Usage,
}
import fabric/tool
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import json/blueprint/codec.{type Codec}

/// The content of every tool result in the transcript, oldest first.
pub fn results(messages: List(Message)) -> List(String) {
  list.filter_map(messages, fn(message) {
    case message {
      ToolResultMessage(_, content) -> Ok(content)
      _ -> Error(Nil)
    }
  })
}

/// A model that answers `text` at once.
pub fn answering(text: String) -> Model {
  model.new(fn(_request) {
    Ok(FinalAnswer(text, Some(Usage(input_tokens: 10, output_tokens: 5))))
  })
}

/// The reply of a model that calls the tool `name` once with
/// `arguments_json`, then answers with `finish` applied to the tool's
/// results. A function of the request alone, so an example can wrap it.
pub fn call_once_then(
  name: String,
  arguments_json: String,
  finish: fn(List(String)) -> String,
) -> fn(model.Request) -> Result(model.Reply, model.ModelError) {
  fn(request: model.Request) {
    let usage = Some(Usage(input_tokens: 10, output_tokens: 5))
    case results(request.messages) {
      [] ->
        Ok(ToolRequest(
          model.AssistantTurn(
            "",
            [model.tool_call(id: "c1", name:, arguments_json:)],
            None,
          ),
          usage,
        ))
      seen -> Ok(FinalAnswer(finish(seen), usage))
    }
  }
}

/// A model that calls the tool `name` once, then answers.
pub fn calling_once(
  name: String,
  arguments_json: String,
  finish: fn(List(String)) -> String,
) -> Model {
  model.new(call_once_then(name, arguments_json, finish))
}

/// An object with the one required property `name`, decoded as its value.
pub fn one_field(name: String, inner: Codec(a)) -> Codec(a) {
  use value <- codec.field(name, inner, get: fn(value) { value })
  codec.success(value)
}

/// A tool `echo` that returns its input.
pub fn echo_tool() -> tool.Tool(Nil) {
  tool.define(
    "echo",
    "Returns its input.",
    one_field("text", codec.string()),
    codec.string(),
  )
  |> tool.bind(
    fn(_context, _call, text: String) -> Result(String, Nil) { Ok(text) },
    fn(_) { tool.Explain("failed") },
  )
}

/// The signal that a tool body has started.
pub type Gate {
  Gate(arrived: Subject(Nil))
}

pub fn new_gate() -> Gate {
  Gate(arrived: process.new_subject())
}

/// A tool `wait` whose body announces its start on `gate.arrived`, then
/// blocks for half a minute unless its run is cancelled first. The body waits
/// on a subject it creates itself, because only the owning process may receive
/// from a subject.
pub fn waiting_tool(gate: Gate) -> tool.Tool(Nil) {
  tool.define(
    "wait",
    "Waits to be released.",
    one_field("text", codec.string()),
    codec.string(),
  )
  |> tool.bind(
    fn(_context, _call, text: String) -> Result(String, Nil) {
      process.send(gate.arrived, Nil)
      let _ = process.receive(process.new_subject(), 30_000)
      Ok(text)
    },
    fn(_) { tool.Explain("failed") },
  )
}

//// Adapts an llm_wire provider to the Fabric model port.
////
//// Fabric owns the conversation. Every request is prepared from its stored
//// transcript; each tool response retains provider-owned data alongside its
//// original text and calls. The same path preserves signed Google parts and
//// custom adapter data across pauses and restarts, without a live continuation.
//// The turn's provider metadata is stored with llm_wire's replay codec
//// under the `llm_wire.turn.v1` tag; earlier records still decode.
//// llm_wire validates provider data and exact result coverage before I/O.
////
//// A call's arguments are replayed exactly as the model sent them, even
//// when they were not a JSON object and were answered with
//// `invalid_arguments`; llm_wire encodes such text for each provider
//// (Anthropic and Google wrap it as `{"unparsed_arguments": text}`, OpenAI
//// sends it verbatim).
////
//// The adapter asks llm_wire to report invalid tool calls rather than fail
//// the turn (`tool.ReportInvalidToolCalls`): every call reaches Fabric, whose
//// registry answers an unknown tool or malformed arguments per call, as for
//// any other model. Names outside the tool-name grammar, duplicate call ids,
//// and bounds still fail the turn in llm_wire.

import fabric/model.{type Model, type ModelError, type Reply, type Request}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import http_gun
import json/blueprint/contract
import llm_wire
import llm_wire/error
import llm_wire/message
import llm_wire/tool

/// A model backed by llm_wire. `client` is the caller's started HTTP Gun
/// client: its destination, trust, connection policy and correlation apply to
/// every turn, and Fabric neither starts nor stops it. `config` owns the
/// provider, endpoint, credentials, limits, and timeouts. Nothing is
/// allocated until a turn runs. Killing the task that runs a turn closes its
/// HTTP stream.
pub fn model(
  client: http_gun.Client,
  config: llm_wire.Config,
  model_id: String,
) -> Model {
  let config =
    llm_wire.with_tool_call_checks(config, tool.ReportInvalidToolCalls)
  model.new(fn(request) { call(client, config, model_id, request) })
}

fn call(
  client: http_gun.Client,
  config: llm_wire.Config,
  model_id: String,
  request: Request,
) -> Result(Reply, ModelError) {
  use tools <- result.try(list.try_map(request.tools, declaration))
  use messages <- result.try(wire_messages(request))
  let wire_request =
    llm_wire.request(model_id, messages) |> llm_wire.with_tools(tools)
  use prepared <- result.try(
    llm_wire.prepare(config, wire_request)
    |> result.map_error(fn(error) {
      model.ModelError(error.describe_prepare_error(error), retryable: False)
    }),
  )
  case llm_wire.run(client, prepared) {
    Ok(llm_wire.Answer(text:, usage:, ..)) ->
      Ok(model.FinalAnswer(text, usage_of(usage)))
    Ok(llm_wire.NeedsTools(turn:, usage:, ..)) ->
      Ok(model.ToolRequest(from_wire_turn(turn), usage_of(usage)))
    Ok(llm_wire.OutputLimited(partial_text:, usage:, ..)) ->
      Ok(model.Truncated(partial_text, usage_of(usage)))
    Ok(llm_wire.Refused(reason:, usage:)) ->
      Ok(model.Refusal(reason, usage_of(usage)))
    Error(failure) -> Error(failure_of(failure))
  }
}

fn declaration(spec: model.ToolSpec) -> Result(tool.Tool, ModelError) {
  use contract <- result.try(
    contract.from_schema(spec.schema)
    |> result.map_error(fn(error) {
      model.ModelError(
        "tool "
          <> spec.name
          <> " has no admissible schema: "
          <> string.inspect(error),
        retryable: False,
      )
    }),
  )
  // A tool name outside the providers' grammar cannot be sent; retrying does
  // not help.
  tool.from_contract(spec.name, spec.description, contract)
  |> result.map_error(fn(error) {
    model.ModelError(tool.describe_error(error), retryable: False)
  })
}

fn wire_messages(
  request: Request,
) -> Result(List(message.Message), ModelError) {
  let system = case request.system {
    Some(text) -> [message.System(text)]
    None -> []
  }
  use rest <- result.map(list.try_map(request.messages, wire_message))
  list.append(system, rest)
}

/// Call ids and tool names in history are checked by `llm_wire.prepare`.
fn wire_message(message: model.Message) -> Result(message.Message, ModelError) {
  case message {
    model.UserMessage(text) -> Ok(message.User(text))
    model.AssistantMessage(turn) ->
      restore_turn(turn) |> result.map(message.Assistant)
    model.ToolResultMessage(call_id, content) ->
      Ok(message.ToolResult(call_id, content))
  }
}

fn to_wire_call(call: model.ToolCall) -> message.ToolCall {
  message.ToolCall(
    id: call.id,
    name: call.name,
    arguments_json: call.arguments_json,
    provider_id: call.provider_id,
    provider_state: call.provider_state,
  )
}

fn from_wire_call(call: message.ToolCall) -> model.ToolCall {
  model.ToolCall(
    id: call.id,
    name: call.name,
    arguments_json: call.arguments_json,
    provider_id: call.provider_id,
    provider_state: call.provider_state,
  )
}

fn usage_of(usage: Option(message.Usage)) -> Option(model.Usage) {
  option.map(usage, fn(usage) {
    model.Usage(
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
    )
  })
}

/// The wire library classifies the cause; Fabric chooses its retry policy.
/// Unknown prospects stop. Every accepted retry still spends a model turn.
fn failure_of(failure: llm_wire.Failure) -> ModelError {
  let retryable = case llm_wire.advise(failure).prospect {
    llm_wire.MayHelp -> True
    llm_wire.WillNotHelpUnchanged | llm_wire.Unknown -> False
  }
  model.ModelError(llm_wire.describe_failure(failure), retryable:)
}

// The tag of the stored provider data: llm_wire's replay fields (`provider`,
// `response_id`, `provider_data`). Records written before llm_wire owned the
// codec also carry an `issues` list, which the decoder ignores. A future
// representation change needs a new tag.
const turn_format = "llm_wire.turn.v1"

fn from_wire_turn(turn: message.AssistantTurn) -> model.AssistantTurn {
  let data = json.to_string(message.turn_replay_to_json(turn))
  model.AssistantTurn(
    turn.text,
    list.map(turn.calls, from_wire_call),
    Some(model.ProviderData(turn_format, data)),
  )
}

/// A turn without provider data is an application model's plain turn.
fn restore_turn(
  turn: model.AssistantTurn,
) -> Result(message.AssistantTurn, ModelError) {
  let calls = list.map(turn.calls, to_wire_call)
  case turn.data {
    None ->
      Ok(message.AssistantTurn(
        provider: None,
        text: turn.text,
        calls:,
        response_id: None,
        provider_data: None,
      ))
    Some(model.ProviderData(format, data)) if format == turn_format ->
      json.parse(data, message.turn_replay_decoder(turn.text, calls))
      |> result.replace_error(model.ModelError(
        "Corrupt assistant provider data",
        False,
      ))
    Some(_) ->
      Error(model.ModelError(
        "Unsupported assistant provider data format",
        False,
      ))
  }
}

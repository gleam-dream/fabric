//// Adapts an llm_wire provider to the Fabric model port.
////
//// Fabric owns the conversation. Every request is prepared from its stored
//// transcript; each tool response retains provider-owned data alongside its
//// original text and calls. The same path preserves signed Google parts and
//// custom adapter data across pauses and restarts, without a live continuation.
//// The adapter alone encodes and interprets its versioned metadata envelope.
//// llm_wire validates provider data and exact result coverage before I/O.
////
//// A call's arguments are replayed exactly as the model sent them, even
//// when they were not a JSON object and were answered with
//// `invalid_arguments`; llm_wire encodes such text for each provider
//// (Anthropic and Google wrap it as `{"unparsed_arguments": text}`, OpenAI
//// sends it verbatim).
////
//// The adapter asks llm_wire to report invalid tool calls rather than fail
//// the turn (`types.ReportInvalidToolCalls`): every call reaches Fabric, whose
//// registry answers an unknown tool or malformed arguments per call, as for
//// any other model. Names outside the tool-name grammar, duplicate call ids,
//// and bounds still fail the turn in llm_wire.

import fabric/model.{type Model, type ModelError, type Reply, type Request}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import http_gun
import json/blueprint/runtime
import llm_wire/config
import llm_wire/retry
import llm_wire/session
import llm_wire/types

/// A model backed by llm_wire. `client` is the caller's started HTTP Gun
/// client: its destination, trust and connection policy apply to every turn,
/// and Fabric neither starts nor stops it. `settings` owns the provider,
/// endpoint, credentials, limits, and deadlines. Nothing is allocated until a
/// turn runs. Killing the task that runs a turn closes its HTTP stream.
pub fn model(
  client: http_gun.Client,
  settings: config.Config,
  model_id: types.ModelId,
) -> Model {
  let settings =
    config.with_tool_call_checks(settings, types.ReportInvalidToolCalls)
  model.new(fn(request) { call(client, settings, model_id, request) })
}

fn call(
  client: http_gun.Client,
  settings: config.Config,
  model_id: types.ModelId,
  request: Request,
) -> Result(Reply, ModelError) {
  use tools <- result.try(list.try_map(request.tools, declaration))
  use messages <- result.try(wire_messages(request))
  let wire_request =
    types.new_request(model_id, messages) |> types.with_tools(tools)
  use prepared <- result.try(
    session.prepare(settings, wire_request)
    |> result.map_error(fn(error) { local_failure(error) }),
  )
  case session.run(client, prepared) {
    Ok(session.RunText(text, usage)) ->
      Ok(model.FinalAnswer(text, usage_of(usage)))
    Ok(session.RunToolCalls(turn, usage)) ->
      Ok(model.ToolRequest(from_wire_turn(turn), usage_of(usage)))
    Ok(session.RunOutputLimited(partial, _partial_calls, usage)) ->
      Ok(model.Truncated(partial, usage_of(usage)))
    Ok(session.RunRefusal(reason, usage)) ->
      Ok(model.Refusal(reason, usage_of(usage)))
    Error(session.RunFailure(error, evidence)) ->
      Error(failure(session.prepared_provider(prepared), error, evidence))
  }
}

fn declaration(
  spec: model.ToolSpec,
) -> Result(types.ToolDefinition, ModelError) {
  use name <- result.try(
    types.tool_name(spec.name) |> result.map_error(name_failure(spec.name, _)),
  )
  use contract <- result.map(
    runtime.from_schema(spec.schema)
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
  types.tool_from_contract(name, spec.description, contract)
}

fn wire_messages(request: Request) -> Result(List(types.Message), ModelError) {
  let system = case request.system {
    Some(text) -> [types.SystemMessage(text)]
    None -> []
  }
  use rest <- result.map(list.try_map(request.messages, wire_message))
  list.append(system, rest)
}

fn wire_message(message: model.Message) -> Result(types.Message, ModelError) {
  case message {
    model.UserMessage(text) -> Ok(types.UserMessage(text))
    model.AssistantMessage(model.AssistantTurn(text, [], None)) ->
      Ok(types.AssistantMessage(text))
    model.AssistantMessage(model.AssistantTurn(text, calls, None)) -> {
      use calls <- result.map(list.try_map(calls, to_wire_call))
      case text {
        "" -> types.AssistantToolCalls(calls)
        _ -> types.AssistantToolCallsWithText(text, calls)
      }
    }
    model.AssistantMessage(turn) -> {
      use restored <- result.map(restore_turn(turn))
      types.AssistantTurnMessage(restored)
    }
    model.ToolResultMessage(call_id, content) -> {
      use id <- result.map(
        types.call_id(call_id) |> result.map_error(local_failure),
      )
      types.ToolResultMessage(id, content)
    }
  }
}

fn to_wire_call(call: model.ToolCall) -> Result(types.ToolCall, ModelError) {
  use id <- result.try(
    types.call_id(call.id) |> result.map_error(local_failure),
  )
  use name <- result.map(
    types.tool_name(call.name) |> result.map_error(name_failure(call.name, _)),
  )
  types.ToolCall(
    id:,
    name:,
    arguments_json: call.arguments_json,
    provider_id: call.provider_id,
    provider_state: call.provider_state,
  )
}

fn from_wire_call(call: types.ToolCall) -> model.ToolCall {
  model.ToolCall(
    id: types.call_id_to_string(call.id),
    name: types.tool_name_to_string(call.name),
    arguments_json: call.arguments_json,
    provider_id: call.provider_id,
    provider_state: call.provider_state,
  )
}

fn usage_of(usage: Option(types.Usage)) -> Option(model.Usage) {
  option.map(usage, fn(usage) {
    model.Usage(
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
    )
  })
}

/// The wire library classifies the cause; Fabric chooses its retry policy.
/// Unknown prospects stop. Every accepted retry still spends a model turn.
fn failure(
  provider: types.Provider,
  error: types.WireError,
  evidence: types.RetryEvidence,
) -> ModelError {
  let retryable = case retry.assess(provider, error) {
    retry.MayHelp -> True
    retry.WillNotHelpUnchanged | retry.Unknown -> False
  }
  model.ModelError(
    describe(error) <> " (" <> string.inspect(evidence.classification) <> ")",
    retryable:,
  )
}

fn local_failure(error: types.WireError) -> ModelError {
  model.ModelError(describe(error), retryable: False)
}

/// A tool name outside the providers' grammar cannot be sent; retrying does
/// not help.
fn name_failure(name: String, error: types.ToolNameError) -> ModelError {
  model.ModelError(
    "tool name " <> name <> " is not admissible: " <> string.inspect(error),
    retryable: False,
  )
}

fn describe(error: types.WireError) -> String {
  case error {
    types.HttpStatusError(status_code:, ..) ->
      "HTTP status " <> int.to_string(status_code)
    other -> string.inspect(other)
  }
}

// This is Fabric's storage envelope for wire response metadata. A future wire
// representation change needs an explicit decoder here or a new format tag.
const turn_format = "llm_wire.turn.v1"

fn from_wire_turn(turn: types.AssistantTurn) -> model.AssistantTurn {
  let data =
    json.object([
      #("provider", provider_json(turn.provider)),
      #("response_id", json.nullable(turn.response_id, json.string)),
      #("provider_data", json.nullable(turn.provider_data, json.string)),
      #("issues", json.array(turn.issues, issue_json)),
    ])
    |> json.to_string
  model.AssistantTurn(
    turn.text,
    list.map(turn.calls, from_wire_call),
    Some(model.ProviderData(turn_format, data)),
  )
}

fn provider_json(provider: types.Provider) -> json.Json {
  let #(kind, name) = case provider {
    types.OpenAI -> #("openai", None)
    types.Anthropic -> #("anthropic", None)
    types.Google -> #("google", None)
    types.Custom(name) -> #("custom", Some(name))
  }
  json.object([
    #("kind", json.string(kind)),
    #("name", json.nullable(name, json.string)),
  ])
}

fn issue_json(issue: types.ToolCallIssue) -> json.Json {
  let #(id, reason) = case issue {
    types.UnknownTool(id) -> #(id, None)
    types.InvalidArguments(id, reason) -> #(id, Some(reason))
  }
  json.object([
    #("call_id", json.string(types.call_id_to_string(id))),
    #("reason", json.nullable(reason, json.string)),
  ])
}

fn restore_turn(
  turn: model.AssistantTurn,
) -> Result(types.AssistantTurn, ModelError) {
  use data <- result.try(case turn.data {
    Some(model.ProviderData(format, value)) if format == turn_format -> Ok(value)
    _ ->
      Error(model.ModelError(
        "Unsupported assistant provider data format",
        False,
      ))
  })
  let decoder = {
    use provider <- decode.field("provider", provider_decoder())
    use response_id <- decode.field(
      "response_id",
      decode.optional(decode.string),
    )
    use provider_data <- decode.field(
      "provider_data",
      decode.optional(decode.string),
    )
    use issues <- decode.field(
      "issues",
      decode.list({
        use id <- decode.field("call_id", decode.string)
        use reason <- decode.field("reason", decode.optional(decode.string))
        decode.success(#(id, reason))
      }),
    )
    decode.success(#(provider, response_id, provider_data, issues))
  }
  use #(provider, response_id, provider_data, stored_issues) <- result.try(
    json.parse(data, decoder)
    |> result.replace_error(model.ModelError(
      "Corrupt assistant provider data",
      False,
    )),
  )
  use calls <- result.try(list.try_map(turn.calls, to_wire_call))
  use issues <- result.map(
    list.try_map(stored_issues, fn(issue) {
      use id <- result.map(
        types.call_id(issue.0) |> result.map_error(local_failure),
      )
      case issue.1 {
        None -> types.UnknownTool(id)
        Some(reason) -> types.InvalidArguments(id, reason)
      }
    }),
  )
  types.AssistantTurn(
    provider,
    turn.text,
    calls,
    response_id,
    provider_data,
    issues,
  )
}

fn provider_decoder() -> decode.Decoder(types.Provider) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "openai" -> decode.success(types.OpenAI)
    "anthropic" -> decode.success(types.Anthropic)
    "google" -> decode.success(types.Google)
    "custom" ->
      decode.field("name", decode.string, fn(name) {
        decode.success(types.Custom(name))
      })
    _ -> decode.failure(types.OpenAI, "a known provider kind")
  }
}

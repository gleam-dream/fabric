//// Adapts an llm_wire provider to the Fabric model port.
////
//// Every turn re-prepares the whole request from Fabric's transcript with
//// `session.prepare`; llm_wire's in-memory `Continuation` is not used. The
//// same path therefore works within one process lifetime and after a
//// restart. What this gives up:
////
//// - Google: raw non-call parts of a tool turn (text or thought parts) are
////   not replayed; call ids and thought signatures are, through
////   `provider_id` and `provider_state`.
//// - Custom providers: a `provider.Replay` closure is not used; the
////   adapter's plain encoder rebuilds the request.
//// - llm_wire's exact result-coverage check at `prepare_continue`; Fabric's
////   controller only continues when every call has exactly one result.
////
//// llm_wire validates tool-call arguments and tool names while it reads the
//// response, so through this adapter an unknown tool or malformed arguments
//// arrive as a failed model call (`ModelError`), not as the per-call
//// outcomes Fabric reports for models that pass them through.

import fabric/model.{type Model, type ModelError, type Reply, type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import json/blueprint/runtime
import llm_wire/config
import llm_wire/session
import llm_wire/types

/// A model backed by llm_wire. `settings` owns the provider, endpoint,
/// credentials, limits, and deadlines; nothing is allocated until a turn
/// runs. Killing the task that runs a turn closes its HTTP stream.
pub fn model(settings: config.Config, model_id: types.ModelId) -> Model {
  model.new(fn(request) { call(settings, model_id, request) })
}

fn call(
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
    |> result.map_error(fn(error) { failure(error, None) }),
  )
  case session.run(prepared) {
    Ok(session.RunText(text, usage)) ->
      Ok(model.FinalAnswer(text, usage_of(usage)))
    Ok(session.RunToolCalls(text, calls, _continuation, usage)) ->
      Ok(model.ToolRequest(
        text,
        list.map(calls, from_wire_call),
        usage_of(usage),
      ))
    Ok(session.RunOutputLimited(partial, _partial_calls, usage)) ->
      Ok(model.Truncated(partial, usage_of(usage)))
    Ok(session.RunRefusal(reason, usage)) ->
      Ok(model.Refusal(reason, usage_of(usage)))
    Error(session.RunFailure(error, retry)) ->
      Error(failure(error, Some(retry)))
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
    model.AssistantMessage(text, []) -> Ok(types.AssistantMessage(text))
    model.AssistantMessage(text, calls) -> {
      use calls <- result.map(list.try_map(calls, to_wire_call))
      case text {
        "" -> types.AssistantToolCalls(calls)
        _ -> types.AssistantToolCallsWithText(text, calls)
      }
    }
    model.ToolResultMessage(call_id, content) -> {
      use id <- result.map(
        types.call_id(call_id) |> result.map_error(failure(_, None)),
      )
      types.ToolResultMessage(id, content)
    }
  }
}

fn to_wire_call(call: model.ToolCall) -> Result(types.ToolCall, ModelError) {
  use id <- result.try(
    types.call_id(call.id) |> result.map_error(failure(_, None)),
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

/// Only failures that another attempt may cure are retryable: transport
/// trouble, deadlines, rate limits, and server errors.
fn failure(
  error: types.WireError,
  retry: Option(types.RetryEvidence),
) -> ModelError {
  let retryable = case error {
    types.TransportError(_) | types.DeadlineExceeded(_) -> True
    types.HttpStatusError(status_code: status, ..) ->
      status == 408 || status == 429 || status >= 500
    types.ConfigurationError(_)
    | types.PreparationError(_)
    | types.ProviderError(..)
    | types.ProtocolError(_)
    | types.ResourceLimitExceeded(..)
    | types.CancelledLocally
    | types.OutputValidationError(_) -> False
  }
  let evidence = case retry {
    Some(types.RetryEvidence(classification:, ..)) ->
      " (" <> string.inspect(classification) <> ")"
    None -> ""
  }
  model.ModelError(describe(error) <> evidence, retryable:)
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

//// How the native port owner admits one line from the MCP server: a reply
//// to a request, a notification, or an invalid frame.

import fabric_mcp/client.{
  type Error, type Response, InvalidResponse, RemoteError, Response,
}
import gleam/list
import gleam/option.{type Option, None, Some}
import json/blueprint/codec
import json/blueprint/value.{type Value}

pub type Frame {
  Reply(id: Int, response: Result(Response, Error))
  Notification
  InvalidFrame(String)
}

/// Called by the native port owner before another request can be dispatched.
pub fn admit_frame(raw: String) -> Frame {
  case value.parse(raw, value.default_limits()) {
    Error(_) -> InvalidFrame("invalid or unbounded JSON response")
    Ok(value.Object(fields)) -> admit_envelope(fields, raw)
    Ok(_) -> InvalidFrame("JSON-RPC message must be an object")
  }
}

fn admit_envelope(fields: List(#(String, Value)), raw: String) -> Frame {
  case
    field(fields, "jsonrpc"),
    field(fields, "id"),
    field(fields, "method"),
    field(fields, "params")
  {
    Some(value.String("2.0")), Some(wire_id), None, None ->
      case codec.decode(codec.int(), wire_id) {
        Ok(id) if id > 0 && id <= 9_007_199_254_740_991 ->
          case decode_payload(id, fields, raw) {
            Error(InvalidResponse(reason)) -> InvalidFrame(reason)
            response -> Reply(id, response)
          }
        _ -> InvalidFrame("invalid JSON-RPC response ID")
      }
    Some(value.String("2.0")), None, Some(value.String(method)), params -> {
      let valid_params = case params {
        None | Some(value.Object(_)) -> True
        _ -> False
      }
      case
        method != ""
        && valid_params
        && field(fields, "result") == None
        && field(fields, "error") == None
      {
        True -> Notification
        False -> InvalidFrame("invalid JSON-RPC notification")
      }
    }
    _, _, _, _ -> InvalidFrame("invalid JSON-RPC envelope")
  }
}

fn decode_payload(
  id: Int,
  fields: List(#(String, Value)),
  raw: String,
) -> Result(Response, Error) {
  case field(fields, "result"), field(fields, "error") {
    Some(value.Object(_) as payload), None -> Ok(Response(id, payload, raw))
    None, Some(value.Object(error)) ->
      case field(error, "code"), field(error, "message") {
        Some(code), Some(value.String(message)) ->
          case codec.decode(codec.int(), code) {
            Ok(code) -> Error(RemoteError(code, message, field(error, "data")))
            Error(_) ->
              Error(InvalidResponse("JSON-RPC error code must be an integer"))
          }
        _, _ -> Error(InvalidResponse("invalid JSON-RPC error"))
      }
    _, _ -> Error(InvalidResponse("response must contain one result or error"))
  }
}

fn field(fields: List(#(String, Value)), name: String) -> Option(Value) {
  list.key_find(fields, name) |> option.from_result
}

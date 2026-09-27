//// What one erased tool invocation reports, and the canonical model-visible
//// encoding of failures.

import gleam/int
import gleam/json
import gleam/string
import json/blueprint/codec

pub type Outcome {
  /// The handler succeeded; `content` is the encoded output.
  Returned(content: String)
  /// A typed failure the model may see; `content` is already encoded.
  FailedVisibly(content: String)
  /// The effect may or may not have happened.
  EffectUncertain(evidence: String)
  /// The arguments no longer decode. Admission checks them first, so this
  /// indicates a codec that changed behaviour between admission and call.
  ArgumentsRejected(detail: String)
  /// The handler returned a value its output codec cannot encode.
  OutputUnencodable(detail: String)
}

/// `{"error": message}`: the one encoding for every model-visible failure.
pub fn error_content(message: String) -> String {
  json.to_string(json.object([#("error", json.string(message))]))
}

/// `{"error": kind, "detail": detail}` for failures Fabric itself reports.
pub fn error_detail_content(kind: String, detail: String) -> String {
  json.to_string(
    json.object([
      #("error", json.string(kind)),
      #("detail", json.string(detail)),
    ]),
  )
}

pub fn describe_decode_error(error: codec.JsonDecodeError) -> String {
  case error {
    codec.BlueprintParserFailure(codec.BlueprintJsonParseFailure(
      location:,
      reason:,
    )) ->
      "invalid JSON at line "
      <> int.to_string(location.line)
      <> ", column "
      <> int.to_string(location.column)
      <> ": "
      <> string.inspect(reason)
    codec.NativeJsonFailure(error) -> "invalid JSON: " <> string.inspect(error)
    codec.TypedCodecFailure(error) -> describe_value_error(error, "$")
  }
}

fn describe_value_error(error: codec.DecodeError, path: String) -> String {
  case error {
    codec.DecodeAtField(field, inner) ->
      describe_value_error(inner, path <> "." <> field)
    codec.DecodeAtIndex(index, inner) ->
      describe_value_error(inner, path <> "[" <> int.to_string(index) <> "]")
    codec.CannotDecode(reason) -> path <> ": " <> describe_reason(reason)
  }
}

fn describe_reason(reason: codec.DecodeReason) -> String {
  case reason {
    codec.DecodeExpectedString -> "expected a string"
    codec.DecodeExpectedInt -> "expected an integer"
    codec.DecodeExpectedNumber -> "expected a number"
    codec.DecodeExpectedBool -> "expected a boolean"
    codec.DecodeExpectedArray -> "expected an array"
    codec.DecodeExpectedObject -> "expected an object"
    codec.DecodeMissingProperty(name) -> "missing property " <> name
    codec.DecodeUnknownProperty(name) -> "unknown property " <> name
    codec.DecodeDuplicateProperty(name) -> "duplicate property " <> name
    other -> string.inspect(other)
  }
}

pub fn describe_encode_error(error: codec.EncodeError) -> String {
  case error {
    codec.EncodeAtField(field, inner) ->
      field <> ": " <> describe_encode_error(inner)
    codec.EncodeAtIndex(index, inner) ->
      int.to_string(index) <> ": " <> describe_encode_error(inner)
    codec.CannotEncode(reason) -> string.inspect(reason)
  }
}

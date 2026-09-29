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
  /// The arguments no longer decode, or the tool is not registered.
  /// Admission checks both first, so this means the tool changed between
  /// admission and start: a host failure, never shown to the model.
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

pub fn describe_encode_error(error: codec.EncodeError) -> String {
  case error {
    codec.EncodeAtField(field, inner) ->
      field <> ": " <> describe_encode_error(inner)
    codec.EncodeAtIndex(index, inner) ->
      int.to_string(index) <> ": " <> describe_encode_error(inner)
    codec.CannotEncode(reason) -> string.inspect(reason)
  }
}

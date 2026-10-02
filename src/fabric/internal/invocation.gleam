//// What one erased tool invocation reports, and the canonical model-visible
//// encoding of failures.

import gleam/json

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

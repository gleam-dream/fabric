//// Helpers for testing an application's agents with scripted models.
//// Production code needs nothing here. A store backend's checks are in
//// `fabric/store/conformance`.

import fabric/internal/tool as core_tool
import fabric/model.{type ToolCall}
import fabric/tool.{type Definition}
import json/blueprint/codec

/// A call to `definition` with `input` encoded by its input codec, as a
/// model would request it: for a scripted model (`model.new`) that calls
/// the application's tools. The arguments always decode under the tool
/// bound from the same definition.
pub fn call(
  definition: Definition(input, output),
  id: String,
  input: input,
) -> Result(ToolCall, codec.EncodeError) {
  core_tool.call(definition, id, input)
}

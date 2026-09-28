//// Helpers for testing an application's agents with scripted models.
//// Production code needs nothing here.

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
  tool.call(definition, id, input)
}

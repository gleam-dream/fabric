//// The representation behind `fabric/model.ToolCall`. Callers build one
//// with `model.tool_call` and read it by label; only Fabric constructs the
//// record, so that it can gain fields.

import gleam/option.{type Option}

pub type ToolCall {
  ToolCall(
    id: String,
    name: String,
    arguments_json: String,
    provider_id: Option(String),
    provider_state: Option(String),
  )
}

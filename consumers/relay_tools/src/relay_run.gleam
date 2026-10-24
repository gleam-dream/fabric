import fabric/run
import gleam/option.{type Option, None, Some}
import json/blueprint/value
import relay/client
import relay/client/output

pub fn run_of(result: client.ToolResult(a)) -> Option(run.RunId) {
  case output.meta(result, "io.github.gleam-dream/run-id") {
    Some(value.String(id)) -> run.parse_id(id) |> option.from_result
    _ -> None
  }
}

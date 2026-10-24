import fabric/invoke
import fabric/run
import gleam/option.{None, Some}
import gleam/result
import json/blueprint/value
import relay/content
import relay/tool

pub fn serve(
  definition: tool.Definition(i, a),
  service: invoke.Service(c, input, a),
  start: fn(tool.Call(s), i) -> Result(invoke.Request(c, input), tool.ToolError),
) -> Result(tool.Tool(s), invoke.ConfigError) {
  use Nil <- result.map(invoke.check(service))
  tool.handle_call(definition, fn(call, input) {
    use request <- result.try(start(call, input))
    let request =
      request
      |> invoke.with_key(tool.idempotency_key(call))
      |> invoke.with_correlation(tool.correlation(call))
      |> invoke.with_cancelled(tool.cancelled(call))
    let response = invoke.call(service, request)
    let meta = [
      #(
        "io.github.gleam-dream/run-id",
        value.String(run.id_to_string(invoke.id(response))),
      ),
    ]
    case invoke.answer(response) {
      Some(answer) -> Ok(tool.complete_with_meta(answer, meta))
      None ->
        Error(tool.error_with(
          [
            content.text(invoke.describe_response(response))
            |> content.with_meta(meta),
          ],
          Some(invoke.details(response)),
        ))
    }
  })
}

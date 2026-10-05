import fabric/graph/operation
import fabric/run
import gleam/option.{Some}
import relay/client
import relay/client/output
import relay/tool
import relay_tools

pub fn operation(
  definition: tool.Definition(i, o),
  version version: Int,
  peer peer: fn(c) -> client.Client,
) -> operation.Operation(c, i, o) {
  let assert Some(codec) = tool.output_codec(definition)
  operation.new(
    run.DefinitionId(tool.name(definition), version),
    tool.input_codec(definition),
    codec,
    fn(context, call: operation.Invocation, input) {
      peer(context)
      |> client.with_correlation(call.correlation)
      |> client.with_idempotency_key(operation.idempotency_key(call))
      |> client.call(definition, input)
      |> output.require
    },
    relay_tools.failure(tool.declaration(definition), _),
  )
}

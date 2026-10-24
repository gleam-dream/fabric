import fabric/tool
import gleam/option.{Some}
import relay/client
import relay/client/output
import relay/tool as remote

pub fn tool(
  definition: remote.Definition(i, o),
  peer peer: fn(c) -> client.Client,
) -> tool.Tool(c) {
  let declaration = remote.declaration(definition)
  let assert Some(codec) = remote.output_codec(definition)
  tool.bind(
    tool.define(
      declaration.name,
      option.unwrap(declaration.description, ""),
      remote.input_codec(definition),
      codec,
    ),
    fn(context, call: tool.Call, input) {
      peer(context)
      |> client.with_correlation(call.correlation)
      |> client.with_idempotency_key(tool.idempotency_key(call))
      |> client.call(definition, input)
      |> output.require
    },
    failure(declaration, _),
  )
}

pub fn failure(
  declaration: remote.Declaration,
  error: output.Error,
) -> tool.Failure {
  let message = output.describe_error(error)
  case output.evidence(error), declaration.annotations.read_only_hint {
    client.MaybeSent, hint if hint != Some(True) -> tool.Uncertain(message)
    _, _ -> tool.Explain(message)
  }
}

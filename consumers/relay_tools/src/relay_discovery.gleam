import fabric/tool
import gleam/option
import gleam/result
import json/blueprint/codec
import json/blueprint/contract
import relay/client
import relay/client/output
import relay/tool as remote
import relay_tools

pub type Error {
  UnsupportedName(String)
  UnsupportedSchema(contract.DocumentError)
}

pub fn describe_error(error: Error) -> String {
  case error {
    UnsupportedName(name) -> "unsupported model tool name: " <> name
    UnsupportedSchema(error) -> contract.describe_document_error(error)
  }
}

pub fn discovered(
  declaration: remote.Declaration,
  peer peer: fn(c) -> client.Client,
) -> Result(tool.Tool(c), Error) {
  use Nil <- result.try(case tool.valid_name(declaration.name) {
    True -> Ok(Nil)
    False -> Error(UnsupportedName(declaration.name))
  })
  use schema <- result.map(
    remote.input_contract(declaration) |> result.map_error(UnsupportedSchema),
  )
  tool.bind(
    tool.define(
      declaration.name,
      option.unwrap(declaration.description, ""),
      contract.value_codec(schema),
      codec.value(),
    ),
    fn(context, call: tool.Call, input) {
      peer(context)
      |> client.with_correlation(call.correlation)
      |> client.with_idempotency_key(tool.idempotency_key(call))
      |> client.call_discovered(declaration, input)
      |> output.require_discovered(declaration)
    },
    relay_tools.failure(declaration, _),
  )
}

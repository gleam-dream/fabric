//// Typed, schema-pinned MCP operations for Fabric graphs.

import fabric/graph/operation
import fabric/run
import fabric_mcp/client
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec
import json/blueprint/contract.{type Contract}
import json/blueprint/value.{type Value}

pub opaque type Tool {
  Tool(
    server: String,
    name: String,
    input: Contract,
    output: Option(Contract),
    input_schema: Value,
    output_schema: Option(Value),
  )
}

pub type ToolResult {
  ToolResult(content: List(Value), structured: Option(Value))
}

pub type Receipt(output) {
  Receipt(server: String, tool: String, value: output, raw_response: String)
}

/// Store a pinned descriptor in application configuration. Restoring it validates
/// the schemas without contacting the server, including during graph recovery.
pub fn tool_codec() -> codec.Codec(Tool) {
  codec.custom(
    encode: fn(tool: Tool) {
      Ok(
        value.Array([
          value.String("fabric.mcp.tool.v1"),
          value.String(tool.server),
          value.String(tool.name),
          tool.input_schema,
          case tool.output_schema {
            None -> value.Null
            Some(schema) -> schema
          },
        ]),
      )
    },
    decode: fn(saved) {
      case saved {
        value.Array([
          value.String("fabric.mcp.tool.v1"),
          value.String(server),
          value.String(name),
          input,
          output,
        ]) ->
          read_tool(server, name, input, case output {
            value.Null -> None
            schema -> Some(schema)
          })
          |> result.map_error(codec.decode_failure)
        _ -> Error(codec.decode_failure("invalid MCP tool descriptor format"))
      }
    },
    schema: None,
    placeholder: placeholder_tool(),
  )
}

/// A descriptor value for `codec.custom`, which needs one of the type; no
/// operation reads it.
fn placeholder_tool() -> Tool {
  // An empty object schema is always a valid contract.
  let assert Ok(empty) = contract.from_codec(codec.success(Nil))
  Tool("", "", empty, None, value.Object([]), None)
}

/// Read one remote tool's contracts. No tool is invoked by discovery.
pub fn discover(
  connection: client.Client,
  name: String,
) -> Result(Tool, String) {
  use Nil <- result.try(require(string.trim(name) != "", "empty MCP tool name"))
  use discovered <- result.try(
    client.request(connection, "server/discover", [])
    |> result.map_error(string.inspect),
  )
  use fields <- result.try(complete(discovered.result))
  use versions <- result.try(required(fields, "supportedVersions"))
  use versions <- result.try(
    codec.decode(codec.list(codec.string()), versions)
    |> result.map_error(fn(_) { "invalid supported protocol versions" }),
  )
  use Nil <- result.try(require(
    list.contains(versions, client.protocol_version),
    "server does not support the selected MCP version",
  ))
  use capabilities <- result.try(required(fields, "capabilities"))
  use capabilities <- result.try(object(capabilities))
  use tools <- result.try(required(capabilities, "tools"))
  use _ <- result.try(object(tools))
  discover_page(connection, name, None, [], None, 16)
}

fn discover_page(
  connection: client.Client,
  name: String,
  cursor: Option(String),
  seen: List(String),
  found: Option(Value),
  remaining: Int,
) -> Result(Tool, String) {
  use Nil <- result.try(require(
    remaining > 0,
    "MCP tool catalog page limit exceeded",
  ))
  let parameters = case cursor {
    None -> []
    Some(cursor) -> [#("cursor", value.String(cursor))]
  }
  use reply <- result.try(
    client.request(connection, "tools/list", parameters)
    |> result.map_error(string.inspect),
  )
  use fields <- result.try(complete(reply.result))
  use tools <- result.try(required(fields, "tools"))
  use tools <- result.try(case tools {
    value.Array(tools) -> Ok(tools)
    _ -> Error("tools must be an array")
  })
  use found <- result.try(
    list.try_fold(tools, found, fn(found, item) {
      use fields <- result.try(object(item))
      use remote_name <- result.try(required(fields, "name"))
      case remote_name {
        value.String(remote_name) if remote_name != "" ->
          case remote_name == name, found {
            True, None -> Ok(Some(item))
            True, Some(_) -> Error("duplicate MCP tool name")
            False, _ -> Ok(found)
          }
        _ -> Error("invalid MCP tool name")
      }
    }),
  )
  case field(fields, "nextCursor") {
    None ->
      case found {
        None -> Error("MCP tool is absent from the catalog")
        Some(item) -> {
          use fields <- result.try(object(item))
          use input <- result.try(required(fields, "inputSchema"))
          read_tool(
            client.server(connection),
            name,
            input,
            field(fields, "outputSchema"),
          )
        }
      }
    Some(value.String(cursor)) if cursor != "" -> {
      use Nil <- result.try(require(
        !list.contains(seen, cursor),
        "MCP catalog cursor repeated",
      ))
      discover_page(
        connection,
        name,
        Some(cursor),
        [cursor, ..seen],
        found,
        remaining - 1,
      )
    }
    Some(_) -> Error("invalid MCP catalog cursor")
  }
}

fn read_tool(
  server: String,
  name: String,
  input: Value,
  output: Option(Value),
) -> Result(Tool, String) {
  use Nil <- result.try(require(
    string.trim(server) != "" && string.trim(name) != "",
    "MCP server and tool identities must be nonempty",
  ))
  use fields <- result.try(object(input))
  use Nil <- result.try(require(
    field(fields, "type") == Some(value.String("object")),
    "MCP input schema must describe an object",
  ))
  use input_contract <- result.try(schema(input))
  use output_contract <- result.try(case output {
    None -> Ok(None)
    Some(document) -> schema(document) |> result.map(Some)
  })
  Ok(Tool(server, name, input_contract, output_contract, input, output))
}

fn schema(raw: Value) -> Result(Contract, String) {
  use fields <- result.try(object(raw))
  let document = case field(fields, "$schema") {
    None ->
      value.Object([
        #(
          "$schema",
          value.String("https://json-schema.org/draft/2020-12/schema"),
        ),
        ..fields
      ])
    Some(_) -> raw
  }
  contract.load(document) |> result.map_error(contract.describe_document_error)
}

/// Bind a descriptor to a versioned application operation. The connection comes
/// from fresh context only after policy admission. Remote annotations never
/// authorize an effect or opt it into replay.
pub fn bind(
  identity: run.Identity,
  tool: Tool,
  input: codec.Codec(input),
  output: codec.Codec(output),
  connection: fn(context) -> client.Client,
  convert: fn(ToolResult) -> Result(output, String),
) -> Result(operation.Operation(context, input, Receipt(output)), String) {
  use native <- result.try(
    contract.from_codec(input) |> result.map_error(string.inspect),
  )
  use Nil <- result.try(require(
    contract.same_schema(native, tool.input),
    "native input codec differs from MCP input schema",
  ))
  Ok(
    operation.new(
      identity,
      input,
      receipt_codec(tool, output, convert),
      fn(context, _, value) {
        use arguments <- result.try(
          codec.encode(input, value)
          |> result.map_error(fn(_) {
            operation.DefiniteFailure("MCP input cannot be encoded")
          }),
        )
        use _ <- result.try(
          contract.validate(tool.input, arguments)
          |> result.map_error(fn(_) {
            operation.DefiniteFailure("MCP input violates its retained schema")
          }),
        )
        let connection = connection(context)
        use Nil <- result.try(
          require(
            client.server(connection) == tool.server,
            "MCP server identity changed",
          )
          |> result.map_error(operation.DefiniteFailure),
        )
        use current <- result.try(
          discover(connection, tool.name)
          |> result.map_error(operation.DefiniteFailure),
        )
        use Nil <- result.try(
          require(same_tool(tool, current), "MCP tool schema changed")
          |> result.map_error(operation.DefiniteFailure),
        )
        use response <- result.try(
          client.request(connection, "tools/call", [
            #("name", value.String(tool.name)),
            #("arguments", arguments),
          ])
          |> result.map_error(call_failure),
        )
        use result <- result.try(
          tool_result(tool, response.result)
          |> result.map_error(fn(reason) {
            operation.UncertainEffect(reason <> ": " <> response.raw_json)
          }),
        )
        use native <- result.try(
          convert(result)
          |> result.map_error(fn(reason) {
            operation.UncertainEffect(
              "MCP result conversion failed: "
              <> reason
              <> ": "
              <> response.raw_json,
            )
          }),
        )
        Ok(Receipt(tool.server, tool.name, native, response.raw_json))
      },
      fn(failure) { failure },
    ),
  )
}

fn call_failure(error: client.Error) -> operation.Failure {
  case error {
    client.BeforeSend(reason) -> operation.DefiniteFailure(reason)
    client.AfterSend(_) | client.InvalidResponse(_) | client.RemoteError(..) ->
      operation.UncertainEffect(string.inspect(error))
  }
}

fn same_tool(left: Tool, right: Tool) -> Bool {
  left.server == right.server
  && left.name == right.name
  && contract.same_schema(left.input, right.input)
  && case left.output, right.output {
    None, None -> True
    Some(left), Some(right) -> contract.same_schema(left, right)
    _, _ -> False
  }
}

fn tool_result(tool: Tool, payload: Value) -> Result(ToolResult, String) {
  use fields <- result.try(complete(payload))
  use Nil <- result.try(case field(fields, "isError") {
    None | Some(value.Bool(False)) -> Ok(Nil)
    Some(value.Bool(True)) -> Error("MCP tool reported an execution error")
    Some(_) -> Error("invalid MCP tool error marker")
  })
  use content <- result.try(required(fields, "content"))
  use content <- result.try(case content {
    value.Array(items) -> Ok(items)
    _ -> Error("MCP content must be an array")
  })
  use _ <- result.try(list.try_map(content, check_content))
  let structured = field(fields, "structuredContent")
  use Nil <- result.try(case tool.output, structured {
    None, _ -> Ok(Nil)
    Some(_), None -> Error("MCP output schema requires structured content")
    Some(contract), Some(value) ->
      contract.validate(contract, value)
      |> result.map(fn(_) { Nil })
      |> result.map_error(fn(_) {
        "MCP structured result violates its output schema"
      })
  })
  Ok(ToolResult(content, structured))
}

// Preserve content and metadata unchanged, admitting the supported content
// kinds' required payload fields. Applications decide which fields to consume.
fn check_content(item: Value) -> Result(Nil, String) {
  use fields <- result.try(object(item))
  case field(fields, "type") {
    Some(value.String("text")) -> text_field(fields, "text")
    Some(value.String("image")) | Some(value.String("audio")) -> {
      use Nil <- result.try(text_field(fields, "data"))
      text_field(fields, "mimeType")
    }
    Some(value.String("resource_link")) -> {
      use Nil <- result.try(text_field(fields, "uri"))
      text_field(fields, "name")
    }
    Some(value.String("resource")) -> {
      use resource <- result.try(required(fields, "resource"))
      use resource <- result.try(object(resource))
      use Nil <- result.try(text_field(resource, "uri"))
      case field(resource, "text"), field(resource, "blob") {
        Some(value.String(_)), None | None, Some(value.String(_)) -> Ok(Nil)
        _, _ -> Error("invalid embedded MCP resource")
      }
    }
    _ -> Error("unsupported MCP content kind")
  }
}

/// The envelope stores original protocol evidence and retained contracts.
/// Its native value is reconstructed with a pure conversion, without I/O.
pub fn receipt_codec(
  tool: Tool,
  output: codec.Codec(output),
  convert: fn(ToolResult) -> Result(output, String),
) -> codec.Codec(Receipt(output)) {
  codec.custom(
    encode: fn(receipt: Receipt(output)) {
      use Nil <- result.try(
        require(
          receipt.server == tool.server && receipt.tool == tool.name,
          "MCP receipt identity mismatch",
        )
        |> result.map_error(codec.encode_failure),
      )
      use restored <- result.try(
        restore_result(tool, receipt.raw_response, output, convert)
        |> result.map_error(codec.encode_failure),
      )
      use actual <- result.try(codec.encode(output, receipt.value))
      use expected <- result.try(codec.encode(output, restored))
      use Nil <- result.try(
        require(
          actual == expected,
          "MCP native value differs from its original result",
        )
        |> result.map_error(codec.encode_failure),
      )
      Ok(
        value.Array([
          value.String("fabric.mcp.receipt.v1"),
          value.String(tool.server),
          value.String(tool.name),
          tool.input_schema,
          case tool.output_schema {
            None -> value.Null
            Some(schema) -> schema
          },
          value.String(receipt.raw_response),
        ]),
      )
    },
    decode: fn(saved) {
      case saved {
        value.Array([
          value.String("fabric.mcp.receipt.v1"),
          value.String(server),
          value.String(name),
          input,
          output_schema,
          value.String(raw),
        ]) -> {
          use saved_tool <- result.try(
            read_tool(server, name, input, case output_schema {
              value.Null -> None
              other -> Some(other)
            })
            |> result.map_error(codec.decode_failure),
          )
          use Nil <- result.try(
            require(
              same_tool(tool, saved_tool),
              "MCP receipt contract differs from deployed binding",
            )
            |> result.map_error(codec.decode_failure),
          )
          use native <- result.map(
            restore_result(tool, raw, output, convert)
            |> result.map_error(codec.decode_failure),
          )
          Receipt(server, name, native, raw)
        }
        _ -> Error(codec.decode_failure("invalid MCP receipt format"))
      }
    },
    schema: None,
    placeholder: Receipt("", "", codec.placeholder(output), ""),
  )
}

fn restore_result(
  tool: Tool,
  raw: String,
  output: codec.Codec(output),
  convert: fn(ToolResult) -> Result(output, String),
) -> Result(output, String) {
  use response <- result.try(case client.admit_frame(raw) {
    client.Reply(_, Ok(response)) -> Ok(response)
    _ -> Error("MCP receipt requires a valid successful RPC response")
  })
  use result <- result.try(tool_result(tool, response.result))
  use native <- result.try(convert(result))
  use encoded <- result.try(
    codec.encode(output, native)
    |> result.map_error(fn(_) { "MCP receipt output cannot be encoded" }),
  )
  codec.decode(output, encoded)
  |> result.map_error(fn(_) { "MCP receipt output cannot be decoded" })
}

fn complete(payload: Value) -> Result(List(#(String, Value)), String) {
  use fields <- result.try(object(payload))
  use Nil <- result.map(case field(fields, "resultType") {
    None | Some(value.String("complete")) -> Ok(Nil)
    _ -> Error("MCP interaction requires unsupported result handling")
  })
  fields
}

fn object(value: Value) -> Result(List(#(String, Value)), String) {
  case value {
    value.Object(fields) -> Ok(fields)
    _ -> Error("expected MCP object")
  }
}

fn field(fields: List(#(String, Value)), name: String) -> Option(Value) {
  list.key_find(fields, name) |> option.from_result
}

fn required(
  fields: List(#(String, Value)),
  name: String,
) -> Result(Value, String) {
  list.key_find(fields, name)
  |> result.map_error(fn(_) { "missing MCP field: " <> name })
}

fn text_field(
  fields: List(#(String, Value)),
  name: String,
) -> Result(Nil, String) {
  case field(fields, name) {
    Some(value.String(_)) -> Ok(Nil)
    _ -> Error("invalid MCP text field: " <> name)
  }
}

fn require(condition: Bool, reason: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(reason)
  }
}

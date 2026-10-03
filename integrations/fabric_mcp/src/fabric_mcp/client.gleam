//// An application-owned, bounded MCP 2026-07-28 stdio connection.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import json/blueprint/value.{type Value}

pub const protocol_version = "2026-07-28"

/// Process configuration is live context, not persisted workflow data.
///
/// `environment` is a closure returning the extra variables for the server
/// process, because they often carry credentials: `string.inspect` of an
/// `Options` or a `Client`, and crash reports that contain one, print a
/// function reference instead of the values. It runs once, when `start`
/// opens the process.
pub type Options {
  Options(
    command: String,
    arguments: List(String),
    environment: fn() -> List(#(String, String)),
    /// Each request's deadline (default 10 s), from 1 ms to 2^32 - 1 ms.
    timeout: Duration,
    max_bytes: Int,
    max_notifications: Int,
  )
}

pub fn options(command: String, arguments: List(String)) -> Options {
  Options(command, arguments, fn() { [] }, duration.seconds(10), 1_048_576, 64)
}

type Connection

pub opaque type Client {
  Client(server: String, connection: Connection, options: Options)
}

pub type Error {
  BeforeSend(reason: String)
  AfterSend(reason: String)
  InvalidResponse(reason: String)
  RemoteError(code: Int, message: String, data: Option(Value))
}

pub type Response {
  Response(request_id: Int, result: Value, raw_json: String)
}

pub fn start(server: String, options: Options) -> Result(Client, String) {
  use Nil <- result.try(
    case
      string.trim(server) != ""
      && string.trim(options.command) != ""
      && valid_timeout(options.timeout)
      && options.max_bytes >= 1024
      && options.max_bytes <= 10_485_760
      && options.max_notifications >= 0
      && options.max_notifications <= 10_000
    {
      True -> Ok(Nil)
      False -> Error("invalid MCP server identity or transport bounds")
    },
  )
  use connection <- result.map(open(
    options.command,
    options.arguments,
    options.environment(),
    options.max_bytes,
    options.max_notifications,
  ))
  Client(server, connection, options)
}

fn valid_timeout(timeout: Duration) -> Bool {
  let ms = duration.to_milliseconds(timeout)
  ms > 0 && ms <= 4_294_967_295
}

pub fn server(client: Client) -> String {
  client.server
}

pub fn stop(client: Client) -> Nil {
  close(client.connection)
}

/// Queue time is included in the deadline. The connection never retries.
/// Server error data is preserved, but does not imply absence of an effect.
pub fn request(
  client: Client,
  method: String,
  parameters: List(#(String, Value)),
) -> Result(Response, Error) {
  request_with_timeout(client, method, parameters, client.options.timeout)
}

/// Override one request's deadline without opening another connection.
/// The timeout includes time spent waiting behind an earlier request.
pub fn request_with_timeout(
  client: Client,
  method: String,
  parameters: List(#(String, Value)),
  timeout: Duration,
) -> Result(Response, Error) {
  use Nil <- result.try(case valid_timeout(timeout) {
    True -> Ok(Nil)
    False -> Error(BeforeSend("invalid MCP request timeout"))
  })
  use Nil <- result.try(
    case
      string.trim(method) == ""
      || list.any(parameters, fn(field) { field.0 == "_meta" })
    {
      True ->
        Error(BeforeSend("method must be nonempty; _meta belongs to the client"))
      False -> Ok(Nil)
    },
  )
  use params <- result.try(
    value.object([
      #(
        "_meta",
        value.Object([
          #(
            "io.modelcontextprotocol/protocolVersion",
            value.String(protocol_version),
          ),
          #(
            "io.modelcontextprotocol/clientInfo",
            value.Object([
              #("name", value.String("fabric_mcp")),
              #("version", value.String("0.1.0")),
            ]),
          ),
          #("io.modelcontextprotocol/clientCapabilities", value.Object([])),
        ]),
      ),
      ..parameters
    ])
    |> result.map_error(fn(error) {
      BeforeSend("duplicate request parameter: " <> error.key)
    }),
  )
  let raw = value.to_string(params)
  use Nil <- result.try(
    case
      bit_array.byte_size(bit_array.from_string(raw)) > client.options.max_bytes
    {
      True -> Error(BeforeSend("request exceeds byte limit"))
      False -> Ok(Nil)
    },
  )
  // Value constructors allow nested duplicate object keys. Validate the exact
  // outbound bytes before they can cause an external effect.
  use _ <- result.try(
    value.parse(raw, value.default_limits())
    |> result.map_error(fn(_) {
      BeforeSend("request is not valid bounded JSON")
    }),
  )
  send(client.connection, method, raw, duration.to_milliseconds(timeout))
}

@external(erlang, "fabric_mcp_stdio", "start")
fn open(
  command: String,
  arguments: List(String),
  environment: List(#(String, String)),
  max_bytes: Int,
  max_notifications: Int,
) -> Result(Connection, String)

@external(erlang, "fabric_mcp_stdio", "request")
fn send(
  connection: Connection,
  method: String,
  parameters: String,
  timeout: Int,
) -> Result(Response, Error)

@external(erlang, "fabric_mcp_stdio", "stop")
fn close(connection: Connection) -> Nil

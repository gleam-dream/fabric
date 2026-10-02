//// One bounded HTTP request. Configuration is live context, never a receipt.

import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub type Bounds {
  Bounds(
    timeout: Int,
    request_bytes: Int,
    response_bytes: Int,
    header_bytes: Int,
  )
}

pub fn bounds() -> Bounds {
  Bounds(20_000, 1_048_576, 1_048_576, 16_384)
}

type Endpoint {
  Endpoint(host: String, port: Int, path: String, tls: Bool)
}

/// The API key is kept as a closure, so `string.inspect` of a `Config`, and
/// crash reports or logs that contain one, print a function reference
/// instead of the key.
pub opaque type Config {
  Config(key: fn() -> String, endpoint: Endpoint, bounds: Bounds)
}

pub type Error {
  BeforeSend(String)
  AfterSend(String)
}

pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: String)
}

pub fn new(key: String) -> Result(Config, String) {
  use Nil <- result.map(
    case
      string.trim(key) != ""
      && list.all(string.to_utf_codepoints(key), fn(c) {
        let n = string.utf_codepoint_to_int(c)
        n > 32 && n < 127
      })
    {
      True -> Ok(Nil)
      False -> Error("classifier API key is empty or invalid")
    },
  )
  Config(
    fn() { key },
    Endpoint("api.typesafe.ai", 443, "/v1/systemone", True),
    bounds(),
  )
}

pub fn with_bounds(config: Config, bounds: Bounds) -> Result(Config, String) {
  use Nil <- result.map(
    case
      bounds.timeout > 0
      && bounds.timeout <= 3_600_000
      && bounds.request_bytes > 0
      && bounds.request_bytes <= 10_485_760
      && bounds.response_bytes > 0
      && bounds.response_bytes <= 10_485_760
      && bounds.header_bytes >= 1024
      && bounds.header_bytes <= 131_072
    {
      True -> Ok(Nil)
      False -> Error("invalid classifier transport bounds")
    },
  )
  Config(..config, bounds: bounds)
}

/// Remote endpoints require TLS. Plain HTTP is restricted to explicit loopback
/// endpoints for protocol testing. Redirects are never followed.
pub fn with_endpoint(config: Config, url: String) -> Result(Config, String) {
  use Nil <- result.try(
    case
      list.any(string.to_utf_codepoints(url), fn(c) {
        let n = string.utf_codepoint_to_int(c)
        n <= 32 || n == 127
      })
    {
      True -> Error("invalid classifier endpoint characters")
      False -> Ok(Nil)
    },
  )
  use parsed <- result.try(
    uri.parse(url) |> result.map_error(fn(_) { "invalid classifier endpoint" }),
  )
  case parsed {
    uri.Uri(Some(scheme), None, Some(host), port, path, None, None)
      if host != "" && path != ""
    -> {
      let tls = scheme == "https"
      use Nil <- result.try(
        case
          tls
          || scheme == "http"
          && list.contains(["127.0.0.1", "localhost", "::1"], host)
        {
          True -> Ok(Nil)
          False -> Error("classifier endpoint must use HTTPS or loopback HTTP")
        },
      )
      let port = case port {
        None ->
          case tls {
            True -> 443
            False -> 80
          }
        Some(port) -> port
      }
      use Nil <- result.map(case port > 0 && port <= 65_535 {
        True -> Ok(Nil)
        False -> Error("invalid classifier endpoint port")
      })
      Config(..config, endpoint: Endpoint(host, port, path, tls))
    }
    _ ->
      Error(
        "classifier endpoint requires a host/path without credentials, query or fragment",
      )
  }
}

pub fn post(config: Config, body: String) -> Result(Response, Error) {
  use Nil <- result.try(
    case
      bit_array.byte_size(bit_array.from_string(body))
      <= config.bounds.request_bytes
    {
      True -> Ok(Nil)
      False -> Error(BeforeSend("classifier request exceeds byte limit"))
    },
  )
  send(
    config.endpoint.host,
    config.endpoint.port,
    config.endpoint.path,
    config.endpoint.tls,
    config.key(),
    body,
    config.bounds,
  )
}

@external(erlang, "fabric_typesafe_http", "request")
fn send(
  host: String,
  port: Int,
  path: String,
  tls: Bool,
  key: String,
  body: String,
  bounds: Bounds,
) -> Result(Response, Error)

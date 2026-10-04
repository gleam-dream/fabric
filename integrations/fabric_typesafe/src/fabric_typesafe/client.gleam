//// The live configuration of a classifier operation: the caller's HTTP Gun
//// client, the API key and the endpoint. It is context, never a receipt.
////
//// The request goes through the client view the caller passes to `new`,
//// so its timeouts, body and header limits, destination policy and
//// telemetry are HTTP Gun's: bound a request with `http_gun.with_timeout`
//// or `with_deadline` on the view, and its response with
//// `http_gun.with_body_limit` or the client's configuration. Each request
//// is tagged with the graph run's correlation. HTTP Gun never retries,
//// follows a redirect or decompresses.

import fabric_typesafe/internal/transport.{Config, Endpoint}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import http_gun

/// A classifier's live configuration. `string.inspect` of one never prints
/// the API key.
pub type Config =
  transport.Config

/// A configuration that posts to TypeSafe's System One API
/// (`https://api.typesafe.ai/v1/systemone`) through `http` with `key`.
pub fn new(http: http_gun.Client, key key: String) -> Result(Config, String) {
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
    http,
    fn() { key },
    Endpoint("api.typesafe.ai", 443, "/v1/systemone", True),
  )
}

/// Remote endpoints require TLS. Plain HTTP is restricted to explicit loopback
/// endpoints for protocol testing, and HTTP Gun admits it only when every
/// address the host resolves to is loopback. Redirects are never followed.
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

//// One classifier request over the caller's HTTP Gun client.

import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/option.{type Option, None, Some}
import gleam/result
import http_gun
import http_gun/destination
import http_gun/error
import sinal/correlation.{type Correlation}

pub type Endpoint {
  Endpoint(host: String, port: Int, path: String, tls: Bool)
}

/// The API key is kept as a closure, so `string.inspect` of a `Config`, and
/// crash reports or logs that contain one, print a function reference
/// instead of the key.
pub type Config {
  Config(http: http_gun.Client, key: fn() -> String, endpoint: Endpoint)
}

/// Whether the request may have reached the classifier.
pub type Error {
  BeforeSend(String)
  AfterSend(String)
}

pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: String)
}

/// Posts `body` through the configuration's client view. The view's
/// timeouts, body limits and destination policy apply; a plaintext
/// endpoint is narrowed to loopback addresses, so the key never crosses a
/// network in clear text. `correlation` replaces the view's.
pub fn post(
  config: Config,
  body: String,
  correlation: Option(Correlation),
) -> Result(Response, Error) {
  let Endpoint(host:, port:, path:, tls:) = config.endpoint
  let http = case correlation {
    Some(correlation) -> http_gun.with_correlation(config.http, correlation)
    None -> config.http
  }
  let http = case tls {
    True -> http
    False ->
      http_gun.with_destination(
        http,
        destination.default()
          |> destination.allow_loopback
          |> destination.allow_private
          |> destination.with_plaintext(destination.PlaintextToLoopbackOnly),
      )
  }
  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_scheme(case tls {
      True -> http.Https
      False -> http.Http
    })
    |> request.set_host(host)
    |> request.set_port(port)
    |> request.set_path(path)
    |> request.set_header("authorization", "Bearer " <> config.key())
    |> request.set_header("content-type", "application/json")
    |> request.set_header("accept", "application/json")
    |> request.set_header("accept-encoding", "identity")
    |> request.set_body(bit_array.from_string(body))
  use buffered <- result.try(
    http_gun.send(http, req) |> result.map_error(failure),
  )
  let response = buffered.response
  use text <- result.map(
    bit_array.to_string(response.body)
    |> result.replace_error(AfterSend("classifier response is not UTF-8")),
  )
  Response(response.status, response.headers, text)
}

fn failure(failure: error.Failure) -> Error {
  let reason = "classifier request failed: " <> error.describe(failure)
  case error.evidence(failure) {
    error.NotSent -> BeforeSend(reason)
    error.MaybeSent -> AfterSend(reason <> "; dispatch is unknown")
  }
}

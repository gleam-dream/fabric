import fabric_typesafe/client
import fabric_typesafe/internal/transport
import gleam/list
import gleam/option.{None}
import http_gun
import http_gun/config as http_config
import json/blueprint/codec
import json/blueprint/value

pub type Server

@external(erlang, "fabric_typesafe_test_ffi", "start_server")
pub fn start() -> #(Server, String)

@external(erlang, "fabric_typesafe_test_ffi", "stop_server")
pub fn stop(server: Server) -> Nil

@external(erlang, "fabric_typesafe_test_ffi", "temp_dir")
pub fn temp_dir() -> String

@external(erlang, "fabric_typesafe_test_ffi", "remove_dir")
pub fn remove_dir(path: String) -> Nil

/// A client for the loopback fixture, linked to the test process.
pub fn http() -> http_gun.Client {
  http_with(http_config.default())
}

pub fn http_with(settings: http_config.Config) -> http_gun.Client {
  let assert Ok(http) = http_gun.start(settings |> http_config.allow_loopback)
  http
}

pub fn config(url: String, path: String) -> client.Config {
  config_over(http(), url, path)
}

pub fn config_over(
  http: http_gun.Client,
  url: String,
  path: String,
) -> client.Config {
  let assert Ok(config) = client.new(http, key: "test-key")
  let assert Ok(config) = client.with_endpoint(config, url <> path)
  config
}

pub fn post(
  config: client.Config,
  body: String,
) -> Result(transport.Response, transport.Error) {
  transport.post(config, body, None)
}

pub fn fixture(body: fn(String) -> Nil) -> Nil {
  let #(server, url) = start()
  body(url)
  stop(server)
}

pub fn field(object: value.Value, key: String) -> value.Value {
  let assert value.Object(fields) = object
  let assert Ok(value) = list.key_find(fields, key)
  value
}

pub fn parse(raw: String) -> value.Value {
  let assert Ok(value) = value.parse(raw, value.default_limits())
  value
}

pub fn stats(url: String, key: String) -> Int {
  let assert Ok(response) = post(config(url, "/stats"), "{}")
  let assert Ok(n) = codec.decode(codec.int(), field(parse(response.body), key))
  n
}

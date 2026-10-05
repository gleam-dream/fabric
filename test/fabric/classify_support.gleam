import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/list
import http_gun
import http_gun/config as http_config
import json/blueprint/codec
import json/blueprint/value
import llm_wire/classify

pub type Config {
  Config(http: http_gun.Client, settings: classify.Config)
}

pub type Server

@external(erlang, "fabric_classify_test_ffi", "start_server")
pub fn start() -> #(Server, String)

@external(erlang, "fabric_classify_test_ffi", "stop_server")
pub fn stop(server: Server) -> Nil

@external(erlang, "fabric_classify_test_ffi", "temp_dir")
pub fn temp_dir() -> String

@external(erlang, "fabric_classify_test_ffi", "remove_dir")
pub fn remove_dir(path: String) -> Nil

pub fn http() -> http_gun.Client {
  http_with(http_config.default())
}

pub fn http_with(settings: http_config.Config) -> http_gun.Client {
  let assert Ok(http) = http_gun.start(settings |> http_config.allow_loopback)
  http
}

pub fn settings() -> classify.Config {
  classify.config(fn() { "test-key" })
}

pub fn config(url: String, path: String) -> Config {
  config_over(http(), url, path)
}

pub fn config_over(http: http_gun.Client, url: String, path: String) -> Config {
  Config(http, settings() |> classify.with_endpoint(url <> path))
}

pub fn fixture(body: fn(String) -> Nil) -> Nil {
  let #(server, url) = start()
  body(url)
  stop(server)
}

pub fn stats(url: String, key: String) -> Int {
  let assert Ok(req) = request.to(url <> "/stats")
  let assert Ok(buffered) =
    http_gun.send(
      http(),
      req
        |> request.set_method(http.Post)
        |> request.set_body(bit_array.from_string("{}")),
    )
  let assert Ok(body) = bit_array.to_string(buffered.response.body)
  let assert Ok(value.Object(fields)) =
    value.parse(body, value.default_limits())
  let assert Ok(raw) = list.key_find(fields, key)
  let assert Ok(n) = codec.decode(codec.int(), raw)
  n
}

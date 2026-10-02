import fabric_typesafe/client
import gleam/list
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

pub fn config(url: String, path: String) -> client.Config {
  let assert Ok(config) = client.new("test-key")
  let assert Ok(config) = client.with_endpoint(config, url <> path)
  config
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
  let assert Ok(response) = client.post(config(url, "/stats"), "{}")
  let assert Ok(n) = codec.decode(codec.int(), field(parse(response.body), key))
  n
}

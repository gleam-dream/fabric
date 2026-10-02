//// llm_wire's scripted replies served over loopback HTTP to a caller-owned
//// HTTP Gun client. Request bodies are recorded in arrival order.

import gleam/list
import http_gun
import http_gun/config as http_config
import http_gun/destination
import llm_wire/config
import llm_wire/testing
import llm_wire/types

pub type Server

pub type Fake {
  Fake(server: Server, client: http_gun.Client, settings: config.Config)
}

pub fn start(replies: List(testing.Reply)) -> Fake {
  let server = start_server(list.map(replies, wire))
  // HTTP Gun's default policy rejects loopback; this client admits only it.
  let policy =
    http_config.Config(
      ..http_config.default(),
      destination: destination.Policy(
        ..destination.default(),
        allow_public: False,
        allow_loopback: True,
      ),
    )
  let assert Ok(client) = http_gun.start(policy)
  let assert Ok(endpoint) = types.endpoint(url(server))
  Fake(server, client, testing.config() |> config.with_endpoint(endpoint))
}

pub fn stop(fake: Fake) -> Nil {
  let _ = http_gun.stop(fake.client)
  stop_server(fake.server)
}

pub fn request_count(fake: Fake) -> Int {
  list.length(requests(fake.server))
}

fn wire(reply: testing.Reply) -> #(Int, List(String), Bool) {
  case reply {
    testing.Events(chunks) -> #(200, chunks, True)
    testing.Interrupted(chunks) -> #(200, chunks, False)
    testing.Status(code, body) -> #(code, [body], True)
  }
}

@external(erlang, "fabric_writing_fake_provider_ffi", "start")
fn start_server(replies: List(#(Int, List(String), Bool))) -> Server

@external(erlang, "fabric_writing_fake_provider_ffi", "url")
fn url(server: Server) -> String

@external(erlang, "fabric_writing_fake_provider_ffi", "requests")
fn requests(server: Server) -> List(#(String, String))

@external(erlang, "fabric_writing_fake_provider_ffi", "stop")
fn stop_server(server: Server) -> Nil

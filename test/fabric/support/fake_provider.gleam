//// A loopback provider for adapter tests: llm_wire's scripted replies served
//// over real HTTP to a caller-owned HTTP Gun client that admits loopback.
//// Every request body is recorded in arrival order.

import gleam/list
import http_gun
import http_gun/config as http_config
import http_gun/destination
import llm_wire
import llm_wire/anthropic
import llm_wire/google
import llm_wire/openai
import llm_wire/testing

pub type Server

pub type Fake {
  Fake(server: Server, client: http_gun.Client, url: String)
}

/// HTTP Gun's default policy rejects loopback; tests admit only loopback.
pub fn loopback() -> http_config.Config {
  http_config.default()
  |> http_config.with_destination(destination.loopback_only())
}

pub fn start(replies: List(testing.Reply)) -> Fake {
  let server = start_server(list.map(replies, wire))
  let assert Ok(client) = http_gun.start(loopback())
  Fake(server, client, url(server))
}

pub fn stop(fake: Fake) -> Nil {
  http_gun.stop(fake.client)
  stop_server(fake.server)
}

/// Request bodies in arrival order.
pub fn bodies(fake: Fake) -> List(String) {
  requests(fake.server) |> list.map(fn(request) { request.1 })
}

/// Replies not yet served.
pub fn remaining(fake: Fake) -> Int {
  remaining_replies(fake.server)
}

/// llm_wire's scripted provider, sent to this server.
pub fn scripted(fake: Fake) -> llm_wire.Config {
  testing.config() |> llm_wire.with_endpoint(fake.url)
}

pub fn openai(fake: Fake) -> llm_wire.Config {
  openai.new("sk-scripted")
  |> openai.config
  |> llm_wire.with_endpoint(fake.url <> "/v1")
}

pub fn anthropic(fake: Fake) -> llm_wire.Config {
  anthropic.new("sk-scripted")
  |> anthropic.config
  |> llm_wire.with_endpoint(fake.url <> "/v1")
}

pub fn google(fake: Fake, key: String) -> llm_wire.Config {
  google.new(key)
  |> google.config
  |> llm_wire.with_endpoint(fake.url <> "/v1beta")
}

/// `testing.http_reply` is private, so the server lowers each reply itself.
fn wire(reply: testing.Reply) -> #(Int, List(String), Bool) {
  case reply {
    testing.Events(chunks) -> #(200, chunks, True)
    testing.Interrupted(chunks) -> #(200, chunks, False)
    testing.Status(code, body) -> #(code, [body], True)
  }
}

@external(erlang, "fabric_fake_provider_ffi", "start")
fn start_server(replies: List(#(Int, List(String), Bool))) -> Server

@external(erlang, "fabric_fake_provider_ffi", "url")
fn url(server: Server) -> String

@external(erlang, "fabric_fake_provider_ffi", "requests")
fn requests(server: Server) -> List(#(String, String))

@external(erlang, "fabric_fake_provider_ffi", "remaining")
fn remaining_replies(server: Server) -> Int

@external(erlang, "fabric_fake_provider_ffi", "stop")
fn stop_server(server: Server) -> Nil

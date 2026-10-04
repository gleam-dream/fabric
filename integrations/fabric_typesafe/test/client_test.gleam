import fabric_typesafe/client
import fabric_typesafe/internal/transport
import gleam/erlang/process
import gleam/list
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/config as http_config
import support

pub fn credentials_and_endpoints_are_checked_locally_test() {
  let http = support.http()
  list.each(["", "\r\nsecret", "secret\u{0}"], fn(key) {
    client.new(http, key:) |> should.be_error
  })
  let assert Ok(config) = client.new(http, key: "test-key")
  list.each(
    [
      "http://example.com/v1/systemone",
      "https://name:secret@example.com/api",
      "https://example.com/api?secret=1",
      "https://example.com/api#fragment",
      "https://example.com/a\nb",
    ],
    fn(url) { client.with_endpoint(config, url) |> should.be_error },
  )
}

pub fn a_bounded_post_retains_status_headers_and_exact_body_without_retry_test() {
  use url <- support.fixture
  let assert Ok(response) = support.post(support.config(url, "/busy"), "{}")
  response.status |> should.equal(429)
  list.key_find(response.headers, "retry-after") |> should.equal(Ok("9"))
  string.contains(response.body, "private diagnostic body") |> should.be_true
  support.stats(url, "calls") |> should.equal(1)
  Nil
}

pub fn redirects_are_returned_without_forwarding_credentials_or_repeating_test() {
  use url <- support.fixture
  let assert Ok(response) = support.post(support.config(url, "/redirect"), "{}")
  response.status |> should.equal(307)
  support.stats(url, "calls") |> should.equal(1)
  Nil
}

/// The client's limits are HTTP Gun's: an oversize request is refused
/// before it is sent; an oversize or lost reply may have been acted on.
pub fn oversize_requests_are_unsent_but_lost_or_oversize_replies_are_uncertain_test() {
  use url <- support.fixture
  let small =
    support.http_with(
      http_config.default()
      |> http_config.with_max_request_body_bytes(16)
      |> http_config.with_max_response_body_bytes(1024)
      |> http_config.with_max_header_bytes(1024),
    )
  let assert Error(transport.BeforeSend(_)) =
    support.post(
      support.config_over(small, url, "/busy"),
      string.repeat("x", 17),
    )
  support.stats(url, "calls") |> should.equal(0)
  list.each(["/large", "/drop", "/headers"], fn(path) {
    let assert Error(transport.AfterSend(_)) =
      support.post(support.config_over(small, url, path), "{}")
    Nil
  })
  support.stats(url, "calls") |> should.equal(3)
  Nil
}

/// The view's timeout bounds the request, and a caller that exits takes
/// its request with it: HTTP Gun closes the connection both times.
pub fn deadlines_and_owner_loss_close_the_actual_http_connection_test() {
  use url <- support.fixture
  let http =
    support.http()
    |> http_gun.with_timeout(http_config.After(duration.milliseconds(100)))
  let assert Error(transport.AfterSend(_)) =
    support.post(support.config_over(http, url, "/hold"), "{}")
  await_stat(url, "disconnected", 1, 100)
  let config = support.config(url, "/hold")
  let owner =
    process.spawn_unlinked(fn() {
      let _ = support.post(config, "{}")
      Nil
    })
  await_stat(url, "calls", 2, 100)
  process.kill(owner)
  await_stat(url, "disconnected", 2, 100)
}

pub fn refused_connection_is_proven_before_dispatch_test() {
  let #(server, url) = support.start()
  support.stop(server)
  let assert Error(transport.BeforeSend(_)) =
    support.post(support.config(url, "/v1/systemone"), "{}")
}

/// The caller's destination policy applies: a client that admits no
/// loopback address refuses the loopback fixture before sending.
pub fn the_clients_destination_policy_applies_test() {
  use url <- support.fixture
  let assert Ok(public_only) = http_gun.start(http_config.default())
  let assert Error(transport.BeforeSend(reason)) =
    support.post(support.config_over(public_only, url, "/busy"), "{}")
  string.contains(reason, "test-key") |> should.be_false
  support.stats(url, "calls") |> should.equal(0)
  Nil
}

fn await_stat(url: String, key: String, expected: Int, left: Int) -> Nil {
  case support.stats(url, key) == expected, left {
    True, _ -> Nil
    False, 0 -> panic as "HTTP fixture never observed expected event"
    False, _ -> {
      process.sleep(10)
      await_stat(url, key, expected, left - 1)
    }
  }
}

pub fn inspecting_a_config_never_prints_the_api_key_test() {
  let secret = "typesafe-inspect-secret-7f3a"
  let assert Ok(config) = client.new(support.http(), key: secret)
  let assert Ok(local) =
    client.with_endpoint(config, "http://127.0.0.1:8080/v1/systemone")
  list.each([config, local], fn(config) {
    string.contains(string.inspect(config), secret) |> should.be_false
  })
}

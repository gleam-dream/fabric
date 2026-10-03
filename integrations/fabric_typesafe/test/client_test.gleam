import fabric_typesafe/client
import gleam/erlang/process
import gleam/list
import gleam/string
import gleam/time/duration
import gleeunit/should
import support

pub fn credentials_endpoints_and_bounds_are_checked_locally_test() {
  list.each(["", "\r\nsecret", "secret\u{0}"], fn(key) {
    client.new(key) |> should.be_error
  })
  let assert Ok(config) = client.new("test-key")
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
  client.with_bounds(
    config,
    client.Bounds(..client.bounds(), timeout: duration.milliseconds(0)),
  )
  |> should.be_error
}

pub fn a_bounded_post_retains_status_headers_and_exact_body_without_retry_test() {
  use url <- support.fixture
  let assert Ok(response) = client.post(support.config(url, "/busy"), "{}")
  response.status |> should.equal(429)
  list.key_find(response.headers, "retry-after") |> should.equal(Ok("9"))
  string.contains(response.body, "private diagnostic body") |> should.be_true
  support.stats(url, "calls") |> should.equal(1)
  Nil
}

pub fn redirects_are_returned_without_forwarding_credentials_or_repeating_test() {
  use url <- support.fixture
  let assert Ok(response) = client.post(support.config(url, "/redirect"), "{}")
  response.status |> should.equal(307)
  support.stats(url, "calls") |> should.equal(1)
  Nil
}

pub fn oversize_requests_are_unsent_but_lost_or_oversize_replies_are_uncertain_test() {
  use url <- support.fixture
  let assert Ok(config) =
    client.with_bounds(
      support.config(url, "/busy"),
      client.Bounds(..client.bounds(), request_bytes: 16),
    )
  let assert Error(client.BeforeSend(_)) =
    client.post(config, string.repeat("x", 17))
  support.stats(url, "calls") |> should.equal(0)
  list.each(["/large", "/drop", "/headers"], fn(path) {
    let assert Ok(config) =
      client.with_bounds(
        support.config(url, path),
        client.Bounds(
          ..client.bounds(),
          response_bytes: 1024,
          header_bytes: 1024,
        ),
      )
    let assert Error(client.AfterSend(_)) = client.post(config, "{}")
    Nil
  })
  support.stats(url, "calls") |> should.equal(3)
  Nil
}

pub fn deadlines_and_owner_loss_close_the_actual_http_connection_test() {
  use url <- support.fixture
  let assert Ok(config) =
    client.with_bounds(
      support.config(url, "/hold"),
      client.Bounds(..client.bounds(), timeout: duration.milliseconds(100)),
    )
  let assert Error(client.AfterSend(_)) = client.post(config, "{}")
  await_stat(url, "disconnected", 1, 100)
  let owner =
    process.spawn_unlinked(fn() {
      let _ = client.post(support.config(url, "/hold"), "{}")
      Nil
    })
  await_stat(url, "calls", 2, 100)
  process.kill(owner)
  await_stat(url, "disconnected", 2, 100)
}

pub fn refused_connection_is_proven_before_dispatch_test() {
  let #(server, url) = support.start()
  support.stop(server)
  let assert Error(client.BeforeSend(_)) =
    client.post(support.config(url, "/v1/systemone"), "{}")
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
  let assert Ok(config) = client.new(secret)
  let assert Ok(local) =
    client.with_endpoint(config, "http://127.0.0.1:8080/v1/systemone")
  let assert Ok(bounded) = client.with_bounds(local, client.bounds())
  list.each([config, local, bounded], fn(config) {
    string.contains(string.inspect(config), secret) |> should.be_false
  })
}

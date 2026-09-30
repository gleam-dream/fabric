import fabric_mcp/client
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import json/blueprint/value

fn settings(dir: String) -> client.Options {
  client.options("python3", [
    "-u",
    "test/support/server.py",
    dir <> "/counter.sqlite",
  ])
}

fn with_client(body: fn(client.Client, String) -> Nil) -> Nil {
  let dir = temp_dir()
  let assert Ok(connection) = client.start("local-counter", settings(dir))
  body(connection, dir)
  client.stop(connection)
  remove_dir(dir)
}

fn read(connection: client.Client, name: String) -> Int {
  let assert Ok(response) =
    client.request(connection, "tools/call", [
      #("name", value.String("counter/read")),
      #("arguments", value.Object([#("name", value.String(name))])),
    ])
  let assert Ok(answer) =
    codec.decode(
      codec.field("value", codec.int()),
      field(response.result, "structuredContent"),
    )
  answer
}

pub fn a_real_counter_survives_connection_restart_and_retains_raw_reply_test() {
  use connection, dir <- with_client
  let assert Ok(discovery) = client.request(connection, "server/discover", [])
  codec.decode(
    codec.list(codec.string()),
    field(discovery.result, "supportedVersions"),
  )
  |> should.equal(Ok([client.protocol_version]))
  let assert Ok(added) =
    client.request(connection, "tools/call", [
      #("name", value.String("counter/add")),
      #(
        "arguments",
        value.Object([
          #("name", value.String("apples")),
          #("amount", integer(7)),
        ]),
      ),
    ])
  added.request_id |> should.equal(discovery.request_id + 1)
  added.raw_json |> should.not_equal("")
  read(connection, "apples") |> should.equal(7)
  client.stop(connection)
  let assert Ok(reopened) = client.start("same-counter", settings(dir))
  read(reopened, "apples") |> should.equal(7)
  client.stop(reopened)
}

pub fn remote_error_preserves_code_message_and_data_test() {
  use connection, _ <- with_client
  client.request(connection, "unknown", [])
  |> should.equal(
    Error(client.RemoteError(
      -32_601,
      "method not found",
      Some(value.Object([#("method", value.String("unknown"))])),
    )),
  )
  read(connection, "unaffected") |> should.equal(0)
}

pub fn invalid_outbound_json_is_rejected_before_dispatch_test() {
  use connection, _ <- with_client
  let assert Error(client.BeforeSend(_)) =
    client.request(connection, "tools/call", [
      #("name", value.String("counter/add")),
      #(
        "arguments",
        value.Object([
          #("name", value.String("bad")),
          #("name", value.String("bad")),
          #("amount", integer(1)),
        ]),
      ),
    ])
  let assert Error(client.BeforeSend(_)) =
    client.request(connection, "tools/call", [#("_meta", value.Null)])
  read(connection, "bad") |> should.equal(0)
}

pub fn malformed_responses_close_the_connection_test() {
  list.each(
    ["test/duplicate", "test/wrong_id", "test/wrong_version"],
    fn(method) {
      use connection, _ <- with_client
      client.request(connection, method, []) |> should.be_error
      // A broken stream must not remain eligible to run another operation.
      client.request(connection, "server/discover", []) |> should.be_error
      Nil
    },
  )
}

pub fn response_bytes_and_ignored_notifications_are_bounded_test() {
  let dir = temp_dir()
  list.each(["test/large", "test/noise"], fn(method) {
    let assert Ok(connection) =
      client.start(
        "bounded",
        client.Options(..settings(dir), max_bytes: 1024, max_notifications: 2),
      )
    let assert Error(client.AfterSend(_)) =
      client.request(connection, method, [])
    client.request(connection, "server/discover", []) |> should.be_error
    client.stop(connection)
  })
  remove_dir(dir)
}

pub fn deadline_cancels_without_repeating_the_effect_or_accepting_a_late_reply_test() {
  let dir = temp_dir()
  let assert Ok(connection) =
    client.start("deadline", client.Options(..settings(dir), timeout: 300))
  let assert Error(client.AfterSend(_)) =
    client.request(connection, "test/hold", [#("name", value.String("expired"))])
  read(connection, "expired") |> should.equal(1)
  read(connection, "expired/cancelled") |> should.equal(1)
  client.stop(connection)
  remove_dir(dir)
}

pub fn caller_loss_cancels_but_keeps_the_application_connection_alive_test() {
  use connection, dir <- with_client
  let assert Ok(observer) = client.start("observer", settings(dir))
  let caller =
    process.spawn_unlinked(fn() {
      let _ =
        client.request(connection, "test/hold", [
          #("name", value.String("killed")),
        ])
      Nil
    })
  await_count(observer, "killed", 1, 100)
  process.kill(caller)
  read(connection, "killed/cancelled") |> should.equal(1)
  read(connection, "killed") |> should.equal(1)
  client.stop(observer)
}

pub fn lost_reply_does_not_repeat_a_real_committed_effect_test() {
  use connection, dir <- with_client
  let assert Error(client.AfterSend(_)) =
    client.request(connection, "test/exit_after_effect", [
      #("name", value.String("lost")),
    ])
  let assert Ok(observer) = client.start("observer", settings(dir))
  read(observer, "lost") |> should.equal(1)
  client.stop(observer)
}

pub fn an_expired_queued_request_never_reaches_the_service_test() {
  use connection, dir <- with_client
  let assert Ok(observer) = client.start("observer", settings(dir))
  let held =
    process.spawn_unlinked(fn() {
      let _ =
        client.request(connection, "test/hold", [
          #("name", value.String("queue")),
        ])
      Nil
    })
  await_count(observer, "queue", 1, 100)
  // Release the busy request only after the queued operation's deadline.
  let _ =
    process.spawn_unlinked(fn() {
      process.sleep(100)
      process.kill(held)
    })
  let assert Error(client.BeforeSend(_)) =
    client.request_with_timeout(
      connection,
      "tools/call",
      [
        #("name", value.String("counter/add")),
        #(
          "arguments",
          value.Object([
            #("name", value.String("never")),
            #("amount", integer(9)),
          ]),
        ),
      ],
      30,
    )
  read(observer, "never") |> should.equal(0)
  read(connection, "queue/cancelled") |> should.equal(1)
  client.stop(observer)
}

pub fn the_connection_closes_when_its_application_owner_exits_test() {
  let dir = temp_dir()
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(connection) = client.start("owned", settings(dir))
      let assert Ok(_) = client.request(connection, "server/discover", [])
      process.send(ready, connection)
      process.receive_forever(process.new_subject())
    })
  let connection = process.receive_forever(ready)
  process.kill(owner)
  await_closed(connection, 100)
  let assert Error(client.BeforeSend(_)) =
    client.request(connection, "server/discover", [])
  client.stop(connection)
  remove_dir(dir)
}

pub fn invalid_configuration_and_oversized_requests_are_definite_test() {
  let dir = temp_dir()
  client.start("", settings(dir)) |> should.be_error
  client.start("bad", client.Options(..settings(dir), timeout: 0))
  |> should.be_error
  client.start("bad", client.options("/no/such/fabric-mcp-server", []))
  |> should.be_error
  let assert Ok(connection) =
    client.start("small", client.Options(..settings(dir), max_bytes: 1024))
  let assert Error(client.BeforeSend(_)) =
    client.request(connection, "unknown", [
      #("large", value.String(string.repeat("x", 2048))),
    ])
  let assert Ok(_) = client.request(connection, "server/discover", [])
  client.stop(connection)
  remove_dir(dir)
}

fn await_closed(connection: client.Client, remaining: Int) -> Nil {
  case client.request(connection, "server/discover", []), remaining {
    Error(_), _ -> Nil
    Ok(_), 0 -> panic as "connection survived application owner"
    Ok(_), _ -> {
      process.sleep(10)
      await_closed(connection, remaining - 1)
    }
  }
}

fn await_count(
  connection: client.Client,
  name: String,
  expected: Int,
  remaining: Int,
) -> Nil {
  case read(connection, name) == expected, remaining {
    True, _ -> Nil
    False, 0 -> panic as "counter never reached expected value"
    False, _ -> {
      process.sleep(10)
      await_count(connection, name, expected, remaining - 1)
    }
  }
}

@external(erlang, "fabric_mcp_test_ffi", "temp_dir")
fn temp_dir() -> String

@external(erlang, "fabric_mcp_test_ffi", "remove_dir")
fn remove_dir(path: String) -> Nil

fn integer(n: Int) -> value.Value {
  let assert Ok(value) = codec.encode_int_value(n)
  value
}

fn field(object: value.Value, key: String) -> value.Value {
  let assert value.Object(fields) = object
  let assert Ok(found) = list.key_find(fields, key)
  found
}

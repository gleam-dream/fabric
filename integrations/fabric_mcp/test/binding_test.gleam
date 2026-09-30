import fabric/graph
import fabric/graph/definition
import fabric/policy
import fabric/run
import fabric/store
import fabric_mcp
import fabric_mcp/client
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleeunit/should
import json/blueprint/codec
import json/blueprint/value as json

type Increment {
  Increment(name: String, amount: Int)
}

fn increment_codec() -> codec.Codec(Increment) {
  let assert Ok(fields) =
    codec.record2(
      codec.required("name", codec.string()),
      codec.required("amount", codec.int()),
      Increment,
      fn(v) { v.name },
      fn(v) { v.amount },
    )
  fields
}

fn value(result: fabric_mcp.ToolResult) -> Result(Int, String) {
  case result.structured {
    Some(value) ->
      case codec.decode(codec.field("value", codec.int()), value) {
        Ok(value) -> Ok(value)
        Error(_) -> Error("expected structured counter value")
      }
    _ -> Error("missing structured result")
  }
}

fn settings(dir: String) -> client.Options {
  client.options("python3", [
    "-u",
    "test/support/server.py",
    dir <> "/counter.sqlite",
  ])
}

fn runtime(
  connection: client.Client,
  tool: fabric_mcp.Tool,
  runs: store.Store,
  admission: graph.Policy(client.Client),
) -> graph.Runtime(client.Client, Increment, fabric_mcp.Receipt(Int)) {
  runtime_converting(connection, tool, runs, admission, value)
}

fn runtime_converting(
  connection: client.Client,
  tool: fabric_mcp.Tool,
  runs: store.Store,
  admission: graph.Policy(client.Client),
  convert: fn(fabric_mcp.ToolResult) -> Result(Int, String),
) -> graph.Runtime(client.Client, Increment, fabric_mcp.Receipt(Int)) {
  let assert Ok(op) =
    fabric_mcp.bind(
      run.Identity("increment-counter", 1),
      tool,
      increment_codec(),
      codec.int(),
      fn(context) { context },
      convert,
    )
  let assert Ok(id) = definition.node_id("increment")
  let node =
    definition.node(
      id,
      op,
      fn(input) { Ok(input) },
      fn(state, receipt) { Ok(definition.Finish(state, receipt)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("counter-graph", 1),
      id,
      [node],
      increment_codec(),
      fabric_mcp.receipt_codec(tool, codec.int(), convert),
      1,
    ))
  graph.new(spec, runs, fn() { connection }, admission)
}

pub fn a_real_mcp_operation_returns_a_native_result_and_retained_receipt_test() {
  let dir = temp_dir()
  let assert Ok(connection) = client.start("warehouse", settings(dir))
  let assert Ok(tool) = fabric_mcp.discover(connection, "counter/add")
  let runs = store.in_memory(process.new_name("mcp-native"))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(id) = run.parse_id("mcp-native")
  let assert Ok(handle) =
    graph.start(
      runtime(connection, tool, runs, fn(_, _) { Ok(policy.Allow) }),
      id,
      Increment("apple", 3),
    )
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Completed(receipt) = done.status
  receipt.server |> should.equal("warehouse")
  receipt.tool |> should.equal("counter/add")
  receipt.value |> should.equal(3)
  let assert [saved] = done.receipts
  codec.decode_json(
    fabric_mcp.receipt_codec(tool, codec.int(), value),
    saved.output_json,
  )
  |> should.equal(Ok(receipt))
  client.stop(connection)
  remove_dir(dir)
}

pub fn policy_holds_the_real_effect_until_approval_test() {
  use connection, tool, _ <- fixture
  let definition =
    runtime(connection, tool, memory(), fn(_, action) {
      action.operation |> should.equal(run.Identity("increment-counter", 1))
      Ok(policy.RequireApproval(run.Requirement("counter-owner", 1)))
    })
  let assert Ok(handle) =
    graph.start(definition, id("approval"), Increment("approved", 5))
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingApproval(approval) = waiting.status
  read(connection, "approved") |> should.equal(0)
  graph.approve(handle, approval) |> should.be_ok
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Completed(receipt) = done.status
  receipt.value |> should.equal(5)
  read(connection, "approved") |> should.equal(5)
}

pub fn changed_contracts_and_server_identity_refuse_before_the_tool_effect_test() {
  list.each(
    [
      "drift",
      "no_output",
      "open_schema",
      "legacy_dialect",
      "reference_schema",
      "legacy",
      "duplicate",
      "cursor_loop",
    ],
    fn(mode) {
      use connection, tool, _ <- fixture
      configure(connection, mode)
      let assert Ok(handle) =
        graph.start(
          runtime(connection, tool, memory(), allow),
          id("drift"),
          Increment("refused", 3),
        )
      let assert Ok(done) = graph.await(handle, 5000)
      let assert graph.Failed(graph.OperationFailed(_)) = done.status
      done.receipts |> should.equal([])
      read(connection, "refused") |> should.equal(0)
      Nil
    },
  )
  use connection, tool, dir <- fixture
  let assert Ok(other) = client.start("other-server", settings(dir))
  let assert Ok(_) = client.request(other, "server/discover", [])
  let assert Ok(handle) =
    graph.start(
      runtime(other, tool, memory(), allow),
      id("wrong-server"),
      Increment("refused", 3),
    )
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Failed(graph.OperationFailed(_)) = done.status
  read(connection, "refused") |> should.equal(0)
  client.stop(other)
}

pub fn optional_output_schema_description_updates_and_paged_catalogs_work_test() {
  list.each(
    ["no_output", "description", "pages", "implicit_complete"],
    fn(mode) {
      use connection, original, _ <- fixture
      configure(connection, mode)
      let assert Ok(current) = fabric_mcp.discover(connection, "counter/add")
      let tool = case mode {
        "no_output" -> current
        _ -> original
      }
      let assert Ok(handle) =
        graph.start(
          runtime(connection, tool, memory(), allow),
          id("compatible"),
          Increment("count", 2),
        )
      let assert Ok(done) = graph.await(handle, 5000)
      let assert graph.Completed(receipt) = done.status
      receipt.value |> should.equal(2)
      Nil
    },
  )
  use connection, _, _ <- fixture
  configure(connection, "text_only")
  let assert Ok(tool) = fabric_mcp.discover(connection, "counter/add")
  let convert = fn(result: fabric_mcp.ToolResult) {
    case result.content {
      [json.Object(fields)] ->
        case list.key_find(fields, "text") {
          Ok(json.String(text)) ->
            case int.parse(text) {
              Ok(n) -> Ok(n)
              Error(_) -> Error("invalid counter text")
            }
          _ -> Error("missing counter text")
        }
      _ -> Error("expected one text item")
    }
  }
  let assert Ok(handle) =
    graph.start(
      runtime_converting(connection, tool, memory(), allow, convert),
      id("text"),
      Increment("text", 6),
    )
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Completed(receipt) = done.status
  receipt.value |> should.equal(6)
}

pub fn post_call_errors_remain_uncertain_without_routes_or_retries_test() {
  list.each(
    [
      "bad_output",
      "tool_error",
      "rpc_error",
      "input_required",
      "bad_content",
      "missing_structured",
      "exit",
    ],
    fn(mode) {
      use connection, tool, dir <- fixture
      configure(connection, mode)
      let assert Ok(handle) =
        graph.start(
          runtime(connection, tool, memory(), allow),
          id("uncertain"),
          Increment("committed", 1),
        )
      let assert Ok(blocked) = graph.await(handle, 5000)
      let assert graph.Blocked(_, graph.EffectUncertain(_)) = blocked.status
      blocked.receipts |> should.equal([])
      graph.recover(handle) |> should.be_ok
      let assert Ok(observer) = client.start("observer", settings(dir))
      read(observer, "committed") |> should.equal(1)
      client.stop(observer)
    },
  )
}

pub fn a_saved_receipt_recovers_without_a_live_connection_after_store_loss_test() {
  use connection, tool, dir <- fixture
  let assert Ok(pinned_descriptor) =
    codec.encode_json(fabric_mcp.tool_codec(), tool)
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let runs = directory(dir <> "/records")
      let assert Ok(handle) =
        graph.start(
          runtime(connection, tool, runs, allow),
          id("saved"),
          Increment("once", 8),
        )
      process.send(ready, #(runs, handle))
      process.receive_forever(process.new_subject())
    })
  let #(runs, handle) = process.receive_forever(ready)
  let assert Ok(before) = graph.await(handle, 5000)
  let assert graph.Completed(_) = before.status
  let assert Ok(store_pid) = store.pid(runs)
  let monitor = process.monitor(store_pid)
  process.kill(owner)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive_forever
  client.stop(connection)
  let assert Ok(tool) =
    codec.decode_json(fabric_mcp.tool_codec(), pinned_descriptor)
  let restored =
    graph.attach(
      runtime(connection, tool, directory(dir <> "/records"), allow),
      id("saved"),
    )
  let assert Ok(after) = graph.recover(restored)
  after.status |> should.equal(before.status)
  after.receipts |> should.equal(before.receipts)
  let assert Ok(observer) = client.start("observer", settings(dir))
  read(observer, "once") |> should.equal(8)
  client.stop(observer)
}

pub fn graph_cancellation_stops_waiting_but_retains_the_unresolved_effect_test() {
  use connection, tool, dir <- fixture
  configure(connection, "hold")
  let assert Ok(observer) = client.start("observer", settings(dir))
  let assert Ok(handle) =
    graph.start(
      runtime(connection, tool, memory(), allow),
      id("cancel"),
      Increment("cancelled", 1),
    )
  await_count(observer, "cancelled", 1, 100)
  graph.cancel(handle) |> should.be_ok
  let assert Ok(cancelled) = graph.await(handle, 5000)
  let assert graph.Cancelled(graph.Unresolved(_, _)) = cancelled.status
  cancelled.receipts |> should.equal([])
  await_count(observer, "cancelled/cancelled", 1, 100)
  graph.recover(handle) |> should.be_ok
  read(connection, "cancelled") |> should.equal(1)
  client.stop(observer)
}

pub fn output_conversion_failure_preserves_the_actual_effect_test() {
  use connection, tool, _ <- fixture
  let assert Ok(handle) =
    graph.start(
      runtime_converting(connection, tool, memory(), allow, fn(_) {
        Error("cannot interpret this result")
      }),
      id("conversion"),
      Increment("once", 1),
    )
  let assert Ok(blocked) = graph.await(handle, 5000)
  let assert graph.Blocked(_, graph.EffectUncertain(_)) = blocked.status
  blocked.receipts |> should.equal([])
  read(connection, "once") |> should.equal(1)
  Nil
}

fn await_count(
  connection: client.Client,
  name: String,
  expected: Int,
  left: Int,
) -> Nil {
  case read(connection, name) == expected, left {
    True, _ -> Nil
    False, 0 -> panic as "MCP effect was not observable"
    False, _ -> {
      process.sleep(10)
      await_count(connection, name, expected, left - 1)
    }
  }
}

pub fn protocol_content_is_preserved_for_the_application_converter_test() {
  use connection, tool, _ <- fixture
  configure(connection, "all_content")
  let convert = fn(result: fabric_mcp.ToolResult) {
    list.length(result.content) |> should.equal(6)
    value(result)
  }
  let assert Ok(handle) =
    graph.start(
      runtime_converting(connection, tool, memory(), allow, convert),
      id("content"),
      Increment("content", 1),
    )
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Completed(receipt) = done.status
  let assert Ok(raw) =
    codec.encode(fabric_mcp.receipt_codec(tool, codec.int(), convert), receipt)
  codec.decode(fabric_mcp.receipt_codec(tool, codec.int(), convert), raw)
  |> should.equal(Ok(receipt))
}

pub fn pinned_descriptors_refuse_invalid_identities_and_schema_dialects_test() {
  use _, tool, _ <- fixture
  let descriptor_codec = fabric_mcp.tool_codec()
  let assert Ok(json.Array([format, server, name, input, output])) =
    codec.encode(descriptor_codec, tool)
  let assert json.Object(fields) = input
  list.each(
    [
      [json.String("future-tool"), server, name, input, output],
      [format, json.String(""), name, input, output],
      [format, server, json.String(""), input, output],
      [
        format,
        server,
        name,
        json.Object([#("$schema", json.String("draft-07")), ..fields]),
        output,
      ],
    ],
    fn(fields) {
      codec.decode(descriptor_codec, json.Array(fields)) |> should.be_error
      Nil
    },
  )
}

pub fn incompatible_native_input_and_corrupt_receipts_are_rejected_test() {
  use connection, tool, _ <- fixture
  fabric_mcp.bind(
    run.Identity("bad", 1),
    tool,
    codec.string(),
    codec.int(),
    fn(c) { c },
    value,
  )
  |> should.be_error
  let assert Ok(handle) =
    graph.start(
      runtime(connection, tool, memory(), allow),
      id("receipt"),
      Increment("counter", 2),
    )
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Completed(receipt) = done.status
  let receipt_codec = fabric_mcp.receipt_codec(tool, codec.int(), value)
  codec.encode(receipt_codec, fabric_mcp.Receipt(..receipt, value: 3))
  |> should.be_error
  codec.encode(
    receipt_codec,
    fabric_mcp.Receipt(..receipt, tool: "counter/read"),
  )
  |> should.be_error
  let assert Ok(json.Array(saved)) = codec.encode(receipt_codec, receipt)
  let assert [format, server, name, input, output, raw] = saved
  list.each(
    [
      [json.String("future-version"), server, name, input, output, raw],
      [format, json.String("wrong-server"), name, input, output, raw],
      [format, server, name, input, json.Null, raw],
      [format, server, name, input, output, json.String("{}")],
    ],
    fn(fields) {
      codec.decode(receipt_codec, json.Array(fields)) |> should.be_error
      Nil
    },
  )
}

fn fixture(body: fn(client.Client, fabric_mcp.Tool, String) -> Nil) -> Nil {
  let dir = temp_dir()
  let assert Ok(connection) = client.start("warehouse", settings(dir))
  let assert Ok(tool) = fabric_mcp.discover(connection, "counter/add")
  body(connection, tool, dir)
  client.stop(connection)
  remove_dir(dir)
}

fn configure(connection: client.Client, mode: String) -> Nil {
  let assert Ok(_) =
    client.request(connection, "test/config", [#("mode", json.String(mode))])
  Nil
}

fn read(connection: client.Client, name: String) -> Int {
  let assert Ok(response) =
    client.request(connection, "tools/call", [
      #("name", json.String("counter/read")),
      #("arguments", json.Object([#("name", json.String(name))])),
    ])
  let assert json.Object(fields) = response.result
  let assert Ok(raw) = list.key_find(fields, "structuredContent")
  let assert Ok(answer) = codec.decode(codec.field("value", codec.int()), raw)
  answer
}

fn memory() -> store.Store {
  let runs = store.in_memory(process.new_name("mcp-binding"))
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn directory(path: String) -> store.Store {
  let runs = store.directory(process.new_name("mcp-restart"), path)
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn id(text: String) -> run.RunId {
  let assert Ok(id) = run.parse_id(text)
  id
}

fn allow(_: client.Client, _: graph.Action) -> Result(policy.Decision, String) {
  Ok(policy.Allow)
}

@external(erlang, "fabric_mcp_test_ffi", "temp_dir")
fn temp_dir() -> String

@external(erlang, "fabric_mcp_test_ffi", "remove_dir")
fn remove_dir(path: String) -> Nil

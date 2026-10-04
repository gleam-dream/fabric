//// Relay MCP tools mounted in Fabric agents and graphs: the typed and the
//// listed paths, the correlation and idempotency key every call carries,
//// and how each kind of failure reaches the run.

import fabric
import fabric/agent
import fabric/graph
import fabric/graph/definition
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric_relay
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import relay/client
import relay/content
import relay/server
import relay/testing
import relay/tool as relay_tool
import sinal/correlation.{type Correlation}

// --- the inventory server -------------------------------------------------------

pub type Item {
  Item(name: String, stock: Int)
}

fn sku_codec() -> codec.Codec(String) {
  use sku <- codec.field("sku", codec.string(), get: fn(sku) { sku })
  codec.success(sku)
}

fn item_codec() -> codec.Codec(Item) {
  use name <- codec.field("name", codec.string(), get: fn(i: Item) { i.name })
  use stock <- codec.field("stock", codec.int(), get: fn(i: Item) { i.stock })
  codec.success(Item(name:, stock:))
}

fn lookup() -> relay_tool.Definition(String, Item) {
  relay_tool.define("lookup", sku_codec(), item_codec())
  |> relay_tool.with_description("Looks up a product by SKU")
  |> relay_tool.with_read_only_hint(True)
}

fn reserve() -> relay_tool.Definition(String, Item) {
  relay_tool.define("reserve", sku_codec(), item_codec())
  |> relay_tool.with_description("Reserves one unit")
}

/// What a handler saw of one call.
pub type Seen {
  Seen(tool: String, correlation: Correlation, key: option.Option(String))
}

/// The server: `lookup` and `reserve` answer for `AB-1` after `delay`
/// milliseconds, and fail visibly for any other SKU; `notes` answers with
/// content only.
fn inventory(seen: process.Subject(Seen), delay: Int) -> server.Server(Nil) {
  let handler = fn(name) {
    fn(call, sku) {
      process.send(
        seen,
        Seen(
          name,
          relay_tool.correlation(call),
          relay_tool.idempotency_key(call),
        ),
      )
      process.sleep(delay)
      case sku {
        "AB-1" -> Ok(relay_tool.complete(Item("Widget", 3)))
        _ -> Error(relay_tool.error_message("unknown SKU " <> sku))
      }
    }
  }
  let notes =
    relay_tool.define_content("notes", sku_codec())
    |> relay_tool.handle(fn(sku) { Ok([content.text("notes for " <> sku)]) })
  server.new([
    relay_tool.handle_call(lookup(), handler("lookup")),
    relay_tool.handle_call(reserve(), handler("reserve")),
    notes,
  ])
}

// --- the agent ---------------------------------------------------------------------

/// A model that calls `tool` with `arguments` on its first turn and answers
/// with the result it saw on the next.
fn calling(tool: String, arguments: String) -> model.Model {
  model.new(fn(request: model.Request) {
    case list.last(request.messages) {
      Ok(model.ToolResultMessage(content:, ..)) ->
        Ok(model.FinalAnswer(content, None))
      _ ->
        Ok(model.ToolRequest(
          model.AssistantTurn(
            "",
            [model.tool_call(id: "c1", name: tool, arguments_json: arguments)],
            None,
          ),
          None,
        ))
    }
  })
}

pub type Context {
  Context(inventory: client.Client)
}

fn peer(context: Context) -> client.Client {
  context.inventory
}

fn runs() -> store.Store {
  let runs = store.in_memory(process.new_name("fabric-relay-runs"))
  let assert Ok(Nil) = store.start(runs)
  runs
}

/// Runs an agent with `tools` whose model calls `tool` once, and returns
/// the run's status.
fn run_once(tools, inventory: client.Client, tool: String, arguments: String) {
  let assert Ok(assistant) =
    agent.new(
      "assistant",
      calling(tool, arguments),
      tools,
      policy.always_allow(),
    )
    |> agent.build
  let id = run.new_id()
  let assert Ok(handle) =
    fabric.start(
      runs(),
      assistant,
      id:,
      context: Context(inventory),
      prompt: "check stock",
      correlation: Some(correlation.from_key("question-7")),
    )
  let assert Ok(status) = fabric.await(handle, within: duration.seconds(5))
  #(id, status)
}

// --- the typed path -------------------------------------------------------------------

pub fn a_typed_tool_answers_with_its_structured_output_test() {
  let seen = process.new_subject()
  let inventory = testing.connect(inventory(seen, 0), Nil)
  let #(id, status) =
    run_once(
      [fabric_relay.tool(lookup(), peer:)],
      inventory,
      "lookup",
      "{\"sku\":\"AB-1\"}",
    )
  status
  |> should.equal(
    run.Finished(run.Completed("{\"name\":\"Widget\",\"stock\":3}")),
  )
  // The call carries the run's correlation and a key named by its action.
  let assert Ok(Seen("lookup", correlation, Some(key))) =
    process.receive(seen, 1000)
  correlation |> should.equal(correlation.from_key("question-7"))
  key
  |> should.equal(
    run.id_to_string(
      run.id_from_parts("action", [run.id_to_string(id), "1", "c1"]),
    ),
  )
}

pub fn the_definition_names_and_describes_the_fabric_tool_test() {
  let seen = process.new_subject()
  let inventory = testing.connect(inventory(seen, 0), Nil)
  let requests = process.new_subject()
  let model =
    model.new(fn(request: model.Request) {
      process.send(requests, request.tools)
      Ok(model.FinalAnswer("ok", None))
    })
  let assert Ok(assistant) =
    agent.new(
      "assistant",
      model,
      [fabric_relay.tool(lookup(), peer:)],
      policy.always_allow(),
    )
    |> agent.build
  let assert Ok(handle) =
    fabric.start(
      runs(),
      assistant,
      id: run.new_id(),
      context: Context(inventory),
      prompt: "hi",
      correlation: None,
    )
  let assert Ok(_) = fabric.await(handle, within: duration.seconds(5))
  let assert Ok([spec]) = process.receive(requests, 1000)
  spec.name |> should.equal("lookup")
  spec.description |> should.equal("Looks up a product by SKU")
  let assert Ok(schema) = codec.schema(sku_codec())
  spec.schema |> should.equal(schema)
}

pub fn an_is_error_result_is_explained_to_the_model_test() {
  let seen = process.new_subject()
  let inventory = testing.connect(inventory(seen, 0), Nil)
  let #(_, status) =
    run_once(
      [fabric_relay.tool(reserve(), peer:)],
      inventory,
      "reserve",
      "{\"sku\":\"ZZ-9\"}",
    )
  status
  |> should.equal(
    run.Finished(run.Completed("{\"error\":\"unknown SKU ZZ-9\"}")),
  )
}

/// A call that may have reached the server is uncertain for a tool that
/// may change state: the run stops for a person instead of retrying it.
pub fn a_lost_call_to_a_changing_tool_is_uncertain_test() {
  let seen = process.new_subject()
  let assert Ok(inventory) =
    client.in_process(inventory(seen, 500), Nil)
    |> client.with_timeout(duration.milliseconds(50))
    |> client.connect
  let #(_, status) =
    run_once(
      [fabric_relay.tool(reserve(), peer:)],
      inventory,
      "reserve",
      "{\"sku\":\"AB-1\"}",
    )
  let assert run.Suspended([], [uncertain]) = status
  uncertain.tool |> should.equal("reserve")
  string.contains(uncertain.evidence, "timed_out.maybe_sent")
  |> should.be_true
}

/// The same lost call to a read-only tool changed nothing: the model sees
/// the failure.
pub fn a_lost_call_to_a_read_only_tool_is_explained_test() {
  let seen = process.new_subject()
  let assert Ok(inventory) =
    client.in_process(inventory(seen, 500), Nil)
    |> client.with_timeout(duration.milliseconds(50))
    |> client.connect
  let #(_, status) =
    run_once(
      [fabric_relay.tool(lookup(), peer:)],
      inventory,
      "lookup",
      "{\"sku\":\"AB-1\"}",
    )
  let assert run.Finished(run.Completed(seen_by_model)) = status
  string.contains(seen_by_model, "the MCP call failed") |> should.be_true
}

/// A call the client never sent is a definite failure even for a tool that
/// changes state.
pub fn a_call_never_sent_is_explained_test() {
  let assert Ok(config) = client.http("http://127.0.0.1:9/mcp")
  let assert Ok(unreachable) =
    config
    |> client.with_connect_timeout(duration.milliseconds(200))
    |> client.connect
  let #(_, status) =
    run_once(
      [fabric_relay.tool(reserve(), peer:)],
      unreachable,
      "reserve",
      "{\"sku\":\"AB-1\"}",
    )
  let assert run.Finished(run.Completed(seen_by_model)) = status
  string.contains(seen_by_model, "connect_failed") |> should.be_true
}

// --- the listed path ----------------------------------------------------------------

pub fn listed_tools_are_mounted_and_validate_their_arguments_test() {
  let seen = process.new_subject()
  let inventory = testing.connect(inventory(seen, 0), Nil)
  let assert Ok(tools) = fabric_relay.discover(inventory, peer:)
  list.length(tools) |> should.equal(3)
  // Structured content as the server sent it.
  let #(_, status) = run_once(tools, inventory, "lookup", "{\"sku\":\"AB-1\"}")
  status
  |> should.equal(
    run.Finished(run.Completed("{\"name\":\"Widget\",\"stock\":3}")),
  )
  // A content-only result reads as its text.
  let #(_, status) = run_once(tools, inventory, "notes", "{\"sku\":\"AB-1\"}")
  status |> should.equal(run.Finished(run.Completed("\"notes for AB-1\"")))
  // Arguments outside the advertised schema never reach the server.
  let #(_, status) = run_once(tools, inventory, "lookup", "{\"code\":1}")
  let assert run.Finished(run.Completed(seen_by_model)) = status
  string.contains(seen_by_model, "invalid_arguments") |> should.be_true
  let assert Ok(Seen("lookup", ..)) = process.receive(seen, 100)
  process.receive(seen, 100) |> should.equal(Error(Nil))
}

pub fn a_listed_tool_needs_a_name_a_model_accepts_test() {
  let declaration =
    relay_tool.Declaration(
      ..relay_tool.declaration(lookup()),
      name: "files.read",
    )
  let assert Error(error) = fabric_relay.discovered(declaration, peer:)
  error |> should.equal(fabric_relay.UnsupportedName("files.read"))
  fabric_relay.describe_discovery_error(error)
  |> string.contains("files.read")
  |> should.be_true
}

pub fn a_listing_failure_is_reported_test() {
  let assert Ok(config) = client.http("http://127.0.0.1:9/mcp")
  let assert Ok(unreachable) =
    config
    |> client.with_connect_timeout(duration.milliseconds(200))
    |> client.connect
  let assert Error(fabric_relay.ListingFailed(error)) =
    fabric_relay.discover(unreachable, peer:)
  client.evidence(error) |> should.equal(client.NotSent)
}

// --- graph operations -------------------------------------------------------------------

fn one_node_graph(runs: store.Store, inventory: client.Client, tool) {
  let node = definition.node_id("check")
  let assert Ok(spec) =
    definition.build(definition.new(
      run.DefinitionId("stock-check", 1),
      entry: node,
      nodes: [
        definition.node(
          node,
          fabric_relay.operation(tool, version: 1, peer:),
          select: fn(sku) { Ok(sku) },
          accept: fn(sku, item: Item) { Ok(definition.Finish(sku, item.stock)) },
          destinations: [],
        ),
      ],
      state: codec.string(),
      answer: codec.int(),
    ))
  graph.new(spec, runs, context: fn(_) { Context(inventory) }, policy: fn(_, _) {
    Ok(policy.Allow)
  })
}

pub fn a_graph_operation_calls_the_tool_with_the_runs_correlation_test() {
  let seen = process.new_subject()
  let inventory = testing.connect(inventory(seen, 0), Nil)
  let runtime = one_node_graph(runs(), inventory, lookup())
  let id = run.new_id()
  let assert Ok(handle) =
    graph.start(
      runtime,
      id:,
      initial: "AB-1",
      correlation: Some(correlation.from_key("graph-7")),
    )
  graph.await(handle, within: duration.seconds(5))
  |> should.equal(Ok(graph.Completed(3)))
  let assert Ok(Seen("lookup", correlation, Some(key))) =
    process.receive(seen, 1000)
  correlation |> should.equal(correlation.from_key("graph-7"))
  key
  |> should.equal(
    run.id_to_string(run.id_from_parts("graph", [run.id_to_string(id), "1"])),
  )
}

pub fn a_graph_operation_fails_on_an_is_error_result_test() {
  let seen = process.new_subject()
  let inventory = testing.connect(inventory(seen, 0), Nil)
  let runtime = one_node_graph(runs(), inventory, reserve())
  let assert Ok(handle) =
    graph.start(runtime, id: run.new_id(), initial: "ZZ-9", correlation: None)
  let assert Ok(graph.Failed(graph.OperationFailed(reason))) =
    graph.await(handle, within: duration.seconds(5))
  string.contains(reason, "unknown SKU ZZ-9") |> should.be_true
}

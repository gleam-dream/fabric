//// What a run copies between processes. An agent made with
//// `agent.build_with` is built in each process that runs it: its runners
//// receive the builder, the context and the record, never the agent with
//// its codecs; a tool's task receives that one tool. The meter sums
//// `erts_debug:flat_size` (in bytes) of every message and start closure
//// that crosses into a runner, and of the largest single copy anywhere.

import fabric
import fabric/agent.{type Agent}
import fabric/internal/checked_agent
import fabric/internal/executor
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/scripted
import fabric/testing
import fabric/tool
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec.{type Codec}

// --- an agent with nested combinator codecs ------------------------------------

pub type Line {
  Line(sku: String, quantity: Int, notes: List(String))
}

pub type Priority {
  Low
  High
}

pub type Order {
  Order(customer: String, lines: List(Line), priority: Priority)
}

pub type Batch {
  Batch(orders: List(Order), tag: Option(String))
}

/// Each child codec is made inside its field, by its own function.
fn line_codec() -> Codec(Line) {
  use sku <- codec.field("sku", codec.string(), get: fn(line: Line) { line.sku })
  use quantity <- codec.field("quantity", codec.int(), get: fn(line: Line) {
    line.quantity
  })
  use notes <- codec.field(
    "notes",
    codec.list(of: codec.string()),
    get: fn(line: Line) { line.notes },
  )
  codec.success(Line(sku:, quantity:, notes:))
}

fn order_codec() -> Codec(Order) {
  use customer <- codec.field("customer", codec.string(), get: fn(o: Order) {
    o.customer
  })
  use lines <- codec.field(
    "lines",
    codec.list(of: line_codec()),
    get: fn(o: Order) { o.lines },
  )
  use priority <- codec.field(
    "priority",
    codec.string_enum([#("low", Low), #("high", High)]),
    get: fn(o: Order) { o.priority },
  )
  codec.success(Order(customer:, lines:, priority:))
}

fn batch_codec() -> Codec(Batch) {
  use orders <- codec.field(
    "orders",
    codec.list(of: order_codec()),
    get: fn(batch: Batch) { batch.orders },
  )
  use tag <- codec.optional_field("tag", codec.string(), get: fn(b: Batch) {
    b.tag
  })
  codec.success(Batch(orders:, tag:))
}

fn batch_tool(prefix: String, index: Int) -> tool.Tool(Nil) {
  tool.bind(
    tool.define(
      prefix <> int.to_string(index),
      "Submit a batch of orders.",
      batch_codec(),
      batch_codec(),
    ),
    fn(_, _, batch: Batch) -> Result(Batch, Nil) { Ok(batch) },
    fn(_) { tool.Explain("failed") },
  )
}

fn tools(prefix: String, count: Int) -> List(tool.Tool(Nil)) {
  list.map(
    int.range(from: 1, to: count + 1, with: [], run: list.prepend),
    fn(index) { batch_tool(prefix, index) },
  )
}

const empty_batch = "{\"orders\":[]}"

/// Calls its first tool, then answers.
fn picker() -> agent.Spec(Nil, Batch) {
  agent.new(
    "picker",
    scripted.model(fn(messages) {
      case scripted.results(messages) {
        [] ->
          model.ToolRequest(
            model.AssistantTurn(
              "",
              [scripted.call("p1", "pick_1", empty_batch)],
              None,
            ),
            None,
          )
        _ -> model.FinalAnswer(empty_batch, None)
      }
    }),
    tools("pick_", 6),
    fn(_, _) { Ok(policy.Allow) },
  )
  |> agent.with_answer(batch_codec())
}

fn delegation() -> tool.Definition(Batch, Batch) {
  tool.define("delegate", "Ask the picker.", batch_codec(), batch_codec())
}

/// Delegates to the picker, then calls `submit_1`, which needs an approval,
/// then answers.
fn orders() -> agent.Spec(Nil, Batch) {
  let assert Ok(picker) = agent.build_with(picker)
  agent.new(
    "orders",
    scripted.model(fn(messages) {
      let call = fn(id, name) {
        model.ToolRequest(
          model.AssistantTurn("", [scripted.call(id, name, empty_batch)], None),
          None,
        )
      }
      case list.length(scripted.results(messages)) {
        0 -> call("c1", "delegate")
        1 -> call("c2", "submit_1")
        _ -> model.FinalAnswer(empty_batch, None)
      }
    }),
    tools("submit_", 12),
    fn(_, action) {
      case action.name {
        "submit_1" -> Ok(policy.RequireApproval(run.Requirement("submit", 1)))
        _ -> Ok(policy.Allow)
      }
    },
  )
  |> agent.with_answer(batch_codec())
  |> agent.with_approvers(testing.trusting_approvers())
  |> agent.with_sub_agent(delegation(), to: picker, prompt: fn(_) { "pick" })
}

// --- the meter -------------------------------------------------------------------

@external(erlang, "fabric_copy_ffi", "crossing")
fn crossing(body: fn() -> a) -> #(a, Int, Int)

@external(erlang, "fabric_copy_ffi", "flat_bytes")
fn flat_bytes(term: a) -> Int

/// Starts a run of `agent`, approves its call, and waits for its end.
fn run_to_end(agent: Agent(Nil, Batch)) -> run.Status(Batch) {
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(handle, within: duration.seconds(5))
  let assert Ok(_) =
    fabric.approve(
      handle,
      pending.reference,
      proof: support.proof(
        pending.reference.requirement,
        support.reviewer("reviewer"),
      ),
      context: Nil,
    )
  let assert Ok(status) = fabric.await(handle, within: duration.seconds(5))
  status
}

// --- tests -------------------------------------------------------------------------

/// The run starts three runners (the root, the picker, the root again for
/// the approved call) and calls two tools. All that is copied into its
/// runners together (each one's record and first model request with the
/// tool declarations, and the builder) stays under a quarter of one copy
/// of the built agent, and no single copy anywhere reaches a tenth of one.
pub fn a_run_copies_its_builder_never_its_agent_test() {
  let assert Ok(agent) = agent.build_with(orders)
  let agent_bytes = flat_bytes(checked_agent.built(agent))
  // The meter would see a copy of the agent: it is large.
  { agent_bytes > 150_000 } |> should.be_true

  let #(status, into_runners, largest) = crossing(fn() { run_to_end(agent) })

  let assert run.Finished(run.Completed(Batch([], None))) = status
  { into_runners < agent_bytes / 4 } |> should.be_true
  { largest < agent_bytes / 10 } |> should.be_true
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(UniqueOption)) -> Int

/// `erlang:unique_integer/1`'s options.
type UniqueOption {
  Positive
  Monotonic
}

/// A builder must build the same agent every time: one whose version
/// changes between builds is refused where it is built again, before
/// anything is stored.
pub fn a_builder_that_builds_another_agent_is_refused_test() {
  let assert Ok(agent) =
    agent.build_with(fn() {
      agent.new("drifting", scripted.plan([]), [], fn(_, _) { Ok(policy.Allow) })
      |> agent.with_version(unique_integer([Positive, Monotonic]) % 1000 + 1)
    })
  let store = support.store()
  let id = run.new_id()
  executor.rescue(fn() {
    fabric.start(
      store,
      agent,
      id:,
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  })
  |> should.be_error
}

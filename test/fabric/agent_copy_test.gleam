//// What a run copies between processes. An agent made with
//// `agent.build_with` is built in each process that runs it: its runners
//// receive the builder, the context and the record, never the agent with
//// its codecs; a tool's task receives that one tool. The meter sums
//// `erts_debug:flat_size` (in bytes) of every message and start closure
//// that crosses into a runner, and of the largest single copy anywhere.

import fabric
import fabric/agent.{type Agent}
import fabric/internal/checked_agent
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/scripted
import fabric/testing
import fabric/tool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
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

pub fn batch_codec() -> Codec(Batch) {
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

/// A tool that waits `pause` milliseconds, then returns its input.
fn batch_tool(prefix: String, pause: Int, index: Int) -> tool.Tool(Nil) {
  tool.bind(
    tool.define(
      prefix <> int.to_string(index),
      "Submit a batch of orders.",
      batch_codec(),
      batch_codec(),
    ),
    fn(_, _, batch: Batch) -> Result(Batch, Nil) {
      process.sleep(pause)
      Ok(batch)
    },
    fn(_) { tool.Explain("failed") },
  )
}

fn tools(prefix: String, count: Int, pause: Int) -> List(tool.Tool(Nil)) {
  int.range(from: 1, to: count + 1, with: [], run: list.prepend)
  |> list.map(batch_tool(prefix, pause, _))
}

const empty_batch = "{\"orders\":[]}"

/// A delegation from `family` takes an `Ask`; every other tool a batch.
fn arguments(tool: String) -> String {
  case tool {
    "delegate_" <> _ -> "{\"topic\":\"pick\"}"
    _ -> empty_batch
  }
}

/// A model that calls the tools `turns` names, one list per turn, then
/// answers.
fn turns(names: List(List(String))) -> model.Model {
  scripted.model(fn(messages) {
    let done = list.length(scripted.results(messages))
    let seen =
      list.fold(names, #(0, None), fn(found, calls) {
        case found {
          #(count, None) if count == done -> #(count, Some(calls))
          #(count, None) -> #(count + list.length(calls), None)
          _ -> found
        }
      })
    case seen.1 {
      Some(calls) ->
        model.ToolRequest(
          model.AssistantTurn(
            "",
            list.map(calls, fn(name) {
              scripted.call("c-" <> name, name, arguments(name))
            }),
            None,
          ),
          None,
        )
      None -> model.FinalAnswer(empty_batch, None)
    }
  })
}

/// Calls its first tool, which waits `pause` milliseconds, then answers.
fn picker(pause: Int) -> fn() -> agent.Spec(Nil, Batch) {
  fn() {
    agent.new("picker", turns([["pick_1"]]), tools("pick_", 6, pause), fn(_, _) {
      Ok(policy.Allow)
    })
    |> agent.with_answer(batch_codec())
  }
}

fn delegation() -> tool.Definition(Batch, Batch) {
  tool.define("delegate", "Ask the picker.", batch_codec(), batch_codec())
}

/// Calls the tools `calls` names, turn by turn, then answers: `delegate`
/// asks `picker` (an agent kept as its builder, so capturing it is
/// cheap), `submit_1` needs an approval, and every `submit_` tool waits
/// `pause` milliseconds.
fn orders(
  picker: Agent(Nil, Batch),
  calls: List(List(String)),
  pause: Int,
) -> fn() -> agent.Spec(Nil, Batch) {
  fn() {
    agent.new(
      "orders",
      turns(calls),
      tools("submit_", 12, pause),
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
}

/// Delegates to the picker, then calls `submit_1`, which needs an approval,
/// then answers.
fn approving_orders() -> Agent(Nil, Batch) {
  let assert Ok(picker) = agent.build_with(picker(0))
  let assert Ok(orders) =
    agent.build_with(orders(picker, [["delegate"], ["submit_1"]], 0))
  orders
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
      proof: support.proof(pending.reference, support.reviewer("reviewer")),
      context: Nil,
    )
  let assert Ok(status) = fabric.await(handle, within: duration.seconds(5))
  status
}

// --- tests -------------------------------------------------------------------------

/// A sub-agent's prompt: the only input a delegation declares to the model.
pub type Ask {
  Ask(topic: String)
}

fn ask_codec() -> Codec(Ask) {
  use topic <- codec.field("topic", codec.string(), get: fn(ask: Ask) {
    ask.topic
  })
  codec.success(Ask(topic:))
}

/// `orders` with `children` pickers beside it, each with its own six tools
/// and a delegation `delegate_<n>` whose declared input is one string. The
/// built agent holds every child built, so it grows by a whole picker per
/// child, while the model sees one small declaration per child.
fn family(
  children: Int,
  calls: List(List(String)),
  pause: Int,
) -> fn() -> agent.Spec(Nil, Batch) {
  fn() {
    int.range(from: 1, to: children + 1, with: [], run: list.prepend)
    |> list.reverse
    |> list.fold(
      agent.new(
        "orders",
        turns(calls),
        tools("submit_", 12, pause),
        fn(_, action) {
          case action.name {
            "submit_1" ->
              Ok(policy.RequireApproval(run.Requirement("submit", 1)))
            _ -> Ok(policy.Allow)
          }
        },
      )
        |> agent.with_answer(batch_codec())
        |> agent.with_approvers(testing.trusting_approvers()),
      fn(spec, n) {
        let name = int.to_string(n)
        let assert Ok(picker) =
          agent.build_with(fn() {
            agent.new(
              "picker_" <> name,
              turns([["pick_1"]]),
              tools("pick_", 6, pause),
              fn(_, _) { Ok(policy.Allow) },
            )
            |> agent.with_answer(batch_codec())
          })
        agent.with_sub_agent(
          spec,
          tool.define(
            "delegate_" <> name,
            "Ask picker " <> name <> ".",
            ask_codec(),
            batch_codec(),
          ),
          to: picker,
          prompt: fn(ask: Ask) { ask.topic },
        )
      },
    )
  }
}

/// One measurement: the built agent's size, and what the run copied into
/// its runners and in its largest single copy, all in bytes.
type Copied {
  Copied(agent: Int, into_runners: Int, largest: Int)
}

/// Builds the family of `children` and runs `run` over it, measured.
fn measure(
  children: Int,
  calls: List(List(String)),
  pause: Int,
  run: fn(Agent(Nil, Batch)) -> run.Status(Batch),
) -> Copied {
  let assert Ok(agent) = agent.build_with(family(children, calls, pause))
  let agent_bytes = flat_bytes(checked_agent.built(agent))
  let #(status, into_runners, largest) = crossing(fn() { run(agent) })
  let assert run.Finished(run.Completed(Batch([], None))) = status
  Copied(agent: agent_bytes, into_runners:, largest:)
}

/// The family sizes the scaling tests compare.
const scale = [1, 10, 100]

/// Checks what a run copies as its agent grows. Each step from one child
/// to `n` adds whole built pickers to the agent, so a copy of the agent
/// into even one runner would add at least that growth to `into_runners`.
/// What legitimately grows is one small declaration per child in each
/// runner's model request. The runners' growth stays under a quarter of
/// the agent's, and the largest copy's under a tenth.
fn grows_slower_than_its_agent(measured: List(Copied)) -> Nil {
  let assert [first, ..rest] = measured
  list.each(rest, fn(copied) {
    let agent_growth = copied.agent - first.agent
    // The meter would see a copy of the agent: it grows.
    { agent_growth > first.agent } |> should.be_true
    { copied.into_runners - first.into_runners < agent_growth / 4 }
    |> should.be_true
    { copied.largest - first.largest < agent_growth / 10 } |> should.be_true
  })
}

/// The run starts three runners (the root, a picker, the root again for
/// the approved call) and calls two tools, for an agent with 1, 10 and 100
/// sub-agents. What its runners receive (each one's record and first model
/// request with the tool declarations, and the builder) does not grow with
/// the agent the way a copy of it would.
pub fn a_run_copies_its_builder_never_its_agent_test() {
  list.map(scale, measure(_, [["delegate_1"], ["submit_1"]], 0, run_to_end))
  |> grows_slower_than_its_agent
}

/// On a leased store a runner whose sub-agent works reads its children
/// every third of the lease, from a process of its own. The parent here
/// stays live (its own tool runs as long as the child's) through several
/// such reads; none copies the agent, at any family size.
pub fn a_leased_parent_reading_its_children_copies_no_agent_test() {
  support.leased(fn() {
    list.map(
      scale,
      measure(_, [["delegate_1", "submit_2"]], 1600, fn(agent) {
        let assert Ok(handle) =
          fabric.start(
            support.store(),
            agent,
            id: run.new_id(),
            context: Nil,
            prompt: "go",
            correlation: None,
          )
        let assert Ok(status) =
          fabric.await(handle, within: duration.seconds(10))
        status
      }),
    )
    |> grows_slower_than_its_agent
  })
}

/// The watcher `fabric.cancel_when_down` starts holds what a cancellation
/// needs, not the handle's agent.
pub fn watching_an_owner_copies_no_agent_test() {
  let agent = approving_orders()
  let agent_bytes = flat_bytes(checked_agent.built(agent))
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended(_, _)) =
    fabric.await(handle, within: duration.seconds(5))
  let owner = process.spawn_unlinked(fn() { process.sleep(60_000) })

  let #(Nil, _, largest) =
    crossing(fn() { fabric.cancel_when_down(handle, owner:) })

  { largest < agent_bytes / 10 } |> should.be_true
  process.kill(owner)
  cancelled(handle, 100) |> should.be_true
}

/// Whether the run is cancelled within `tries` reads 20 ms apart: a
/// suspended run's `await` returns at once, so nothing else waits for the
/// watcher's cancellation.
fn cancelled(handle: fabric.Run(Nil, Batch), tries: Int) -> Bool {
  case fabric.await(handle, within: duration.milliseconds(0)) {
    Ok(run.Finished(run.Cancelled)) -> True
    _ if tries > 0 -> {
      process.sleep(20)
      cancelled(handle, tries - 1)
    }
    _ -> False
  }
}

@external(erlang, "fabric_copy_ffi", "counter")
fn counter() -> Counter

@external(erlang, "fabric_copy_ffi", "count")
fn count(counter: Counter) -> Int

type Counter

/// A spec whose version is 1 for its first `stable` builds and 2 after,
/// counting its builds in `builds`.
fn drifting(builds: Counter, stable: Int) -> fn() -> agent.Spec(Nil, String) {
  fn() {
    let version = case count(builds) <= stable {
      True -> 1
      False -> 2
    }
    agent.new("drifting", scripted.plan([]), [], fn(_, _) { Ok(policy.Allow) })
    |> agent.with_version(version)
  }
}

fn stable() -> agent.Agent(Nil, String) {
  let assert Ok(agent) = agent.build_with(drifting(counter(), 1_000_000))
  agent
}

/// A builder must build the same agent every time. One that builds another
/// version in the caller is refused there; one that does so only in the
/// runner is refused by the runner before the start is stored. Either way
/// nothing is stored, and the caller gets an error rather than a crash.
pub fn a_builder_that_builds_another_agent_is_refused_before_storing_test() {
  let store = support.store()

  // Built once by `build_with`, then again in the caller of `start`.
  let assert Ok(in_caller) = agent.build_with(drifting(counter(), 1))
  let id = run.new_id()
  let assert Error(fabric.AgentUnbuildable(_)) =
    fabric.start(
      store,
      in_caller,
      id:,
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  fabric.open(store, stable(), Nil, id)
  |> should.equal(Error(fabric.RunNotFound))

  // The caller's build matches; the runner's does not.
  let assert Ok(in_runner) = agent.build_with(drifting(counter(), 2))
  let id = run.new_id()
  let assert Error(fabric.AgentUnbuildable(_)) =
    fabric.start(
      store,
      in_runner,
      id:,
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  fabric.open(store, stable(), Nil, id)
  |> should.equal(Error(fabric.RunNotFound))
}

/// The watcher of `cancel_when_down` builds the agent again; when that
/// build fails (here the builder builds another version from its fourth
/// build: the check, the caller, the runner, the watcher), the owner's exit
/// still cancels the run.
pub fn an_owner_exit_cancels_even_when_the_watcher_cannot_build_test() {
  let builds = counter()
  let assert Ok(agent) =
    agent.build_with(fn() {
      let version = case count(builds) <= 3 {
        True -> 1
        False -> 2
      }
      let assert Ok(picker) = agent.build_with(picker(0))
      orders(picker, [["submit_1"]], 0)()
      |> agent.with_version(version)
    })
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended(_, _)) =
    fabric.await(handle, within: duration.seconds(5))
  let owner = process.spawn_unlinked(fn() { process.sleep(60_000) })
  fabric.cancel_when_down(handle, owner:)
  process.kill(owner)
  cancelled(handle, 100) |> should.be_true
}

/// `open` and `recover` build the agent in the caller: a builder that
/// builds another agent there is an error, not a crash.
pub fn opening_with_a_drifting_builder_is_an_error_test() {
  let store = support.store()
  let id = run.new_id()
  let assert Ok(_) =
    fabric.start(
      store,
      stable(),
      id:,
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(drifted) = agent.build_with(drifting(counter(), 1))
  let assert Error(fabric.AgentUnbuildable(_)) =
    fabric.open(store, drifted, Nil, id)
  let assert Error(fabric.AgentUnbuildable(_)) =
    fabric.recover(store, drifted, Nil, id)
}

/// A sub-agent kept as its builder is built once each time its parent is:
/// `build_with`'s check of the parent builds the child once.
pub fn a_sub_agent_is_built_once_per_parent_build_test() {
  let builds = counter()
  let assert Ok(child) =
    agent.build_with(fn() {
      let _ = count(builds)
      picker(0)()
    })
  let before = count(builds)
  let assert Ok(_) = agent.build_with(orders(child, [], 0))
  // `count` itself adds one.
  count(builds) |> should.equal(before + 2)
}

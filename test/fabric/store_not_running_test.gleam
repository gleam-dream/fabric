//// Sends to a store that is not running. The functions that send to the
//// store without waiting for an answer return when no process holds the
//// store's name, and an application waiting for a run gets an outcome, not
//// a crash, when its store stops during the wait. Each test calls the code
//// in a process of its own, so that a crash is reported with its exit
//// reason and stack (`in_process`).

import fabric
import fabric/agent
import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/internal/store as store_core
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import fabric/testing
import fabric/tool
import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/option.{None}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

/// A store value whose process was never started: no process holds its
/// name.
fn not_running() -> store.Store {
  store.in_memory(process.new_name("fabric-not-running"))
}

/// `draining` returns when the store is not running.
pub fn draining_returns_when_the_store_is_not_running_test() {
  let #(_, sent) =
    in_process(fn() { store_core.draining(not_running(), process.self()) })
  sent() |> should.equal(Nil)
}

/// `handoff_failed` returns when the store is not running.
pub fn handoff_failed_returns_when_the_store_is_not_running_test() {
  let #(_, sent) =
    in_process(fn() { store_core.handoff_failed(not_running(), process.self()) })
  sent() |> should.equal(Nil)
}

/// `release_job_observation` returns when the store is not running.
pub fn release_job_observation_returns_when_the_store_is_not_running_test() {
  let #(_, sent) =
    in_process(fn() { store_core.release_job_observation(not_running(), "run") })
  sent() |> should.equal(Nil)
}

/// `unwatch` returns when the store is not running.
pub fn unwatch_returns_when_the_store_is_not_running_test() {
  let #(_, sent) =
    in_process(fn() {
      store_core.unwatch(not_running(), "run", process.new_subject())
    })
  sent() |> should.equal(Nil)
}

/// `with_backend_timeout` returns the store when the store is not running.
pub fn with_backend_timeout_returns_when_the_store_is_not_running_test() {
  let runs = not_running()
  let #(_, sent) =
    in_process(fn() { store_core.with_backend_timeout(runs, 100) })
  let _configured = sent()
  Nil
}

/// `renew_now` returns when the store is not running.
pub fn renew_now_returns_when_the_store_is_not_running_test() {
  let #(_, sent) = in_process(fn() { store_core.renew_now(not_running()) })
  sent() |> should.equal(Nil)
}

/// `tick_now` returns when the store is not running.
pub fn tick_now_returns_when_the_store_is_not_running_test() {
  let #(_, sent) = in_process(fn() { store_core.tick_now(not_running()) })
  sent() |> should.equal(Nil)
}

/// Runs `body` in a new, unlinked process and returns a function that waits
/// for its result, or panics with the process's exit reason (which carries
/// the stack) when it crashes. The monitor is taken before `body` is
/// released, so a quick exit is never missed.
fn in_process(body: fn() -> b) -> #(Pid, fn() -> b) {
  let reply = process.new_subject()
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let go = process.new_subject()
      process.send(ready, go)
      let assert Ok(Nil) = process.receive(go, 10_000)
      process.send(reply, body())
    })
  let monitor = process.monitor(pid)
  let assert Ok(go) = process.receive(ready, 10_000)
  process.send(go, Nil)
  let result = fn() {
    let outcome =
      process.new_selector()
      |> process.select_map(reply, Ok)
      |> process.select_specific_monitor(monitor, fn(down) {
        Error(string.inspect(down))
      })
      |> process.selector_receive(10_000)
    case outcome {
      Ok(Ok(value)) -> value
      Ok(Error(down)) -> panic as { "the calling process crashed: " <> down }
      Error(Nil) -> panic as "the calling process did not answer in time"
    }
  }
  #(pid, result)
}

/// Waits, up to 10 seconds, until `pid` is blocked in a receive that
/// `module`'s code entered.
fn blocked_in(pid: Pid, module: String) -> Nil {
  blocked_within(pid, atom.create(module), 10_000)
}

fn blocked_within(pid: Pid, module: atom.Atom, left: Int) -> Nil {
  case restart.waits_in(pid, module), left > 0 {
    True, _ -> Nil
    False, True -> {
      process.sleep(1)
      blocked_within(pid, module, left - 1)
    }
    False, False ->
      panic as { "the process never waited in " <> atom.to_string(module) }
  }
}

/// An application waits for an agent run with `await_with` and its own
/// interrupt selector. While it waits, its interrupt message arrives and
/// then the store stops (its starter exits). The wait returns the message
/// it received first; the waiting process does not crash on its way out.
///
/// Deterministic: the waiting process is suspended while both happen, so
/// its mailbox holds the interrupt before the store's `DOWN`.
pub fn await_with_returns_when_the_store_stops_during_the_wait_test() {
  let gate = probe.new()
  let #(owner, runs) = restart.owned(support.store)
  let desk =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("a", "a")]),
      [scripted.gated_tool(gate)],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let _ = probe.arrival(gate)
  let interrupts = process.new_subject()
  let #(waiter, outcome) =
    in_process(fn() {
      let interrupt = process.new_subject()
      process.send(interrupts, interrupt)
      fabric.await_with(
        handle,
        within: duration.seconds(20),
        or: process.new_selector() |> process.select(interrupt),
      )
    })
  let assert Ok(interrupt) = process.receive(interrupts, 10_000)
  blocked_in(waiter, "fabric")
  restart.suspend(waiter)
  process.send(interrupt, "shutdown")
  restart.crash(owner, runs)
  restart.resume(waiter)
  outcome() |> should.equal(Ok(fabric.Interrupted("shutdown")))
}

fn blocked_graph(worker: process.Subject(Pid)) {
  let node =
    definition.node(
      definition.node_id("only"),
      operation.new(
        run.DefinitionId("blocked", 1),
        codec.int(),
        codec.int(),
        fn(_, _, n) {
          process.send(worker, process.self())
          process.sleep_forever()
          Ok(n)
        },
        fn(_) { tool.Explain("cannot fail") },
      ),
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("blocked", 1),
        entry: definition.node_id("only"),
        nodes: [node],
        state: codec.int(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(1),
    )
  spec
}

/// An application waits for a graph run with `graph.await` and the store
/// stops during the wait (its starter exits). The wait returns the store's
/// unavailability; the waiting process does not crash on its way out.
///
/// Deterministic: the store stops only once the waiter is blocked in the
/// await's receive, after its watch; the await reads the run again within
/// 100 ms and finds no store.
pub fn graph_await_returns_when_the_store_stops_during_the_wait_test() {
  let worker = process.new_subject()
  let #(owner, runs) = restart.owned(support.store)
  let assert Ok(runtime) =
    graph.new(blocked_graph(worker), runs, fn(_) { Nil }, fn(_, _) {
      Ok(policy.Allow)
    })
    |> graph.with_approvers(testing.trusting_approvers())
    |> graph.build
  let assert Ok(id) = run.parse_id("graph-await-store-stops")
  let assert Ok(handle) = graph.start(runtime, id, 0, correlation: None)
  let assert Ok(_body) = process.receive(worker, 10_000)
  let #(waiter, outcome) =
    in_process(fn() { graph.await(handle, within: duration.seconds(20)) })
  blocked_in(waiter, "fabric@graph")
  restart.crash(owner, runs)
  let assert Error(graph.StoreUnavailable(_)) = outcome()
  Nil
}

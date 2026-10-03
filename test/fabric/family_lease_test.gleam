//// A family's runs may be recovered on different nodes. Each run keeps
//// its own lease; a live parent learns a recovered child's stored result.

import fabric
import fabric/agent
import fabric/model
import fabric/policy
import fabric/run
import fabric/store/backend
import fabric/store/conformance
import fabric/support
import fabric/support/codecs
import fabric/support/nodes
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import fabric/sweeper
import fabric/testing
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import json/blueprint/codec

pub fn a_child_is_recovered_beneath_a_live_foreign_parent_test() {
  let memory = conformance.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let body = probe.new()
  let calls = probe.new()
  let researcher =
    agent.new(
      "researcher",
      scripted.model(fn(_) {
        probe.record(calls, "call")
        case probe.count(calls, "call") {
          1 -> probe.gate(calls, "model")
          _ -> Nil
        }
        model.FinalAnswer("found", None)
      }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let research =
    tool.define("research", "Research a topic", codec.string(), codec.string())
  let assert Ok(delegation) = testing.call(research, "r", "weather")
  let parent =
    agent.new(
      "parent",
      scripted.model(fn(messages) {
        case scripted.results(messages) {
          [] ->
            model.ToolRequest(
              model.AssistantTurn(
                "",
                [scripted.slow("a", "a"), delegation],
                None,
              ),
              None,
            )
          seen -> model.FinalAnswer(string.join(seen, ","), None)
        }
      }),
      [scripted.gated_tool(body)],
      policy.always_allow(),
    )
    |> agent.with_sub_agent(
      research,
      to: researcher,
      prompt: fn(x) { x },
      output: Ok,
    )
    |> support.agent
  let assert Ok(root) =
    fabric.start(
      a,
      parent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(body)
  let _ = probe.arrival(calls)
  let child = support.child_id(fabric.id(root), 1)
  let assert Ok(child_runner) = restart.runner(a, child)
  restart.kill(child_runner)
  let assert Ok(current) = memory.backend.get(run.id_to_string(child))
  let assert backend.Held(owner, True) = current.holder
  memory.backend.renew(owner, [run.id_to_string(child)], 0)
  |> should.equal(Ok([run.id_to_string(child)]))

  let contexts = process.new_subject()
  let assert Ok(started) =
    sweeper.start(
      b,
      [sweeper.agent(parent, fn(id) { process.send(contexts, id) })],
      every: duration.milliseconds(10),
    )
  child_completed(root, 500)
  process.receive(contexts, 100) |> should.equal(Ok(fabric.id(root)))
  let assert Ok(snapshot) = fabric.snapshot(root)
  snapshot.incarnation |> should.equal(1)
  probe.count(calls, "call") |> should.equal(2)
  // The ended child's retained lease is a retry cue, cleared only once
  // the live parent has acknowledged its result.
  let assert backend.Held(owner, True) = nodes.holder(memory.backend, child)
  memory.backend.renew(owner, [run.id_to_string(child)], 0)
  |> should.equal(Ok([run.id_to_string(child)]))
  await_free(memory.backend, child, 200)
  probe.release(running)
  fabric.await(root, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("\"a\",\"found\""))))
  process.unlink(started)
  restart.kill(started)
}

fn await_free(backend, id, tries) {
  case nodes.holder(backend, id) {
    backend.Free -> Nil
    _ if tries > 0 -> {
      process.sleep(10)
      await_free(backend, id, tries - 1)
    }
    _ -> panic as "acknowledged child retained its lease"
  }
}

fn child_completed(root: fabric.Run(Nil), tries: Int) -> Nil {
  let assert Ok(snapshot) = fabric.snapshot(root)
  case
    list.any(snapshot.actions, fn(action) {
      action.state == run.Succeeded("\"found\"")
    })
  {
    True -> Nil
    False if tries > 0 -> {
      process.sleep(10)
      child_completed(root, tries - 1)
    }
    False -> panic as "the live parent never learned the child's result"
  }
}

/// The root waits for a child's stopped tool to settle. If that child's
/// runner dies, recovery on another node must complete the cancellation.
pub fn a_stopping_child_is_recovered_beneath_a_live_cancelling_parent_test() {
  let memory = conformance.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let entered = process.new_subject()
  let slow =
    tool.define(
      "slow",
      "Work with late settlement",
      codecs.one_field("x", codec.string()),
      codec.string(),
    )
  let child_tool =
    tool.bind_settling(
      slow,
      fn(_, _call, _, _settlement) {
        process.send(entered, Nil)
        process.receive_forever(process.new_subject())
        Ok("done")
      },
      fn(_: Nil) { tool.Explain("failed") },
      settle_within: duration.milliseconds(60_000),
    )
  let researcher =
    agent.new(
      "researcher",
      scripted.plan([scripted.slow("w", "work")]),
      [child_tool],
      policy.always_allow(),
    )
    |> support.agent
  let research =
    tool.define("research", "Research", codec.string(), codec.string())
  let assert Ok(call) = testing.call(research, "r", "topic")
  let parent =
    agent.new("parent", scripted.plan([call]), [], policy.always_allow())
    |> agent.with_sub_agent(
      research,
      to: researcher,
      prompt: fn(x) { x },
      output: Ok,
    )
    |> support.agent
  let assert Ok(root) =
    fabric.start(
      a,
      parent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  process.receive(entered, 5000) |> should.equal(Ok(Nil))
  let child = support.child_id(fabric.id(root), 1)
  let assert Ok(_) = fabric.cancel(root)
  await_stopping(a, child, 200)
  let assert Ok(child_runner) = restart.runner(a, child)
  restart.kill(child_runner)
  let assert backend.Held(owner, True) = nodes.holder(memory.backend, child)
  memory.backend.renew(owner, [run.id_to_string(child)], 0)
  |> should.equal(Ok([run.id_to_string(child)]))
  let assert Ok(started) =
    sweeper.start(
      b,
      [sweeper.agent(parent, fn(_) { Nil })],
      every: duration.milliseconds(10),
    )
  fabric.await(root, within: duration.milliseconds(3000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert Ok(snapshot) = fabric.snapshot(root)
  snapshot.incarnation |> should.equal(1)
  process.unlink(started)
  restart.kill(started)
}

import fabric/internal/controller
import fabric/internal/runner
import gleam/time/duration

fn await_stopping(node, id, tries) {
  case runner.load(node, run.id_to_string(id)) {
    Ok(#(
      _,
      controller.State(phase: controller.Stopping(tools_stopped: True, ..), ..),
    )) -> Nil
    _ if tries > 0 -> {
      process.sleep(10)
      await_stopping(node, id, tries - 1)
    }
    _ -> panic as "child did not reach settlement wait"
  }
}

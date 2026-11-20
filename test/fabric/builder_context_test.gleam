//// An agent kept as its builder is built again in each process that runs
//// it, with the context each run has now: a sub-agent started by an
//// approval runs with the approval's context, and keeps it when its own
//// sub-agent ends and its runner is started again from that sub-agent's
//// link back to it.

import fabric
import fabric/agent
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/codecs
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn delegation(name: String) -> tool.Definition(String, String) {
  tool.define(
    name,
    "Delegate a topic.",
    codecs.one_field("topic", codec.string()),
    codec.string(),
  )
}

/// Calls the tools `calls` names, one per turn, then answers.
fn calling(calls: List(String)) -> model.Model {
  scripted.model(fn(messages) {
    case list.drop(calls, list.length(scripted.results(messages))) {
      [name, ..] ->
        model.ToolRequest(
          model.AssistantTurn(
            "",
            [scripted.call("c-" <> name, name, "{\"topic\":\"t\"}")],
            None,
          ),
          None,
        )
      [] -> model.FinalAnswer("done", None)
    }
  })
}

/// Reports the context it is called with to `seen`.
fn probe(seen: Subject(String)) -> tool.Tool(String) {
  tool.bind(
    tool.define(
      "probe",
      "Report the context.",
      codecs.one_field("topic", codec.string()),
      codec.string(),
    ),
    fn(context: String, _call, _topic) -> Result(String, Nil) {
      process.send(seen, context)
      Ok(context)
    },
    fn(_) { tool.Explain("failed") },
  )
}

/// A slow leaf: its tool waits long enough for its parent to give up its
/// runner while it waits for this run.
fn leaf() -> agent.Agent(String, String) {
  let slow =
    tool.bind(
      tool.define(
        "slow",
        "Wait.",
        codecs.one_field("topic", codec.string()),
        codec.string(),
      ),
      fn(_, _, _) -> Result(String, Nil) {
        process.sleep(300)
        Ok("slow")
      },
      fn(_) { tool.Explain("failed") },
    )
  agent.new("leaf", calling(["slow"]), [slow], fn(_, _) { Ok(policy.Allow) })
  |> support.agent
}

/// Delegates to the leaf, then calls `probe`.
fn middle(seen: Subject(String)) -> agent.Agent(String, String) {
  agent.new("middle", calling(["to_leaf", "probe"]), [probe(seen)], fn(_, _) {
    Ok(policy.Allow)
  })
  |> agent.with_sub_agent(delegation("to_leaf"), to: leaf(), prompt: fn(topic) {
    topic
  })
  |> support.agent
}

pub fn a_sub_agent_keeps_its_approved_context_across_its_own_delegation_test() {
  let seen = process.new_subject()
  let root =
    agent.new("root", calling(["to_middle"]), [], fn(_, action: policy.Action) {
      case action.name {
        "to_middle" -> Ok(policy.RequireApproval(run.Requirement("lead", 1)))
        _ -> Ok(policy.Allow)
      }
    })
    |> agent.with_max_depth(2)
    |> agent.with_sub_agent(
      delegation("to_middle"),
      to: middle(seen),
      prompt: fn(topic) { topic },
    )
    |> support.agent
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      root,
      id: run.new_id(),
      context: "C0",
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
        support.reviewer("lead"),
      ),
      context: "C1",
    )
  let assert Ok(run.Finished(run.Completed("done"))) =
    fabric.await(handle, within: duration.seconds(10))
  process.receive(seen, 0) |> should.equal(Ok("C1"))
}

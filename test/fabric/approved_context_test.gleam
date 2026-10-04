//// The context an approved action runs with, through the public API. An
//// approved tool call, or an approved sub-agent start, runs with exactly
//// the context its answer's policy recheck passed with, whether or not a
//// runner was live when the answer arrived; the run's other actions keep
//// the run's context. The context is a live value and is not stored, so an
//// approved action that had not started when its runner was lost is asked
//// for again.
////
//// The context here is the name of whoever acts; every tool and policy
//// records it.

import fabric
import fabric/agent.{type Agent}
import fabric/model
import fabric/policy
import fabric/run.{Requirement}
import fabric/support
import fabric/support/apps
import fabric/support/codecs
import fabric/support/flaky
import fabric/support/probe.{type Probe}
import fabric/support/restart
import fabric/support/scripted
import fabric/testing
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

// --- the application -----------------------------------------------------------

/// A transfer tool that records who pays.
fn paying_tool(probe: Probe) -> tool.Tool(String) {
  tool.bind(
    apps.transfer_definition(),
    fn(who: String, _call, transfer: apps.Transfer) -> Result(apps.Receipt, Nil) {
      probe.record(probe, "pay as " <> who)
      Ok(apps.Receipt("r-" <> transfer.to))
    },
    fn(_) { tool.Explain("failed") },
  )
}

/// A `note` tool that records `<label> as <who>`.
fn note_tool(probe: Probe, label: String) -> tool.Tool(String) {
  tool.define(
    "note",
    "Write a note.",
    codecs.one_field("x", codec.string()),
    codec.string(),
  )
  |> tool.bind(
    fn(who: String, _call, x: String) -> Result(String, Nil) {
      probe.record(probe, label <> " as " <> who)
      Ok(x)
    },
    fn(_) { tool.Explain("failed") },
  )
}

fn transfer_call() -> model.ToolCall {
  scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}")
}

fn note_call() -> model.ToolCall {
  scripted.call("n", "note", "{\"x\":\"later\"}")
}

/// Transfers and sub-agent starts need an approval; every decision records
/// the context it was made with.
fn gate(
  probe: Probe,
  label: String,
) -> fn(String, policy.Action) -> Result(policy.Decision, String) {
  fn(who: String, action: policy.Action) {
    probe.record(probe, label <> " " <> action.name <> " as " <> who)
    case action.name, action.target {
      "transfer_funds", _ ->
        Ok(policy.RequireApproval(Requirement("transfer", 1)))
      _, policy.StartAgent(..) ->
        Ok(policy.RequireApproval(Requirement("delegate", 1)))
      _, _ -> Ok(policy.Allow)
    }
  }
}

/// Requests `first`, then a note, then answers.
fn two_turns(first: List(model.ToolCall)) -> model.Model {
  scripted.model(fn(messages) {
    let seen = scripted.results(messages)
    case seen, list.length(seen) == list.length(first) {
      [], _ -> model.ToolRequest(model.AssistantTurn("", first, None), None)
      _, True ->
        model.ToolRequest(model.AssistantTurn("", [note_call()], None), None)
      _, False -> model.FinalAnswer("done", None)
    }
  })
}

fn paying_agent_spec(
  probe: Probe,
  first: List(model.ToolCall),
) -> agent.Spec(String, String) {
  agent.new(
    "agent",
    two_turns(first),
    [scripted.gated_tool(probe), paying_tool(probe), note_tool(probe, "note")],
    gate(probe, "policy"),
  )
}

fn paying_agent(
  probe: Probe,
  first: List(model.ToolCall),
) -> Agent(String, String) {
  support.agent(paying_agent_spec(probe, first))
}

/// What the actions and the policy did, without the barrier's entries.
fn acts(probe: Probe) -> List(String) {
  probe.entries(probe)
  |> list.filter(fn(entry) { string.contains(entry, " as ") })
}

fn approve(
  run: fabric.Run(String, String),
  pending: run.PendingApproval,
  who: String,
) -> Result(run.Status(String), fabric.Error) {
  fabric.approve(
    run,
    pending.reference,
    proof: support.proof(pending.reference.requirement, support.reviewer(who)),
    context: who,
  )
}

// --- approved tools --------------------------------------------------------------

/// No runner holds the suspended run when the answer arrives: the approved
/// transfer runs as the reviewer whose context passed the recheck, and the
/// run's next action runs with the run's own context again.
pub fn an_approved_tool_runs_with_the_recheck_context_without_a_runner_test() {
  let probe = probe.new()
  let assert Ok(run) =
    fabric.start(
      support.store(),
      paying_agent(probe, [transfer_call()]),
      id: run.new_id(),
      context: "carol",
      prompt: "pay",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let assert Ok(_) = approve(run, pending, "alice")
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done"))))
  acts(probe)
  |> should.equal([
    "policy transfer_funds as carol", "policy transfer_funds as alice",
    "pay as alice", "policy note as carol", "note as carol",
  ])
}

/// A runner is live (another tool of the batch runs) when the answer
/// arrives: the approved transfer runs as the reviewer, the runner keeps
/// the run's context for everything else.
pub fn an_approved_tool_runs_with_the_recheck_context_under_a_live_runner_test() {
  let probe = probe.new()
  let store = support.store()
  let assert Ok(run) =
    fabric.start(
      store,
      paying_agent(probe, [scripted.slow("s", "s"), transfer_call()]),
      id: run.new_id(),
      context: "carol",
      prompt: "pay",
      correlation: None,
    )
  let slow = probe.arrival(probe)
  let assert Ok(_) = restart.runner(store, fabric.id(run))
  let assert Ok([pending]) = fabric.pending(run)
  let assert Ok(run.Working) = approve(run, pending, "alice")
  probe.release(slow)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done"))))
  acts(probe)
  |> should.equal([
    "policy slow as carol", "policy transfer_funds as carol",
    "policy transfer_funds as alice", "pay as alice", "policy note as carol",
    "note as carol",
  ])
}

/// The runner is lost after the answer committed the transfer but before
/// it started (it waits for the only execution slot). The answer's context
/// is gone with it, and a stored approval alone does not authorize a later
/// incarnation: recovery asks for the approval again, the old reference is
/// stale, and the transfer runs once, as whoever answers the new request.
pub fn an_approved_tool_not_started_before_a_restart_is_asked_for_again_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let agent =
    paying_agent_spec(probe, [scripted.slow("s", "s"), transfer_call()])
    |> agent.with_max_concurrency(1)
    |> support.agent
  let #(owner, #(old, run)) =
    restart.owned(fn() {
      let store = support.directory(dir)
      let assert Ok(run) =
        fabric.start(
          store,
          agent,
          id: run.new_id(),
          context: "carol",
          prompt: "pay",
          correlation: None,
        )
      #(store, run)
    })
  let _ = probe.arrival(probe)
  let assert Ok([pending]) = fabric.pending(run)
  let assert Ok(run.Working) = approve(run, pending, "alice")
  let assert Ok(snapshot) = fabric.snapshot(run)
  list.map(snapshot.actions, fn(action) { action.state })
  |> should.equal([run.Running, run.Queued])
  restart.crash(owner, old)

  let store = support.directory(dir)
  let assert Ok(run) = fabric.recover(store, agent, "carol", fabric.id(run))
  let assert Ok(run.Suspended([renewed], [uncertain])) =
    fabric.await(run, within: duration.milliseconds(0))
  uncertain.tool |> should.equal("slow")
  renewed.reference.id |> should.equal(pending.reference.id)
  renewed.reference.requirement |> should.equal(pending.reference.requirement)
  { renewed.reference.revision > pending.reference.revision }
  |> should.be_true
  approve(run, pending, "alice") |> should.equal(Error(fabric.StaleReference))

  let assert Ok(_) = approve(run, renewed, "dave")
  let assert Ok(run.Suspended([], [_])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let assert Ok(_) = fabric.reconcile(run, uncertain.reference, "\"s\"")
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done"))))
  acts(probe)
  |> should.equal([
    "policy slow as carol", "policy transfer_funds as carol",
    "policy transfer_funds as alice", "policy transfer_funds as dave",
    "pay as dave", "policy note as carol", "note as carol",
  ])
  restart.remove_dir(dir)
}

// --- approved sub-agent starts ---------------------------------------------------

pub type Topic {
  Topic(topic: String)
}

pub type Summary {
  Summary(summary: String)
}

/// The summary is the researcher's plain answer.
fn research() -> tool.Definition(Topic, String) {
  tool.define(
    "research",
    "Delegate research on a topic to a researcher.",
    {
      use topic <- codec.field("topic", codec.string(), get: fn(topic) {
        topic.topic
      })
      codec.success(Topic(topic))
    },
    {
      use summary <- codec.field("summary", codec.string(), get: fn(summary) {
        summary
      })
      codec.success(summary)
    },
  )
}

fn research_call() -> model.ToolCall {
  let assert Ok(call) = testing.call(research(), "r", Topic("gleam"))
  call
}

/// A parent that delegates research (behind an approval) and then writes
/// a note; the researcher writes a note of its own and answers.
fn delegating(probe: Probe) -> Agent(String, String) {
  let researcher =
    agent.new(
      "researcher",
      scripted.plan([note_call()]),
      [note_tool(probe, "child note")],
      gate(probe, "child policy"),
    )
    |> support.agent
  agent.new(
    "agent",
    two_turns([research_call()]),
    [note_tool(probe, "parent note")],
    gate(probe, "policy"),
  )
  |> agent.with_sub_agent(research(), to: researcher, prompt: fn(topic: Topic) {
    topic.topic
  })
  |> support.agent
}

/// The approved start is the child run's start: the child runs with the
/// context that passed the recheck, and the parent keeps its own.
pub fn an_approved_sub_agent_starts_with_the_recheck_context_test() {
  let probe = probe.new()
  let assert Ok(run) =
    fabric.start(
      support.store(),
      delegating(probe),
      id: run.new_id(),
      context: "carol",
      prompt: "look it up",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let assert Ok(_) = approve(run, pending, "alice")
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done"))))
  acts(probe)
  |> should.equal([
    "policy research as carol", "policy research as alice",
    "child policy note as alice", "child note as alice", "policy note as carol",
    "parent note as carol",
  ])
}

/// The child of an approved start was never stored (its runner was lost
/// while storing it). Recovery has no context that passed a recheck for
/// it, so it asks for the approval again instead of starting the child;
/// the child then starts as whoever answers.
pub fn an_approved_sub_agent_never_stored_is_asked_for_again_test() {
  let probe = probe.new()
  let backend = flaky.new()
  let #(owner, #(first, run)) =
    restart.owned(fn() {
      let store = flaky.store(backend)
      let assert Ok(run) =
        fabric.start(
          store,
          delegating(probe),
          id: run.new_id(),
          context: "carol",
          prompt: "look it up",
          correlation: None,
        )
      #(store, run)
    })
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  // The answer commits; its runner is lost while it stores the child.
  let held = flaky.hold(backend, string.ends_with(_, "-1"))
  let assert Ok(_) = approve(run, pending, "alice")
  let assert Ok(_) = process.receive(held, 30_000)
  restart.crash(owner, first)
  flaky.drop_held(backend)

  let store = flaky.store(backend)
  let assert Ok(run) =
    fabric.recover(store, delegating(probe), "rita", fabric.id(run))
  let assert Ok(run.Suspended([renewed], [])) =
    fabric.await(run, within: duration.milliseconds(0))
  renewed.reference.id |> should.equal(pending.reference.id)
  { renewed.reference.revision > pending.reference.revision }
  |> should.be_true
  let assert Ok(snapshot) = fabric.snapshot(run)
  let assert [action] = snapshot.actions
  action.child |> should.equal(None)

  let assert Ok(_) = approve(run, renewed, "dave")
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done"))))
  acts(probe)
  |> should.equal([
    "policy research as carol", "policy research as alice",
    "policy research as dave", "child policy note as dave", "child note as dave",
    "policy note as rita", "parent note as rita",
  ])
}

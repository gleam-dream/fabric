//// Fabric's Sinal events, captured by handlers the test attaches: which
//// events a run emits, in which order, with which metadata, and that a
//// failing handler does not affect the run.

import fabric
import fabric/agent
import fabric/model
import fabric/observation as o
import fabric/policy.{Requirement}
import fabric/run
import fabric/store
import fabric/support/apps
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import sinal

// --- capture --------------------------------------------------------------------

/// Attaches a capture handler to every Fabric event; each event arrives at
/// `subject` as one line.
fn capture(subject: Subject(String)) -> List(sinal.Attachment) {
  let suffix = int.to_string(int.random(1_000_000_000))
  let attach = fn(name) { #(subject, suffix, name) }
  [
    attach_line(attach("started"), o.run_started(), fn(_, m: o.RunStarted) {
      "run_started "
      <> m.run
      <> " "
      <> m.agent
      <> " parent="
      <> option_text(m.parent)
    }),
    attach_line(
      attach("recovered"),
      o.run_recovered(),
      fn(_, m: o.RunRecovered) {
        "run_recovered " <> m.run <> " " <> int.to_string(m.incarnation)
      },
    ),
    attach_line(
      attach("model"),
      o.model_turn(),
      fn(t: o.Tokens, m: o.ModelTurn) {
        "model_turn "
        <> m.run
        <> " "
        <> int.to_string(m.turn)
        <> " "
        <> string.inspect(m.result)
        <> " tokens="
        <> int.to_string(t.input_tokens + t.output_tokens)
      },
    ),
    attach_line(
      attach("requested"),
      o.approval_requested(),
      fn(_, m: o.ApprovalRequested) {
        "approval_requested "
        <> action_text(m.action)
        <> " "
        <> m.requirement
        <> " rev="
        <> int.to_string(m.revision)
      },
    ),
    attach_line(
      attach("answered"),
      o.approval_answered(),
      fn(_, m: o.ApprovalAnswered) {
        "approval_answered "
        <> action_text(m.action)
        <> " "
        <> string.inspect(m.answer)
      },
    ),
    attach_line(
      attach("dispatched"),
      o.tool_dispatched(),
      fn(_, m: o.ToolDispatched) { "tool_dispatched " <> action_text(m.action) },
    ),
    attach_line(attach("settled"), o.tool_settled(), fn(_, m: o.ToolSettled) {
      "tool_settled "
      <> action_text(m.action)
      <> " "
      <> string.inspect(m.disposition)
    }),
    attach_line(
      attach("child_started"),
      o.child_started(),
      fn(_, m: o.ChildStarted) {
        "child_started " <> action_text(m.action) <> " " <> m.child
      },
    ),
    attach_line(
      attach("child_settled"),
      o.child_settled(),
      fn(_, m: o.ChildSettled) {
        "child_settled "
        <> action_text(m.action)
        <> " "
        <> m.child
        <> " "
        <> string.inspect(m.disposition)
      },
    ),
    attach_line(
      attach("cancelled"),
      o.run_cancelled(),
      fn(_, m: o.RunCancelled) { "run_cancelled " <> m.run },
    ),
    attach_line(
      attach("finished"),
      o.run_finished(),
      fn(t: o.RunTotals, m: o.RunFinished) {
        "run_finished "
        <> m.run
        <> " "
        <> string.inspect(m.outcome)
        <> " turns="
        <> int.to_string(t.turns)
      },
    ),
  ]
}

fn attach_line(
  at: #(Subject(String), String, String),
  event: sinal.Event(m, d),
  line: fn(m, d) -> String,
) -> sinal.Attachment {
  let #(subject, suffix, name) = at
  let assert Ok(id) = sinal.handler_id("fabric-capture-" <> name <> suffix)
  let assert Ok(attachment) =
    sinal.observe(id, event, fn(measurements, metadata) {
      process.send(subject, line(measurements, metadata))
    })
  attachment
}

fn release(attachments: List(sinal.Attachment)) -> Nil {
  list.each(attachments, fn(attachment) {
    let _ = sinal.detach(attachment)
    Nil
  })
}

fn option_text(value: option.Option(String)) -> String {
  case value {
    Some(text) -> text
    None -> "none"
  }
}

fn action_text(action: o.ActionRef) -> String {
  action.run
  <> " "
  <> int.to_string(action.turn)
  <> "/"
  <> action.call_id
  <> " "
  <> action.tool
}

/// Collects lines until one starts with `last`, in arrival order. Events
/// are emitted after their commit, so a test waits for the last one it
/// expects rather than for the run's status.
fn until(subject: Subject(String), last: String) -> List(String) {
  collect(subject, last, [])
}

fn collect(
  subject: Subject(String),
  last: String,
  seen: List(String),
) -> List(String) {
  let assert Ok(line) = process.receive(subject, 5000)
  let seen = [line, ..seen]
  case string.starts_with(line, last) {
    True -> list.reverse(seen)
    False -> collect(subject, last, seen)
  }
}

/// Only the lines about runs whose id starts with `id`.
fn about(lines: List(String), id: String) -> List(String) {
  list.filter(lines, fn(line) { string.contains(line, id) })
  |> list.map(string.replace(_, id, "R"))
}

fn transfers_need_approval(
  _: Nil,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  case action.tool {
    "transfer_funds" -> Ok(policy.RequireApproval(Requirement("transfer", 1)))
    _ -> Ok(policy.Allow)
  }
}

fn pay_call() -> model.ToolCall {
  scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}")
}

// --- tests ----------------------------------------------------------------------

/// A run that pauses for an approval, is approved, runs its tool, and
/// completes: every transition is observed once, in commit order.
pub fn a_run_is_observed_after_each_commit_test() {
  let events = process.new_subject()
  let attachments = capture(events)
  let agent =
    agent.new(
      scripted.plan([pay_call()]),
      [apps.transfer_tool()],
      transfers_need_approval,
    )
    |> agent.with_identity("desk", 1)
  let assert Ok(run) = fabric.start(store.in_memory(), agent, Nil, "pay")
  let id = fabric.id(run)
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)
  let paused = until(events, "approval_requested")
  let assert Ok(_) =
    fabric.answer(
      run,
      pending.reference,
      run.Approve,
      reviewer: None,
      context: Nil,
    )
  let rest = until(events, "run_finished")
  release(attachments)

  about(list.append(paused, rest), id)
  |> should.equal([
    "run_started R desk parent=none",
    "model_turn R 1 ToolRequest tokens=15",
    "approval_requested R 1/t transfer_funds transfer rev=1",
    "approval_answered R 1/t transfer_funds Approved",
    "tool_dispatched R 1/t transfer_funds",
    "tool_settled R 1/t transfer_funds ModelVisible",
    "model_turn R 2 FinalAnswer tokens=25",
    "run_finished R Completed turns=2",
  ])
}

/// A handler that returns an error and one that crashes are detached by
/// Sinal and telemetry; the run completes and other handlers still see
/// every event.
pub fn a_failing_handler_does_not_affect_the_run_test() {
  let events = process.new_subject()
  let attachments = capture(events)
  let assert Ok(failing_id) = sinal.handler_id("fabric-failing-handler")
  let assert Ok(failing) =
    sinal.attach(
      failing_id,
      o.model_turn(),
      fn(_, _, _) { Error("the handler failed") },
      fn(_, _) { Nil },
    )
  let assert Ok(crashing_id) = sinal.handler_id("fabric-crashing-handler")
  let assert Ok(crashing) =
    sinal.observe(crashing_id, o.tool_settled(), fn(_, _) {
      panic as "the handler crashed"
    })
  let agent =
    agent.new(
      scripted.plan([
        scripted.call("w", "lookup_weather", "{\"city\":\"Paris\"}"),
      ]),
      [apps.weather_tool()],
      policy.always_allow(),
    )
  let assert Ok(run) = fabric.start(store.in_memory(), agent, Nil, "weather")
  fabric.await(run, 5000)
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"sunny\"}"))),
  )
  let lines = until(events, "run_finished") |> about(fabric.id(run))
  release([failing, crashing, ..attachments])
  lines
  |> should.equal([
    "run_started R agent parent=none",
    "model_turn R 1 ToolRequest tokens=15",
    "tool_dispatched R 1/w lookup_weather",
    "tool_settled R 1/w lookup_weather ModelVisible",
    "model_turn R 2 FinalAnswer tokens=25",
    "run_finished R Completed turns=2",
  ])
}

pub type Topic {
  Topic(topic: String)
}

/// A delegation's child is observed as its own run naming its parent; the
/// parent observes the child starting and settling. Cancelling and
/// recovering are observed too.
pub fn sub_agents_cancellation_and_recovery_are_observed_test() {
  let events = process.new_subject()
  let attachments = capture(events)
  let probe = probe.new()
  let researcher =
    agent.new(
      scripted.plan([scripted.slow("s", "s")]),
      [scripted.gated_tool(probe)],
      policy.always_allow(),
    )
    |> agent.with_identity("researcher", 1)
  let research =
    tool.define(
      "research",
      "Research a topic.",
      codec.field("topic", codec.string())
        |> codec.imap(Topic, fn(t) { t.topic }),
      codec.string(),
    )
  let assert Ok(call) = tool.call(research, "r", Topic("gleam"))
  let parent =
    agent.new(scripted.plan([call]), [], policy.always_allow())
    |> agent.with_identity("lead", 1)
    |> agent.with_sub_agent(
      research,
      to: researcher,
      prompt: fn(topic: Topic) { topic.topic },
      result: fn(outcome) {
        case outcome {
          run.Completed(text) -> Ok(text)
          _ -> Error(tool.Explain("no"))
        }
      },
    )
  let dir = restart.temp_dir()
  let #(owner, #(old, run)) =
    restart.owned(fn() {
      let assert Ok(store) = store.directory(dir)
      let assert Ok(run) = fabric.start(store, parent, Nil, "go")
      #(store, run)
    })
  let _ = probe.arrival(probe)
  let started = until(events, "tool_dispatched")
  restart.kill(owner)
  restart.gone(store.pid(old))

  let assert Ok(store) = store.directory(dir)
  let assert Ok(run) = fabric.recover(store, parent, Nil, fabric.id(run))
  let recovered = until(events, "tool_settled")
  let assert Ok(_) = fabric.cancel(run)
  let cancelled = until(events, "run_finished " <> fabric.id(run) <> " ")
  release(attachments)
  restart.remove_dir(dir)

  // Each run's events are in its commit order; the two runs' events
  // interleave as their processes run.
  let lines = list.flatten([started, recovered, cancelled])
  let id = fabric.id(run)
  of_run(lines, id, id)
  |> should.equal([
    "run_started R lead parent=none",
    "model_turn R 1 ToolRequest tokens=15",
    "child_started R 1/r research R-1",
    "run_cancelled R",
    "child_settled R 1/r research R-1 EffectUncertain",
    "run_finished R Cancelled turns=1",
  ])
  of_run(lines, id <> "-1", id)
  |> should.equal([
    "run_started R-1 researcher parent=R",
    "model_turn R-1 1 ToolRequest tokens=15",
    "tool_dispatched R-1 1/s slow",
    "run_recovered R-1 2",
    "tool_settled R-1 1/s slow EffectUncertain",
    "run_cancelled R-1",
    "run_finished R-1 Cancelled turns=1",
  ])
}

/// The lines whose run (the second word) is exactly `id`, with `root`
/// replaced by `R`.
fn of_run(lines: List(String), id: String, root: String) -> List(String) {
  list.filter(lines, fn(line) {
    case string.split(line, " ") {
      [_, run, ..] -> run == id
      _ -> False
    }
  })
  |> list.map(string.replace(_, root, "R"))
}

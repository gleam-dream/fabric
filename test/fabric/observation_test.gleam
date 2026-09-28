//// Fabric's Sinal events, captured by handlers the test attaches: which
//// events a run emits, in which order, with which metadata, that a
//// failing handler does not affect the run, and where handlers run when
//// the application routes Fabric's events through a Sinal forwarder.

import fabric
import fabric/agent
import fabric/model
import fabric/observation as o
import fabric/policy
import fabric/run.{Requirement}
import fabric/store
import fabric/support
import fabric/support/apps
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import fabric/tool
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import sinal
import sinal/forwarder

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
      "desk",
      scripted.plan([pay_call()]),
      [apps.transfer_tool()],
      transfers_need_approval,
    )
    |> support.agent
  let assert Ok(run) = fabric.start(store.in_memory(), agent, Nil, "pay")
  let id = support.text(fabric.id(run))
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)
  let paused = until(events, "approval_requested")
  let assert Ok(_) =
    fabric.approve(run, pending.reference, reviewer: None, context: Nil)
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
      "agent",
      scripted.plan([
        scripted.call("w", "lookup_weather", "{\"city\":\"Paris\"}"),
      ]),
      [apps.weather_tool()],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(run) = fabric.start(store.in_memory(), agent, Nil, "weather")
  fabric.await(run, 5000)
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"sunny\"}"))),
  )
  let lines =
    until(events, "run_finished") |> about(support.text(fabric.id(run)))
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
      "researcher",
      scripted.plan([scripted.slow("s", "s")]),
      [scripted.gated_tool(probe)],
      policy.always_allow(),
    )
    |> support.agent
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
    agent.new("lead", scripted.plan([call]), [], policy.always_allow())
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
    |> support.agent
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
  let cancelled =
    until(events, "run_finished " <> support.text(fabric.id(run)) <> " ")
  release(attachments)
  restart.remove_dir(dir)

  // Each run's events are in its commit order; the two runs' events
  // interleave as their processes run.
  let lines = list.flatten([started, recovered, cancelled])
  let id = support.text(fabric.id(run))
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

// --- routing --------------------------------------------------------------------

/// A `model_turn` handler that announces the run, the process it runs in,
/// and a release subject, then blocks until the test releases it.
fn blocking_model_turn(
  name: String,
) -> #(Subject(#(String, Pid, Subject(Nil))), sinal.Attachment) {
  let entered = process.new_subject()
  let suffix = int.to_string(int.random(1_000_000_000))
  let assert Ok(id) = sinal.handler_id("fabric-blocking-" <> name <> suffix)
  let assert Ok(attachment) =
    sinal.observe(id, o.model_turn(), fn(_, m: o.ModelTurn) {
      let gate = process.new_subject()
      process.send(entered, #(m.run, process.self(), gate))
      process.receive_forever(gate)
    })
  #(entered, attachment)
}

/// The next blocked handler of run `id`; handlers of other runs are
/// released.
fn entered_by(
  entered: Subject(#(String, Pid, Subject(Nil))),
  id: String,
) -> #(Pid, Subject(Nil)) {
  let assert Ok(#(run, pid, gate)) = process.receive(entered, 5000)
  case run == id {
    True -> #(pid, gate)
    False -> {
      process.send(gate, Nil)
      entered_by(entered, id)
    }
  }
}

fn weather_agent_spec() -> agent.Spec(Nil) {
  agent.new(
    "agent",
    scripted.plan([scripted.call("w", "lookup_weather", "{\"city\":\"Paris\"}")]),
    [apps.weather_tool()],
    policy.always_allow(),
  )
}

fn weather_agent() -> agent.Agent(Nil) {
  support.agent(weather_agent_spec())
}

/// With `[fabric]` routed through a forwarder, a blocked handler stalls
/// the forwarder, not the run: the run finishes while the handler of its
/// first model turn is still blocked, and that handler runs in the
/// forwarder's process.
pub fn a_routed_handler_runs_in_the_forwarder_and_does_not_stall_the_run_test() {
  let assert Ok(fwd) =
    forwarder.new(process.new_name("fabric-observation-forwarder"), 64)
  let assert Ok(started) = forwarder.supervised(fwd).start()
  let prefix = [atom.create("fabric")]
  forwarder.route(prefix, fwd)
  let #(entered, attachment) = blocking_model_turn("routed")

  let assert Ok(run) =
    fabric.start(store.in_memory(), weather_agent(), Nil, "weather")
  let #(first, gate) = entered_by(entered, support.text(fabric.id(run)))
  let finished = fabric.await(run, 5000)
  process.send(gate, Nil)
  let #(second, gate) = entered_by(entered, support.text(fabric.id(run)))
  process.send(gate, Nil)
  forwarder.unroute(prefix)
  let _ = sinal.detach(attachment)
  process.unlink(started.pid)
  process.kill(started.pid)

  finished
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"sunny\"}"))),
  )
  #(first, second) |> should.equal(#(started.pid, started.pid))
}

/// Without a route, a handler runs synchronously in the process that made
/// the commit: a model turn's handler runs in the run's runner, which waits
/// for it.
pub fn an_unrouted_handler_runs_in_the_runner_test() {
  let #(entered, attachment) = blocking_model_turn("unrouted")
  let memory = store.in_memory()
  let assert Ok(run) = fabric.start(memory, weather_agent(), Nil, "weather")
  let #(handler, gate) = entered_by(entered, support.text(fabric.id(run)))
  let assert Ok(store.Entry(live: Some(store.Live(_, mailbox)), ..)) =
    store.get(memory, support.text(fabric.id(run)))
  let runner = process.subject_owner(mailbox)
  let waiting = fabric.await(run, 0)
  process.send(gate, Nil)
  let #(_, gate) = entered_by(entered, support.text(fabric.id(run)))
  process.send(gate, Nil)
  let finished = fabric.await(run, 5000)
  let _ = sinal.detach(attachment)

  runner |> should.equal(Ok(handler))
  waiting |> should.equal(Ok(run.Working))
  finished
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"sunny\"}"))),
  )
}

// --- handlers and commands --------------------------------------------------------

/// A synchronous handler runs inside the runner, which cannot take a
/// command until the handler returns: a handler that commands the run it
/// observes (other than cancelling it) is refused at once instead of
/// deadlocking the runner, and the run goes on.
pub fn a_handler_commanding_its_own_run_is_refused_test() {
  let memory = store.in_memory()
  let results = process.new_subject()
  let assert Ok(id) =
    sinal.handler_id(
      "fabric-self-command-" <> int.to_string(int.random(1_000_000_000)),
    )
  let assert Ok(attachment) =
    sinal.observe(id, o.tool_dispatched(), fn(_, m: o.ToolDispatched) {
      let assert Ok(own) =
        fabric.recover(memory, weather_agent(), Nil, support.id(m.action.run))
      process.send(
        results,
        fabric.reconcile(
          own,
          run.ActionRef(fabric.id(own), run.ActionId(1, "w")),
          "{}",
        ),
      )
    })
  let assert Ok(run) = fabric.start(memory, weather_agent(), Nil, "weather")
  let assert Ok(refused) = process.receive(results, 5000)
  let finished = fabric.await(run, 5000)
  let _ = sinal.detach(attachment)

  refused |> should.equal(Error(fabric.RunnerBusy))
  finished
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"sunny\"}"))),
  )
}

/// A cancellation is never refused as busy: a handler that cancels the run
/// its runner drives commits the cancellation to the record, and the
/// runner stops at its next commit.
pub fn a_handler_cancelling_its_own_run_commits_the_cancellation_test() {
  let memory = store.in_memory()
  let results = process.new_subject()
  let assert Ok(id) =
    sinal.handler_id(
      "fabric-self-cancel-" <> int.to_string(int.random(1_000_000_000)),
    )
  let assert Ok(attachment) =
    sinal.observe(id, o.tool_dispatched(), fn(_, m: o.ToolDispatched) {
      process.send(
        results,
        fabric.cancel_stored(memory, support.id(m.action.run)),
      )
    })
  let assert Ok(run) = fabric.start(memory, weather_agent(), Nil, "weather")
  let assert Ok(cancelled) = process.receive(results, 5000)
  let finished = fabric.await(run, 5000)
  let _ = sinal.detach(attachment)

  cancelled |> should.equal(Ok(run.Finished(run.Cancelled)))
  finished |> should.equal(Ok(run.Finished(run.Cancelled)))
}

/// A command is answered once its commit is stored, before the handlers
/// of that commit run: a blocked handler of the cancellation does not hold
/// up `cancel`.
pub fn a_command_returns_before_its_handlers_run_test() {
  let probe = probe.new()
  let entered = process.new_subject()
  let assert Ok(id) =
    sinal.handler_id(
      "fabric-blocking-cancel-" <> int.to_string(int.random(1_000_000_000)),
    )
  let assert Ok(attachment) =
    sinal.observe(id, o.run_cancelled(), fn(_, m: o.RunCancelled) {
      let gate = process.new_subject()
      process.send(entered, #(m.run, gate))
      process.receive_forever(gate)
    })
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("s", "s")]),
      [scripted.gated_tool(probe)],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(run) = fabric.start(store.in_memory(), agent, Nil, "go")
  let _ = probe.arrival(probe)
  let cancelled = fabric.cancel(run)
  let assert Ok(#(cancelled_run, gate)) = process.receive(entered, 5000)
  process.send(gate, Nil)
  let finished = fabric.await(run, 5000)
  let _ = sinal.detach(attachment)

  cancelled |> should.equal(Ok(run.Working))
  cancelled_run |> should.equal(support.text(fabric.id(run)))
  finished |> should.equal(Ok(run.Finished(run.Cancelled)))
}

/// A runner held by a blocked handler does not take a command in time: the
/// command (other than a cancellation) is refused as busy and never applied
/// later.
pub fn a_command_to_a_runner_held_by_a_handler_is_refused_test() {
  let #(entered, attachment) = blocking_model_turn("busy")
  let agent =
    weather_agent_spec()
    |> agent.with_limits(
      agent.Limits(..agent.default_limits(), command_timeout: 20),
    )
    |> support.agent
  let assert Ok(run) = fabric.start(store.in_memory(), agent, Nil, "weather")
  let #(_, gate) = entered_by(entered, support.text(fabric.id(run)))
  let refused =
    fabric.reconcile(
      run,
      run.ActionRef(fabric.id(run), run.ActionId(1, "w")),
      "{}",
    )
  process.send(gate, Nil)
  let #(_, gate) = entered_by(entered, support.text(fabric.id(run)))
  process.send(gate, Nil)
  let finished = fabric.await(run, 5000)
  let _ = sinal.detach(attachment)

  refused |> should.equal(Error(fabric.RunnerBusy))
  finished
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"sunny\"}"))),
  )
}

//// Stopping an application drains its runners: a runner starts nothing
//// new, lets the tool bodies it runs and a model reply in flight finish,
//// commits their results, and hands its run off, ready for `recover`,
//// before the store's process stops. A runner still busy when the drain
//// window ends is killed, as when a node stops.

import fabric
import fabric/agent.{type Agent}
import fabric/internal/store as store_core
import fabric/model
import fabric/policy
import fabric/run.{Requirement}
import fabric/store
import fabric/support
import fabric/support/codecs
import fabric/support/probe.{type Probe}
import fabric/support/restart
import fabric/support/scripted
import fabric/testing
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn one_slow(probe: Probe) -> Agent(Nil) {
  agent.new(
    "agent",
    scripted.plan([scripted.slow("a", "a")]),
    [scripted.gated_tool(probe)],
    policy.always_allow(),
  )
  |> support.agent
}

fn reviewed(
  _context: Nil,
  _action: policy.Action,
) -> Result(policy.Decision, String) {
  Ok(policy.RequireApproval(Requirement("review", 1)))
}

fn states(run: fabric.Run(context)) -> List(run.ActionState) {
  let assert Ok(snapshot) = fabric.snapshot(run)
  list.map(snapshot.actions, fn(action) { action.state })
}

fn turns_used(run: fabric.Run(context)) -> Int {
  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.turns_used
}

/// The tool running when the application stops finishes, its result is
/// committed, and the run is handed off: the next model call was never
/// issued, so its turn is not counted. After a restart, `recover` goes on
/// with no uncertain effect, and the run uses as many turns as it would
/// have without the stop.
pub fn a_stop_lets_a_running_tool_finish_and_hands_the_run_off_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let runs = support.restartable_store(dir)
  let app = restart.application(runs)
  let assert Ok(run) =
    fabric.start(
      runs,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  restart.begin_stop(app)
  restart.draining(runs)
  probe.release(running)
  restart.stopped(app)

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, one_slow(probe), Nil, fabric.id(run))
  fabric.await(run, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Unattended))
  states(run) |> should.equal([run.Succeeded("\"a\"")])
  turns_used(run) |> should.equal(1)

  let assert Ok(run) =
    fabric.recover(runs, one_slow(probe), Nil, fabric.id(run))
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  turns_used(run) |> should.equal(2)
  probe.count(probe, "start:a") |> should.equal(1)
  restart.stop(app)
  restart.remove_dir(dir)
}

/// A tool still running when the drain window ends is killed with its
/// runner: it becomes an uncertain effect after recovery and never runs
/// again.
pub fn a_tool_past_the_drain_window_is_uncertain_and_never_rerun_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let assert Ok(runs) =
    store.with_drain(support.restartable_store(dir), duration.milliseconds(50))
  let app = restart.application(runs)
  let assert Ok(run) =
    fabric.start(
      runs,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let _ = probe.arrival(probe)
  restart.stop(app)

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, one_slow(probe), Nil, fabric.id(run))
  fabric.await(run, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Unattended))
  states(run) |> should.equal([run.Running])
  let assert Ok(run) =
    fabric.recover(runs, one_slow(probe), Nil, fabric.id(run))
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let assert Ok(_) = fabric.reconcile(run, uncertain.reference, "\"a\"")
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  probe.count(probe, "start:a") |> should.equal(1)
  restart.stop(app)
  restart.remove_dir(dir)
}

/// With one tool at a time, an approved tool still queued behind a running
/// one does not start during the drain. Its approval was checked with a
/// context that does not outlive the runner, so the handoff asks for it
/// again: the old reference is stale, and the run waits, suspended, for
/// the new request.
pub fn an_approved_queued_tool_is_asked_for_again_after_the_handoff_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let runs = support.restartable_store(dir)
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("a", "a"), scripted.slow("b", "b")]),
      [scripted.gated_tool(probe)],
      reviewed,
    )
    |> agent.with_max_concurrency(1)
    |> support.agent
  let app = restart.application(runs)
  let assert Ok(run) =
    fabric.start(
      runs,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([first, second], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let assert Ok(_) =
    fabric.approve(
      run,
      first.reference,
      reviewer: support.reviewer("alice"),
      context: Nil,
    )
  let running = probe.arrival(probe)
  let assert Ok(_) =
    fabric.approve(
      run,
      second.reference,
      reviewer: support.reviewer("alice"),
      context: Nil,
    )
  states(run) |> should.equal([run.Running, run.Queued])
  restart.begin_stop(app)
  restart.draining(runs)
  probe.release(running)
  restart.stopped(app)

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, agent, Nil, fabric.id(run))
  let assert Ok(run.Suspended([renewed], [])) =
    fabric.await(run, within: duration.milliseconds(0))
  renewed.reference.id |> should.equal(second.reference.id)
  { renewed.reference.revision > second.reference.revision } |> should.be_true
  fabric.approve(
    run,
    second.reference,
    reviewer: support.reviewer("alice"),
    context: Nil,
  )
  |> should.equal(Error(fabric.StaleReference))
  let assert Ok(_) =
    fabric.approve(
      run,
      renewed.reference,
      reviewer: support.reviewer("bob"),
      context: Nil,
    )
  probe.release(probe.arrival(probe))
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\" | \"b\""))))
  probe.count(probe, "start:a") |> should.equal(1)
  probe.count(probe, "start:b") |> should.equal(1)
  restart.stop(app)
  restart.remove_dir(dir)
}

/// A model call in flight when the application stops is waited for, and
/// its reply committed: the tool it requests stays queued, and recovery
/// starts it.
pub fn a_stop_waits_for_the_model_reply_in_flight_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let runs = support.restartable_store(dir)
  let slow_model =
    model.new(fn(request: model.Request) {
      case scripted.results(request.messages) {
        [] -> {
          probe.gate(probe, "model")
          Ok(model.ToolRequest(
            model.AssistantTurn("", [scripted.slow("a", "a")], None),
            Some(model.Usage(10, 5)),
          ))
        }
        seen ->
          Ok(model.FinalAnswer(
            "final: " <> string.join(seen, " | "),
            Some(model.Usage(20, 5)),
          ))
      }
    })
  let agent =
    agent.new(
      "agent",
      slow_model,
      [scripted.gated_tool(probe)],
      policy.always_allow(),
    )
    |> support.agent
  let app = restart.application(runs)
  let assert Ok(run) =
    fabric.start(
      runs,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let calling = probe.arrival(probe)
  restart.begin_stop(app)
  restart.draining(runs)
  probe.release(calling)
  restart.stopped(app)

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, agent, Nil, fabric.id(run))
  fabric.await(run, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Unattended))
  states(run) |> should.equal([run.Queued])
  turns_used(run) |> should.equal(1)
  let assert Ok(run) = fabric.recover(runs, agent, Nil, fabric.id(run))
  probe.release(probe.arrival(probe))
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  turns_used(run) |> should.equal(2)
  probe.count(probe, "start:a") |> should.equal(1)
  restart.stop(app)
  restart.remove_dir(dir)
}

/// A suspended run has no process, so stopping the application leaves it
/// exactly as it was: its request is answered after the restart.
pub fn a_suspended_run_is_untouched_by_a_stop_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let runs = support.restartable_store(dir)
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("a", "a")]),
      [scripted.gated_tool(probe)],
      reviewed,
    )
    |> support.agent
  let app = restart.application(runs)
  let assert Ok(run) =
    fabric.start(
      runs,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let assert Ok(before) = fabric.snapshot(run)
  restart.stop(app)

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, agent, Nil, fabric.id(run))
  fabric.snapshot(run) |> should.equal(Ok(before))
  let assert Ok(_) =
    fabric.approve(
      run,
      pending.reference,
      reviewer: support.reviewer("alice"),
      context: Nil,
    )
  probe.release(probe.arrival(probe))
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  restart.stop(app)
  restart.remove_dir(dir)
}

/// The store's process stops after its runners: while a runner drains,
/// the store's process runs, and the runner's results are committed
/// through it before it stops.
pub fn a_store_stops_after_its_draining_runners_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let runs = support.restartable_store(dir)
  let app = restart.application(runs)
  let assert Ok(run) =
    fabric.start(
      runs,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  let assert Ok(store_process) = store_core.pid(runs)
  let assert Ok(runner) = restart.runner(runs, fabric.id(run))
  restart.begin_stop(app)
  restart.draining(runs)
  process.is_alive(runner) |> should.be_true
  process.is_alive(store_process) |> should.be_true
  probe.release(running)
  restart.gone(runner)
  restart.stopped(app)
  process.is_alive(store_process) |> should.be_false

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, one_slow(probe), Nil, fabric.id(run))
  states(run) |> should.equal([run.Succeeded("\"a\"")])
  restart.stop(app)
  restart.remove_dir(dir)
}

/// A child run is drained by its own runner: its running tool finishes and
/// the child is handed off, while its parent's delegation stays delegated.
/// Recovering the parent recovers the child, which goes on without
/// running its tool again.
pub fn a_child_run_drains_on_its_own_and_is_recovered_with_its_parent_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let runs = support.restartable_store(dir)
  let research =
    tool.define(
      "research",
      "Delegate research on a topic.",
      codecs.one_field("topic", codec.string()),
      codec.string(),
    )
  let researcher =
    agent.new(
      "researcher",
      scripted.plan([scripted.slow("a", "a")]),
      [scripted.gated_tool(probe)],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(delegation) = testing.call(research, "r", "weather")
  let parent =
    agent.new(
      "parent",
      scripted.model(fn(messages) {
        case scripted.results(messages) {
          [] ->
            model.ToolRequest(model.AssistantTurn("", [delegation], None), None)
          seen -> model.FinalAnswer("done: " <> string.join(seen, ","), None)
        }
      }),
      [],
      policy.always_allow(),
    )
    |> agent.with_sub_agent(
      research,
      to: researcher,
      prompt: fn(topic) { topic },
      output: fn(answer) { Ok(answer) },
    )
    |> support.agent
  let app = restart.application(runs)
  let assert Ok(run) =
    fabric.start(
      runs,
      parent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  restart.begin_stop(app)
  restart.draining(runs)
  probe.release(running)
  restart.stopped(app)

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, parent, Nil, fabric.id(run))
  states(run) |> should.equal([run.Delegated])
  fabric.await(run, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Unattended))
  let assert Ok(child) = fabric.child(run, support.child_id(fabric.id(run), 1))
  states(child) |> should.equal([run.Succeeded("\"a\"")])
  turns_used(child) |> should.equal(1)

  let assert Ok(run) = fabric.recover(runs, parent, Nil, fabric.id(run))
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done: \"final: \\\"a\\\"\""))))
  probe.count(probe, "start:a") |> should.equal(1)
  restart.stop(app)
  restart.remove_dir(dir)
}

fn research() -> tool.Definition(String, String) {
  tool.define(
    "research",
    "Delegate research on a topic.",
    codecs.one_field("topic", codec.string()),
    codec.string(),
  )
}

/// A parent that calls `calls` at once, with the gated tool and a
/// delegation to a researcher that answers at once, under `policy`, which
/// may take up to a minute to decide.
fn delegating(
  probe: Probe,
  calls: List(model.ToolCall),
  policy: policy.Policy(Nil),
) -> Agent(Nil) {
  let researcher =
    agent.new(
      "researcher",
      scripted.model(fn(_) { model.FinalAnswer("found", None) }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  agent.new(
    "parent",
    scripted.model(fn(messages) {
      case scripted.results(messages) {
        [] -> model.ToolRequest(model.AssistantTurn("", calls, None), None)
        seen -> model.FinalAnswer("done: " <> string.join(seen, ","), None)
      }
    }),
    [scripted.gated_tool(probe)],
    policy,
  )
  |> agent.with_policy_timeout(duration.milliseconds(60_000))
  |> agent.with_sub_agent(
    research(),
    to: researcher,
    prompt: fn(topic) { topic },
    output: fn(answer) { Ok(answer) },
  )
  |> support.agent
}

/// Waits until `pid` has at least `count` messages queued.
fn queued(pid: process.Pid, count: Int) -> Nil {
  case restart.queued(pid) >= count {
    True -> Nil
    False -> {
      process.sleep(1)
      queued(pid, count)
    }
  }
}

/// An approval of a delegation that reaches the runner ahead of its
/// shutdown starts the child run while the factory is already stopping:
/// the start does not wait for the factory (the child is stored with no
/// runner), so the drain goes on, the running tool's result is committed,
/// and the run is handed off long before the window ends.
pub fn a_delegation_approved_ahead_of_the_stop_does_not_hold_up_the_drain_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let assert Ok(runs) =
    store.with_drain(
      support.restartable_store(dir),
      duration.milliseconds(60_000),
    )
  let assert Ok(delegation) = testing.call(research(), "r", "weather")
  let policy = fn(_context, action: policy.Action) {
    case action.name {
      "research" -> Ok(policy.RequireApproval(Requirement("review", 1)))
      _ -> Ok(policy.Allow)
    }
  }
  let parent = delegating(probe, [scripted.slow("a", "a"), delegation], policy)
  let app = restart.application(runs)
  let assert Ok(run) =
    fabric.start(
      runs,
      parent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  let assert Ok(run.Working) =
    fabric.await(run, within: duration.milliseconds(0))
  let assert Ok([pending]) = fabric.pending(run)
  let assert Ok(runner) = restart.runner(runs, fabric.id(run))
  restart.suspend(runner)
  let approved = process.new_subject()
  process.spawn(fn() {
    process.send(
      approved,
      fabric.approve(
        run,
        pending.reference,
        reviewer: support.reviewer("reviewer"),
        context: Nil,
      ),
    )
  })
  queued(runner, 1)
  restart.begin_stop(app)
  // The runner's shutdown is queued behind the approval.
  queued(runner, 2)
  restart.resume(runner)
  let assert Ok(Ok(_)) = process.receive(approved, 5000)
  probe.release(running)
  restart.stopped_within(app, 5000) |> should.be_true

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, parent, Nil, fabric.id(run))
  states(run) |> should.equal([run.Succeeded("\"a\""), run.Delegated])
  let assert Ok(run) = fabric.recover(runs, parent, Nil, fabric.id(run))
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done: \"a\",\"found\""))))
  probe.count(probe, "start:a") |> should.equal(1)
  restart.stop(app)
  restart.remove_dir(dir)
}

/// A runner held in a policy decision when the application stops starts
/// its child run once the decision comes: the start does not wait for the
/// stopping factory, and the run is handed off long before the window
/// ends.
pub fn a_delegation_decided_during_the_stop_does_not_hold_up_the_drain_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let gate = probe.new()
  let assert Ok(runs) =
    store.with_drain(
      support.restartable_store(dir),
      duration.milliseconds(60_000),
    )
  let assert Ok(delegation) = testing.call(research(), "r", "weather")
  let policy = fn(_context, action: policy.Action) {
    case action.name {
      "research" -> probe.gate(gate, "policy")
      _ -> Nil
    }
    Ok(policy.Allow)
  }
  let parent = delegating(probe, [delegation], policy)
  let app = restart.application(runs)
  let assert Ok(run) =
    fabric.start(
      runs,
      parent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let deciding = probe.arrival(gate)
  restart.begin_stop(app)
  restart.draining(runs)
  probe.release(deciding)
  restart.stopped_within(app, 5000) |> should.be_true

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, parent, Nil, fabric.id(run))
  states(run) |> should.equal([run.Delegated])
  let assert Ok(run) = fabric.recover(runs, parent, Nil, fabric.id(run))
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done: \"found\""))))
  restart.stop(app)
  restart.remove_dir(dir)
}

/// A model call waiting out its retry backoff when the application stops
/// is never issued: the drain does not wait for the backoff, and the
/// handoff gives its turn back.
pub fn a_retry_backoff_is_not_waited_for_and_its_turn_is_given_back_test() {
  let dir = restart.temp_dir()
  let calls = probe.new()
  let runs = support.restartable_store(dir)
  let flaky_model =
    model.new(fn(_request) {
      probe.record(calls, "call")
      case probe.count(calls, "call") {
        1 -> Error(model.error(model.Overloaded, "overloaded"))
        _ -> Ok(model.FinalAnswer("done", None))
      }
    })
  let agent =
    agent.new("agent", flaky_model, [], policy.always_allow())
    |> agent.with_model_retry_delay(duration.milliseconds(60_000))
    |> support.agent
  let app = restart.application(runs)
  let assert Ok(run) =
    fabric.start(
      runs,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Working) =
    fabric.await(run, within: duration.milliseconds(0))
  wait_for_turns(run, 2)
  restart.stopped_within(app, 0) |> should.be_false
  restart.begin_stop(app)
  restart.stopped_within(app, 5000) |> should.be_true
  probe.count(calls, "call") |> should.equal(1)

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, agent, Nil, fabric.id(run))
  turns_used(run) |> should.equal(1)
  let assert Ok(run) = fabric.recover(runs, agent, Nil, fabric.id(run))
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done"))))
  turns_used(run) |> should.equal(2)
  probe.count(calls, "call") |> should.equal(2)
  restart.stop(app)
  restart.remove_dir(dir)
}

/// Waits until the run's record counts `turns` model turns.
fn wait_for_turns(run: fabric.Run(context), turns: Int) -> Nil {
  case turns_used(run) >= turns {
    True -> Nil
    False -> {
      process.sleep(1)
      wait_for_turns(run, turns)
    }
  }
}

/// A shutdown that reaches the runner behind a tool's report is taken
/// first: the runner drains before it applies the report, so the tool
/// queued behind the finished one never starts, stays queued, and runs
/// after recovery.
pub fn a_shutdown_queued_behind_a_report_is_taken_first_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let assert Ok(runs) =
    store.with_drain(
      support.restartable_store(dir),
      duration.milliseconds(60_000),
    )
  let two =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("a", "a"), scripted.slow("b", "b")]),
      [scripted.gated_tool(probe)],
      policy.always_allow(),
    )
    |> agent.with_max_concurrency(1)
    |> support.agent
  let app = restart.application(runs)
  let assert Ok(run) =
    fabric.start(
      runs,
      two,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  let assert Ok(runner) = restart.runner(runs, fabric.id(run))
  restart.suspend(runner)
  probe.release(running)
  queued(runner, 1)
  let before = restart.queued(runner)
  restart.begin_stop(app)
  queued(runner, before + 1)
  restart.resume(runner)
  restart.stopped_within(app, 5000) |> should.be_true
  probe.count(probe, "start:b") |> should.equal(0)

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, two, Nil, fabric.id(run))
  states(run) |> should.equal([run.Succeeded("\"a\""), run.Queued])
  let assert Ok(run) = fabric.recover(runs, two, Nil, fabric.id(run))
  probe.release(probe.arrival(probe))
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\" | \"b\""))))
  probe.count(probe, "start:b") |> should.equal(1)
  restart.stop(app)
  restart.remove_dir(dir)
}

/// A tool body that starts a run while the application stops does not
/// hold up the drain, even when its start reaches the factory after the
/// factory began stopping (here: the store's process answers the body's
/// request for the factory only after it learned of the drain). The start
/// is given up and the run is stored with no runner; the body returns, and
/// the parent is handed off long before the window ends.
pub fn a_tool_body_starting_a_run_during_the_stop_does_not_hold_up_the_drain_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let assert Ok(runs) =
    store.with_drain(
      support.restartable_store(dir),
      duration.milliseconds(60_000),
    )
  let child =
    agent.new(
      "child",
      scripted.model(fn(_) { model.FinalAnswer("child done", None) }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let starter =
    tool.define(
      "starter",
      "Starts a run.",
      codecs.one_field("x", codec.string()),
      codec.string(),
    )
    |> tool.bind(
      fn(_context, _call, x: String) -> Result(String, Nil) {
        probe.gate(probe, x)
        case
          fabric.start(
            runs,
            child,
            id: run.new_id(),
            context: Nil,
            prompt: "sub",
            correlation: None,
          )
        {
          Ok(started) -> Ok(run.id_to_string(fabric.id(started)))
          Error(_) -> Ok("refused")
        }
      },
      fn(_) { tool.Explain("failed") },
    )
  let parent =
    agent.new(
      "parent",
      scripted.plan([scripted.call("s", "starter", "{\"x\":\"s\"}")]),
      [starter],
      policy.always_allow(),
    )
    |> support.agent
  let app = restart.application(runs)
  let assert Ok(run) =
    fabric.start(
      runs,
      parent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  let assert Ok(store_process) = store_core.pid(runs)
  restart.suspend(store_process)
  probe.release(running)
  // The body waits for the store's answer; the stop begins meanwhile.
  queued(store_process, 1)
  restart.begin_stop(app)
  queued(store_process, 3)
  restart.resume(store_process)
  restart.stopped_within(app, 5000) |> should.be_true

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, parent, Nil, fabric.id(run))
  let assert [run.Succeeded(started)] = states(run)
  let assert Ok(id) = run.parse_id(string.replace(started, "\"", ""))
  let assert Ok(sub) = fabric.open(runs, child, Nil, id)
  fabric.await(sub, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Unattended))
  restart.stop(app)
  restart.remove_dir(dir)
}

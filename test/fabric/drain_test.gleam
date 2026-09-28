//// Stopping an application drains its runners: a runner starts nothing
//// new, lets the tool bodies it runs and a model reply in flight finish,
//// commits their results, and hands its run off, ready for `recover`,
//// before the store's process stops. A runner still busy when the drain
//// window ends is killed, as when a node stops.

import fabric
import fabric/agent.{type Agent}
import fabric/model
import fabric/policy
import fabric/run.{Requirement}
import fabric/store
import fabric/support
import fabric/support/probe.{type Probe}
import fabric/support/restart
import fabric/support/scripted
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should

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

fn directory_store(dir: String) -> store.Store {
  store.directory(process.new_name("draining"), dir)
}

/// The tool running when the application stops finishes, its result is
/// committed, and the run is handed off: the next model call was never
/// issued, so its turn is not counted. After a restart, `recover` goes on
/// with no uncertain effect, and the run uses as many turns as it would
/// have without the stop.
pub fn a_stop_lets_a_running_tool_finish_and_hands_the_run_off_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let runs = directory_store(dir)
  let app = restart.application(runs)
  let assert Ok(run) = fabric.start(runs, one_slow(probe), Nil, "go")
  let running = probe.arrival(probe)
  restart.begin_stop(app)
  restart.draining(runs)
  probe.release(running)
  restart.stopped(app)

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, one_slow(probe), Nil, fabric.id(run))
  fabric.await(run, 0) |> should.equal(Ok(run.Unattended))
  states(run) |> should.equal([run.Succeeded("\"a\"")])
  turns_used(run) |> should.equal(1)

  let assert Ok(run) =
    fabric.recover(runs, one_slow(probe), Nil, fabric.id(run))
  fabric.await(run, 5000)
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
  let assert Ok(runs) = store.with_drain(directory_store(dir), 50)
  let app = restart.application(runs)
  let assert Ok(run) = fabric.start(runs, one_slow(probe), Nil, "go")
  let _ = probe.arrival(probe)
  restart.stop(app)

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, one_slow(probe), Nil, fabric.id(run))
  fabric.await(run, 0) |> should.equal(Ok(run.Unattended))
  states(run) |> should.equal([run.Running])
  let assert Ok(run) =
    fabric.recover(runs, one_slow(probe), Nil, fabric.id(run))
  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(run, 5000)
  let assert Ok(_) = fabric.reconcile(run, uncertain.reference, "\"a\"")
  fabric.await(run, 5000)
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
  let runs = directory_store(dir)
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("a", "a"), scripted.slow("b", "b")]),
      [scripted.gated_tool(probe)],
      reviewed,
    )
    |> agent.with_limits(
      agent.Limits(..agent.default_limits(), max_concurrency: 1),
    )
    |> support.agent
  let app = restart.application(runs)
  let assert Ok(run) = fabric.start(runs, agent, Nil, "go")
  let assert Ok(run.Suspended([first, second], [])) = fabric.await(run, 5000)
  let assert Ok(_) =
    fabric.approve(run, first.reference, reviewer: Some("alice"), context: Nil)
  let running = probe.arrival(probe)
  let assert Ok(_) =
    fabric.approve(run, second.reference, reviewer: Some("alice"), context: Nil)
  states(run) |> should.equal([run.Running, run.Queued])
  restart.begin_stop(app)
  restart.draining(runs)
  probe.release(running)
  restart.stopped(app)

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, agent, Nil, fabric.id(run))
  let assert Ok(run.Suspended([renewed], [])) = fabric.await(run, 0)
  renewed.reference.id |> should.equal(second.reference.id)
  { renewed.reference.revision > second.reference.revision } |> should.be_true
  fabric.approve(run, second.reference, reviewer: Some("alice"), context: Nil)
  |> should.equal(Error(fabric.StaleReference))
  let assert Ok(_) =
    fabric.approve(run, renewed.reference, reviewer: Some("bob"), context: Nil)
  probe.release(probe.arrival(probe))
  fabric.await(run, 5000)
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
  let runs = directory_store(dir)
  let slow_model =
    model.new(fn(request: model.Request) {
      case scripted.results(request.messages) {
        [] -> {
          probe.gate(probe, "model")
          Ok(model.ToolRequest(
            "",
            [scripted.slow("a", "a")],
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
  let assert Ok(run) = fabric.start(runs, agent, Nil, "go")
  let calling = probe.arrival(probe)
  restart.begin_stop(app)
  restart.draining(runs)
  probe.release(calling)
  restart.stopped(app)

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, agent, Nil, fabric.id(run))
  fabric.await(run, 0) |> should.equal(Ok(run.Unattended))
  states(run) |> should.equal([run.Queued])
  turns_used(run) |> should.equal(1)
  let assert Ok(run) = fabric.recover(runs, agent, Nil, fabric.id(run))
  probe.release(probe.arrival(probe))
  fabric.await(run, 5000)
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
  let runs = directory_store(dir)
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("a", "a")]),
      [scripted.gated_tool(probe)],
      reviewed,
    )
    |> support.agent
  let app = restart.application(runs)
  let assert Ok(run) = fabric.start(runs, agent, Nil, "go")
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)
  let assert Ok(before) = fabric.snapshot(run)
  restart.stop(app)

  let app = restart.application(runs)
  let assert Ok(run) = fabric.open(runs, agent, Nil, fabric.id(run))
  fabric.snapshot(run) |> should.equal(Ok(before))
  let assert Ok(_) =
    fabric.approve(
      run,
      pending.reference,
      reviewer: Some("alice"),
      context: Nil,
    )
  probe.release(probe.arrival(probe))
  fabric.await(run, 5000)
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
  let runs = directory_store(dir)
  let app = restart.application(runs)
  let assert Ok(run) = fabric.start(runs, one_slow(probe), Nil, "go")
  let running = probe.arrival(probe)
  let assert Ok(store_process) = store.pid(runs)
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

//// A named store under a supervisor: it outlives the processes that use
//// it, and a restart leaves every run with work in flight unattended until
//// it is recovered.

import fabric
import fabric/agent.{type Agent}
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/probe.{type Probe}
import fabric/support/restart
import fabric/support/scripted
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/time/duration
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

fn supervise(runs: store.Store) -> Nil {
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(store.supervised(runs))
    |> static_supervisor.start
  Nil
}

/// Waits until the store registered under `name` is a process other than
/// `old`.
fn restarted(name: process.Name(store.Message), old: Pid, tries: Int) -> Pid {
  case process.named(name) {
    Ok(pid) if pid != old -> pid
    _ if tries > 0 -> {
      process.sleep(1)
      restarted(name, old, tries - 1)
    }
    _ -> panic as "the supervisor did not restart the store"
  }
}

/// A request process starts a run and exits; the supervised store, not the
/// request process, owns the run's runner, so the run is intact and
/// finishes.
pub fn a_request_process_that_exits_leaves_its_run_intact_test() {
  let probe = probe.new()
  let runs = store.in_memory(process.new_name("requests"))
  supervise(runs)
  let handed = process.new_subject()
  let request =
    process.spawn_unlinked(fn() {
      let assert Ok(run) =
        fabric.start(
          runs,
          one_slow(probe),
          id: run.new_id(),
          context: Nil,
          prompt: "go",
          correlation: None,
        )
      process.send(handed, fabric.id(run))
    })
  let assert Ok(id) = process.receive(handed, 5000)
  restart.gone(request)

  let arrival = probe.arrival(probe)
  let assert Ok(run) = fabric.recover(runs, one_slow(probe), Nil, id)
  fabric.await(run, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Working))
  probe.release(arrival)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  probe.count(probe, "start:a") |> should.equal(1)
}

/// A supervised restart of the store stops its runners and forgets them:
/// the run's work in flight is unattended until `recover` takes it over,
/// which resumes it.
pub fn a_restarted_store_leaves_its_runs_unattended_until_recovered_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let name = process.new_name("restarting")
  let runs = store.directory(name, dir)
  supervise(runs)
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
  let assert Ok(runner) = restart.runner(runs, fabric.id(run))

  let assert Ok(old) = process.named(name)
  process.kill(old)
  let _ = restarted(name, old, 5000)
  restart.gone(runner)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Unattended))

  let assert Ok(run) =
    fabric.recover(runs, one_slow(probe), Nil, fabric.id(run))
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let assert Ok(_) = fabric.reconcile(run, uncertain.reference, "\"a\"")
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  probe.count(probe, "start:a") |> should.equal(1)

  // The restarted subtree runs new runners.
  let assert Ok(next) =
    fabric.start(
      runs,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "again",
      correlation: None,
    )
  probe.release(probe.arrival(probe))
  fabric.await(next, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  restart.remove_dir(dir)
}

/// An `await` in progress when the supervisor restarts the store waits for
/// the new process and goes on through it: the run's work in flight, which
/// the new process knows no runner for, reads `Unattended`.
pub fn an_await_follows_a_restarted_store_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let name = process.new_name("awaited")
  let runs = store.directory(name, dir)
  supervise(runs)
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

  let assert Ok(old) = process.named(name)
  let awaiter = process.self()
  process.spawn(fn() {
    blocked(awaiter, old)
    process.kill(old)
  })
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Unattended))
  restart.remove_dir(dir)
}

/// Waits until `awaiter` monitors the store process `store` and is blocked
/// in a receive.
fn blocked(awaiter: Pid, store: Pid) -> Nil {
  case restart.waits_on(awaiter, store) {
    True -> Nil
    False -> {
      process.sleep(1)
      blocked(awaiter, store)
    }
  }
}

/// A runner of a store process that stopped never commits through the
/// process a supervisor started in its place: here its tool's result is
/// queued before the stop is, and the runner takes it only after the
/// restart. Its commit fails, as the stopped process's would, so the run
/// keeps its running action and reads `Unattended` until recovered.
pub fn a_runner_never_commits_through_a_restarted_store_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let name = process.new_name("pinned")
  let runs = store.directory(name, dir)
  supervise(runs)
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
  let assert Ok(runner) = restart.runner(runs, fabric.id(run))

  restart.suspend(runner)
  probe.release(running)
  reported(runner)
  let assert Ok(old) = process.named(name)
  process.kill(old)
  let _ = restarted(name, old, 5000)
  restart.resume(runner)
  restart.gone(runner)

  fabric.await(run, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Unattended))
  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.actions
  |> list.map(fn(action) { action.state })
  |> should.equal([run.Running])
  restart.remove_dir(dir)
}

/// Waits until the tool's result waits in `runner`'s mailbox.
fn reported(runner: Pid) -> Nil {
  case restart.queued(runner) > 0 {
    True -> Nil
    False -> {
      process.sleep(1)
      reported(runner)
    }
  }
}

/// Two `Store` values built from one name, one given to the supervisor and
/// one for requests, reach the same store process and runner factory: a
/// run started through the second gets a runner and finishes.
pub fn two_store_values_of_one_name_share_the_runners_test() {
  let probe = probe.new()
  let name = process.new_name("shared")
  let supervised = store.in_memory(name)
  let requests = store.in_memory(name)
  supervise(supervised)
  let assert Ok(run) =
    fabric.start(
      requests,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  fabric.await(run, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Working))
  let assert Ok(_) = restart.runner(requests, fabric.id(run))
  probe.release(running)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
}

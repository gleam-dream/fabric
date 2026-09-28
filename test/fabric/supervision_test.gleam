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
import gleam/otp/static_supervisor
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
      let assert Ok(run) = fabric.start(runs, one_slow(probe), Nil, "go")
      process.send(handed, fabric.id(run))
    })
  let assert Ok(id) = process.receive(handed, 5000)
  restart.gone(request)

  let arrival = probe.arrival(probe)
  let assert Ok(run) = fabric.recover(runs, one_slow(probe), Nil, id)
  fabric.await(run, 0) |> should.equal(Ok(run.Working))
  probe.release(arrival)
  fabric.await(run, 5000)
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
  let assert Ok(run) = fabric.start(runs, one_slow(probe), Nil, "go")
  let _ = probe.arrival(probe)
  let assert Ok(runner) = restart.runner(runs, fabric.id(run))

  let assert Ok(old) = process.named(name)
  process.kill(old)
  let _ = restarted(name, old, 5000)
  restart.gone(runner)
  fabric.await(run, 5000) |> should.equal(Ok(run.Unattended))

  let assert Ok(run) =
    fabric.recover(runs, one_slow(probe), Nil, fabric.id(run))
  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(run, 5000)
  let assert Ok(_) = fabric.reconcile(run, uncertain.reference, "\"a\"")
  fabric.await(run, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  probe.count(probe, "start:a") |> should.equal(1)
  restart.remove_dir(dir)
}

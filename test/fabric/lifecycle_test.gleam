//// Lifecycle: a run cancelled when its owner stops, a store stopped by the
//// caller that started it, and a sweeper supervised with its store.

import fabric
import fabric/agent
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/backend
import fabric/store/conformance
import fabric/support
import fabric/support/probe
import fabric/support/scripted
import fabric/sweeper
import gleam/erlang/process
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/time/duration
import gleeunit/should

fn waiting_agent(gate: probe.Probe) -> agent.Agent(Nil, String) {
  agent.new(
    "lifecycle",
    scripted.plan([scripted.slow("c1", "held")]),
    [scripted.gated_tool(gate)],
    policy.always_allow(),
  )
  |> support.agent
}

fn finishing_agent() -> agent.Agent(Nil, String) {
  agent.new(
    "lifecycle",
    scripted.model(fn(_) { model.FinalAnswer("done", None) }),
    [],
    policy.always_allow(),
  )
  |> support.agent
}

pub fn a_run_is_cancelled_when_its_owner_stops_test() {
  let runs = support.store()
  let gate = probe.new()
  let assert Ok(handle) =
    fabric.start(
      runs,
      waiting_agent(gate),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let held = probe.arrival(gate)
  let owner = process.spawn_unlinked(fn() { process.sleep_forever() })
  fabric.cancel_when_down(handle, owner:)
  fabric.await(handle, within: duration.milliseconds(50))
  |> should.equal(Ok(run.Working))
  process.kill(owner)
  let assert Ok(run.Finished(run.Cancelled)) =
    fabric.await(handle, within: duration.seconds(5))
  probe.release(held)
}

pub fn an_owner_that_already_stopped_cancels_at_once_test() {
  let runs = support.store()
  let gate = probe.new()
  let assert Ok(handle) =
    fabric.start(
      runs,
      waiting_agent(gate),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let held = probe.arrival(gate)
  let owner = process.spawn_unlinked(fn() { Nil })
  let monitor = process.monitor(owner)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  fabric.cancel_when_down(handle, owner:)
  let assert Ok(run.Finished(run.Cancelled)) =
    fabric.await(handle, within: duration.seconds(5))
  probe.release(held)
}

pub fn a_finished_run_is_left_alone_when_its_owner_stops_test() {
  let runs = support.store()
  let assert Ok(handle) =
    fabric.start(
      runs,
      finishing_agent(),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Completed(answer))) =
    fabric.await(handle, within: duration.seconds(5))
  let owner = process.spawn_unlinked(fn() { process.sleep_forever() })
  fabric.cancel_when_down(handle, owner:)
  process.kill(owner)
  process.sleep(50)
  fabric.await(handle, within: duration.seconds(1))
  |> should.equal(Ok(run.Finished(run.Completed(answer))))
}

pub fn a_started_store_stops_and_can_start_again_test() {
  let runs = store.in_memory(process.new_name("lifecycle-stop"))
  store.stop(runs) |> should.equal(Ok(Nil))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(_) = store.readiness(runs)
  store.stop(runs) |> should.equal(Ok(Nil))
  let assert Error(backend.Unavailable(_)) = store.readiness(runs)
  store.stop(runs) |> should.equal(Ok(Nil))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(_) = store.readiness(runs)
  store.stop(runs) |> should.equal(Ok(Nil))
}

pub fn a_supervised_store_is_stopped_by_its_supervisor_test() {
  let runs = store.in_memory(process.new_name("lifecycle-supervised"))
  let assert Ok(started) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(store.supervised(runs))
    |> static_supervisor.start
  let assert Error(backend.Unavailable(_)) = store.stop(runs)
  let assert Ok(_) = store.readiness(runs)
  process.unlink(started.pid)
  process.send_exit(started.pid)
}

fn leased(name: String) -> store.Store {
  let assert Ok(runs) =
    store.leased(
      process.new_name(name),
      node: "lifecycle",
      lease: duration.seconds(5),
      backend: conformance.leased_memory().backend,
    )
  runs
}

pub fn the_sweeper_is_supervised_with_its_store_test() {
  let runs = leased("lifecycle-sweeper")
  let assert Ok(subtree) =
    sweeper.supervised(
      runs,
      [sweeper.agent(finishing_agent(), context: fn(_) { Nil })],
      every: duration.milliseconds(50),
    )
  let assert Ok(started) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(subtree)
    |> static_supervisor.start
  let assert Ok(_) = store.readiness(runs)
  let assert Ok(handle) =
    fabric.start(
      runs,
      finishing_agent(),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(handle, within: duration.seconds(5))
  process.unlink(started.pid)
  process.send_exit(started.pid)
}

pub fn a_sweeper_needs_a_running_leased_store_test() {
  let runs = leased("lifecycle-no-store")
  sweeper.start(runs, [], every: duration.milliseconds(50))
  |> should.equal(Error([sweeper.StoreNotRunning]))
  sweeper.supervised(support.store(), [], every: duration.milliseconds(50))
  |> should.equal(Error([sweeper.StoreNotLeased]))
  sweeper.describe_error(sweeper.StoreNotRunning)
  |> should.equal("the sweeper's store is not running")
}

/// A sweeper started outside a supervisor stops with the process that
/// started it, also when that process ends normally, so it cannot outlive
/// a script or a test and keep scanning.
pub fn a_started_sweeper_stops_with_its_caller_test() {
  let runs = leased("lifecycle-sweeper-caller")
  let assert Ok(Nil) = store.start(runs)
  let reply = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      let assert Ok(started) =
        sweeper.start(runs, [], every: duration.milliseconds(50))
      process.unlink(started)
      process.send(reply, started)
    })
  let assert Ok(started) = process.receive(reply, 30_000)
  let monitor = process.monitor(started)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(30_000)
  |> should.equal(Ok(Nil))
  process.is_alive(caller) |> should.be_false
}

//// Several nodes sharing one database, simulated by leased stores of
//// distinct node ids over one in-memory leased backend: a run's lease
//// says which node drives it, a live lease elsewhere reads `Working` and
//// is never taken, a command on an idle run works from any node, and a
//// runner commits only while its store holds the lease.

import fabric
import fabric/agent.{type Agent}
import fabric/internal/store as store_core
import fabric/model
import fabric/policy
import fabric/run.{Requirement}
import fabric/store
import fabric/store/backend
import fabric/store/conformance
import fabric/support
import fabric/support/nodes
import fabric/support/probe.{type Probe}
import fabric/support/restart
import fabric/support/scripted
import fabric/telemetry as o
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import sinal
import sinal/correlation

fn one_slow(probe: Probe) -> Agent(Nil) {
  agent.new(
    "agent",
    scripted.plan([scripted.slow("a", "a")]),
    [scripted.gated_tool(probe)],
    policy.always_allow(),
  )
  |> support.agent
}

/// Every call of the gated tool whose input is `b` needs an approval.
fn b_reviewed(
  _context: Nil,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  case string.contains(action.arguments_json, "\"b\"") {
    True -> Ok(policy.RequireApproval(Requirement("review", 1)))
    False -> Ok(policy.Allow)
  }
}

fn states(run: fabric.Run(context)) -> List(run.ActionState) {
  let assert Ok(snapshot) = fabric.snapshot(run)
  list.map(snapshot.actions, fn(action) { action.state })
}

pub fn a_leased_store_checks_its_settings_test() {
  let backend = conformance.leased_memory().backend
  let name = process.new_name("settings")
  let leased = fn(node, lease) {
    store.leased(name, node:, lease: duration.milliseconds(lease), backend:)
    |> result_error
  }
  leased("", 1000) |> should.equal(Error(store.InvalidNodeId("")))
  leased("a/b", 1000) |> should.equal(Error(store.InvalidNodeId("a/b")))
  leased("nonode@nohost", 1000)
  |> should.equal(Error(store.InvalidNodeId("nonode@nohost")))
  leased(string.repeat("n", 129), 1000)
  |> should.equal(Error(store.InvalidNodeId(string.repeat("n", 129))))
  leased("app@host-1.example:9", 99)
  |> should.equal(
    Error(store.LeaseTooShort(
      duration.milliseconds(99),
      duration.milliseconds(100),
    )),
  )
  leased("app@host-1.example:9", 4_294_967_296)
  |> should.equal(
    Error(store.LeaseTooLong(
      duration.milliseconds(4_294_967_296),
      duration.milliseconds(4_294_967_295),
    )),
  )
  leased("app@host-1.example:9", 100) |> should.equal(Ok(Nil))
  leased("app@host-1.example:9", 4_294_967_295) |> should.equal(Ok(Nil))
}

fn result_error(
  result: Result(a, store.LeaseConfigError),
) -> Result(Nil, store.LeaseConfigError) {
  case result {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

/// A run's lease is claimed with the work its runner is given, held while
/// the runner works, and released when nothing is left in flight.
pub fn a_runner_holds_its_runs_lease_while_it_works_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  nodes.holding(memory.backend, fabric.id(run))
  |> should.equal(Ok(#("a", True)))
  probe.release(running)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  nodes.holding(memory.backend, fabric.id(run)) |> should.equal(Error(Nil))
}

/// Another node sees a run whose lease is live as `Working`, although it
/// knows no runner of it.
pub fn a_live_lease_elsewhere_reads_working_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  let assert Ok(seen) = fabric.open(b, one_slow(probe), Nil, fabric.id(run))
  fabric.await(seen, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Working))
  let assert Ok(snapshot) = fabric.snapshot(seen)
  snapshot.status |> should.equal(run.Working)
  probe.release(running)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
}

/// `recover` on another node leaves a run whose lease is live exactly as
/// it is: its runner keeps working and nothing becomes uncertain.
pub fn recover_does_not_take_a_live_lease_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  let assert Ok(before) = fabric.snapshot(run)
  let revision = nodes.revision(memory.backend, fabric.id(run))
  let assert Ok(recovered) =
    fabric.recover(b, one_slow(probe), Nil, fabric.id(run))
  fabric.snapshot(run) |> should.equal(Ok(before))
  nodes.revision(memory.backend, fabric.id(run)) |> should.equal(revision)
  nodes.holding(memory.backend, fabric.id(run))
  |> should.equal(Ok(#("a", True)))
  fabric.await(recovered, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Working))
  probe.release(running)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  probe.count(probe, "start:a") |> should.equal(1)
}

/// An approval of an idle run works from any node: the node that commits
/// it claims the lease and runs the approved tool.
pub fn an_approval_of_an_idle_run_on_another_node_claims_the_lease_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("b", "b")]),
      [scripted.gated_tool(probe)],
      b_reviewed,
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      a,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  nodes.holding(memory.backend, fabric.id(run)) |> should.equal(Error(Nil))
  let assert Ok(there) = fabric.open(b, agent, Nil, fabric.id(run))
  let assert Ok(run.Working) =
    fabric.approve(there, pending.reference, reviewer: None, context: Nil)
  let running = probe.arrival(probe)
  nodes.holding(memory.backend, fabric.id(run))
  |> should.equal(Ok(#("b", True)))
  let assert Ok(_) = restart.runner(b, fabric.id(run))
  restart.runner(a, fabric.id(run)) |> should.equal(Error(Nil))
  probe.release(running)
  fabric.await(there, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"b\""))))
}

/// An approval that needs the runner another node holds the lease for is
/// `RunUnattended` and changes nothing; through that node it works.
pub fn an_approval_needing_another_nodes_runner_is_unattended_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("a", "a"), scripted.slow("b", "b")]),
      [scripted.gated_tool(probe)],
      b_reviewed,
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      a,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  let assert Ok([pending]) = fabric.pending(run)
  let assert Ok(before) = fabric.snapshot(run)
  let assert Ok(there) = fabric.open(b, agent, Nil, fabric.id(run))
  fabric.approve(there, pending.reference, reviewer: None, context: Nil)
  |> should.equal(Error(fabric.RunUnattended))
  fabric.snapshot(run) |> should.equal(Ok(before))
  let assert Ok(run.Working) =
    fabric.approve(run, pending.reference, reviewer: None, context: Nil)
  let second = probe.arrival(probe)
  probe.release(running)
  probe.release(second)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\" | \"b\""))))
}

/// A cancellation from another node wins over the live lease: it is
/// committed at once and the running tool becomes an uncertain effect. The
/// old owner learns of it at its next renewal and kills its runner, with
/// the tool's body, which never finishes.
pub fn a_cancellation_from_another_node_wins_over_a_live_lease_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let events = capture()
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  let body = body(running)
  let assert Ok(runner) = restart.runner(a, fabric.id(run))
  let assert Ok(there) = fabric.open(b, one_slow(probe), Nil, fabric.id(run))
  fabric.cancel(there)
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  nodes.holding(memory.backend, fabric.id(run)) |> should.equal(Error(Nil))
  let assert [run.Uncertain(_)] = states(there)
  store_core.renew_now(a)
  restart.gone(runner)
  restart.gone(body)
  probe.count(probe, "end:a") |> should.equal(0)
  lines(events, 1)
  |> should.equal([
    "lease_lost " <> support.text(fabric.id(run)) <> " a revoked",
  ])
  release(events)
}

/// `lease_lost` names the run's family root and carries its correlation.
pub fn a_lost_lease_event_carries_the_runs_root_and_correlation_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let lost = process.new_subject()
  let attachment =
    sinal.observe(o.lease_lost(), fn(_, metadata) {
      process.send(lost, metadata)
    })
  let ticket = correlation.from_key("ticket-lease")
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: Some(ticket),
    )
  let _ = probe.arrival(probe)
  let assert Ok(there) = fabric.open(b, one_slow(probe), Nil, fabric.id(run))
  let assert Ok(_) = fabric.cancel(there)
  store_core.renew_now(a)
  let assert Ok(event) = process.receive(lost, 5000)
  let _ = sinal.detach(attachment)
  event.run |> should.equal(support.text(fabric.id(run)))
  event.root |> should.equal(support.text(fabric.id(run)))
  event.correlation |> should.equal(ticket)
}

/// A run whose lease expired is taken over by a recovery on another node.
/// The old owner's next renewal no longer returns it, so the old runner is
/// killed with the body it was running: the tool is an uncertain effect of
/// the new incarnation, never run again.
pub fn a_lost_lease_kills_the_runner_and_its_running_body_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let events = capture()
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  let body = body(running)
  let assert Ok(runner) = restart.runner(a, fabric.id(run))
  memory.advance(nodes.long + 1)
  let assert Ok(there) = fabric.recover(b, one_slow(probe), Nil, fabric.id(run))
  // The new incarnation has nothing in flight: it waits for the uncertain
  // effect to be reconciled, and the lease is free.
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(there, within: duration.milliseconds(0))
  nodes.holding(memory.backend, fabric.id(run)) |> should.equal(Error(Nil))
  store_core.renew_now(a)
  restart.gone(runner)
  restart.gone(body)
  let id = support.text(fabric.id(run))
  lines(events, 2)
  |> should.equal([
    "run_taken_over " <> id <> " 2 a",
    "lease_lost " <> id <> " a revoked",
  ])
  release(events)
  let assert Ok(_) = fabric.reconcile(there, uncertain.reference, "\"a\"")
  fabric.await(there, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  probe.count(probe, "start:a") |> should.equal(1)
  probe.count(probe, "end:a") |> should.equal(0)
}

/// A store whose renewals fail (the backend is unreachable) kills its
/// runners, with their tool bodies, before their leases could have
/// expired: by the backend's clock, the lease is still live when the body
/// is gone.
pub fn a_store_that_cannot_renew_kills_its_runners_before_their_leases_expire_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let unreachable =
    backend.LeasedBackend(..memory.backend, renew: fn(_, _, _) {
      Error(backend.Unavailable("the backend is unreachable"))
    })
  let a = nodes.node(unreachable, "a", 1000)
  let events = capture()
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let body = body(probe.arrival(probe))
  let assert Ok(runner) = restart.runner(a, fabric.id(run))
  restart.gone(body)
  nodes.holding(memory.backend, fabric.id(run))
  |> should.equal(Ok(#("a", True)))
  restart.gone(runner)
  let id = support.text(fabric.id(run))
  let #(before, lost) = until(events, "lease_lost")
  lost |> should.equal("lease_lost " <> id <> " a unrenewed")
  { before != [] && list.all(before, fn(line) { line == "renewal_failed 1" }) }
  |> should.be_true
  release(events)
  probe.count(probe, "end:a") |> should.equal(0)
}

/// A lease event's handler runs outside the store's process: one that
/// blocks on a failed renewal holds up no read or commit through the store.
pub fn a_slow_lease_event_handler_does_not_hold_up_the_store_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let unreachable =
    backend.LeasedBackend(..memory.backend, renew: fn(_, _, _) {
      Error(backend.Unavailable("the backend is unreachable"))
    })
  let a = nodes.node(unreachable, "a", 1000)
  let entered = process.new_subject()
  let attachment =
    sinal.observe(o.renewal_failed(), fn(_, _failed) {
      process.send(entered, Nil)
      process.sleep(2000)
    })
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let _ = probe.arrival(probe)
  let assert Ok(Nil) = process.receive(entered, 5000)
  let read = process.new_subject()
  process.spawn(fn() { process.send(read, fabric.snapshot(run)) })
  let assert Ok(Ok(_)) = process.receive(read, 500)
  let _ = sinal.detach(attachment)
  Nil
}

/// A tick that comes while a renewal is still in flight is made up as
/// soon as that renewal completes, not a third of a lease later: a slow
/// renewal never leaves the next one to start after the fence.
pub fn a_tick_during_a_renewal_is_made_up_when_it_completes_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let calls = process.new_subject()
  let slow =
    backend.LeasedBackend(..memory.backend, renew: fn(owner, runs, ttl) {
      let release = process.new_subject()
      process.send(calls, release)
      let _ = process.receive(release, 1000)
      memory.backend.renew(owner, runs, ttl)
    })
  // Ticks every 500 ms; a renewal may take up to 500 ms.
  let a = nodes.node(slow, "a", 1500)
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  // A tick's renewal, at once.
  let assert Ok(first) = process.receive(calls, 2000)
  process.send(first, Nil)
  // Another, sent between ticks, still in flight at the next tick.
  process.sleep(300)
  store_core.renew_now(a)
  let assert Ok(second) = process.receive(calls, 1000)
  process.sleep(300)
  process.send(second, Nil)
  let assert Ok(third) = process.receive(calls, 150)
  process.send(third, Nil)
  probe.release(running)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
}

/// A healthy store renews its runners' leases in time: a tool that runs
/// through several lease durations keeps its lease and finishes.
pub fn renewals_keep_a_lease_live_past_its_duration_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let renewals = process.new_subject()
  let counted =
    backend.LeasedBackend(..memory.backend, renew: fn(owner, runs, ttl) {
      let renewed = memory.backend.renew(owner, runs, ttl)
      process.send(renewals, renewed)
      renewed
    })
  let a = nodes.node(counted, "a", 150)
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  let id = support.text(fabric.id(run))
  // Ten renewals take over three lease durations.
  list.each(list.repeat(Nil, 10), fn(_) {
    process.receive(renewals, 5000) |> should.equal(Ok(Ok([id])))
  })
  nodes.holding(memory.backend, fabric.id(run))
  |> should.equal(Ok(#("a", True)))
  probe.release(running)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
}

/// Several nodes that recover a run at once whose owner is gone and whose
/// lease expired take it over exactly once: one new incarnation, and the
/// running tool is one uncertain effect. While the lease was live, none
/// took it.
pub fn an_expired_lease_is_taken_over_once_by_racing_recoveries_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let #(owner, a) =
    restart.owned(fn() { nodes.node(memory.backend, "a", nodes.long) })
  let events = capture()
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let _ = probe.arrival(probe)
  let assert Ok(before) = fabric.snapshot(run)
  // The node stops: its store and runner are gone, its lease is not.
  restart.crash(owner, a)
  let others =
    list.index_map(list.repeat(Nil, 8), fn(_, i) {
      nodes.node(memory.backend, "b" <> int.to_string(i), nodes.long)
    })
  let recover_all = fn() {
    together(others, fn(node) {
      let assert Ok(there) =
        fabric.recover(node, one_slow(probe), Nil, fabric.id(run))
      fabric.await(there, within: duration.milliseconds(0))
    })
  }
  recover_all() |> list.unique |> should.equal([Ok(run.Working)])
  let assert [first, ..] = others
  let assert Ok(seen) = fabric.open(first, one_slow(probe), Nil, fabric.id(run))
  let assert Ok(snapshot) = fabric.snapshot(seen)
  snapshot.incarnation |> should.equal(before.incarnation)

  memory.advance(nodes.long + 1)
  let statuses = recover_all()
  let assert [Ok(run.Suspended([], [_]))] = list.unique(statuses)
  let assert Ok(snapshot) = fabric.snapshot(seen)
  snapshot.incarnation |> should.equal(before.incarnation + 1)
  let id = support.text(fabric.id(run))
  let assert [taken] = lines(events, 1)
  string.starts_with(taken, "run_taken_over " <> id <> " ") |> should.be_true
  process.receive(events.lines, 0) |> should.equal(Error(Nil))
  release(events)
  probe.count(probe, "start:a") |> should.equal(1)
}

/// A store restarted on the same node under the same name takes over the
/// lease of its earlier process at once, without waiting for it to
/// expire: that process is gone. Another node still sees the lease live
/// until then.
pub fn a_restarted_store_takes_its_earlier_processes_lease_at_once_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let name = process.new_name("restarting")
  let leased = fn() {
    let assert Ok(leased) =
      store.leased(
        name,
        node: "a",
        lease: duration.milliseconds(nodes.long),
        backend: memory.backend,
      )
    leased
  }
  let #(owner, a) = restart.owned(fn() { support.started(leased()) })
  let b = nodes.node(memory.backend, "b", nodes.long)
  let events = capture()
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let _ = probe.arrival(probe)
  restart.crash(owner, a)
  let assert Ok(there) = fabric.recover(b, one_slow(probe), Nil, fabric.id(run))
  fabric.await(there, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Working))

  let again = support.started(leased())
  let assert Ok(reopened) =
    fabric.open(again, one_slow(probe), Nil, fabric.id(run))
  fabric.await(reopened, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Unattended))
  let assert Ok(recovered) =
    fabric.recover(again, one_slow(probe), Nil, fabric.id(run))
  let assert Ok(run.Suspended([], [_])) =
    fabric.await(recovered, within: duration.milliseconds(0))
  let id = support.text(fabric.id(run))
  lines(events, 1) |> should.equal(["run_taken_over " <> id <> " 2 a"])
  release(events)
}

/// An `await` on another node sees the run's end, although the commits
/// that end it are made through the node that drives it: it reads the run
/// again at least every third of the lease.
pub fn an_await_on_another_node_sees_the_end_of_the_run_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let a = nodes.node(memory.backend, "a", 300)
  let b = nodes.node(memory.backend, "b", 300)
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  let assert Ok(seen) = fabric.open(b, one_slow(probe), Nil, fabric.id(run))
  let awaited = process.new_subject()
  process.spawn(fn() {
    process.send(
      awaited,
      fabric.await(seen, within: duration.milliseconds(60_000)),
    )
  })
  probe.release(running)
  process.receive(awaited, 5000)
  |> should.equal(Ok(Ok(run.Finished(run.Completed("final: \"a\"")))))
}

/// A node that stops drains its runners, and each handoff releases the
/// run's lease as already expired: another node reads the run
/// `Unattended` and recovers it at once, with nothing uncertain.
pub fn a_handoff_releases_the_lease_as_already_expired_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let assert Ok(a) =
    store.leased(
      process.new_name("draining"),
      node: "a",
      lease: duration.milliseconds(nodes.long),
      backend: memory.backend,
    )
  let app = restart.application(a)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  restart.begin_stop(app)
  restart.draining(a)
  probe.release(running)
  restart.stopped(app)

  nodes.holding(memory.backend, fabric.id(run))
  |> should.equal(Ok(#("a", False)))
  let assert Ok(there) = fabric.open(b, one_slow(probe), Nil, fabric.id(run))
  fabric.await(there, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Unattended))
  let assert Ok(there) = fabric.recover(b, one_slow(probe), Nil, fabric.id(run))
  fabric.await(there, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  probe.count(probe, "start:a") |> should.equal(1)
}

/// A start committed while the store drains has no runner and an expired
/// lease. Another node can recover it at once, before the first store stops.
pub fn a_start_committed_during_drain_is_recovered_on_another_node_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let assert Ok(a) =
    store.leased(
      process.new_name("draining"),
      node: "a",
      lease: duration.milliseconds(nodes.long),
      backend: memory.backend,
    )
  let app = restart.application(a)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let assert Ok(_) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "hold the drain",
      correlation: None,
    )
  let running = probe.arrival(probe)
  restart.begin_stop(app)
  restart.draining(a)

  let next =
    agent.new(
      "next",
      scripted.model(fn(_) { model.FinalAnswer("done", None) }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(started) =
    fabric.start(
      a,
      next,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  nodes.holding(memory.backend, fabric.id(started))
  |> should.equal(Ok(#("a", False)))
  let assert Ok(there) = fabric.open(b, next, Nil, fabric.id(started))
  fabric.await(there, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Unattended))
  let assert Ok(there) = fabric.recover(b, next, Nil, fabric.id(started))
  fabric.await(there, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done"))))

  probe.release(running)
  restart.stopped(app)
}

/// A renewal sent while the runner worked but applied after its handoff
/// does not make the handed-off lease live again: a renewal extends only
/// live leases, so another node still takes the run over at once.
pub fn a_renewal_applied_after_the_handoff_leaves_the_lease_expired_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let relay = relay()
  let renewing = process.new_subject()
  let backend =
    backend.LeasedBackend(
      ..memory.backend,
      renew: fn(owner, runs, ttl) {
        // Held until the handoff has been committed.
        let go = process.new_subject()
        process.send(renewing, Nil)
        process.send(relay, Pending(go))
        let applied = process.receive_forever(go)
        let renewed = memory.backend.renew(owner, runs, ttl)
        process.send(applied, Nil)
        renewed
      },
      compare_and_set: fn(run, expected, record, lease) {
        let outcome =
          memory.backend.compare_and_set(run, expected, record, lease)
        case lease {
          backend.Claim(_, 0) -> {
            let applied = process.new_subject()
            process.send(relay, HandedOff(applied))
            let _ = process.receive(applied, 5000)
            Nil
          }
          _ -> Nil
        }
        outcome
      },
    )
  let assert Ok(a) =
    store.leased(
      process.new_name("renewing"),
      node: "a",
      lease: duration.milliseconds(nodes.long),
      backend:,
    )
  let app = restart.application(a)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let running = probe.arrival(probe)
  store_core.renew_now(a)
  let assert Ok(Nil) = process.receive(renewing, 5000)
  restart.begin_stop(app)
  restart.draining(a)
  probe.release(running)
  restart.stopped(app)

  nodes.holding(memory.backend, fabric.id(run))
  |> should.equal(Ok(#("a", False)))
  let assert Ok(there) = fabric.recover(b, one_slow(probe), Nil, fabric.id(run))
  fabric.await(there, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  probe.count(probe, "start:a") |> should.equal(1)
}

type Relay {
  /// A renewal waits for the subject to confirm its application on.
  Pending(go: process.Subject(process.Subject(Nil)))
  /// A handoff was committed: release the pending renewal, if any, and
  /// confirm once it was applied.
  HandedOff(applied: process.Subject(Nil))
}

/// Orders a pending renewal after a handoff's commit.
fn relay() -> process.Subject(Relay) {
  let ready = process.new_subject()
  process.spawn(fn() {
    let relay = process.new_subject()
    process.send(ready, relay)
    relay_loop(relay, None)
  })
  process.receive_forever(ready)
}

fn relay_loop(
  relay: process.Subject(Relay),
  pending: option.Option(process.Subject(process.Subject(Nil))),
) -> Nil {
  case process.receive_forever(relay), pending {
    Pending(go), _ -> relay_loop(relay, option.Some(go))
    HandedOff(applied), option.Some(go) -> {
      process.send(go, applied)
      relay_loop(relay, None)
    }
    HandedOff(applied), None -> {
      process.send(applied, Nil)
      relay_loop(relay, None)
    }
  }
}

/// A runner commits only while its store holds the run's lease: once
/// another owner claimed the expired lease, the runner's next commit, the
/// fence of a tool's start, is refused, and the tool's body never starts.
pub fn a_tool_start_is_refused_once_another_owner_claimed_the_lease_test() {
  let probe = probe.new()
  let memory = conformance.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let replies = process.new_subject()
  // The handler runs in the runner right after the model reply that queues
  // the tool is committed, before the tool starts, and holds it there.
  let attachment =
    sinal.observe(o.model_turn(), fn(_, turn: o.ModelTurn) {
      let go = process.new_subject()
      process.send(replies, #(turn.run, process.self(), go))
      let _ = process.receive(go, 5000)
      Nil
    })
  let assert Ok(run) =
    fabric.start(
      a,
      one_slow(probe),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(#(replied, runner, go)) = process.receive(replies, 5000)
  let _ = sinal.detach(attachment)
  replied |> should.equal(support.text(fabric.id(run)))
  // Meanwhile the lease expires and another owner (a sweeper) claims it.
  memory.advance(nodes.long + 1)
  memory.backend.claim_expired("sweeper", nodes.long, 10)
  |> should.equal(Ok([support.text(fabric.id(run))]))
  process.send(go, Nil)
  restart.gone(runner)
  probe.count(probe, "start:a") |> should.equal(0)
  states(run) |> should.equal([run.Queued])
  nodes.holder(memory.backend, fabric.id(run))
  |> should.equal(backend.Held("sweeper", True))
}

// --- instruments -------------------------------------------------------------------

/// Runs `body` for each of `items` in its own process, all released
/// together, and returns their results in order.
fn together(items: List(a), body: fn(a) -> b) -> List(b) {
  let results = process.new_subject()
  let starts =
    list.index_map(items, fn(item, i) {
      let ready = process.new_subject()
      process.spawn(fn() {
        let start = process.new_subject()
        process.send(ready, start)
        let assert Ok(Nil) = process.receive(start, 5000)
        process.send(results, #(i, body(item)))
      })
      let assert Ok(start) = process.receive(ready, 5000)
      start
    })
  list.each(starts, process.send(_, Nil))
  list.map(starts, fn(_) {
    let assert Ok(result) = process.receive(results, 5000)
    result
  })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.map(fn(entry) { entry.1 })
}

/// The process of a tool body waiting at its barrier.
fn body(arrival: probe.Arrival) -> process.Pid {
  let assert Ok(pid) = process.subject_owner(arrival.release)
  pid
}

type Capture {
  Capture(lines: process.Subject(String), attachments: List(sinal.Attachment))
}

/// Captures the lease events and takeovers, one line each.
fn capture() -> Capture {
  let lines = process.new_subject()
  Capture(lines, [
    attach_line(lines, o.lease_lost(), fn(lost: o.LeaseLost) {
      let assert Ok(#(node, _)) = string.split_once(lost.owner, "/")
      "lease_lost "
      <> lost.run
      <> " "
      <> node
      <> " "
      <> case lost.reason {
        o.Revoked -> "revoked"
        o.Unrenewed -> "unrenewed"
      }
    }),
    attach_line(lines, o.run_taken_over(), fn(taken: o.RunTakenOver) {
      let assert Ok(#(node, _)) = string.split_once(taken.previous_owner, "/")
      "run_taken_over "
      <> taken.run
      <> " "
      <> int.to_string(taken.incarnation)
      <> " "
      <> node
    }),
    attach_line(lines, o.renewal_failed(), fn(failed: o.RenewalFailed) {
      "renewal_failed " <> int.to_string(failed.runs)
    }),
  ])
}

fn attach_line(
  lines: process.Subject(String),
  event: sinal.Event(Nil, d),
  line: fn(d) -> String,
) -> sinal.Attachment {
  sinal.observe(event, fn(_, metadata) { process.send(lines, line(metadata)) })
}

/// The next `count` captured lines.
fn lines(capture: Capture, count: Int) -> List(String) {
  list.map(list.repeat(Nil, count), fn(_) {
    let assert Ok(line) = process.receive(capture.lines, 5000)
    line
  })
}

/// The captured lines up to the first one that starts with `prefix`, and
/// that line.
fn until(capture: Capture, prefix: String) -> #(List(String), String) {
  let assert Ok(line) = process.receive(capture.lines, 5000)
  case string.starts_with(line, prefix) {
    True -> #([], line)
    False -> {
      let #(before, found) = until(capture, prefix)
      #([line, ..before], found)
    }
  }
}

fn release(capture: Capture) -> Nil {
  list.each(capture.attachments, fn(attachment) {
    let _ = sinal.detach(attachment)
    Nil
  })
}

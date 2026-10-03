//// S7 O1–O5: readiness reports current evidence without changing work.

import fabric
import fabric/agent
import fabric/internal/store as store_core
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/backend
import fabric/store/conformance
import fabric/support
import fabric/support/nodes
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import fabric/telemetry
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import sinal

pub fn fresh_idle_stores_are_ready_before_their_first_renewal_test() {
  let runs = support.store()
  store.readiness(runs)
  |> should.equal(Ok(store.Readiness(store.Accepting, 0, store.Unleased)))
  let memory = conformance.leased_memory()
  let leased = nodes.node(memory.backend, "ready", nodes.long)
  store.readiness(leased)
  |> should.equal(
    Ok(store.Readiness(store.Accepting, 0, store.Leased(nodes.long, None))),
  )
}

fn slow(bodies: probe.Probe) -> agent.Agent(Nil) {
  agent.new(
    "readiness",
    scripted.plan([scripted.slow("body", "body")]),
    [scripted.gated_tool(bodies)],
    policy.always_allow(),
  )
  |> support.agent
}

fn renewed(runs: store.Store, remaining: Int) -> Int {
  let assert Ok(report) = store.readiness(runs)
  case report.lease {
    store.Leased(_, Some(age)) -> age
    _ -> {
      should.be_true(remaining > 0)
      process.sleep(1)
      renewed(runs, remaining - 1)
    }
  }
}

pub fn claims_cover_initial_work_and_only_successful_renewals_refresh_age_test() {
  let memory = conformance.leased_memory()
  let bodies = probe.new()
  let failures = probe.new()
  let renewals = probe.new()
  let failed = process.new_subject()
  let attachment =
    sinal.observe(telemetry.renewal_failed(), fn(_, failure) {
      case string.starts_with(failure.owner, "readiness/") {
        True -> process.send(failed, Nil)
        False -> Nil
      }
    })
  let backend =
    backend.LeasedBackend(..memory.backend, renew: fn(owner, runs, ttl) {
      case probe.count(failures, "fail") {
        0 -> {
          probe.gate(renewals, "renewal")
          memory.backend.renew(owner, runs, ttl)
        }
        _ -> Error(backend.Unavailable("renewal offline"))
      }
    })
  let runs = nodes.node(backend, "readiness", nodes.long)
  let assert Ok(handle) =
    fabric.start(
      runs,
      slow(bodies),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let body = probe.arrival(bodies)
  let assert Ok(before) = memory.backend.get(support.text(fabric.id(handle)))
  store.readiness(runs)
  |> should.equal(
    Ok(store.Readiness(store.Accepting, 1, store.Leased(nodes.long, None))),
  )
  memory.backend.get(support.text(fabric.id(handle)))
  |> should.equal(Ok(before))
  store_core.renew_now(runs)
  let renewing = probe.arrival(renewals)
  // Renewal age includes the request's round trip, not just its response.
  process.sleep(20)
  probe.release(renewing)
  let first_age = renewed(runs, 1000)
  should.be_true(first_age >= 20)
  probe.record(failures, "fail")
  store_core.renew_now(runs)
  let assert Ok(Nil) = process.receive(failed, 5000)
  let assert Ok(report) = store.readiness(runs)
  report.status |> should.equal(store.Accepting)
  let assert store.Leased(_, Some(age)) = report.lease
  should.be_true(age >= first_age)
  let _ = sinal.detach(attachment)
  probe.release(body)
  let assert Ok(_) = fabric.await(handle, within: duration.milliseconds(5000))
  let assert Ok(idle) = store.readiness(runs)
  idle.status |> should.equal(store.Accepting)
  idle.runners |> should.equal(0)
}

pub fn a_backend_failure_is_not_a_ready_store_test() {
  let memory = conformance.leased_memory()
  let offline =
    backend.LeasedBackend(..memory.backend, get: fn(_) {
      Error(backend.Unavailable("storage offline"))
    })
  store.readiness(nodes.node(offline, "offline", nodes.long))
  |> should.equal(Error(backend.Unavailable("storage offline")))
  let crashed =
    backend.LeasedBackend(..memory.backend, get: fn(_) {
      panic as "storage crashed"
    })
  let assert Error(backend.Unavailable(_)) =
    store.readiness(nodes.node(crashed, "crashed", nodes.long))
}

pub fn a_slow_probe_is_bounded_and_does_not_block_other_reads_test() {
  let memory = conformance.leased_memory()
  let gates = probe.new()
  let backend =
    backend.LeasedBackend(..memory.backend, get: fn(key) {
      case memory.backend.get(key) {
        Error(backend.NotFound) -> {
          probe.gate(gates, "probe")
          Error(backend.NotFound)
        }
        found -> found
      }
    })
  let runs =
    nodes.node(backend, "bounded", nodes.long)
    |> store_core.with_backend_timeout(100)
  let assert Ok(_) =
    store_core.insert(
      runs,
      "existing",
      "record",
      store_core.Detached(False, False),
    )
  let reply = process.new_subject()
  process.spawn(fn() { process.send(reply, store.readiness(runs)) })
  let _ = probe.arrival(gates)
  let assert Ok(row) = store_core.get(runs, "existing")
  row.record |> should.equal("record")
  let assert Ok(Error(backend.Unavailable(_))) = process.receive(reply, 5000)
}

pub fn a_probe_finishing_after_drain_starts_reports_the_current_state_test() {
  let memory = conformance.leased_memory()
  let gates = probe.new()
  let bodies = probe.new()
  let backend =
    backend.LeasedBackend(..memory.backend, get: fn(key) {
      let found = memory.backend.get(key)
      case found, probe.count(gates, "armed") {
        Error(backend.NotFound), armed if armed > 0 -> probe.gate(gates, "probe")
        _, _ -> Nil
      }
      found
    })
  let assert Ok(runs) =
    store.leased(
      process.new_name("readiness-drain"),
      node: "drain",
      lease: duration.milliseconds(nodes.long),
      backend:,
    )
  let app = restart.application(runs)
  let assert Ok(_) =
    fabric.start(
      runs,
      slow(bodies),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let body = probe.arrival(bodies)
  probe.record(gates, "armed")
  let reply = process.new_subject()
  process.spawn(fn() { process.send(reply, store.readiness(runs)) })
  let checking = probe.arrival(gates)
  restart.begin_stop(app)
  restart.draining(runs)
  probe.release(checking)
  let assert Ok(Ok(report)) = process.receive(reply, 5000)
  report.status |> should.equal(store.StoreDraining)
  report.runners |> should.equal(1)
  probe.release(body)
  restart.stopped(app)
  let assert Error(backend.Unavailable(_)) = store.readiness(runs)
}

pub fn a_restart_does_not_reuse_the_previous_process_renewal_time_test() {
  let memory = conformance.leased_memory()
  let bodies = probe.new()
  let assert Ok(runs) =
    store.leased(
      process.new_name("readiness-restart"),
      node: "restart",
      lease: duration.milliseconds(nodes.long),
      backend: memory.backend,
    )
  let app = restart.application(runs)
  let assert Ok(handle) =
    fabric.start(
      runs,
      slow(bodies),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let body = probe.arrival(bodies)
  store_core.renew_now(runs)
  let _ = renewed(runs, 1000)
  probe.release(body)
  let assert Ok(_) = fabric.await(handle, within: duration.milliseconds(5000))
  restart.stop(app)
  let app = restart.application(runs)
  store.readiness(runs)
  |> should.equal(
    Ok(store.Readiness(store.Accepting, 0, store.Leased(nodes.long, None))),
  )
  restart.stop(app)
}

pub fn a_delayed_report_cannot_reuse_an_expired_lease_window_test() {
  let memory = conformance.leased_memory()
  let bodies = probe.new()
  let probes = probe.new()
  let backend =
    backend.LeasedBackend(..memory.backend, get: fn(key) {
      let found = memory.backend.get(key)
      case found, probe.count(probes, "armed") {
        Error(backend.NotFound), armed if armed > 0 ->
          probe.gate(probes, "probe")
        _, _ -> Nil
      }
      found
    })
  let runs = nodes.node(backend, "delayed-health", 3000)
  let assert Ok(handle) =
    fabric.start(
      runs,
      slow(bodies),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let body = probe.arrival(bodies)
  probe.record(probes, "armed")
  let reply = process.new_subject()
  process.spawn(fn() { process.send(reply, store.readiness(runs)) })
  let checking = probe.arrival(probes)
  let assert Ok(owner) = store_core.pid(runs)
  restart.suspend(owner)
  probe.release(checking)
  queued(owner, 1000)
  // Model a stalled VM: the health reply is queued before renewal/fence ticks,
  // but resumes after the original claim's 2400 ms safe window has expired.
  process.sleep(2500)
  restart.resume(owner)
  let assert Ok(Ok(report)) = process.receive(reply, 1000)
  report.status |> should.equal(store.LeaseUnconfirmed)
  report.runners |> should.equal(1)
  probe.release(body)
  let assert Ok(_) = fabric.cancel(handle)
}

fn queued(owner: process.Pid, remaining: Int) -> Nil {
  case restart.queued(owner) > 0 {
    True -> Nil
    False -> {
      should.be_true(remaining > 0)
      process.sleep(1)
      queued(owner, remaining - 1)
    }
  }
}

//// Recovery is driven by expired leases, without caller commands. Tests
//// advance only dead runners' leases; live work must remain untouched.

import fabric
import fabric/agent
import fabric/internal/bounded
import fabric/observation as o
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/nodes
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import fabric/testing
import gleam/erlang/process
import gleam/int
import gleam/list
import gleeunit/should
import sinal

fn worker(name: String, body: probe.Probe) -> agent.Agent(Nil) {
  agent.new(
    name,
    scripted.plan([scripted.slow("w", "work")]),
    [
      scripted.gated_tool(body),
    ],
    policy.always_allow(),
  )
  |> support.agent
}

fn dead(
  node: store.Store,
  backend: store.LeasedBackend,
  agent: agent.Agent(Nil),
  body: probe.Probe,
) -> run.RunId {
  let assert Ok(run) = fabric.start(node, agent, Nil, "go")
  let _ = probe.arrival(body)
  expire(node, backend, fabric.id(run))
  fabric.id(run)
}

fn expire(node: store.Store, backend: store.LeasedBackend, id: run.RunId) {
  let assert Ok(runner) = restart.runner(node, id)
  restart.kill(runner)
  let assert store.Held(owner, True) = nodes.holder(backend, id)
  backend.renew(owner, [run.id_to_string(id)], 0)
  |> should.equal(Ok([run.id_to_string(id)]))
}

fn start(node: store.Store, recoveries: List(fabric.Recovery), every: Int) {
  let assert Ok(spec) = fabric.sweeper(node, recoveries, every:)
  let assert Ok(started) = spec.start()
  started.pid
}

fn stop(pid: process.Pid) {
  process.unlink(pid)
  restart.kill(pid)
}

fn capture() {
  let events = process.new_subject()
  let assert Ok(id) =
    sinal.handler_id("sweep-test-" <> int.to_string(int.random(1_000_000_000)))
  let assert Ok(attachment) =
    sinal.observe(id, o.sweep(), fn(summary, _) {
      process.send(events, summary)
    })
  #(events, attachment)
}

fn claimed(events: process.Subject(o.Sweep)) -> o.Sweep {
  let assert Ok(summary) = process.receive(events, 10_000)
  case summary.claimed > 0 {
    True -> summary
    False -> claimed(events)
  }
}

fn uncertain(run: fabric.Run(Nil), tries: Int) -> run.UncertainAction {
  case fabric.await(run, 0) {
    Ok(run.Suspended([], [effect])) -> effect
    _ if tries > 0 -> {
      process.sleep(10)
      uncertain(run, tries - 1)
    }
    other -> {
      let detail = "recovery did not suspend: " <> string.inspect(other)
      panic as detail
    }
  }
}

import gleam/string

pub fn invalid_configuration_is_reported_before_starting_test() {
  let memory = testing.leased_memory()
  let node = nodes.node(memory.backend, "a", nodes.long)
  let agent = worker("worker", probe.new())
  let recovery = fabric.recovery(agent, fn(_) { Nil })
  fabric.sweeper(node, [recovery, recovery], every: 0)
  |> should.equal(
    Error([
      fabric.EveryNotPositive(0),
      fabric.DuplicateRecovery(run.Identity("worker", 1)),
    ]),
  )
  fabric.sweeper(node, [], every: 4_294_967_296)
  |> should.equal(Error([fabric.EveryTooLarge(4_294_967_296, 4_294_967_295)]))
  fabric.sweeper(support.store(), [], every: 100)
  |> should.equal(Error([fabric.StoreNotLeased]))
}

pub fn boot_and_periodic_scans_recover_only_expired_work_test() {
  let memory = testing.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let body = probe.new()
  let agent = worker("worker", body)
  let id = dead(a, memory.backend, agent, body)
  let assert Ok(live) = fabric.start(a, agent, Nil, "go")
  let _ = probe.arrival(body)
  let #(events, attachment) = capture()
  let sweeper = start(b, [fabric.recovery(agent, fn(_) { Nil })], 20)
  claimed(events) |> should.equal(o.Sweep(1, 1, 0, 0))
  let assert Ok(seen) = fabric.open(b, agent, Nil, id)
  let _ = uncertain(seen, 100)
  let assert Ok(empty) = process.receive(events, 1000)
  empty |> should.equal(o.Sweep(0, 0, 0, 0))
  let assert Ok(snapshot) = fabric.snapshot(live)
  snapshot.incarnation |> should.equal(1)

  expire(a, memory.backend, fabric.id(live))
  claimed(events) |> should.equal(o.Sweep(1, 1, 0, 0))
  let assert Ok(seen) = fabric.open(b, agent, Nil, fabric.id(live))
  let _ = uncertain(seen, 100)
  probe.count(body, "start:work") |> should.equal(2)
  stop(sweeper)
  let _ = sinal.detach(attachment)
}

pub fn concurrent_sweepers_recover_each_run_once_test() {
  let memory = testing.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let body = probe.new()
  let agent = worker("worker", body)
  let ids =
    list.map(list.repeat(Nil, 8), fn(_) { dead(a, memory.backend, agent, body) })
  let others = [
    nodes.node(memory.backend, "b", nodes.long),
    nodes.node(memory.backend, "c", nodes.long),
  ]
  let sweepers =
    list.map(others, fn(node) {
      start(node, [fabric.recovery(agent, fn(_) { Nil })], 10)
    })
  let assert [b, ..] = others
  list.each(ids, fn(id) {
    let assert Ok(seen) = fabric.open(b, agent, Nil, id)
    let _ = uncertain(seen, 200)
    let assert Ok(snapshot) = fabric.snapshot(seen)
    snapshot.incarnation |> should.equal(2)
  })
  probe.count(body, "start:work") |> should.equal(8)
  list.each(sweepers, stop)
}

pub fn unknown_corrupt_and_failed_contexts_do_not_block_other_roots_test() {
  let memory = testing.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let body = probe.new()
  let unknown = worker("unknown", body)
  let crashing = worker("crashing", body)
  let hanging = worker("hanging", body)
  let good = worker("good", body)
  let _ = dead(a, memory.backend, unknown, body)
  let _ = dead(a, memory.backend, crashing, body)
  let _ = dead(a, memory.backend, hanging, body)
  let good_id = dead(a, memory.backend, good, body)
  let assert Ok(Nil) =
    memory.backend.insert("broken", "invalid", store.Claim("dead", 0))
  let #(events, attachment) = capture()
  let context_ids = process.new_subject()
  let sweeper =
    start(
      b,
      [
        fabric.recovery(crashing, fn(_) { panic as "context unavailable" }),
        fabric.recovery(hanging, fn(_) {
          process.receive_forever(process.new_subject())
        }),
        fabric.recovery(good, fn(id) { process.send(context_ids, id) }),
      ],
      60_000,
    )
  claimed(events) |> should.equal(o.Sweep(5, 1, 1, 3))
  process.receive(context_ids, 100) |> should.equal(Ok(good_id))
  let assert Ok(seen) = fabric.open(b, good, Nil, good_id)
  let _ = uncertain(seen, 100)
  stop(sweeper)
  let _ = sinal.detach(attachment)
}

pub fn supervisor_shutdown_stops_a_blocked_context_before_store_drain_test() {
  let memory = testing.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let body = probe.new()
  let agent = worker("worker", body)
  let _ = dead(a, memory.backend, agent, body)
  let assert Ok(b) =
    store.leased(
      process.new_name("sweeper-stop"),
      node: "b",
      lease: nodes.long,
      backend: memory.backend,
    )
  let entered = process.new_subject()
  let assert Ok(spec) =
    fabric.sweeper(
      b,
      [
        fabric.recovery(agent, fn(_) {
          process.trap_exits(True)
          process.send(entered, process.self())
          process.receive_forever(process.new_subject())
        }),
      ],
      every: 10,
    )
  let app = restart.application_with(b, [spec])
  let assert Ok(context) = process.receive(entered, 1000)
  let monitor = process.monitor(context)
  restart.begin_stop(app)
  restart.stopped_within(app, 1000) |> should.be_true
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(1000)
  |> should.equal(Ok(Nil))
}

pub fn a_bounded_call_kills_its_work_on_timeout_test() {
  let entered = process.new_subject()
  bounded.call(20, fn() {
    process.trap_exits(True)
    process.send(entered, process.self())
    process.receive_forever(process.new_subject())
  })
  |> should.equal(Error(bounded.TimedOut))
  let assert Ok(body) = process.receive(entered, 1000)
  let monitor = process.monitor(body)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(1000)
  |> should.equal(Ok(Nil))
}

pub fn a_restarted_store_replaces_the_sweeper_and_its_pending_context_test() {
  let memory = testing.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let body = probe.new()
  let contexts = probe.new()
  let agent = worker("worker", body)
  let id = dead(a, memory.backend, agent, body)
  let assert Ok(b) =
    store.leased(
      process.new_name("sweeper-restart"),
      node: "b",
      lease: nodes.long,
      backend: memory.backend,
    )
  let entered = process.new_subject()
  let assert Ok(spec) =
    fabric.sweeper(
      b,
      [
        fabric.recovery(agent, fn(_) {
          probe.record(contexts, "called")
          case probe.count(contexts, "called") {
            1 -> {
              process.send(entered, process.self())
              process.receive_forever(process.new_subject())
            }
            _ -> Nil
          }
        }),
      ],
      every: 10,
    )
  let app = restart.application_with(b, [spec])
  let assert Ok(context) = process.receive(entered, 1000)
  let assert Ok(old_store) = store.pid(b)
  restart.kill(old_store)
  let monitor = process.monitor(context)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(1000)
  |> should.equal(Ok(Nil))
  await_restarted(b, old_store, 200)
  process.sleep(30)
  probe.count(contexts, "called") |> should.equal(1)
  let assert store.Held(owner, True) = nodes.holder(memory.backend, id)
  memory.backend.renew(owner, [run.id_to_string(id)], 0)
  |> should.equal(Ok([run.id_to_string(id)]))
  let assert Ok(seen) = fabric.open(b, agent, Nil, id)
  let _ = uncertain(seen, 200)
  probe.count(contexts, "called") |> should.equal(2)
  restart.stop(app)
}

fn await_restarted(node, previous, tries) {
  case store.pid(node), store.runners(node) {
    Ok(pid), Ok(_) if pid != previous -> Nil
    _, _ if tries > 0 -> {
      process.sleep(10)
      await_restarted(node, previous, tries - 1)
    }
    _, _ -> panic as "store did not restart"
  }
}

pub fn a_slow_claim_does_not_overlap_the_next_scan_or_block_the_store_test() {
  let memory = testing.leased_memory()
  let calls = probe.new()
  let backend =
    store.LeasedBackend(..memory.backend, claim_expired: fn(owner, ttl, limit) {
      probe.record(calls, "scan")
      probe.gate(calls, "claim")
      memory.backend.claim_expired(owner, ttl, limit)
    })
  let node = nodes.node(backend, "a", nodes.long)
  let sweeper = start(node, [], 1)
  let first = probe.arrival(calls)
  // The actor remains responsive while its backend claim is blocked.
  let assert Ok(_) = store.runners(node)
  process.sleep(30)
  probe.count(calls, "scan") |> should.equal(1)
  probe.release(first)
  let second = probe.arrival(calls)
  probe.count(calls, "scan") |> should.equal(2)
  stop(sweeper)
  probe.release(second)
}

pub fn a_record_under_the_wrong_run_id_is_rejected_before_recovery_test() {
  let memory = testing.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let body = probe.new()
  let agent = worker("worker", body)
  let assert Ok(original) = fabric.start(a, agent, Nil, "go")
  let running = probe.arrival(body)
  let assert Ok(record) =
    memory.backend.get(run.id_to_string(fabric.id(original)))
  let assert Ok(Nil) =
    memory.backend.insert("misfiled", record.record, store.Claim("dead", 0))
  let contexts = probe.new()
  let #(events, attachment) = capture()
  let sweeper =
    start(
      b,
      [fabric.recovery(agent, fn(_) { probe.record(contexts, "called") })],
      60_000,
    )
  claimed(events) |> should.equal(o.Sweep(1, 0, 0, 1))
  probe.count(contexts, "called") |> should.equal(0)
  let assert Ok(misfiled) = run.parse_id("misfiled")
  let assert Error(fabric.CorruptRecord(_)) =
    fabric.open(b, agent, Nil, misfiled)
  let assert Ok(after) =
    memory.backend.get(run.id_to_string(fabric.id(original)))
  after.revision |> should.equal(record.revision)
  probe.release(running)
  fabric.await(original, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("final: \"work\""))))
  stop(sweeper)
  let _ = sinal.detach(attachment)
}

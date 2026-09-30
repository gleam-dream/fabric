//// G7: registered graph recovery uses saved attachments and existing leases.

import fabric
import fabric/agent
import fabric/graph
import fabric/graph/agent as agent_node
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/operation
import fabric/internal/graph/controller as control
import fabric/internal/graph/record
import fabric/model
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
import gleam/option.{None}
import gleam/result
import gleeunit/should
import json/blueprint/codec
import sinal

fn identity() {
  run.Identity("swept-graph", 1)
}

fn runtime(runs, calls) {
  let op =
    operation.new(
      run.Identity("effect", 1),
      codec.int(),
      codec.int(),
      fn(_, _, n) {
        probe.record(calls, "effect")
        probe.gate(calls, "effect")
        Ok(n + 1)
      },
      fn(_: Nil) { operation.DefiniteFailure("failed") },
    )
  wrap(runs, op)
}

fn wrap(runs, op) {
  let assert Ok(id) = definition.node_id("effect")
  let node =
    definition.node(
      id,
      op,
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      identity(),
      id,
      [node],
      codec.int(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn expire(runs, backend: store.LeasedBackend, id) {
  let assert Ok(pid) = restart.runner(runs, id)
  restart.kill(pid)
  let assert store.Held(owner, True) = nodes.holder(backend, id)
  backend.renew(owner, [run.id_to_string(id)], 0)
  |> should.equal(Ok([run.id_to_string(id)]))
}

fn capture() {
  let events = process.new_subject()
  let assert Ok(id) =
    sinal.handler_id("graph-sweep-" <> int.to_string(int.random(1_000_000_000)))
  let assert Ok(attachment) =
    sinal.observe(id, o.sweep(), fn(summary, _) {
      process.send(events, summary)
    })
  #(events, attachment)
}

fn start(runs, recovery) {
  start_all(runs, [recovery])
}

fn start_all(runs, recoveries) {
  let assert Ok(spec) = fabric.sweeper(runs, recoveries, every: 60_000)
  let assert Ok(started) = spec.start()
  started.pid
}

fn worker(calls) {
  agent.new(
    "swept-graph",
    scripted.model(fn(_) {
      probe.record(calls, "model")
      case probe.count(calls, "model") {
        1 -> probe.gate(calls, "model")
        _ -> Nil
      }
      model.FinalAnswer("42", None)
    }),
    [],
    policy.always_allow(),
  )
  |> support.agent
}

fn managed(runs, calls) {
  let assert Ok(node) =
    agent_node.new(
      agent_node.Definition(
        run.Identity("agent-node", 1),
        worker(calls),
        codec.int(),
        codec.int(),
        int.to_string,
        fn(text) { int.parse(text) |> result.replace_error("invalid number") },
      ),
      runs,
      fn() { Nil },
    )
  wrap(runs, agent_node.as_operation(node))
}

pub fn mixed_family_scanning_keeps_the_foreign_parent_lease_and_uses_its_graph_registration_test() {
  let memory = testing.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let calls = probe.new()
  let contexts = probe.new()
  let assert Ok(parent) =
    graph.start(managed(a, calls), support.id("mixed-root"), 41)
  let _ = probe.arrival(calls)
  let child = support.id(child.reserved_id("mixed-root", 1))
  // Preserve the foreign parent's lease while only the child expires.
  let assert Ok(parent_runner) = restart.runner(a, graph.id(parent))
  restart.kill(parent_runner)
  let parent_revision = nodes.revision(memory.backend, graph.id(parent))
  let parent_holder = nodes.holder(memory.backend, graph.id(parent))
  expire(a, memory.backend, child)
  let registrations = [
    fabric.recovery(worker(calls), fn(_) {
      probe.record(contexts, "wrong-agent-root")
    }),
    graph.recovery(identity(), fn(runs) {
      probe.record(contexts, "graph-root")
      managed(runs, calls)
    }),
  ]
  let #(events, attachment) = capture()
  let sweeper = start_all(b, registrations)
  process.receive(events, 5000) |> should.equal(Ok(o.Sweep(1, 1, 0, 0)))
  let assert Ok(worker) = fabric.open(b, worker(calls), Nil, child)
  fabric.await(worker, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("42"))))
  nodes.revision(memory.backend, graph.id(parent))
  |> should.equal(parent_revision)
  nodes.holder(memory.backend, graph.id(parent)) |> should.equal(parent_holder)
  probe.entries(contexts) |> should.equal(["graph-root"])
  stop(sweeper, attachment)
  let assert store.Held(owner, _) = parent_holder
  memory.backend.renew(owner, ["mixed-root"], 0)
  |> should.equal(Ok(["mixed-root"]))
  nodes.holder(memory.backend, child) |> should.equal(store.Free)
  let #(events, attachment) = capture()
  let sweeper = start_all(b, registrations)
  let assert Ok(summary) = process.receive(events, 5000)
  summary.claimed |> should.equal(1)
  let handle = graph.attach(managed(b, calls), graph.id(parent))
  let assert Ok(done) = graph.await(handle, 5000)
  done.status |> should.equal(graph.Completed(42))
  probe.count(calls, "model") |> should.equal(2)
  probe.count(contexts, "wrong-agent-root") |> should.equal(0)
  stop(sweeper, attachment)
}

pub fn invalid_graph_registrations_do_not_change_the_claimed_execution_test() {
  let memory = testing.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let calls = probe.new()
  let registration =
    graph.recovery(identity(), fn(runs) { runtime(runs, calls) })
  fabric.sweeper(b, [registration, registration], every: 100)
  |> should.equal(Error([fabric.DuplicateRecovery(identity())]))
  let assert Ok(handle) =
    graph.start(runtime(a, calls), support.id("wrong-binding"), 41)
  let _ = probe.arrival(calls)
  expire(a, memory.backend, graph.id(handle))
  let before = nodes.revision(memory.backend, graph.id(handle))
  let #(events, attachment) = capture()
  let sweeper =
    start(b, graph.recovery(identity(), fn(_) { runtime(a, calls) }))
  process.receive(events, 5000) |> should.equal(Ok(o.Sweep(1, 0, 0, 1)))
  nodes.revision(memory.backend, graph.id(handle)) |> should.equal(before)
  probe.count(calls, "effect") |> should.equal(1)
  stop(sweeper, attachment)
}

pub fn competing_graph_scans_claim_each_expired_run_once_test() {
  let memory = testing.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let c = nodes.node(memory.backend, "c", nodes.long)
  let calls = probe.new()
  let ids =
    list.map([1, 2, 3, 4, 5, 6], fn(n) {
      let id = support.id("swept-" <> int.to_string(n))
      let assert Ok(_) = graph.start(runtime(a, calls), id, n)
      let _ = probe.arrival(calls)
      expire(a, memory.backend, id)
      id
    })
  let #(events, attachment) = capture()
  let registration =
    graph.recovery(identity(), fn(runs) { runtime(runs, calls) })
  let first = start(b, registration)
  let second = start(c, registration)
  let assert Ok(one) = process.receive(events, 5000)
  let assert Ok(two) = process.receive(events, 5000)
  one.claimed + two.claimed |> should.equal(6)
  one.recovered + two.recovered |> should.equal(6)
  list.each(ids, fn(id) {
    let assert Ok(done) = graph.await(graph.attach(runtime(b, calls), id), 5000)
    let assert graph.Blocked(_, graph.EffectUncertain(_)) = done.status
    done.receipts |> should.equal([])
  })
  probe.count(calls, "effect") |> should.equal(6)
  process.unlink(second)
  restart.kill(second)
  stop(first, attachment)
}

pub fn unknown_and_misfiled_graphs_do_not_invoke_a_registration_test() {
  let memory = testing.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let calls = probe.new()
  let assert Ok(handle) =
    graph.start(runtime(a, calls), support.id("unknown-graph"), 41)
  let _ = probe.arrival(calls)
  expire(a, memory.backend, graph.id(handle))
  let assert Ok(row) = memory.backend.get("unknown-graph")
  memory.backend.insert("wrong-key", row.record, store.Claim("dead", 0))
  |> should.be_ok
  let #(events, attachment) = capture()
  let sweeper =
    start(
      b,
      graph.recovery(run.Identity("other", 1), fn(runs) {
        probe.record(calls, "wrong-factory")
        runtime(runs, calls)
      }),
    )
  process.receive(events, 5000) |> should.equal(Ok(o.Sweep(2, 0, 1, 1)))
  nodes.revision(memory.backend, graph.id(handle)) |> should.equal(row.revision)
  probe.count(calls, "wrong-factory") |> should.equal(0)
  stop(sweeper, attachment)
}

pub fn a_child_without_a_reciprocal_parent_reservation_cannot_trigger_root_recovery_test() {
  let memory = testing.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let calls = probe.new()
  let contexts = probe.new()
  let assert Ok(parent) =
    graph.start(managed(a, calls), support.id("damaged-family"), 41)
  let _ = probe.arrival(calls)
  let assert Ok(pid) = restart.runner(a, graph.id(parent))
  restart.kill(pid)
  let child = support.id(child.reserved_id("damaged-family", 1))
  expire(a, memory.backend, child)
  // Inject a decodable parent record that no longer names this child.
  let assert Ok(row) = store.get(a, "damaged-family")
  let assert Ok(state) = record.decode(row.record)
  let assert control.Joining(activation, _) = state.phase
  let assert Ok(encoded) =
    record.encode(control.State(..state, phase: control.Ready(activation)))
  store.commit(
    a,
    "damaged-family",
    row.revision,
    encoded,
    store.Detached(False, False),
  )
  |> should.be_ok
  let #(events, attachment) = capture()
  let sweeper =
    start(
      b,
      graph.recovery(identity(), fn(runs) {
        probe.record(contexts, "factory")
        managed(runs, calls)
      }),
    )
  process.receive(events, 5000) |> should.equal(Ok(o.Sweep(1, 0, 0, 1)))
  probe.entries(contexts) |> should.equal([])
  probe.count(calls, "model") |> should.equal(1)
  stop(sweeper, attachment)
}

fn stop(pid, attachment) {
  process.unlink(pid)
  restart.kill(pid)
  let _ = sinal.detach(attachment)
  Nil
}

pub fn expired_graph_work_recovers_without_repeating_its_started_effect_test() {
  let memory = testing.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let calls = probe.new()
  let assert Ok(handle) =
    graph.start(runtime(a, calls), support.id("graph-expired"), 41)
  let _ = probe.arrival(calls)
  expire(a, memory.backend, graph.id(handle))
  let #(events, attachment) = capture()
  let sweeper =
    start(b, graph.recovery(identity(), fn(runs) { runtime(runs, calls) }))
  process.receive(events, 5000) |> should.equal(Ok(o.Sweep(1, 1, 0, 0)))
  let handle = graph.attach(runtime(b, calls), graph.id(handle))
  let assert Ok(snapshot) = graph.await(handle, 5000)
  let assert graph.Blocked(_, graph.EffectUncertain(_)) = snapshot.status
  snapshot.receipts |> should.equal([])
  probe.count(calls, "effect") |> should.equal(1)
  nodes.holder(memory.backend, graph.id(handle)) |> should.equal(store.Free)
  stop(sweeper, attachment)
}

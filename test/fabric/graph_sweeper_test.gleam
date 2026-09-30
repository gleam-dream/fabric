//// G7: registered graph recovery uses saved attachments and existing leases.

import fabric
import fabric/agent
import fabric/graph
import fabric/graph/agent as agent_node
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/operation
import fabric/graph/signal
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
  wrap_native(runs, op, codec.int())
}

fn wrap_native(runs, op, values) {
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
    definition.build(definition.Spec(identity(), id, [node], values, values, 1))
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

fn signal_leaf(runs) {
  wrap(runs, operation.await_signal(codec.int(), response()))
}

fn response() {
  signal.new(run.Identity("sweep-response", 1), codec.int())
}

fn nested(runs) {
  wrap(
    runs,
    graph.as_subgraph(wrap(runs, graph.as_subgraph(signal_leaf(runs)))),
  )
}

fn scan_once(runs) {
  scan_runtime(runs, nested)
}

fn scan_runtime(runs, build) {
  let #(events, attachment) = capture()
  let sweeper = start(runs, graph.recovery(identity(), build))
  let assert Ok(summary) = process.receive(events, 5000)
  stop(sweeper, attachment)
  summary
}

fn mapped_signals(
  runs: store.Store,
) -> graph.Runtime(Nil, List(Int), List(Int)) {
  map_children(runs, signal_leaf(runs), codec.int())
}

fn map_children(
  runs: store.Store,
  child: graph.Runtime(Nil, value, value),
  value: codec.Codec(value),
) -> graph.Runtime(Nil, List(value), List(value)) {
  let assert Ok(op) =
    graph.map(
      run.Identity("mapped-signals", 1),
      child,
      max_members: 3,
      concurrency: 3,
    )
  let assert Ok(id) = definition.node_id("map")
  let node =
    definition.node(
      id,
      op,
      fn(values) { Ok(values) },
      fn(state, output) {
        case output {
          Ok(values) -> Ok(definition.Finish(state, values))
          Error(failure) -> Error(failure.reason)
        }
      },
      [],
    )
  let values = codec.list(value)
  let assert Ok(spec) =
    definition.build(definition.Spec(identity(), id, [node], values, values, 1))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn nested_forks(
  runs: store.Store,
) -> graph.Runtime(Nil, List(List(Int)), List(List(Int))) {
  let outer = map_children(runs, mapped_signals(runs), codec.list(codec.int()))
  wrap_native(
    runs,
    graph.as_subgraph(outer),
    codec.list(codec.list(codec.int())),
  )
}

fn barrier_uncertain_leaf(
  runs: store.Store,
  calls: probe.Probe,
) -> graph.Runtime(Nil, Int, Int) {
  wrap(
    runs,
    operation.new(
      run.Identity("barrier-uncertain", 1),
      codec.int(),
      codec.int(),
      fn(_, _, _) {
        probe.record(calls, "effect")
        probe.gate(calls, "effect")
        Error("external outcome unknown")
      },
      operation.UncertainEffect,
    ),
  )
}

fn uncertain_fork(
  runs: store.Store,
  calls: probe.Probe,
) -> graph.Runtime(Nil, List(Int), List(Int)) {
  let members =
    map_children(runs, barrier_uncertain_leaf(runs, calls), codec.int())
  wrap_native(runs, graph.as_subgraph(members), codec.list(codec.int()))
}

// F6–F8: nested cleanup follows authoritative leaf evidence after restart.
pub fn cancelled_nested_fork_settles_without_routing_or_repeating_effects_test() {
  let memory = testing.leased_memory()
  let calls = probe.new()
  let build = fn(runs) { uncertain_fork(runs, calls) }
  let id = support.id("cancelled-fork")
  let #(owner, #(original, root)) =
    restart.owned(fn() {
      let runs = nodes.node(memory.backend, "original", nodes.long)
      let assert Ok(root) = graph.start(build(runs), id, [1, 2])
      #(runs, root)
    })
  let first = probe.arrival(calls)
  let second = probe.arrival(calls)
  probe.release(first)
  probe.release(second)
  let assert Ok(waiting) = graph.await(root, 5000)
  let assert graph.Child(_, child.Fork(_)) = waiting.status
  let members =
    map_children(original, barrier_uncertain_leaf(original, calls), codec.int())
  let assert Ok(middle) = graph.child(root, 1, members)
  let middle_id = graph.id(middle)
  let leaves =
    list.map([1, 2], fn(member) {
      let assert Ok(leaf) =
        graph.branch(middle, 1, member, barrier_uncertain_leaf(original, calls))
      graph.id(leaf)
    })
  let assert Ok(_) = graph.cancel(root)
  let assert Ok(cancelled) = graph.await(root, 5000)
  let assert graph.Cancelled(graph.ChildUnresolved(_, _)) = cancelled.status
  let ids = [id, middle_id, ..leaves]
  await_free(memory.backend, ids, 200)
  restart.crash(owner, original)
  let a = nodes.node(memory.backend, "scanner", nodes.long)
  let b = nodes.node(memory.backend, "remote", nodes.long)
  list.each([1, 2, 3], fn(_) {
    let _ = scan_runtime(a, build)
    await_free(memory.backend, ids, 200)
  })
  scan_runtime(b, build).claimed |> should.equal(0)
  list.each(leaves, fn(id) {
    let leaf = graph.attach(barrier_uncertain_leaf(b, calls), id)
    let assert Ok(cancelled) = graph.read(leaf)
    let assert graph.Cancelled(graph.Unresolved(reference, _)) =
      cancelled.status
    let assert Ok(_) = graph.reconcile(leaf, reference, "42")
  })
  let _ = scan_runtime(a, build)
  let members = map_children(a, barrier_uncertain_leaf(a, calls), codec.int())
  let assert Ok(middle) = graph.await(graph.attach(members, middle_id), 5000)
  middle.status |> should.equal(graph.Cancelled(graph.ForkSettled(1)))
  let _ = scan_runtime(a, build)
  let assert Ok(done) = graph.read(graph.attach(build(a), id))
  let assert graph.Cancelled(graph.ChildSettled(_)) = done.status
  done.receipts |> should.equal([])
  probe.count(calls, "effect") |> should.equal(2)
}

// G7, F8: a live foreign parent lease cannot hide an independently expired branch.
pub fn expired_fork_branch_recovers_without_taking_the_foreign_parent_lease_test() {
  let memory = testing.leased_memory()
  let calls = probe.new()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let build = fn(runs) { map_children(runs, runtime(runs, calls), codec.int()) }
  let assert Ok(root) = graph.start(build(a), support.id("foreign-fork"), [41])
  let _ = probe.arrival(calls)
  let assert Ok(branch) = graph.branch(root, 1, 1, runtime(a, calls))
  let assert Ok(parent_runner) = restart.runner(a, graph.id(root))
  restart.kill(parent_runner)
  expire(a, memory.backend, graph.id(branch))
  let parent_revision = nodes.revision(memory.backend, graph.id(root))
  let summary = scan_runtime(b, build)
  summary.recovered |> should.equal(1)
  let assert Ok(restored) =
    graph.read(graph.attach(runtime(b, calls), graph.id(branch)))
  let assert graph.Blocked(_, graph.EffectUncertain(_)) = restored.status
  nodes.revision(memory.backend, graph.id(root))
  |> should.equal(parent_revision)
  nodes.holding(memory.backend, graph.id(root))
  |> should.equal(Ok(#("a", True)))
  nodes.holder(memory.backend, graph.id(branch)) |> should.equal(store.Free)
  probe.count(calls, "effect") |> should.equal(1)
}

// G9, F8: serial and parallel ancestors park and discover nested branch changes.
pub fn nested_forks_release_leases_and_converge_after_lost_notifications_test() {
  let memory = testing.leased_memory()
  let id = support.id("nested-forks")
  let #(owner, #(original, ids, leaves)) =
    restart.owned(fn() {
      let runs = nodes.node(memory.backend, "original", nodes.long)
      let assert Ok(root) =
        graph.start(nested_forks(runs), id, [[1, 2], [3, 4]])
      let assert Ok(waiting) = graph.await(root, 5000)
      let assert graph.Child(_, child.Fork(_)) = waiting.status
      let outer_runtime =
        map_children(runs, mapped_signals(runs), codec.list(codec.int()))
      let assert Ok(outer) = graph.child(root, 1, outer_runtime)
      let inners =
        list.map([1, 2], fn(member) {
          let assert Ok(inner) =
            graph.branch(outer, 1, member, mapped_signals(runs))
          inner
        })
      let leaves =
        list.flat_map(inners, fn(inner) {
          list.map([1, 2], fn(member) {
            let assert Ok(leaf) =
              graph.branch(inner, 1, member, signal_leaf(runs))
            graph.id(leaf)
          })
        })
      #(
        runs,
        list.append([id, graph.id(outer), ..list.map(inners, graph.id)], leaves),
        leaves,
      )
    })
  await_free(memory.backend, ids, 200)
  restart.crash(owner, original)
  let a = nodes.node(memory.backend, "scanner", nodes.long)
  let b = nodes.node(memory.backend, "remote", nodes.long)
  // Initial observation and independent claim releases may require several passes.
  list.each([1, 2, 3, 4, 5], fn(_) {
    let _ = scan_runtime(a, nested_forks)
    await_free(memory.backend, ids, 200)
  })
  let revisions = list.map(ids, nodes.revision(memory.backend, _))
  scan_runtime(b, nested_forks).claimed |> should.equal(0)
  list.map(ids, nodes.revision(memory.backend, _)) |> should.equal(revisions)
  list.each(list.reverse(leaves), fn(id) {
    let leaf = graph.attach(signal_leaf(b), id)
    let assert Ok(waiting) = graph.read(leaf)
    let assert graph.AwaitingSignal(reference) = waiting.status
    let assert Ok(_) =
      graph.deliver(leaf, reference, response(), waiting.value * 10)
  })
  let _ = scan_runtime(a, nested_forks)
  let assert Ok(done) = graph.await(graph.attach(nested_forks(a), id), 5000)
  done.status |> should.equal(graph.Completed([[10, 20], [30, 40]]))
}

// G7, G9: any unfinished member can wake a parent without its local watches.
pub fn fork_discovery_survives_lost_watches_and_does_not_repeat_unchanged_waits_test() {
  let memory = testing.leased_memory()
  let id = support.id("fork-discovery")
  let #(owner, original) =
    restart.owned(fn() {
      let runs = nodes.node(memory.backend, "original", nodes.long)
      let assert Ok(handle) = graph.start(mapped_signals(runs), id, [1, 2, 3])
      let assert Ok(waiting) = graph.await(handle, 5000)
      let assert graph.Fork(_, _) = waiting.status
      runs
    })
  let ids = [
    id,
    ..list.map([1, 2, 3], fn(member) {
      support.id(child.branch_id("fork-discovery", 1, member))
    })
  ]
  await_free(memory.backend, ids, 200)
  restart.crash(owner, original)
  let a = nodes.node(memory.backend, "scan", nodes.long)
  let b = nodes.node(memory.backend, "remote", nodes.long)
  scan_runtime(a, mapped_signals).claimed |> should.equal(1)
  await_free(memory.backend, ids, 200)
  let revisions = list.map(ids, nodes.revision(memory.backend, _))
  scan_runtime(b, mapped_signals).claimed |> should.equal(0)
  list.map(ids, nodes.revision(memory.backend, _)) |> should.equal(revisions)
  let root = graph.attach(mapped_signals(b), id)
  let assert Ok(second) = graph.branch(root, 1, 2, signal_leaf(b))
  let assert Ok(waiting) = graph.read(second)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Ok(_) = graph.deliver(second, reference, response(), 20)
  scan_runtime(a, mapped_signals).claimed |> should.equal(1)
  let assert Ok(waiting) =
    graph.await(graph.attach(mapped_signals(a), id), 5000)
  let assert graph.Fork(_, _) = waiting.status
  await_free(memory.backend, ids, 200)
  // The new wait has one fewer dependency; one claim records that new scope.
  scan_runtime(b, mapped_signals).claimed |> should.equal(1)
  await_free(memory.backend, ids, 200)
  scan_runtime(a, mapped_signals).claimed |> should.equal(0)
  list.each([1, 3], fn(member) {
    let assert Ok(handle) = graph.branch(root, 1, member, signal_leaf(b))
    let assert Ok(waiting) = graph.read(handle)
    let assert graph.AwaitingSignal(reference) = waiting.status
    let assert Ok(_) = graph.deliver(handle, reference, response(), member * 10)
  })
  scan_runtime(a, mapped_signals).claimed |> should.equal(1)
  let assert Ok(done) = graph.await(graph.attach(mapped_signals(a), id), 5000)
  done.status |> should.equal(graph.Completed([10, 20, 30]))
}

fn await_free(backend, ids, tries) {
  case list.all(ids, fn(id) { nodes.holder(backend, id) == store.Free }) {
    True -> Nil
    False if tries > 0 -> {
      process.sleep(10)
      await_free(backend, ids, tries - 1)
    }
    False -> panic as "family did not release its leases"
  }
}

pub fn nested_idle_discovery_converges_and_later_observes_an_external_signal_test() {
  let memory = testing.leased_memory()
  let #(owner, original) =
    restart.owned(fn() {
      let original = nodes.node(memory.backend, "original", nodes.long)
      let assert Ok(handle) =
        graph.start(nested(original), support.id("idle-root"), 41)
      let assert Ok(waiting) = graph.await(handle, 5000)
      let assert graph.Child(_, child.Signal(_)) = waiting.status
      original
    })
  let root = support.id("idle-root")
  let middle = support.id(child.reserved_id("idle-root", 1))
  let leaf = support.id(child.reserved_id(run.id_to_string(middle), 1))
  let ids = [root, middle, leaf]
  await_free(memory.backend, ids, 200)
  restart.crash(owner, original)
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let _ = scan_once(a)
  await_free(memory.backend, ids, 200)
  let _ = scan_once(b)
  await_free(memory.backend, ids, 200)
  let _ = scan_once(a)
  await_free(memory.backend, ids, 200)
  let revisions = list.map(ids, nodes.revision(memory.backend, _))
  scan_once(b).claimed |> should.equal(0)
  list.map(ids, nodes.revision(memory.backend, _)) |> should.equal(revisions)
  let handle = graph.attach(signal_leaf(b), leaf)
  let assert Ok(waiting) = graph.read(handle)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Ok(_) = graph.deliver(handle, reference, response(), 42)
  let _ = scan_once(a)
  let assert Ok(done) = graph.await(graph.attach(nested(a), root), 5000)
  done.status |> should.equal(graph.Completed(42))
}

fn uncertain_leaf(runs, calls) {
  wrap(
    runs,
    operation.new(
      run.Identity("uncertain", 1),
      codec.int(),
      codec.int(),
      fn(_, _, _) {
        probe.record(calls, "effect")
        Error("external outcome unknown")
      },
      operation.UncertainEffect,
    ),
  )
}

fn nested_uncertain(runs, calls) {
  wrap(
    runs,
    graph.as_subgraph(wrap(runs, graph.as_subgraph(uncertain_leaf(runs, calls)))),
  )
}

pub fn nested_blocked_discovery_converges_without_replaying_uncertain_effects_test() {
  let memory = testing.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let calls = probe.new()
  let build = fn(runs) { nested_uncertain(runs, calls) }
  let root = support.id("blocked-root")
  let middle = support.id(child.reserved_id("blocked-root", 1))
  let leaf = support.id(child.reserved_id(run.id_to_string(middle), 1))
  let ids = [root, middle, leaf]
  let assert Ok(handle) = graph.start(build(a), root, 41)
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.Child(_, child.Uncertain(_)) = waiting.status
  await_free(memory.backend, ids, 200)
  let _ = scan_runtime(b, build)
  await_free(memory.backend, ids, 200)
  let _ = scan_runtime(a, build)
  await_free(memory.backend, ids, 200)
  let _ = scan_runtime(b, build)
  await_free(memory.backend, ids, 200)
  let revisions = list.map(ids, nodes.revision(memory.backend, _))
  scan_runtime(a, build).claimed |> should.equal(0)
  list.map(ids, nodes.revision(memory.backend, _)) |> should.equal(revisions)
  probe.count(calls, "effect") |> should.equal(1)
  let leaf_handle = graph.attach(uncertain_leaf(b, calls), leaf)
  let assert Ok(waiting) = graph.read(leaf_handle)
  let assert graph.Blocked(reference, _) = waiting.status
  let assert Ok(_) = graph.reconcile(leaf_handle, reference, "42")
  let _ = scan_runtime(a, build)
  let assert Ok(done) = graph.await(handle, 5000)
  done.status |> should.equal(graph.Completed(42))
  probe.count(calls, "effect") |> should.equal(1)
}

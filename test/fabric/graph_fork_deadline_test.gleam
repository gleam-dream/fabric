//// F6–F8: expiration retains fork ownership until every admitted member settles.

import fabric/graph
import fabric/graph/definition
import fabric/graph/fork
import fabric/graph/operation
import fabric/graph/signal
import fabric/internal/store as store_core
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/backend
import fabric/store/conformance
import fabric/store/discovery
import fabric/store/retention
import fabric/support
import fabric/support/nodes
import fabric/support/probe
import fabric/support/restart
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn node_id() -> definition.NodeId {
  let id = definition.node_id("work")
  id
}

fn leaf(runs: store.Store) -> graph.Runtime(Nil, Int, Int) {
  member(
    runs,
    operation.await_signal(
      codec.int(),
      signal.new(run.DefinitionId("answer", 1), codec.int()),
    ),
  )
}

fn member(
  runs: store.Store,
  op: operation.Operation(Nil, Int, Int),
) -> graph.Runtime(Nil, Int, Int) {
  let node =
    definition.node(
      node_id(),
      op,
      fn(n) { Ok(n) },
      fn(state, n) { Ok(definition.Finish(state, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("fork-leaf", 1),
        entry: node_id(),
        nodes: [node],
        state: codec.int(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(1),
    )
  graph.new(spec, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
  |> graph.build
  |> should.be_ok
}

fn parent(runs: store.Store) {
  parent_with(runs, leaf(runs), fn(_, _) {
    panic as "expiration cannot accept or route a join"
  })
}

fn parent_with(
  runs: store.Store,
  child: graph.Runtime(Nil, Int, Int),
  accept: fn(List(Int), Result(List(Int), fork.Failure)) ->
    Result(definition.Command(List(Int), List(Int)), String),
) {
  let values = codec.list(codec.int())
  let op = graph.map(run.DefinitionId("expiring-map", 1), child, 3, 2)
  let op = operation.with_deadline(op, run.After(duration.milliseconds(60_000)))
  let node =
    definition.node(node_id(), op, fn(values) { Ok(values) }, accept, [])
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("fork-deadline", 1),
        entry: node_id(),
        nodes: [node],
        state: values,
        answer: values,
      )
      |> definition.with_max_activations(1),
    )
  graph.new(spec, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
  |> graph.build
  |> should.be_ok
}

fn action(runs, perform) {
  member(
    runs,
    operation.new(
      run.DefinitionId("effect", 1),
      codec.int(),
      codec.int(),
      fn(_, _, input) { perform(input) },
      fn(failure) { failure },
    ),
  )
}

pub fn a_failed_join_cannot_reconcile_past_its_original_deadline_test() {
  let memory = conformance.leased_memory()
  let calls = probe.new()
  let runs = nodes.node(memory.backend, "blocked-join", 300_000)
  let runtime =
    parent_with(runs, action(runs, fn(n) { Ok(n) }), fn(_, _) {
      probe.record(calls, "accept")
      Error("join needs correction")
    })
  let assert Ok(root) =
    graph.start(
      runtime,
      support.id("blocked-fork-join"),
      [1],
      correlation: None,
    )
  let assert Ok(_) = graph.await(root, within: duration.milliseconds(5000))
  let assert Ok(blocked) = graph.snapshot(root)
  let assert graph.Blocked(reference, graph.InvalidResult(output, _)) =
    blocked.status
  let assert Some(due) = blocked.deadline
  let assert Ok(row) = store_core.get(runs, run.id_to_string(graph.id(root)))
  let assert Ok(Some(wait)) = discovery.inspect(row.record)
  wait.trigger |> should.equal(discovery.At(due))
  memory.advance(60_001)
  graph.reconcile(root, reference, output) |> should.be_ok
  let assert Ok(_) = graph.await(root, within: duration.milliseconds(5000))
  let assert Ok(done) = graph.snapshot(root)
  done.status |> should.equal(graph.Expired(due, graph.ForkSettled(1)))
  done.receipts |> should.equal([])
  probe.count(calls, "accept") |> should.equal(1)
}

pub fn a_failed_join_reconciles_before_deadline_without_repeating_members_test() {
  let memory = conformance.leased_memory()
  let calls = probe.new()
  let runs = nodes.node(memory.backend, "corrected-join", 300_000)
  let runtime =
    parent_with(
      runs,
      action(runs, fn(n) {
        probe.record(calls, "member")
        Ok(n)
      }),
      fn(state, output) {
        probe.record(calls, "accept")
        case probe.count(calls, "accept"), output {
          1, _ -> Error("join needs correction")
          _, Ok(values) -> Ok(definition.Finish(state, values))
          _, Error(failure) -> Error(failure.reason)
        }
      },
    )
  let assert Ok(root) =
    graph.start(
      runtime,
      support.id("corrected-fork-join"),
      [1, 2],
      correlation: None,
    )
  let assert Ok(_) = graph.await(root, within: duration.milliseconds(5000))
  let assert Ok(blocked) = graph.snapshot(root)
  let assert graph.Blocked(reference, graph.InvalidResult(output, _)) =
    blocked.status
  graph.reconcile(root, reference, output) |> should.be_ok
  let assert Ok(_) = graph.await(root, within: duration.milliseconds(5000))
  let assert Ok(done) = graph.snapshot(root)
  done.status |> should.equal(graph.Completed([1, 2]))
  done.forks |> should.equal(blocked.forks)
  list.length(done.receipts) |> should.equal(1)
  probe.count(calls, "member") |> should.equal(2)
  probe.count(calls, "accept") |> should.equal(2)
}

pub fn a_join_callback_crossing_the_deadline_keeps_results_without_routing_test() {
  let memory = conformance.leased_memory()
  let runs = nodes.node(memory.backend, "join", 300_000)
  let runtime =
    parent_with(runs, action(runs, fn(n) { Ok(n) }), fn(state, _) {
      memory.advance(60_001)
      Ok(definition.Finish(state, [999]))
    })
  let assert Ok(root) =
    graph.start(
      runtime,
      support.id("late-fork-join"),
      [1, 2],
      correlation: None,
    )
  let assert Ok(_) = graph.await(root, within: duration.milliseconds(5000))
  let assert Ok(done) = graph.snapshot(root)
  let assert Some(due) = done.deadline
  done.status |> should.equal(graph.Expired(due, graph.ForkSettled(1)))
  done.receipts |> should.equal([])
  let assert [saved] = done.forks
  list.map(saved.members, fn(member) { member.status })
  |> should.equal([
    fork.Admitted(fork.Succeeded("1")),
    fork.Admitted(fork.Succeeded("2")),
  ])
}

pub fn expired_uncertain_fork_retains_cleanup_and_reconciles_without_replay_test() {
  let memory = conformance.leased_memory()
  let calls = probe.new()
  let runs = nodes.node(memory.backend, "uncertain", 300_000)
  let child =
    action(runs, fn(_) {
      probe.record(calls, "effect")
      Error(tool.Uncertain("effect outcome unknown"))
    })
  let runtime =
    parent_with(runs, child, fn(_, _) { panic as "expired join cannot route" })
  let assert Ok(root) =
    graph.start(
      runtime,
      support.id("uncertain-fork-deadline"),
      [1, 2, 3],
      correlation: None,
    )
  let assert Ok(_) = graph.await(root, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(root)
  let assert Some(due) = waiting.deadline
  let assert graph.Fork(_, _) = waiting.status
  parked(memory.backend, graph.id(root), 3000)
  let started = probe.count(calls, "effect")
  { started > 0 && started <= 2 } |> should.be_true
  memory.advance(60_001)
  graph.recover(root) |> should.be_ok
  let assert Ok(stopping) =
    graph.await(root, within: duration.milliseconds(5000))
  let assert graph.Fork(saved, Some(operation.DeadlineReached(_))) = stopping
  let assert Ok(row) = store_core.get(runs, run.id_to_string(graph.id(root)))
  let assert Ok(metadata) = retention.inspect(row.record)
  metadata.settled |> should.be_false
  let assert Ok(Some(wait)) = discovery.inspect(row.record)
  let assert discovery.Changed(_, None) = wait.trigger
  graph.cancel(root) |> should.be_ok
  list.each(
    list.index_map(saved.members, fn(member, index) { #(member, index + 1) }),
    fn(item) {
      case item.0.status {
        fork.Admitted(fork.Uncertain(_)) -> {
          let assert Ok(branch) = graph.branch(root, 1, item.1, child)
          let assert Ok(stopped) = graph.snapshot(branch)
          let assert graph.Cancelled(graph.Unresolved(reference, _)) =
            stopped.status
          graph.reconcile(branch, reference, "42") |> should.be_ok
          Nil
        }
        _ -> Nil
      }
    },
  )
  graph.recover(root) |> should.be_ok
  let assert Ok(_) = graph.await(root, within: duration.milliseconds(5000))
  let assert Ok(done) = graph.snapshot(root)
  done.status |> should.equal(graph.Expired(due, graph.ForkSettled(1)))
  done.receipts |> should.equal([])
  probe.count(calls, "effect") |> should.equal(started)
}

fn parked(backend: backend.LeasedBackend, id: run.RunId, left: Int) -> Nil {
  case nodes.holder(backend, id), left {
    backend.Free, _ -> Nil
    _, n if n > 0 -> {
      process.sleep(10)
      parked(backend, id, n - 1)
    }
    _, _ -> panic as "fork did not release its lease"
  }
}

pub fn overdue_fork_recovers_the_same_children_and_withdraws_pending_members_test() {
  let memory = conformance.leased_memory()
  let id = support.id("expired-fork")
  let #(owner, #(runs, root)) =
    restart.owned(fn() {
      let runs = nodes.node(memory.backend, "before", 300_000)
      let assert Ok(root) =
        graph.start(parent(runs), id, [1, 2, 3], correlation: None)
      #(runs, root)
    })
  let assert Ok(_) = graph.await(root, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(root)
  let assert graph.Fork(_, _) = waiting.status
  let assert Some(due) = waiting.deadline
  let branches =
    list.map([1, 2], fn(n) {
      let assert Ok(branch) = graph.branch(root, 1, n, leaf(runs))
      graph.id(branch)
    })
  parked(memory.backend, id, 3000)
  restart.crash(owner, runs)
  memory.advance(60_001)
  let runs = nodes.node(memory.backend, "after", 300_000)
  let root = support.open_graph(parent(runs), id)
  let assert Ok(before_recovery) = graph.snapshot(root)
  before_recovery.deadline |> should.equal(Some(due))
  let assert graph.Fork(_, _) = before_recovery.status
  graph.recover(root) |> should.be_ok
  let assert Ok(_) = graph.await(root, within: duration.milliseconds(5000))
  let assert Ok(done) = graph.snapshot(root)
  done.status |> should.equal(graph.Expired(due, graph.ForkSettled(1)))
  done.receipts |> should.equal([])
  let assert [saved] = done.forks
  saved.stop |> should.equal(Some(fork.DeadlineElapsed(due)))
  list.map(saved.members, fn(member) { member.status })
  |> should.equal([
    fork.Admitted(fork.Cancelled),
    fork.Admitted(fork.Cancelled),
    fork.Withdrawn,
  ])
  graph.branch(root, 1, 3, leaf(runs)) |> should.be_error
  list.each(branches, fn(id) {
    let assert Ok(stopped) = graph.snapshot(support.open_graph(leaf(runs), id))
    stopped.status |> should.equal(graph.Cancelled(graph.BeforeStart))
  })
  let assert Ok(row) = store_core.get(runs, run.id_to_string(id))
  let assert Ok(metadata) = retention.inspect(row.record)
  metadata.settled |> should.be_true
  list.map(metadata.children, fn(link) { link.run }) |> should.equal(branches)
}

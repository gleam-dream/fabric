//// G9, F8: parallel dependencies survive store loss in the real database.

import fabric
import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/graph/signal
import fabric/policy
import fabric/run
import fabric/store
import fabric_postgres
import fabric_postgres/agents
import fabric_postgres/support
import gleam/erlang/process
import gleam/list
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn response() -> signal.Signal(Int) {
  signal.new(run.Identity("pg-branch-signal", 1), codec.int())
}

fn leaf(runs: store.Store) -> graph.Runtime(Nil, Int, Int) {
  let assert Ok(id) = definition.node_id("wait")
  let node =
    definition.node(
      id,
      operation.await_signal(codec.int(), response()),
      fn(value) { Ok(value) },
      fn(state, value) { Ok(definition.Finish(state, value)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("pg-branch", 1),
      id,
      [node],
      codec.int(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn mapped(runs: store.Store) -> graph.Runtime(Nil, List(Int), List(Int)) {
  let assert Ok(op) =
    graph.map(
      run.Identity("pg-map", 1),
      leaf(runs),
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
  let values = codec.list(codec.int())
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("pg-parallel", 1),
      id,
      [node],
      values,
      values,
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn start_store(settings: fabric_postgres.Settings) -> store.Store {
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("parallel"), settings)
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn release(backend: store.LeasedBackend, id: String) -> Nil {
  let assert Ok(row) = backend.get(id)
  let assert Ok(_) =
    backend.compare_and_set(id, row.revision, row.record, store.Release)
  Nil
}

fn idle(backend: store.LeasedBackend, id: String, left: Int) -> Nil {
  let assert Ok(row) = backend.get(id)
  case row.holder, left {
    store.Free, _ -> Nil
    _, n if n > 0 -> {
      process.sleep(10)
      idle(backend, id, n - 1)
    }
    _, _ -> panic as "parallel parent did not release its lease"
  }
}

fn await_done(
  handle: graph.Handle(Nil, List(Int), List(Int)),
  left: Int,
) -> graph.Snapshot(List(Int), List(Int)) {
  let assert Ok(snapshot) = graph.read(handle)
  case snapshot.status, left {
    graph.Completed(_), _ -> snapshot
    _, n if n > 0 -> {
      process.sleep(10)
      await_done(handle, n - 1)
    }
    _, _ -> panic as "parallel sweep did not finish"
  }
}

pub fn all_branch_revisions_are_claimed_once_and_swept_after_store_loss_test() {
  let settings = support.migrated(support.pool(8), "parallel", support.schema())
  let backend = fabric_postgres.backend(settings)
  let assert Ok(id) = run.parse_id("pg-parallel")
  let #(owner, _) =
    agents.owned(fn() {
      let runs = start_store(settings)
      let assert Ok(handle) = graph.start(mapped(runs), id, [1, 2, 3])
      let assert Ok(waiting) =
        graph.await(handle, within: duration.milliseconds(5000))
      let assert graph.Fork(_, _) = waiting.status
      Nil
    })
  idle(backend, "pg-parallel", 200)
  agents.kill(owner)
  backend.claim_ready("baseline", 60_000, 10)
  |> should.equal(Ok(["pg-parallel"]))
  release(backend, "pg-parallel")
  backend.claim_ready("unchanged", 60_000, 10) |> should.equal(Ok([]))
  let runs = start_store(settings)
  let root = graph.attach(mapped(runs), id)
  // Changing the last branch must wake the parent even while the first is idle.
  list.each([3, 2], fn(member) {
    let assert Ok(handle) = graph.branch(root, 1, member, leaf(runs))
    let assert Ok(waiting) = graph.read(handle)
    let assert graph.AwaitingSignal(reference) = waiting.status
    let assert Ok(_) = graph.deliver(handle, reference, response(), member * 10)
    let replies = process.new_subject()
    list.each(["scanner-a", "scanner-b"], fn(owner) {
      process.spawn(fn() {
        process.send(replies, backend.claim_ready(owner, 60_000, 1))
      })
    })
    let assert Ok(Ok(a)) = process.receive(replies, 5000)
    let assert Ok(Ok(b)) = process.receive(replies, 5000)
    list.append(a, b) |> should.equal(["pg-parallel"])
    release(backend, "pg-parallel")
    backend.claim_ready("unchanged", 60_000, 10) |> should.equal(Ok([]))
  })
  // The last signal is picked up by registered recovery, with no local watches.
  let assert Ok(first) = graph.branch(root, 1, 1, leaf(runs))
  let assert Ok(waiting) = graph.read(first)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Ok(_) = graph.deliver(first, reference, response(), 10)
  let assert Ok(spec) =
    fabric.sweeper(
      runs,
      [graph.recovery(run.Identity("pg-parallel", 1), mapped)],
      every: duration.milliseconds(20),
    )
  let assert Ok(sweeper) = spec.start()
  let done = await_done(root, 300)
  done.status |> should.equal(graph.Completed([10, 20, 30]))
  idle(backend, "pg-parallel", 200)
  process.unlink(sweeper.pid)
  agents.kill(sweeper.pid)
  fabric_postgres.prune(
    settings,
    ended_for: duration.milliseconds(0),
    limit: 10,
  )
  |> should.equal(Ok(4))
}

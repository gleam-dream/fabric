//// F6–F8: database time and persisted dependencies drive nested fork cleanup.

import fabric/budget
import fabric/graph
import fabric/graph/definition
import fabric/graph/fork
import fabric/graph/operation
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/backend
import fabric/sweeper
import fabric/tool
import fabric_postgres
import fabric_postgres/agents
import fabric_postgres/support
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import pog

fn wrap(runs, name, op, values, accept) {
  let id = definition.node_id("work")
  let node = definition.node(id, op, fn(value) { Ok(value) }, accept, [])
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId(name, 1),
        entry: id,
        nodes: [node],
        state: values,
        answer: values,
      )
      |> definition.with_max_activations(1),
    )
  graph.new(spec, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn leaf(runs, arrivals) {
  wrap(
    runs,
    "pg-fork-effect",
    operation.new(
      run.DefinitionId("uncertain-effect", 1),
      codec.int(),
      codec.int(),
      fn(_, _, _) {
        let release = process.new_subject()
        process.send(arrivals, release)
        process.receive_forever(release)
        Error(tool.Uncertain("external result requires reconciliation"))
      },
      fn(error) { error },
    ),
    codec.int(),
    fn(state, n) { Ok(definition.Finish(state, n)) },
  )
}

fn inner(runs, arrivals) {
  let op =
    graph.map(run.DefinitionId("inner-map", 1), leaf(runs, arrivals), 1, 1)
  wrap(runs, "pg-inner-fork", op, codec.list(codec.int()), fn(state, output) {
    case output {
      Ok(values) -> Ok(definition.Finish(state, values))
      Error(failure) -> Error(failure.reason)
    }
  })
}

fn parent(runs, arrivals) {
  let op =
    graph.map(run.DefinitionId("outer-map", 1), inner(runs, arrivals), 3, 2)
  let op = operation.with_deadline(op, run.After(duration.milliseconds(5000)))
  wrap(
    runs,
    "pg-fork-deadline",
    op,
    codec.list(codec.list(codec.int())),
    fn(_, _) { panic as "expired fork cannot route" },
  )
}

fn start_store(settings) {
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("fork-deadline"), settings)
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn sweep(runs, arrivals) {
  let assert Ok(started) =
    sweeper.start(
      runs,
      [
        sweeper.graph(run.DefinitionId("pg-fork-deadline", 1), fn(runs) {
          parent(runs, arrivals)
        }),
      ],
      every: duration.milliseconds(20),
    )
  started
}

fn idle(
  backend: backend.LeasedBackend,
  ids: List(run.RunId),
  left: Int,
) -> Nil {
  let free =
    list.all(ids, fn(id) {
      let assert Ok(row) = backend.get(run.id_to_string(id))
      row.holder == backend.Free
    })
  case free, left {
    True, _ -> Nil
    False, n if n > 0 -> {
      process.sleep(10)
      idle(backend, ids, n - 1)
    }
    _, _ -> panic as "nested fork leases did not release"
  }
}

fn wait_for(root, settled, left) {
  let assert Ok(snapshot) = graph.snapshot(root)
  case snapshot.status, settled, left {
    graph.Expired(_, graph.ForkSettled(_)), True, _ -> snapshot
    graph.Fork(saved, Some(operation.DeadlineReached(_))), False, _ -> {
      case list.take(saved.members, 2) {
        [
          fork.Member(_, fork.Admitted(fork.Uncertain(_))),
          fork.Member(_, fork.Admitted(fork.Uncertain(_))),
        ] -> snapshot
        _ if left > 0 -> {
          process.sleep(10)
          wait_for(root, settled, left - 1)
        }
        _ -> panic as "nested uncertainty did not settle into its parent"
      }
    }
    _, _, n if n > 0 -> {
      process.sleep(10)
      wait_for(root, settled, n - 1)
    }
    _, _, _ -> panic as "nested fork expiration did not settle"
  }
}

pub fn nested_expiration_recovers_after_two_store_losses_without_effect_replay_test() {
  let connection = support.pool(8)
  let settings = support.migrated(connection, "fork-deadline", support.schema())
  let backend = fabric_postgres.backend(settings)
  let arrivals = process.new_subject()
  let assert Ok(id) = run.parse_id("pg-fork-deadline")
  let #(owner, #(runs, root)) =
    agents.owned(fn() {
      let runs = start_store(settings)
      let assert Ok(root) =
        graph.start(
          graph.with_family_budget(
            parent(runs, arrivals),
            budget.limits(work: 5)
              |> budget.with_children(4)
              |> budget.with_depth(2),
          ),
          id,
          [[1], [2], [3]],
          correlation: None,
        )
      #(runs, root)
    })
  // Both external effects must start before either becomes uncertain.
  let assert Ok(first) = process.receive(arrivals, 30_000)
  let assert Ok(second) = process.receive(arrivals, 30_000)
  process.send(first, Nil)
  process.send(second, Nil)
  let assert Ok(waiting) = graph.await(root, within: duration.seconds(30))
  let assert graph.Fork(_, _) = waiting.status
  let assert Some(due) = waiting.deadline
  let members =
    list.map([1, 2], fn(ordinal) {
      let assert Ok(inner) =
        graph.branch(root, 1, ordinal, inner(runs, arrivals))
      let assert Ok(leaf) = graph.branch(inner, 1, 1, leaf(runs, arrivals))
      #(graph.id(inner), graph.id(leaf))
    })
  let ids = [id, ..list.flat_map(members, fn(member) { [member.0, member.1] })]
  idle(backend, ids, 3000)
  agents.kill(owner)
  // Establish dependency baselines without changing execution bytes; releasing
  // each claim advances its revision, so ancestors need one later observation.
  list.each([1, 2, 3], fn(_) {
    let assert Ok(claimed) = backend.claim_ready("baseline", 60_000, 10)
    list.each(claimed, fn(id) {
      let assert Ok(row) = backend.get(id)
      backend.compare_and_set(id, row.revision, row.record, backend.Release)
      |> should.be_ok
    })
  })
  backend.claim_ready("early", 60_000, 10) |> should.equal(Ok([]))
  let assert Ok(_) =
    pog.query(
      "SELECT true FROM pg_sleep(GREATEST(0, ($1::bigint - floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint)::double precision / 1000.0) + 0.02)",
    )
    |> pog.parameter(pog.int(due))
    |> pog.timeout(30_000)
    |> pog.execute(connection)
  let #(cleanup_owner, cleanup_runs) =
    agents.owned(fn() {
      let runs = start_store(settings)
      let _ = sweep(runs, arrivals)
      runs
    })
  let root = open_graph(parent(cleanup_runs, arrivals), id)
  let stopping = wait_for(root, False, 3000)
  let assert graph.Fork(saved, Some(operation.DeadlineReached(saved_due))) =
    stopping.status
  saved_due |> should.equal(due)
  list.last(saved.members)
  |> should.equal(
    Ok(fork.Member(
      fork.Request(run.DefinitionId("pg-inner-fork", 1), "[3]"),
      fork.Withdrawn,
    )),
  )
  fabric_postgres.prune(
    settings,
    ended_for: duration.milliseconds(0),
    limit: 10,
  )
  |> should.equal(Ok(0))
  process.sleep(100)
  idle(backend, ids, 3000)
  backend.claim_ready("not-again", 60_000, 10) |> should.equal(Ok([]))
  agents.kill(cleanup_owner)
  // Reconcile through another store after all original cleanup watches are gone.
  let runs = start_store(settings)
  list.each(members, fn(member) {
    let leaf = open_graph(leaf(runs, arrivals), member.1)
    let assert Ok(stopped) = graph.snapshot(leaf)
    let assert graph.Cancelled(graph.Unresolved(reference, _)) = stopped.status
    graph.reconcile(leaf, reference, "42") |> should.be_ok
  })
  let started = sweep(runs, arrivals)
  let root = open_graph(parent(runs, arrivals), id)
  let done = wait_for(root, True, 3000)
  done.status |> should.equal(graph.Expired(due, graph.ForkSettled(1)))
  done.receipts |> should.equal([])
  graph.branch(root, 1, 3, inner(runs, arrivals)) |> should.be_error
  process.receive(arrivals, 0) |> should.be_error
  idle(backend, ids, 3000)
  process.unlink(started)
  agents.kill(started)
  fabric_postgres.prune(
    settings,
    ended_for: duration.milliseconds(0),
    limit: 10,
  )
  |> should.equal(Ok(6))
}

fn open_graph(
  runtime: graph.Runtime(context, state, answer),
  id: run.RunId,
) -> graph.Handle(context, state, answer) {
  let assert Ok(handle) = graph.open(runtime, id)
  handle
}

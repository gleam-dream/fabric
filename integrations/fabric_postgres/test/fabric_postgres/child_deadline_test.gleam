//// D14–D18: database discovery expires a child and retains uncertain cleanup.

import fabric/budget
import fabric/graph
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/operation
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/backend
import fabric/sweeper
import fabric_postgres
import fabric_postgres/agents
import fabric_postgres/support
import gleam/erlang/process
import gleam/option.{Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import pog

fn runtime(runs, identity, op) {
  let assert Ok(id) = definition.node_id("work")
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId(identity, 1),
      id,
      [
        definition.node(
          id,
          op,
          fn(n) { Ok(n) },
          fn(_, n) { Ok(definition.Finish(n, n)) },
          [],
        ),
      ],
      codec.int(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn leaf(runs) {
  runtime(
    runs,
    "pg-uncertain-child",
    operation.new(
      run.DefinitionId("uncertain-effect", 1),
      codec.int(),
      codec.int(),
      fn(_, _, _) {
        Error(operation.UncertainEffect("effect requires reconciliation"))
      },
      fn(error) { error },
    ),
  )
}

fn parent(runs) {
  let assert Ok(op) =
    graph.as_subgraph(leaf(runs))
    |> operation.with_deadline(duration.milliseconds(2000))
  runtime(runs, "pg-child-deadline", op)
}

fn start_store(settings) {
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("child-deadline"), settings)
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn sweep(runs) {
  let assert Ok(started) =
    sweeper.start(
      runs,
      [sweeper.graph(run.DefinitionId("pg-child-deadline", 1), parent)],
      every: duration.milliseconds(20),
    )
  started
}

fn idle(backend: backend.LeasedBackend, remaining: Int) {
  let assert Ok(row) = backend.get("pg-child-deadline")
  case row.holder, remaining {
    backend.Free, _ -> Nil
    _, n if n > 0 -> {
      process.sleep(10)
      idle(backend, n - 1)
    }
    _, _ -> panic as "parent lease not released"
  }
}

fn wait_for(handle, settled, remaining) {
  let assert Ok(snapshot) = graph.read(handle)
  case snapshot.status, settled, remaining {
    graph.Expired(_, graph.ChildUnresolved(..)), False, _ -> snapshot
    graph.Expired(_, graph.ChildSettled(_)), True, _ -> snapshot
    _, _, n if n > 0 -> {
      process.sleep(10)
      wait_for(handle, settled, n - 1)
    }
    _, _, _ -> panic as "child deadline did not settle"
  }
}

pub fn unchanged_children_expire_after_restart_and_remain_retained_until_reconciled_test() {
  let connection = support.pool(4)
  let settings =
    support.migrated(connection, "child-deadline", support.schema())
  let backend = fabric_postgres.backend(settings)
  let assert Ok(id) = run.parse_id("pg-child-deadline")
  let #(owner, #(waiting, reference)) =
    agents.owned(fn() {
      let runs = start_store(settings)
      let assert Ok(handle) =
        graph.start_with_budget(parent(runs), id, 41, budget.Limits(2, 1, 1))
      let assert Ok(waiting) =
        graph.await(handle, within: duration.milliseconds(5000))
      let assert graph.Child(child_ref, child.Uncertain(_)) = waiting.status
      let assert Ok(child_handle) =
        graph.child(handle, child_ref.activation, leaf(runs))
      let assert Ok(blocked) = graph.read(child_handle)
      let assert graph.Blocked(reference, _) = blocked.status
      // Observe the initial dependency before its unchanged deadline becomes due.
      let _ = sweep(runs)
      process.sleep(100)
      idle(backend, 300)
      backend.claim_ready("early", 60_000, 10) |> should.equal(Ok([]))
      #(waiting, reference)
    })
  let assert Some(due) = waiting.deadline
  let assert graph.Child(child_ref, _) = waiting.status
  agents.kill(owner)
  let assert Ok(_) =
    pog.query(
      "SELECT true FROM pg_sleep(GREATEST(0, ($1::bigint - floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint)::double precision / 1000.0) + 0.02)",
    )
    |> pog.parameter(pog.int(due))
    |> pog.execute(connection)
  let runs = start_store(settings)
  let started = sweep(runs)
  let handle = graph.attach(parent(runs), id)
  let expired = wait_for(handle, False, 500)
  let assert graph.Expired(saved_due, graph.ChildUnresolved(saved_child, _)) =
    expired.status
  saved_due |> should.equal(due)
  saved_child |> should.equal(child_ref)
  fabric_postgres.prune(
    settings,
    ended_for: duration.milliseconds(0),
    limit: 10,
  )
  |> should.equal(Ok(0))
  // Once the settlement dependency is observed, an expired timestamp cannot spin.
  process.sleep(100)
  idle(backend, 300)
  backend.claim_ready("not-again", 60_000, 10) |> should.equal(Ok([]))
  let assert Ok(child_handle) =
    graph.child(handle, child_ref.activation, leaf(runs))
  let assert Ok(_) = graph.reconcile(child_handle, reference, "42")
  let done = wait_for(handle, True, 500)
  done.status |> should.equal(graph.Expired(due, graph.ChildSettled(child_ref)))
  done.value |> should.equal(41)
  done.receipts |> should.equal([])
  process.unlink(started)
  agents.kill(started)
  idle(backend, 300)
  fabric_postgres.prune(
    settings,
    ended_for: duration.milliseconds(0),
    limit: 10,
  )
  |> should.equal(Ok(3))
}

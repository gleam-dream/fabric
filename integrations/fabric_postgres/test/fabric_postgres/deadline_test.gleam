//// D4–D8: the real database discovers overdue signals after process loss.

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
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import pog

fn runtime(runs) {
  let assert Ok(node) = definition.node_id("answer")
  let assert Ok(wait) =
    operation.await_signal(
      codec.int(),
      signal.new(run.Identity("answer", 1), codec.bool()),
    )
    |> operation.with_deadline(duration.milliseconds(2000))
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("pg-deadline", 1),
      node,
      [
        definition.node(
          node,
          wait,
          fn(n) { Ok(n) },
          fn(n, _) { Ok(definition.Finish(n, n)) },
          [],
        ),
      ],
      codec.int(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

pub fn overdue_signal_is_swept_after_store_loss_and_can_be_pruned_test() {
  let connection = support.pool(4)
  let settings = support.migrated(connection, "deadline", support.schema())
  let backend = fabric_postgres.backend(settings)
  let assert Ok(id) = run.parse_id("pg-deadline-run")
  let #(owner, waiting) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("deadline-original"), settings)
      let assert Ok(Nil) = store.start(runs)
      let assert Ok(handle) = graph.start(runtime(runs), id, 7)
      let assert Ok(waiting) =
        graph.await(handle, within: duration.milliseconds(5000))
      let assert graph.AwaitingSignal(_) = waiting.status
      let assert Ok(row) = store.get(runs, run.id_to_string(id))
      row.live |> should.equal(None)
      waiting
    })
  let assert Some(due) = waiting.deadline
  let assert Ok(before) = backend.get(run.id_to_string(id))
  backend.claim_ready("early", 60_000, 5) |> should.equal(Ok([]))
  fabric_postgres.refresh_discovery(settings, 10) |> should.equal(Ok(0))
  backend.get(run.id_to_string(id)) |> should.equal(Ok(before))
  agents.kill(owner)
  // Wait against database time, without editing the execution or its projection.
  let assert Ok(_) =
    pog.query(
      "SELECT true FROM pg_sleep(GREATEST(0, ($1::bigint - floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint)::double precision / 1000.0) + 0.02)",
    )
    |> pog.parameter(pog.int(due))
    |> pog.execute(connection)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("deadline-restored"), settings)
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(spec) =
    fabric.sweeper(
      runs,
      [graph.recovery(run.Identity("pg-deadline", 1), runtime)],
      every: duration.milliseconds(60_000),
    )
  let assert Ok(started) = spec.start()
  let expired = await_expired(graph.attach(runtime(runs), id), 300)
  process.unlink(started.pid)
  agents.kill(started.pid)
  expired.status |> should.equal(graph.Failed(graph.DeadlineExpired(due)))
  expired.receipts |> should.equal([])
  let assert Ok(row) = backend.get(run.id_to_string(id))
  row.holder |> should.equal(store.Free)
  backend.claim_ready("after", 60_000, 5) |> should.equal(Ok([]))
  fabric_postgres.prune(settings, ended_for: duration.milliseconds(0), limit: 1)
  |> should.equal(Ok(1))
}

fn await_expired(handle, remaining) {
  let assert Ok(snapshot) = graph.read(handle)
  case snapshot.status, remaining {
    graph.Failed(graph.DeadlineExpired(_)), _ -> snapshot
    _, n if n > 0 -> {
      process.sleep(10)
      await_expired(handle, n - 1)
    }
    _, _ -> panic as "sweeper did not expire the signal"
  }
}

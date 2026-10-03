//// S7 O6–O11: aggregate real database state without changing execution.

import fabric
import fabric/budget
import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/graph/signal
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/backend
import fabric_postgres
import fabric_postgres/agents
import fabric_postgres/statistics
import fabric_postgres/support
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import pog

pub fn an_empty_database_has_zero_counts_and_no_invented_ages_test() {
  use connection <- support.using_pool(1)
  let settings = support.migrated(connection, "stats", support.schema())
  let assert Ok(report) = fabric_postgres.stats(settings)
  report.working.count |> should.equal(0)
  report.working.oldest_record_age_ms |> should.equal(None)
  report.unattended.count |> should.equal(0)
  report.approval.count |> should.equal(0)
  report.reconciliation.count |> should.equal(0)
  report.unknown.count |> should.equal(0)
  report.budget_records |> should.equal(0)
  report.leases_per_node |> should.equal([])
  report.expired_leases.oldest_overdue_ms |> should.equal(None)
}

fn started(settings: fabric_postgres.Settings) -> store.Store {
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("stats"), settings)
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn execute(connection: pog.Connection, sql: String) -> Nil {
  let assert Ok(_) = pog.query(sql) |> pog.execute(connection)
  Nil
}

fn durable(connection: pog.Connection, schema: String) -> String {
  let assert Ok(found) =
    pog.query(
      "SELECT coalesce(jsonb_agg(jsonb_build_array(run_id, revision, record, lease_owner, lease_until, updated_at) ORDER BY run_id), '[]'::jsonb)::text FROM "
      <> schema
      <> ".fabric_runs",
    )
    |> pog.returning(decode.field(0, decode.string, decode.success))
    |> pog.execute(connection)
  let assert [value] = found.rows
  value
}

pub fn counts_follow_real_runs_and_lease_backlog_without_mutation_test() {
  use connection <- support.using_pool(4)
  let schema = support.schema()
  let settings = support.migrated(connection, "active", schema)
  let runs = started(settings)
  let backend = fabric_postgres.backend(settings)
  let gate = agents.gate()
  let assert Ok(working) =
    fabric.start(
      runs,
      agents.agent(gate, 1),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let working_body = agents.arrival(gate)
  let assert Ok(approval) =
    fabric.start(
      runs,
      agents.agent(gate, 500),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([_], [])) =
    fabric.await(approval, within: duration.milliseconds(5000))
  let assert Ok(finished) =
    fabric.start(
      runs,
      agents.agent(gate, 2),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  agents.release(agents.arrival(gate))
  let assert Ok(run.Finished(_)) =
    fabric.await(finished, within: duration.milliseconds(5000))
  let assert Ok(uncertain) =
    fabric.start(
      runs,
      agents.agent(gate, 3),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  agents.kill(agents.arrival(gate).body)
  let assert Ok(run.Suspended([], [_])) =
    fabric.await(uncertain, within: duration.milliseconds(5000))
  let #(owner, lost) =
    agents.owned(fn() {
      let settings = support.migrated(connection, "lost", schema)
      let runs = started(settings)
      let assert Ok(lost) =
        fabric.start(
          runs,
          agents.agent(gate, 4),
          id: run.new_id(),
          context: Nil,
          prompt: "go",
          correlation: None,
        )
      fabric.id(lost)
    })
  let _ = agents.arrival(gate)
  agents.kill(owner)
  // Move database time evidence at the storage boundary; no live lost-node
  // process remains to renew this lease.
  let assert Ok(_) =
    pog.query(
      "UPDATE "
      <> schema
      <> ".fabric_runs SET lease_until = clock_timestamp() - interval '3 seconds' WHERE run_id = $1",
    )
    |> pog.parameter(pog.text(run.id_to_string(lost)))
    |> pog.execute(connection)
  let assert Ok(Nil) =
    backend.insert(
      "unknown-live",
      "{}",
      backend.Claim("other/store/one", 60_000),
    )
  let assert Ok(Nil) =
    backend.insert("unknown-expired", "{}", backend.Claim("old/store/one", 0))
  execute(
    connection,
    "UPDATE "
      <> schema
      <> ".fabric_runs SET updated_at = clock_timestamp() - interval '2 seconds'",
  )
  let before = durable(connection, schema)
  let assert Ok(report) = fabric_postgres.stats(settings)
  report.working.count |> should.equal(1)
  report.unattended.count |> should.equal(1)
  report.waiting.count |> should.equal(2)
  report.finished.count |> should.equal(1)
  report.approval.count |> should.equal(1)
  report.reconciliation.count |> should.equal(1)
  report.unknown.count |> should.equal(2)
  report.budget_records |> should.equal(0)
  report.leases_per_node
  |> should.equal([
    statistics.NodeLeases("active", 1),
    statistics.NodeLeases("other", 1),
  ])
  report.expired_leases.count |> should.equal(2)
  let assert Some(overdue) = report.expired_leases.oldest_overdue_ms
  should.be_true(overdue >= 3000)
  list.each(
    [
      report.working,
      report.unattended,
      report.waiting,
      report.finished,
      report.approval,
      report.reconciliation,
      report.unknown,
    ],
    fn(group) {
      let assert Some(age) = group.oldest_record_age_ms
      should.be_true(age >= 2000)
    },
  )
  durable(connection, schema) |> should.equal(before)
  let assert Ok(_) = fabric.cancel(uncertain)
  let assert Ok(after_cancel) = fabric_postgres.stats(settings)
  after_cancel.reconciliation.count |> should.equal(1)
  after_cancel.finished.count |> should.equal(2)
  agents.release(working_body)
  let assert Ok(_) = fabric.await(working, within: duration.milliseconds(5000))
}

pub fn stale_statistics_are_unknown_until_explicit_refresh_and_keep_record_age_test() {
  use connection <- support.using_pool(2)
  let schema = support.schema()
  let settings = support.migrated(connection, "refresh", schema)
  let runs = started(settings)
  let assert Ok(waiting) =
    fabric.start(
      runs,
      agents.agent(agents.gate(), 500),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([_], [])) =
    fabric.await(waiting, within: duration.milliseconds(5000))
  let backend = fabric_postgres.backend(settings)
  let assert Ok(Nil) = backend.insert("broken", "not-json", backend.Release)
  execute(
    connection,
    "UPDATE "
      <> schema
      <> ".fabric_runs SET statistics = NULL, statistics_revision = NULL, updated_at = clock_timestamp() - interval '5 seconds'",
  )
  let before = durable(connection, schema)
  let assert Ok(stale) = fabric_postgres.stats(settings)
  stale.unknown.count |> should.equal(2)
  stale.approval.count |> should.equal(0)
  fabric_postgres.refresh_statistics(settings, 0)
  |> should.equal(Error(fabric_postgres.RefreshLimitNotPositive(0)))
  fabric_postgres.refresh_statistics(settings, 1) |> should.equal(Ok(1))
  fabric_postgres.refresh_statistics(settings, 1) |> should.equal(Ok(1))
  fabric_postgres.refresh_statistics(settings, 1) |> should.equal(Ok(0))
  let assert Ok(fresh) = fabric_postgres.stats(settings)
  fresh.unknown.count |> should.equal(1)
  fresh.approval.count |> should.equal(1)
  let assert Some(age) = fresh.approval.oldest_record_age_ms
  should.be_true(age >= 5000)
  durable(connection, schema) |> should.equal(before)
  execute(
    connection,
    "UPDATE " <> schema <> ".fabric_runs SET statistics_revision = revision - 1",
  )
  let assert Ok(stale) = fabric_postgres.stats(settings)
  stale.unknown.count |> should.equal(2)
  execute(
    connection,
    "UPDATE "
      <> schema
      <> ".fabric_runs SET statistics_revision = revision, statistics = jsonb_set(statistics, '{version}', '0')",
  )
  let assert Ok(stale) = fabric_postgres.stats(settings)
  stale.unknown.count |> should.equal(2)
  fabric_postgres.refresh_statistics(settings, 10) |> should.equal(Ok(2))
  durable(connection, schema) |> should.equal(before)
}

pub fn a_graph_wait_is_neither_unattended_work_nor_a_budget_run_test() {
  use connection <- support.using_pool(2)
  let settings = support.migrated(connection, "graph", support.schema())
  let runs = started(settings)
  let signal = signal.new(run.DefinitionId("answer", 1), codec.bool())
  let assert Ok(node) = definition.node_id("wait")
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId("stats-graph", 1),
      node,
      [
        definition.node(
          node,
          operation.await_signal(codec.int(), signal),
          fn(n) { Ok(n) },
          fn(n, answer) { Ok(definition.Finish(n, answer)) },
          [],
        ),
      ],
      codec.int(),
      codec.bool(),
      1,
    ))
  let runtime =
    graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(id) = run.parse_id("graph-stats")
  let assert Ok(handle) =
    graph.start_with_budget(runtime, id, 1, budget.Limits(1, 1, 1))
  let assert Ok(snapshot) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingSignal(reference) = snapshot.status
  let assert Ok(waiting) = fabric_postgres.stats(settings)
  waiting.waiting.count |> should.equal(1)
  waiting.unattended.count |> should.equal(0)
  waiting.budget_records |> should.equal(1)
  waiting.unknown.count |> should.equal(0)
  let assert Ok(_) = graph.deliver(handle, reference, signal, True)
  let assert Ok(finished) = fabric_postgres.stats(settings)
  finished.waiting.count |> should.equal(0)
  finished.finished.count |> should.equal(1)
  finished.budget_records |> should.equal(1)
}

pub fn statistics_errors_never_become_zero_counts_test() {
  use connection <- support.using_pool(1)
  let assert Ok(settings) =
    fabric_postgres.settings(connection, node: "absent")
    |> fabric_postgres.with_schema(support.schema())
  let assert Error(fabric_postgres.StatsFailed(_)) =
    fabric_postgres.stats(settings)
  let assert Error(fabric_postgres.RefreshFailed(_)) =
    fabric_postgres.refresh_statistics(settings, 1)
}

pub fn a_concurrent_write_and_refresh_leave_current_statistics_test() {
  use connection <- support.using_pool(2)
  let schema = support.schema()
  let settings = support.migrated(connection, "race", schema)
  let runs = started(settings)
  let assert Ok(waiting) =
    fabric.start(
      runs,
      agents.agent(agents.gate(), 500),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([_], [])) =
    fabric.await(waiting, within: duration.milliseconds(5000))
  let backend = fabric_postgres.backend(settings)
  let id = run.id_to_string(fabric.id(waiting))
  let assert Ok(before) = backend.get(id)
  execute(
    connection,
    "UPDATE " <> schema <> ".fabric_runs SET statistics = NULL",
  )
  let results = process.new_subject()
  process.spawn(fn() {
    let assert Ok(_) = fabric_postgres.refresh_statistics(settings, 10)
    process.send(results, Nil)
  })
  process.spawn(fn() {
    let assert Ok(Nil) =
      backend.compare_and_set(
        id,
        before.revision,
        before.record,
        backend.Release,
      )
    process.send(results, Nil)
  })
  let assert Ok(Nil) = process.receive(results, 5000)
  let assert Ok(Nil) = process.receive(results, 5000)
  let assert Ok(report) = fabric_postgres.stats(settings)
  report.unknown.count |> should.equal(0)
  report.approval.count |> should.equal(1)
  fabric_postgres.refresh_statistics(settings, 10) |> should.equal(Ok(0))
}

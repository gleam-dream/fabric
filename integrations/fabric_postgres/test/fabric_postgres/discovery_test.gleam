//// G7: migrated discovery is derived metadata; it never changes executions.

import fabric/graph
import fabric/graph/child
import fabric/graph/job
import fabric/run
import fabric/store
import fabric_postgres
import fabric_postgres/graph_run_test
import fabric_postgres/internal/migrations
import fabric_postgres/support
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleeunit/should
import pog

fn table(schema) {
  "\"" <> schema <> "\".fabric_runs"
}

fn waiting_family() {
  let runs = store.in_memory(process.new_name("discovery-fixture"))
  let assert Ok(Nil) = store.start(runs)
  let #(parent, _) = graph_run_test.managed_pair(runs)
  let assert Ok(id) = run.parse_id("migration-parent")
  let assert Ok(handle) = graph.start(parent, id, 41)
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.Child(reference, child.Approval(_)) = waiting.status
  let row = await_parked(runs, run.id_to_string(id), 200)
  let assert Ok(child) = store.get(runs, run.id_to_string(reference.child))
  [
    #(run.id_to_string(id), row.record),
    #(run.id_to_string(reference.child), child.record),
  ]
}

fn await_parked(runs, id, left) {
  let assert Ok(row) = store.get(runs, id)
  case row.live, left {
    None, _ -> row
    _, n if n > 0 -> {
      process.sleep(10)
      await_parked(runs, id, n - 1)
    }
    _, _ -> panic as "fixture did not park"
  }
}

fn executions(connection, table) {
  let assert Ok(rows) =
    pog.query(
      "SELECT json_build_array(run_id,record,revision,lease_owner,lease_until,updated_at)::text FROM "
      <> table
      <> " ORDER BY run_id",
    )
    |> pog.returning(decode.field(0, decode.string, decode.success))
    |> pog.execute(connection)
  rows.rows
}

pub fn migration_and_refresh_preserve_execution_data_and_refuse_stale_indexes_test() {
  let connection = support.pool(4)
  let schema = support.schema()
  let assert Ok(settings) =
    fabric_postgres.settings(connection, "refresh")
    |> fabric_postgres.with_schema(schema)
  let assert [first, second, ..] = migrations.all()
  let assert Ok(_) =
    pog.transaction(connection, fn(connection) {
      use _ <- result.try(
        pog.query("CREATE SCHEMA \"" <> schema <> "\"")
        |> pog.execute(connection),
      )
      use _ <- result.try(
        pog.query("SET LOCAL search_path TO \"" <> schema <> "\"")
        |> pog.execute(connection),
      )
      list.try_each(list.append(first.statements, second.statements), fn(sql) {
        pog.query(sql) |> pog.execute(connection) |> result.replace(Nil)
      })
    })
  let table = table(schema)
  list.each([#("unknown", "not json"), ..waiting_family()], fn(row) {
    let assert Ok(_) =
      pog.query(
        "INSERT INTO "
        <> table
        <> " (run_id,revision,record,lease_owner,lease_until) VALUES ($1,1,$2,'legacy',clock_timestamp()+interval '1 hour')",
      )
      |> pog.parameter(pog.text(row.0))
      |> pog.parameter(pog.text(row.1))
      |> pog.execute(connection)
  })
  let before = executions(connection, table)
  fabric_postgres.migrate(settings) |> should.equal(Ok(Nil))
  let backend = fabric_postgres.backend(settings)
  backend.claim_ready("scanner", 60_000, 10) |> should.equal(Ok([]))
  fabric_postgres.refresh_discovery(settings, 0)
  |> should.equal(Error(fabric_postgres.RefreshLimitNotPositive(0)))
  fabric_postgres.refresh_discovery(settings, 1) |> should.equal(Ok(1))
  fabric_postgres.refresh_discovery(settings, 10) |> should.equal(Ok(2))
  fabric_postgres.refresh_discovery(settings, 10) |> should.equal(Ok(0))
  executions(connection, table) |> should.equal(before)
  backend.claim_ready("scanner", 60_000, 10) |> should.equal(Ok([]))
  let assert Ok(_) =
    pog.query("UPDATE " <> table <> " SET lease_owner=NULL,lease_until=NULL")
    |> pog.execute(connection)
  backend.claim_ready("scanner", 60_000, 10)
  |> should.equal(Ok(["migration-parent"]))
  // An older writer changes execution revision but cannot maintain the index.
  let assert Ok(_) =
    pog.query(
      "UPDATE "
      <> table
      <> " SET revision=revision+1,lease_owner=NULL,lease_until=NULL WHERE run_id='migration-parent'",
    )
    |> pog.execute(connection)
  backend.claim_ready("scanner", 60_000, 10) |> should.equal(Ok([]))
  let before = executions(connection, table)
  fabric_postgres.refresh_discovery(settings, 10) |> should.equal(Ok(1))
  executions(connection, table) |> should.equal(before)
  backend.claim_ready("scanner", 60_000, 10)
  |> should.equal(Ok(["migration-parent"]))
  fabric_postgres.refresh_discovery(settings, 10) |> should.equal(Ok(0))
}

pub fn concurrent_refresh_batches_examine_each_stale_row_once_test() {
  let connection = support.pool(8)
  let schema = support.schema()
  let settings = support.migrated(connection, "refresh", schema)
  let backend = fabric_postgres.backend(settings)
  list.each([1, 2, 3, 4, 5, 6, 7, 8], fn(n) {
    backend.insert("unknown-" <> int.to_string(n), "not json", store.Release)
    |> should.be_ok
  })
  let table = table(schema)
  let assert Ok(_) =
    pog.query("UPDATE " <> table <> " SET discovery=NULL")
    |> pog.execute(connection)
  let before = executions(connection, table)
  let replies = process.new_subject()
  list.each([1, 2, 3, 4], fn(_) {
    process.spawn(fn() {
      process.send(replies, fabric_postgres.refresh_discovery(settings, 2))
    })
  })
  list.map([1, 2, 3, 4], fn(_) {
    let assert Ok(Ok(count)) = process.receive(replies, 5000)
    count
  })
  |> should.equal([2, 2, 2, 2])
  fabric_postgres.refresh_discovery(settings, 10) |> should.equal(Ok(0))
  executions(connection, table) |> should.equal(before)
  backend.claim_ready("scanner", 60_000, 10) |> should.equal(Ok([]))
}

pub fn refreshing_a_scheduled_wait_preserves_its_last_claim_time_test() {
  let connection = support.pool(4)
  let schema = support.schema()
  let settings = support.migrated(connection, "poll-refresh", schema)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("poll-refresh"), settings)
  let assert Ok(Nil) = store.start(runs)
  let runtime =
    graph_run_test.scheduled_job(runs, 60_000, fn(_) { Ok(job.Pending) })
  let assert Ok(id) = run.parse_id("refresh-poll")
  let assert Ok(handle) = graph.start(runtime, id, "receipt")
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingJob(_) = waiting.status
  let backend = fabric_postgres.backend(settings)
  backend.claim_ready("poller", 60_000, 1) |> should.equal(Ok(["refresh-poll"]))
  let assert Ok(row) = backend.get("refresh-poll")
  backend.compare_and_set(
    "refresh-poll",
    row.revision,
    row.record,
    store.Release,
  )
  |> should.be_ok
  let table = table(schema)
  let assert Ok(_) =
    pog.query(
      "UPDATE "
      <> table
      <> " SET revision=revision+1 WHERE run_id='refresh-poll'",
    )
    |> pog.execute(connection)
  let before = executions(connection, table)
  fabric_postgres.refresh_discovery(settings, 10) |> should.equal(Ok(1))
  executions(connection, table) |> should.equal(before)
  backend.claim_ready("poller-again", 60_000, 1) |> should.equal(Ok([]))
}

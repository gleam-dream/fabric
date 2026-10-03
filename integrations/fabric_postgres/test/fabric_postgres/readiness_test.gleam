//// S7 O1/O5: a real table read is required and it leaves durable work alone.

import fabric/store
import fabric/store/backend
import fabric_postgres
import fabric_postgres/support
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/option.{None}
import gleeunit/should
import pog

pub fn readiness_requires_a_migrated_store_and_leaves_records_untouched_test() {
  let connection = support.pool(4)
  let schema = support.schema()
  let assert Ok(settings) =
    fabric_postgres.settings(connection, node: "ready")
    |> fabric_postgres.with_schema(schema)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("readiness"), settings)
  let assert Ok(Nil) = store.start(runs)
  let assert Error(backend.Unavailable(_)) = store.readiness(runs)
  let assert Ok(Nil) = fabric_postgres.migrate(settings)
  let backend = fabric_postgres.backend(settings)
  let assert Ok(Nil) =
    backend.insert("kept", "record", backend.Claim("owner", 60_000))
  let assert Ok(before) = backend.get("kept")
  store.readiness(runs)
  |> should.equal(
    Ok(store.Readiness(store.Accepting, 0, store.Leased(30_000, None))),
  )
  backend.get("kept") |> should.equal(Ok(before))
  let assert Ok(count) =
    pog.query("SELECT count(*) FROM " <> schema <> ".fabric_runs")
    |> pog.returning(decode.field(0, decode.int, decode.success))
    |> pog.execute(connection)
  count.rows |> should.equal([1])
}

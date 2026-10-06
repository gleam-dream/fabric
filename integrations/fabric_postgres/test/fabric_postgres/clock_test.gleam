//// Persisted deadline time uses the database's UTC epoch.

import fabric/store
import fabric/store/backend
import fabric_postgres
import fabric_postgres/support
import gleam/dynamic/decode
import gleam/erlang/process
import gleeunit/should
import pog

fn database_now(connection: pog.Connection) -> Int {
  let assert Ok(answer) =
    pog.query(
      "SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint",
    )
    |> pog.returning(decode.field(0, decode.int, decode.success))
    |> pog.execute(connection)
  let assert [now] = answer.rows
  now
}

pub fn stores_read_database_time_without_changing_execution_records_test() {
  let connection = support.pool(4)
  let settings = support.migrated(connection, "clock", support.schema())
  let backend = fabric_postgres.backend(settings)
  let assert Ok(Nil) =
    backend.insert("clock-row", "unchanged", backend.Claim("owner", 60_000))
  let assert Ok(row) = backend.get("clock-row")
  let assert Ok(first) =
    fabric_postgres.store(process.new_name("first-clock"), settings)
  let assert Ok(Nil) = store.start(first)
  let before = database_now(connection)
  let assert Ok(observed) = store.now(first)
  let after = database_now(connection)
  should.be_true(observed >= before && observed <= after)
  should.be_true(observed > 946_684_800_000)
  let assert Ok(second) =
    fabric_postgres.store(process.new_name("second-clock"), settings)
  let assert Ok(Nil) = store.start(second)
  let before = database_now(connection)
  let assert Ok(observed) = store.now(second)
  let after = database_now(connection)
  should.be_true(observed >= before && observed <= after)
  backend.get("clock-row") |> should.equal(Ok(row))
}

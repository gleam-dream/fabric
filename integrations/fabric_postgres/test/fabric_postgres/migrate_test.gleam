//// `migrate` creates the schema and brings it up to date once, however
//// often and from however many nodes it is called; `with_schema` keeps
//// stores apart; the cigogne files hold the same statements.

import fabric/store
import fabric_postgres
import fabric_postgres/internal/migrations
import fabric_postgres/support
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit/should
import pog

fn versions(connection: pog.Connection, schema: String) -> List(Int) {
  let assert Ok(returned) =
    pog.query(
      "SELECT version FROM \""
      <> schema
      <> "\".fabric_schema_migrations ORDER BY version",
    )
    |> pog.returning(decode.field(0, decode.int, decode.success))
    |> pog.execute(connection)
  returned.rows
}

pub fn migrate_creates_the_schema_once_and_again_changes_nothing_test() {
  let connection = support.pool(2)
  let schema = support.schema()
  let assert Ok(settings) =
    fabric_postgres.settings(connection, node: "a")
    |> fabric_postgres.with_schema(schema)
  fabric_postgres.migrate(settings) |> should.equal(Ok(Nil))
  versions(connection, schema) |> should.equal([1, 2, 3])
  let backend = fabric_postgres.backend(settings)
  backend.insert("run-a1", "{}", store.Release) |> should.equal(Ok(Nil))
  fabric_postgres.migrate(settings) |> should.equal(Ok(Nil))
  versions(connection, schema) |> should.equal([1, 2, 3])
  backend.get("run-a1") |> should.equal(Ok(store.Current(1, "{}", store.Free)))
}

/// Nodes starting together all migrate: one applies the migrations, the
/// others wait for its lock and find nothing left to do.
pub fn concurrent_migrations_all_succeed_and_apply_once_test() {
  let connection = support.pool(12)
  let schema = support.schema()
  let assert Ok(settings) =
    fabric_postgres.settings(connection, node: "a")
    |> fabric_postgres.with_schema(schema)
  let results = process.new_subject()
  list.each(list.repeat(Nil, 10), fn(_) {
    process.spawn(fn() {
      process.send(results, fabric_postgres.migrate(settings))
    })
  })
  list.map(list.repeat(Nil, 10), fn(_) {
    let assert Ok(result) = process.receive(results, 30_000)
    result
  })
  |> list.unique
  |> should.equal([Ok(Nil)])
  versions(connection, schema) |> should.equal([1, 2, 3])
}

/// A database a newer version of this package migrated further is left
/// as it is.
pub fn migrate_leaves_a_newer_schema_alone_test() {
  let connection = support.pool(2)
  let schema = support.schema()
  let settings = support.migrated(connection, "a", schema)
  let assert Ok(_) =
    pog.query(
      "INSERT INTO \""
      <> schema
      <> "\".fabric_schema_migrations (version) VALUES (99)",
    )
    |> pog.execute(connection)
  fabric_postgres.migrate(settings) |> should.equal(Ok(Nil))
  versions(connection, schema) |> should.equal([1, 2, 3, 99])
}

pub fn migrate_reports_an_unreachable_database_test() {
  // The throwaway cluster, but a database it does not have.
  let connection =
    support.pool_with(1, fn(config) { pog.database(config, "nowhere") })
  let settings = fabric_postgres.settings(connection, node: "a")
  let assert Error(fabric_postgres.MigrationFailed(_)) =
    fabric_postgres.migrate(settings)
  let assert Error(store.Unavailable(_)) =
    fabric_postgres.backend(settings).get("run-a1")
}

/// Two schemas in one database hold separate runs.
pub fn stores_in_separate_schemas_are_apart_test() {
  let connection = support.pool(2)
  let one = support.migrated(connection, "a", support.schema())
  let other = support.migrated(connection, "a", support.schema())
  fabric_postgres.backend(one).insert("run-a1", "one", store.Release)
  |> should.equal(Ok(Nil))
  fabric_postgres.backend(other).get("run-a1")
  |> should.equal(Error(store.NotFound))
  fabric_postgres.backend(other).insert("run-a1", "other", store.Release)
  |> should.equal(Ok(Nil))
  fabric_postgres.backend(one).get("run-a1")
  |> should.equal(Ok(store.Current(1, "one", store.Free)))
}

pub fn a_schema_name_is_a_plain_lowercase_identifier_test() {
  let settings = fabric_postgres.settings(support.pool(1), node: "a")
  let refused = fn(schema) {
    fabric_postgres.with_schema(settings, schema)
    |> should.equal(Error(fabric_postgres.InvalidSchema(schema)))
  }
  refused("")
  refused("Runs")
  refused("1runs")
  refused("runs\"; DROP TABLE x; --")
  refused("my-runs")
  refused(string.repeat("a", 64))
  let assert Ok(_) = fabric_postgres.with_schema(settings, "_runs_2")
  let assert Ok(_) =
    fabric_postgres.with_schema(settings, string.repeat("a", 63))
}

/// Each cigogne file's up section is its migration's statements, in order.
pub fn the_cigogne_files_hold_the_same_statements_test() {
  list.each(migrations.all(), fn(migration) {
    let assert Ok(text) =
      support.read_file("priv/migrations/" <> migration.file)
    let assert Ok(#(_, rest)) = string.split_once(text, "--- migration:up")
    let assert Ok(#(up, _)) = string.split_once(rest, "--- migration:down")
    up
    |> string.split(";\n")
    |> list.map(string.trim)
    |> list.filter(fn(statement) { statement != "" })
    |> should.equal(migration.statements)
  })
}

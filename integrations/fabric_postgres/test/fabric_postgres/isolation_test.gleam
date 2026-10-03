//// How writes behave when they race an open transaction on the same row:
//// under READ COMMITTED a blocked write re-checks its condition against
//// the committed row and changes nothing; under REPEATABLE READ the same
//// statement fails with 40001, which the backend reads back or retries,
//// so its callers see the same results at both levels.

import fabric/store/backend
import fabric_postgres
import fabric_postgres/support
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleeunit/should
import pog

fn repeatable_read(size: Int) -> pog.Connection {
  support.pool_with(size, pog.connection_parameter(
    _,
    name: "default_transaction_isolation",
    value: "repeatable read",
  ))
}

fn isolation(connection: pog.Connection) -> String {
  let assert Ok(returned) =
    pog.query("SHOW default_transaction_isolation")
    |> pog.returning(decode.field(0, decode.string, decode.success))
    |> pog.execute(connection)
  let assert [level] = returned.rows
  level
}

/// Runs `sql` on `connection` in a transaction that stays open, holding
/// the row locks it took, until the returned function is called; that
/// function commits it.
fn held(connection: pog.Connection, sql: String) -> fn() -> Nil {
  let ready = process.new_subject()
  let done = process.new_subject()
  process.spawn(fn() {
    let go = process.new_subject()
    let assert Ok(Nil) =
      pog.transaction(connection, fn(transaction) {
        let assert Ok(_) = pog.query(sql) |> pog.execute(transaction)
        process.send(ready, go)
        process.receive_forever(go)
        Ok(Nil)
      })
    process.send(done, Nil)
  })
  let go = process.receive_forever(ready)
  fn() {
    process.send(go, Nil)
    process.receive_forever(done)
  }
}

/// Starts `body` in a new process and returns a receiver of its result.
fn started(body: fn() -> a) -> process.Subject(a) {
  let result = process.new_subject()
  process.spawn(fn() { process.send(result, body()) })
  result
}

/// `write` blocks behind an open transaction that runs `sql`, and gives
/// its result only once that transaction commits.
fn behind(holder: pog.Connection, sql: String, write: fn() -> a) -> a {
  let commit = held(holder, sql)
  let result = started(write)
  process.receive(result, 300) |> should.equal(Error(Nil))
  commit()
  let assert Ok(result) = process.receive(result, 30_000)
  result
}

fn table(schema: String) -> String {
  "\"" <> schema <> "\".fabric_runs"
}

/// The raw statement a write makes fails with 40001 under REPEATABLE READ
/// when a concurrent transaction commits a change to its row first, and
/// changes no row under READ COMMITTED: the difference the backend maps.
pub fn a_blocked_update_fails_only_under_repeatable_read_test() {
  let holder = support.pool(2)
  let schema = support.schema()
  let backend = fabric_postgres.backend(support.migrated(holder, "a", schema))
  let schema_table = table(schema)
  let bump = "UPDATE " <> schema_table <> " SET revision = revision + 1"
  let raw = fn(connection, run) {
    fn() {
      pog.query(
        "UPDATE "
        <> schema_table
        <> " SET revision = revision + 1 WHERE run_id = '"
        <> run
        <> "' AND revision = 1",
      )
      |> pog.execute(connection)
    }
  }
  let assert Ok(Nil) = backend.insert("run-a1", "a", backend.Release)
  let assert Ok(returned) = behind(holder, bump, raw(support.pool(1), "run-a1"))
  returned.count |> should.equal(0)
  let assert Ok(Nil) = backend.insert("run-a2", "a", backend.Release)
  let rr = repeatable_read(1)
  isolation(rr) |> should.equal("repeatable read")
  let assert Error(pog.PostgresqlError(code: "40001", ..)) =
    behind(
      holder,
      "UPDATE " <> schema_table <> " SET revision = 2 WHERE run_id = 'run-a2'",
      raw(rr, "run-a2"),
    )
}

/// A compare-and-set blocked behind a concurrent commit of its row is a
/// `Conflict` at both levels, and a claim blocked behind a concurrent
/// lease taker is `LeaseRefused` with the new holder.
pub fn blocked_writes_report_the_committed_row_at_both_levels_test() {
  let holder = support.pool(2)
  list.each([support.pool(2), repeatable_read(2)], fn(connection) {
    let schema = support.schema()
    let _ = support.migrated(holder, "a", schema)
    let assert Ok(settings) =
      fabric_postgres.settings(connection, node: "a")
      |> fabric_postgres.with_schema(schema)
    let backend = fabric_postgres.backend(settings)
    let assert Ok(Nil) = backend.insert("run-a1", "a", backend.Release)
    behind(
      holder,
      "UPDATE " <> table(schema) <> " SET revision = 2, record = 'b'",
      fn() { backend.compare_and_set("run-a1", 1, "c", backend.Release) },
    )
    |> should.equal(Error(backend.Conflict(2)))
    behind(
      holder,
      "UPDATE "
        <> table(schema)
        <> " SET lease_owner = 'o2', lease_until = clock_timestamp() + interval '1 minute'",
      fn() {
        backend.compare_and_set("run-a1", 2, "c", backend.Claim("o1", 60_000))
      },
    )
    |> should.equal(Error(backend.LeaseRefused(backend.Held("o2", True))))
    backend.get("run-a1")
    |> should.equal(Ok(backend.Current(2, "b", backend.Held("o2", True))))
  })
}

/// A renewal blocked behind a concurrent commit of its row (here a new
/// revision, the lease untouched) still renews it at both levels: under
/// REPEATABLE READ it is retried after its 40001.
pub fn a_blocked_renewal_still_renews_at_both_levels_test() {
  let holder = support.pool(2)
  list.each([support.pool(2), repeatable_read(2)], fn(connection) {
    let schema = support.schema()
    let _ = support.migrated(holder, "a", schema)
    let assert Ok(settings) =
      fabric_postgres.settings(connection, node: "a")
      |> fabric_postgres.with_schema(schema)
    let backend = fabric_postgres.backend(settings)
    let assert Ok(Nil) =
      backend.insert("run-a1", "a", backend.Claim("o1", 60_000))
    behind(
      holder,
      "UPDATE " <> table(schema) <> " SET revision = 2, record = 'b'",
      fn() { backend.renew("o1", ["run-a1"], 60_000) },
    )
    |> should.equal(Ok(["run-a1"]))
    backend.get("run-a1")
    |> should.equal(Ok(backend.Current(2, "b", backend.Held("o1", True))))
  })
}

/// Racing writers on a REPEATABLE READ pool: each revision has exactly
/// one winner, and every loser is a `Conflict`.
pub fn racing_writers_under_repeatable_read_have_one_winner_per_revision_test() {
  let connection = repeatable_read(16)
  let settings = support.migrated(connection, "a", support.schema())
  let backend = fabric_postgres.backend(settings)
  let assert Ok(Nil) = backend.insert("run-a1", "0", backend.Release)
  let results = process.new_subject()
  list.each(list.repeat(Nil, 16), fn(_) {
    process.spawn(fn() {
      list.each(list.repeat(Nil, 10), fn(_) {
        let assert Ok(current) = backend.get("run-a1")
        let outcome =
          backend.compare_and_set(
            "run-a1",
            current.revision,
            "w",
            backend.Release,
          )
        process.send(results, #(current.revision, outcome))
      })
    })
  })
  let outcomes =
    list.map(list.repeat(Nil, 160), fn(_) {
      let assert Ok(outcome) = process.receive(results, 30_000)
      outcome
    })
  let wins =
    list.filter_map(outcomes, fn(outcome) {
      case outcome.1 {
        Ok(Nil) -> Ok(outcome.0)
        Error(_) -> Error(Nil)
      }
    })
  list.length(list.unique(wins)) |> should.equal(list.length(wins))
  list.filter(outcomes, fn(outcome) {
    case outcome.1 {
      Ok(Nil) | Error(backend.Conflict(_)) -> False
      Error(_) -> True
    }
  })
  |> should.equal([])
  let assert Ok(current) = backend.get("run-a1")
  current.revision |> should.equal(1 + list.length(wins))
}

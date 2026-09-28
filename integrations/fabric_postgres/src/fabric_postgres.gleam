//// A PostgreSQL store for Fabric runs, for several nodes that share one
//// database: a leased backend (`fabric/store`, Leases) over one table,
//// `fabric_runs`, and the migrations that create it.
////
//// ```gleam
//// let settings =
////   fabric_postgres.settings(db, node: "api-1")
////   |> fabric_postgres.with_lease(30_000)
//// let assert Ok(Nil) = fabric_postgres.migrate(settings)
//// let assert Ok(runs) =
////   fabric_postgres.store(process.new_name("runs"), settings)
//// ```
////
//// The application owns the connection pool (`pog.supervised`) and passes
//// its `pog.Connection`. Each run is one row: its latest record as text
//// (the exact bytes Fabric wrote), its revision, and its lease (an owner
//// and an expiry). Every write is one conditional statement, committed on
//// its own, whose condition checks the revision and the lease together.
//// Lease expiry is judged by the database's clock alone
//// (`clock_timestamp()`), so the nodes' clocks need not agree.
////
//// The pool may use any isolation level: READ COMMITTED, PostgreSQL's
//// default, is what the statements are written for, and a write that fails
//// to serialise under REPEATABLE READ or SERIALIZABLE is read back or
//// retried (see `fabric_postgres/internal/backend`).

import fabric/store.{type LeaseConfigError, type LeasedBackend, type Store}
import fabric_postgres/internal/backend
import fabric_postgres/internal/migrations
import gleam/dynamic/decode
import gleam/erlang/process.{type Name}
import gleam/list
import gleam/result
import gleam/string
import pog

/// Where and how a store keeps its runs: the connection, this node's id,
/// the lease duration and the schema.
pub opaque type Settings {
  Settings(connection: pog.Connection, node: String, lease: Int, schema: String)
}

/// Settings over `connection` for the node `node`, with a 30 000 ms lease
/// in the schema `public`.
///
/// `node` names this VM among every VM that shares the database: unique to
/// it, and the same after it restarts (a host name, or a pod's stable name),
/// 1 to 128 letters, digits, and `.`, `_`, `-`, `@` or `:`. Never
/// `nonode@nohost`, the name of every undistributed VM. Two VMs given one
/// node id would each take over the other's runs as soon as they restart.
pub fn settings(connection: pog.Connection, node node: String) -> Settings {
  Settings(connection:, node:, lease: 30_000, schema: "public")
}

/// Sets the lease duration in milliseconds (default 30 000): how long a
/// run stays with this node after its last renewal (every `lease / 3` ms),
/// and so how long another node waits before taking over a run whose node
/// stopped. `store` checks it: at least 100 ms, at most 2^32 - 1 ms.
pub fn with_lease(settings: Settings, milliseconds: Int) -> Settings {
  Settings(..settings, lease: milliseconds)
}

/// Why a schema name was refused (`with_schema`).
pub type SchemaError {
  /// A schema name here is 1 to 63 lowercase letters, digits and `_`, not
  /// starting with a digit.
  InvalidSchema(String)
}

/// Keeps the tables in `schema` (default `public`), which `migrate`
/// creates if missing. Several applications, or several tests, may share
/// one database in schemas of their own.
pub fn with_schema(
  settings: Settings,
  schema: String,
) -> Result(Settings, SchemaError) {
  let allowed = fn(grapheme, first) {
    string.contains("abcdefghijklmnopqrstuvwxyz_", grapheme)
    || { !first && string.contains("0123456789", grapheme) }
  }
  let graphemes = string.to_graphemes(schema)
  case
    graphemes != []
    && list.length(graphemes) <= 63
    && list.index_fold(graphemes, True, fn(ok, grapheme, index) {
      ok && allowed(grapheme, index == 0)
    })
  {
    True -> Ok(Settings(..settings, schema:))
    False -> Error(InvalidSchema(schema))
  }
}

/// Why `migrate` failed.
pub type MigrateError {
  /// The database was unreachable or refused a statement (`reason`). The
  /// migration runs in one transaction, so it applied nothing, unless the
  /// failure was the commit's own reply; running `migrate` again is safe.
  MigrationFailed(reason: String)
}

/// Brings the schema up to date: creates it if missing, then applies, in
/// one transaction, each numbered migration it has not applied yet,
/// recording each in `fabric_schema_migrations`. Idempotent, and safe to
/// call from several nodes at once: a transaction-scoped advisory lock per
/// schema serialises the callers, and a later one finds nothing to do.
/// Migrations only move forward; a database already migrated further by a
/// newer version of this package is left as it is.
///
/// The same migrations are in `priv/migrations/`, in cigogne's format, for
/// an application that applies its migrations with cigogne instead; they
/// take the same lock.
pub fn migrate(settings: Settings) -> Result(Nil, MigrateError) {
  let schema = settings.schema
  pog.transaction(settings.connection, fn(connection) {
    let run = fn(sql, parameters) {
      list.fold(parameters, pog.query(sql), pog.parameter)
      |> pog.timeout(60_000)
      |> pog.execute(connection)
      |> result.replace(Nil)
    }
    // A later statement must see what an earlier locked migration
    // committed, whatever the database's default isolation.
    use Nil <- result.try(
      run("SET TRANSACTION ISOLATION LEVEL READ COMMITTED", []),
    )
    use Nil <- result.try(
      run(
        "SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended($1, 0))) AS l",
        [pog.text(migrations.lock_prefix <> schema)],
      ),
    )
    use exists <- result.try(
      pog.query("SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = $1)")
      |> pog.parameter(pog.text(schema))
      |> pog.returning(decode.field(0, decode.bool, decode.success))
      |> pog.execute(connection)
      |> result.map(fn(returned) { returned.rows == [True] }),
    )
    // Creating only a missing schema needs no database privilege when an
    // administrator created it beforehand.
    use Nil <- result.try(case exists {
      True -> Ok(Nil)
      False -> run("CREATE SCHEMA " <> quoted(schema), [])
    })
    use Nil <- result.try(
      run("SET LOCAL search_path TO " <> quoted(schema), []),
    )
    use marked <- result.try(
      pog.query("SELECT to_regclass('fabric_schema_migrations') IS NOT NULL")
      |> pog.returning(decode.field(0, decode.bool, decode.success))
      |> pog.execute(connection)
      |> result.map(fn(returned) { returned.rows == [True] }),
    )
    use applied <- result.try(case marked {
      False -> Ok(0)
      True ->
        pog.query(
          "SELECT coalesce(max(version), 0) FROM fabric_schema_migrations",
        )
        |> pog.returning(decode.field(0, decode.int, decode.success))
        |> pog.execute(connection)
        |> result.map(fn(returned) {
          list.first(returned.rows) |> result.unwrap(0)
        })
    })
    migrations.all()
    |> list.filter(fn(migration) { migration.version > applied })
    |> list.try_each(fn(migration) {
      list.try_each(migration.statements, run(_, []))
    })
  })
  |> result.map_error(fn(error) {
    MigrationFailed(case error {
      pog.TransactionQueryError(error) | pog.TransactionRolledBack(error) ->
        backend.describe(error)
    })
  })
}

/// The leased backend a `store` of these settings uses, over the table
/// `fabric_runs` in the settings' schema. For `fabric/testing`'s
/// conformance checks, or for a store an application wraps.
pub fn backend(settings: Settings) -> LeasedBackend {
  backend.new(settings.connection, table(settings))
}

/// A leased store of these settings, registered as `name` (see
/// `fabric/store.leased`): its process identifies itself as
/// `<node>/<name>/<random>`, and renews its runners' leases every
/// `lease / 3` ms. Run `migrate` first. Refused when the node id or the
/// lease duration is invalid.
pub fn store(
  name: Name(store.Message),
  settings: Settings,
) -> Result(Store, LeaseConfigError) {
  store.leased(
    name,
    node: settings.node,
    lease: settings.lease,
    backend: backend(settings),
  )
}

/// Why `prune` deleted nothing.
pub type PruneError {
  PruneAgeNegative(Int)
  PruneLimitNotPositive(Int)
  /// The database was unreachable or refused the statement (`reason`);
  /// nothing was deleted.
  PruneFailed(reason: String)
}

/// Deletes finished runs, a whole family at a time: up to `limit` root
/// runs that ended at least `ended_for` milliseconds ago (by the
/// database's clock), each with every sub-agent run of its family, and
/// only when every run of the family has ended (or never started) and
/// none holds a live lease. An ended sub-agent run is never deleted on its
/// own, since recovering its parent would start it again. Returns how many
/// runs it deleted, sub-agent runs included. Safe to call from several
/// nodes at once: each family is deleted by one of them.
pub fn prune(
  settings: Settings,
  ended_for milliseconds: Int,
  limit limit: Int,
) -> Result(Int, PruneError) {
  let table = table(settings)
  case milliseconds < 0, limit < 1 {
    True, _ -> Error(PruneAgeNegative(milliseconds))
    _, True -> Error(PruneLimitNotPositive(limit))
    False, False ->
      pog.query(
        "WITH roots AS (SELECT r.run_id FROM "
        <> table
        <> " AS r WHERE r.phase = 'ended' AND r.root_id = r.run_id"
        <> " AND r.updated_at <= clock_timestamp() - $1::bigint * interval '1 millisecond'"
        <> " AND NOT EXISTS (SELECT 1 FROM "
        <> table
        <> " AS m WHERE m.root_id = r.run_id AND (m.phase IS NULL"
        <> " OR m.phase NOT IN ('ended', 'never_started') OR m.lease_until > clock_timestamp()))"
        <> " ORDER BY r.updated_at LIMIT $2 FOR UPDATE SKIP LOCKED)"
        <> " DELETE FROM "
        <> table
        <> " AS d USING roots WHERE d.root_id = roots.run_id",
      )
      |> pog.parameter(pog.int(milliseconds))
      |> pog.parameter(pog.int(limit))
      |> pog.execute(settings.connection)
      |> result.map(fn(returned) { returned.count })
      |> result.map_error(fn(error) { PruneFailed(backend.describe(error)) })
  }
}

fn table(settings: Settings) -> String {
  quoted(settings.schema) <> ".fabric_runs"
}

/// A schema name `with_schema` accepted, as an SQL identifier.
fn quoted(schema: String) -> String {
  "\"" <> schema <> "\""
}

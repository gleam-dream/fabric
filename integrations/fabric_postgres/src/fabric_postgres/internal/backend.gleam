//// The leased backend over one PostgreSQL table (see `fabric/store`,
//// Leases). Every write is one conditional statement, committed on its
//// own (autocommit), so the revision check and the lease condition hold
//// in one atomic step; the lease's clock is the database's
//// `clock_timestamp()`, never the application's.
////
//// A write that changes no row is read back to say why: `NotFound`,
//// `Conflict(current)` or `LeaseRefused(holder)`. Under READ COMMITTED, the
//// default, a write that loses a race to a concurrent one re-checks its
//// condition against the winner's row and changes nothing. A database
//// whose default isolation is REPEATABLE READ or SERIALIZABLE fails that
//// write with 40001 instead (and may report a deadlock, 40P01): the write
//// did nothing, so it is read back the same way, and a renewal or a claim
//// is retried. Any other failure, the connection's included, is
//// `Unavailable`.
////
//// A renewal changes only the expiry of leases its owner holds live; a
//// claim of expired leases changes only the owner and expiry, taking the
//// rows with `FOR UPDATE SKIP LOCKED` so that concurrent claimers never
//// take the same run. Neither changes a revision.

import fabric/discovery
import fabric/retention
import fabric/statistics
import fabric/store.{
  type Current, type Holder, type Lease, type LeasedBackend, type StoreError,
  AlreadyExists, Claim, Conflict, Current, Free, Held, Hold, LeaseRefused,
  LeasedBackend, NotFound, Release, Seize, Unavailable,
}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pog

/// How many times a statement that failed to serialise, or a write whose
/// read-back shows its condition now holds, is tried again.
const retries = 5

/// The backend over `table`, a schema-qualified `fabric_runs`.
pub fn new(connection: pog.Connection, table: String) -> LeasedBackend {
  LeasedBackend(
    now: fn() { now(connection) },
    get: fn(run) { get(connection, table, run) },
    insert: fn(run, record, lease) {
      insert(connection, table, run, record, lease, retries)
    },
    compare_and_set: fn(run, expected, record, lease) {
      compare_and_set(connection, table, run, expected, record, lease, retries)
    },
    renew: fn(owner, runs, ttl) {
      renew(connection, table, owner, runs, ttl, retries)
    },
    claim_expired: fn(owner, ttl, limit) {
      claim_expired(connection, table, owner, ttl, limit, retries)
    },
    claim_ready: fn(owner, ttl, limit) {
      claim_ready(connection, table, owner, ttl, limit, retries)
    },
  )
}

fn now(connection: pog.Connection) -> Result(Int, StoreError) {
  pog.query(
    "SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint",
  )
  |> pog.returning(decode.field(0, decode.int, decode.success))
  |> pog.execute(connection)
  |> result.map_error(unavailable)
  |> result.try(fn(returned) {
    case returned.rows {
      [milliseconds] -> Ok(milliseconds)
      _ -> Error(Unavailable("database clock returned no single timestamp"))
    }
  })
}

fn get(
  connection: pog.Connection,
  table: String,
  run: String,
) -> Result(Current, StoreError) {
  let row = {
    use revision <- decode.field(0, decode.int)
    use record <- decode.field(1, decode.string)
    use owner <- decode.field(2, decode.optional(decode.string))
    use live <- decode.field(3, decode.optional(decode.bool))
    decode.success(Current(revision, record, holder(owner, live)))
  }
  pog.query(
    "SELECT revision, record, lease_owner, lease_until > clock_timestamp() FROM "
    <> table
    <> " WHERE run_id = $1",
  )
  |> pog.parameter(pog.text(run))
  |> pog.returning(row)
  |> pog.execute(connection)
  |> result.map_error(unavailable)
  |> result.try(fn(returned) {
    case returned.rows {
      [current] -> Ok(current)
      _ -> Error(NotFound)
    }
  })
}

fn holder(owner: Option(String), live: Option(Bool)) -> Holder {
  case owner {
    None -> Free
    Some(owner) -> Held(owner, live == Some(True))
  }
}

const expiry = "clock_timestamp() + $5::bigint * interval '1 millisecond'"

fn insert(
  connection: pog.Connection,
  table: String,
  run: String,
  record: String,
  lease: Lease,
  retries: Int,
) -> Result(Nil, StoreError) {
  let #(owner, ttl) = case lease {
    Claim(owner, ttl) | Seize(owner, ttl) -> #(pog.text(owner), ttl)
    Hold(_) | Release -> #(pog.null(), 0)
  }
  let outcome =
    pog.query(
      "INSERT INTO "
      <> table
      <> " (run_id, revision, record, phase, lease_owner, lease_until, retention, retention_revision, discovery, discovery_revision, statistics, statistics_revision)"
      <> " VALUES ($1, 1, $2, $3, $4::text, CASE WHEN $4::text IS NULL THEN NULL ELSE "
      <> expiry
      <> " END, $6::jsonb, 1, $7::jsonb, 1, $8::jsonb, 1) ON CONFLICT (run_id) DO NOTHING",
    )
    |> pog.parameter(pog.text(run))
    |> pog.parameter(pog.text(record))
    |> pog.parameter(phase(record))
    |> pog.parameter(owner)
    |> pog.parameter(pog.int(ttl))
    |> pog.parameter(pog.text(retention.encode(run, record)))
    |> pog.parameter(pog.text(discovery.encode(run, record)))
    |> pog.parameter(pog.text(statistics.encode(run, record)))
    |> pog.execute(connection)
  case outcome {
    Ok(returned) if returned.count == 1 -> Ok(Nil)
    Ok(_) -> Error(AlreadyExists)
    Error(error) ->
      case serialisation(error), retries > 0 {
        True, True ->
          // Nothing was written: another writer's row, or none yet.
          case get(connection, table, run) {
            Ok(_) -> Error(AlreadyExists)
            Error(NotFound) ->
              insert(connection, table, run, record, lease, retries - 1)
            Error(other) -> Error(other)
          }
        _, _ -> Error(unavailable(error))
      }
  }
}

fn compare_and_set(
  connection: pog.Connection,
  table: String,
  run: String,
  expected: Int,
  record: String,
  lease: Lease,
  retries: Int,
) -> Result(Nil, StoreError) {
  let update =
    "UPDATE "
    <> table
    <> " SET revision = revision + 1, record = $3, phase = $4, updated_at = clock_timestamp(), retention = $5::jsonb, retention_revision = revision + 1, discovery = $6::jsonb, discovery_revision = revision + 1, statistics = $7::jsonb, statistics_revision = revision + 1"
  let current = " WHERE run_id = $1 AND revision = $2"
  let #(sql, parameters) = case lease {
    Hold(owner) -> #(update <> current <> " AND lease_owner = $8", [
      pog.text(owner),
    ])
    Claim(owner, ttl) -> #(
      update
        <> ", lease_owner = $8, lease_until = clock_timestamp() + $9::bigint * interval '1 millisecond'"
        <> current
        <> " AND (lease_owner IS NULL OR lease_owner = $8 OR lease_until <= clock_timestamp())",
      [pog.text(owner), pog.int(ttl)],
    )
    Seize(owner, ttl) -> #(
      update
        <> ", lease_owner = $8, lease_until = clock_timestamp() + $9::bigint * interval '1 millisecond'"
        <> current,
      [pog.text(owner), pog.int(ttl)],
    )
    Release -> #(
      update <> ", lease_owner = NULL, lease_until = NULL" <> current,
      [],
    )
  }
  let outcome =
    pog.query(sql)
    |> pog.parameter(pog.text(run))
    |> pog.parameter(pog.int(expected))
    |> pog.parameter(pog.text(record))
    |> pog.parameter(phase(record))
    |> pog.parameter(pog.text(retention.encode(run, record)))
    |> pog.parameter(pog.text(discovery.encode(run, record)))
    |> pog.parameter(pog.text(statistics.encode(run, record)))
    |> list.fold(parameters, _, pog.parameter)
    |> pog.execute(connection)
  let again = fn() {
    compare_and_set(
      connection,
      table,
      run,
      expected,
      record,
      lease,
      retries - 1,
    )
  }
  case outcome {
    Ok(returned) if returned.count == 1 -> Ok(Nil)
    Ok(_) -> refused(connection, table, run, expected, lease, retries, again)
    Error(error) ->
      case serialisation(error) {
        True -> refused(connection, table, run, expected, lease, retries, again)
        False -> Error(unavailable(error))
      }
  }
}

/// A write that changed nothing: reads the run back to say why. A write
/// whose conditions hold on the row read back (a lease that expired
/// meanwhile, or a write that failed to serialise) is tried again.
fn refused(
  connection: pog.Connection,
  table: String,
  run: String,
  expected: Int,
  lease: Lease,
  retries: Int,
  again: fn() -> Result(Nil, StoreError),
) -> Result(Nil, StoreError) {
  use current <- result.try(get(connection, table, run))
  case current.revision == expected, permits(lease, current.holder) {
    False, _ -> Error(Conflict(current.revision))
    True, False -> Error(LeaseRefused(current.holder))
    True, True if retries > 0 -> again()
    True, True ->
      Error(Unavailable(
        "the write kept failing although its conditions held; nothing was written",
      ))
  }
}

/// Whether `lease`'s condition holds for a run whose lease is `holder`.
fn permits(lease: Lease, holder: Holder) -> Bool {
  case lease, holder {
    Hold(owner), Held(holding, _) -> owner == holding
    Hold(_), Free -> False
    Claim(_, _), Free -> True
    Claim(owner, _), Held(holding, live) -> owner == holding || !live
    Seize(_, _), _ | Release, _ -> True
  }
}

fn renew(
  connection: pog.Connection,
  table: String,
  owner: String,
  runs: List(String),
  ttl: Int,
  retries: Int,
) -> Result(List(String), StoreError) {
  case runs {
    [] -> Ok([])
    _ ->
      pog.query(
        "UPDATE "
        <> table
        <> " SET lease_until = clock_timestamp() + $3::bigint * interval '1 millisecond'"
        <> " WHERE lease_owner = $1 AND lease_until > clock_timestamp() AND run_id = ANY($2)"
        <> " RETURNING run_id",
      )
      |> pog.parameter(pog.text(owner))
      |> pog.parameter(pog.array(pog.text, runs))
      |> pog.parameter(pog.int(ttl))
      |> pog.returning(decode.field(0, decode.string, decode.success))
      |> rows(connection, retries)
  }
}

fn claim_expired(
  connection: pog.Connection,
  table: String,
  owner: String,
  ttl: Int,
  limit: Int,
  retries: Int,
) -> Result(List(String), StoreError) {
  case limit > 0 {
    False -> Ok([])
    True ->
      pog.query(
        "UPDATE "
        <> table
        <> " AS r SET lease_owner = $1, lease_until = clock_timestamp() + $2::bigint * interval '1 millisecond'"
        <> " FROM (SELECT run_id FROM "
        <> table
        <> " WHERE lease_owner IS NOT NULL AND lease_until <= clock_timestamp()"
        <> " ORDER BY lease_until LIMIT $3 FOR UPDATE SKIP LOCKED) AS c"
        <> " WHERE r.run_id = c.run_id RETURNING r.run_id",
      )
      |> pog.parameter(pog.text(owner))
      |> pog.parameter(pog.int(ttl))
      |> pog.parameter(pog.int(limit))
      |> pog.returning(decode.field(0, decode.string, decode.success))
      |> rows(connection, retries)
  }
}

fn claim_ready(
  connection: pog.Connection,
  table: String,
  owner: String,
  ttl: Int,
  limit: Int,
  retries: Int,
) -> Result(List(String), StoreError) {
  case limit > 0 {
    False -> Ok([])
    True ->
      pog.query(
        "WITH candidates AS (SELECT r.run_id, r.discovery #>> '{wait,key}' AS key, dependencies.revisions FROM "
        <> table
        <> " r LEFT JOIN LATERAL (SELECT COALESCE(jsonb_object_agg(ids.id, d.revision), '{}'::jsonb) AS revisions"
        <> " FROM jsonb_array_elements_text(COALESCE(r.dependency_ids, '[]'::jsonb)) AS ids(id) LEFT JOIN "
        <> table
        <> " d ON d.run_id = ids.id) AS dependencies ON TRUE"
        <> " WHERE r.lease_owner IS NULL"
        <> " AND (r.dependency_ids IS NOT NULL OR r.discovery #>> '{wait,every}' IS NOT NULL OR r.discovery #>> '{wait,due}' IS NOT NULL)"
        <> " AND r.discovery_revision = r.revision AND r.discovery->>'version' = $4"
        <> " AND ((r.dependency_ids IS NOT NULL AND (r.observed_key IS DISTINCT FROM r.discovery #>> '{wait,key}' OR r.observed_dependencies IS DISTINCT FROM dependencies.revisions))"
        <> " OR (r.discovery #>> '{wait,every}' IS NOT NULL AND (r.observed_key IS DISTINCT FROM r.discovery #>> '{wait,key}' OR r.discovery_checked_at + (r.discovery #>> '{wait,every}')::bigint * interval '1 millisecond' <= clock_timestamp()))"
        <> " OR (r.discovery #>> '{wait,due}' IS NOT NULL AND (r.discovery #>> '{wait,due}')::bigint <= floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint))"
        <> " ORDER BY r.discovery_checked_at, r.run_id LIMIT $3 FOR UPDATE OF r SKIP LOCKED)"
        <> " UPDATE "
        <> table
        <> " r SET lease_owner = $1, lease_until = clock_timestamp() + $2::bigint * interval '1 millisecond',"
        <> " observed_key = c.key, observed_dependencies = c.revisions, discovery_checked_at = clock_timestamp()"
        <> " FROM candidates c WHERE r.run_id = c.run_id RETURNING r.run_id",
      )
      |> pog.parameter(pog.text(owner))
      |> pog.parameter(pog.int(ttl))
      |> pog.parameter(pog.int(limit))
      |> pog.parameter(pog.text(int.to_string(discovery.version)))
      |> pog.returning(decode.field(0, decode.string, decode.success))
      |> rows(connection, retries)
  }
}

/// The rows of `query`, run again while it fails to serialise.
fn rows(
  query: pog.Query(a),
  connection: pog.Connection,
  retries: Int,
) -> Result(List(a), StoreError) {
  case pog.execute(query, connection) {
    Ok(returned) -> Ok(returned.rows)
    Error(error) ->
      case serialisation(error), retries > 0 {
        True, True -> rows(query, connection, retries - 1)
        _, _ -> Error(unavailable(error))
      }
  }
}

/// The record's phase tag, kept in the `phase` column for queries, or
/// null for a record without one. Decoded here rather than by PostgreSQL,
/// whose JSON functions refuse a string holding an escaped NUL (`\u0000`),
/// which a model reply or a tool result may contain.
fn phase(record: String) -> pog.Value {
  case json.parse(record, decode.at(["phase", "tag"], decode.string)) {
    Ok(tag) -> pog.text(tag)
    Error(_) -> pog.null()
  }
}

/// Whether a statement failed only because it could not be serialised
/// with a concurrent one; it then changed nothing.
fn serialisation(error: pog.QueryError) -> Bool {
  case error {
    pog.PostgresqlError(code: "40001", ..)
    | pog.PostgresqlError(code: "40P01", ..) -> True
    _ -> False
  }
}

fn unavailable(error: pog.QueryError) -> StoreError {
  Unavailable(describe(error))
}

/// A query failure as text, for `Unavailable` and errors.
pub fn describe(error: pog.QueryError) -> String {
  case error {
    pog.ConnectionUnavailable -> "no database connection is available"
    pog.QueryTimeout -> "the query timed out"
    pog.PostgresqlError(code, name, message) ->
      "PostgreSQL " <> code <> " " <> name <> ": " <> message
    pog.ConstraintViolated(message, constraint, _) ->
      "constraint " <> constraint <> " violated: " <> message
    pog.UnexpectedArgumentCount(expected, got) ->
      "expected "
      <> int.to_string(expected)
      <> " query arguments, got "
      <> int.to_string(got)
    pog.UnexpectedArgumentType(expected, got) ->
      "expected a query argument of type " <> expected <> ", got " <> got
    pog.UnexpectedResultType(errors) ->
      "unexpected result: " <> string.inspect(errors)
  }
}

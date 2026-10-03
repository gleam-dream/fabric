//// Family retention uses supported record projections, never ID prefixes.
//// Serializable deletion and parent foreign keys protect against concurrent
//// metadata changes, lease renewal and delayed child creation.

import fabric/store/retention
import fabric_postgres/internal/backend
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import pog

pub fn prune(
  connection: pog.Connection,
  table: String,
  age: Int,
  limit: Int,
) -> Result(Int, String) {
  serial(
    connection,
    fn(connection) {
      pog.query(
        "WITH RECURSIVE candidates AS (SELECT run_id FROM "
        <> table
        <> " WHERE parent_id IS NULL AND retention_revision = revision"
        <> " AND retention->>'version' = $3 AND retention->>'settled' = 'true'"
        <> " AND updated_at <= clock_timestamp() - $1::bigint * interval '1 millisecond'),"
        <> " members AS (SELECT r.run_id AS root, r.* FROM "
        <> table
        <> " r JOIN candidates c ON c.run_id = r.run_id UNION ALL SELECT m.root, r.* FROM "
        <> table
        <> " r JOIN members m ON r.parent_id = m.run_id),"
        <> " eligible AS (SELECT c.run_id FROM candidates c WHERE NOT EXISTS (SELECT 1 FROM members m"
        <> " WHERE m.root = c.run_id AND (m.retention_revision IS DISTINCT FROM m.revision"
        <> " OR m.retention->>'version' IS DISTINCT FROM $3 OR m.retention->>'settled' IS DISTINCT FROM 'true'"
        <> " OR m.lease_until > clock_timestamp()"
        <> " OR m.updated_at > clock_timestamp() - $1::bigint * interval '1 millisecond'"
        <> " OR EXISTS (SELECT 1 FROM jsonb_array_elements(m.retention->'children') link LEFT JOIN "
        <> table
        <> " child ON child.run_id = link->>'run' WHERE child.run_id IS NULL"
        <> " OR child.parent_id IS DISTINCT FROM m.run_id OR child.retention->>'attachment' IS DISTINCT FROM link->>'key')"
        <> " OR (m.parent_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM "
        <> table
        <> " parent CROSS JOIN LATERAL jsonb_array_elements(parent.retention->'children') link"
        <> " WHERE parent.run_id = m.parent_id AND link->>'run' = m.run_id AND link->>'key' = m.retention->>'attachment'))))),"
        <> " roots AS (SELECT r.run_id FROM "
        <> table
        <> " r JOIN eligible e ON e.run_id = r.run_id ORDER BY r.updated_at, r.run_id LIMIT $2 FOR UPDATE OF r SKIP LOCKED)"
        <> " DELETE FROM "
        <> table
        <> " d USING members m, roots WHERE d.run_id = m.run_id AND m.root = roots.run_id",
      )
      |> pog.parameter(pog.int(age))
      |> pog.parameter(pog.int(limit))
      |> pog.parameter(pog.text(int.to_string(retention.version)))
      |> pog.execute(connection)
      |> result.map(fn(returned) { returned.count })
    },
    5,
  )
}

pub fn refresh(
  connection: pog.Connection,
  table: String,
  limit: Int,
) -> Result(Int, String) {
  serial(
    connection,
    fn(connection) {
      let row = {
        use id <- decode.field(0, decode.string)
        use revision <- decode.field(1, decode.int)
        use record <- decode.field(2, decode.string)
        decode.success(#(id, revision, record))
      }
      use rows <- result.try(
        pog.query(
          "SELECT run_id, revision, record FROM "
          <> table
          <> " WHERE retention_revision IS DISTINCT FROM revision OR retention->>'version' IS DISTINCT FROM $2"
          <> " ORDER BY run_id LIMIT $1 FOR UPDATE SKIP LOCKED",
        )
        |> pog.parameter(pog.int(limit))
        |> pog.parameter(pog.text(int.to_string(retention.version)))
        |> pog.returning(row)
        |> pog.execute(connection),
      )
      use Nil <- result.try(
        list.try_each(rows.rows, fn(row) {
          // An old orphan is retained as unknown instead of aborting the entire
          // refresh batch on its missing parent. It cannot be pruned alone.
          pog.query(
            "UPDATE "
            <> table
            <> " SET retention = CASE WHEN $3::jsonb->>'parent' IS NULL"
            <> " OR EXISTS (SELECT 1 FROM "
            <> table
            <> " p WHERE p.run_id = $3::jsonb->>'parent')"
            <> " THEN $3::jsonb ELSE jsonb_build_object('version', $4::int) END, retention_revision = revision"
            <> " WHERE run_id = $1 AND revision = $2",
          )
          |> pog.parameter(pog.text(row.0))
          |> pog.parameter(pog.int(row.1))
          |> pog.parameter(pog.text(retention.encode(row.0, row.2)))
          |> pog.parameter(pog.int(retention.version))
          |> pog.execute(connection)
          |> result.replace(Nil)
        }),
      )
      Ok(list.length(rows.rows))
    },
    5,
  )
}

fn serial(
  connection: pog.Connection,
  work: fn(pog.Connection) -> Result(a, pog.QueryError),
  tries: Int,
) -> Result(a, String) {
  case
    pog.transaction(connection, fn(connection) {
      use _ <- result.try(
        pog.query("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
        |> pog.execute(connection),
      )
      work(connection)
    })
  {
    Ok(value) -> Ok(value)
    Error(error) -> {
      let error = case error {
        pog.TransactionQueryError(error) | pog.TransactionRolledBack(error) ->
          error
      }
      case error {
        pog.PostgresqlError(code: "40001", ..)
          | pog.PostgresqlError(code: "40P01", ..)
          if tries > 1
        -> serial(connection, work, tries - 1)
        _ -> Error(backend.describe(error))
      }
    }
  }
}

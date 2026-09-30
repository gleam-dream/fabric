//// Database-wide diagnostic snapshots. Run ages measure time since the latest
//// durable record write, not time in a phase. Intervention groups can overlap.

import fabric/statistics as projection
import fabric_postgres/internal/backend
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import pog

pub type Group {
  Group(count: Int, oldest_record_age_ms: Option(Int))
}

pub type NodeLeases {
  NodeLeases(node: String, count: Int)
}

pub type ExpiredLeases {
  ExpiredLeases(count: Int, oldest_overdue_ms: Option(Int))
}

pub type Snapshot {
  Snapshot(
    sampled_at_ms: Int,
    working: Group,
    unattended: Group,
    waiting: Group,
    finished: Group,
    approval: Group,
    reconciliation: Group,
    unknown: Group,
    budget_records: Int,
    leases_per_node: List(NodeLeases),
    expired_leases: ExpiredLeases,
  )
}

fn group_decoder() -> decode.Decoder(Group) {
  use count <- decode.field("count", decode.int)
  use age <- decode.field("oldest_record_age_ms", decode.optional(decode.int))
  decode.success(Group(count, age))
}

fn snapshot_decoder() -> decode.Decoder(Snapshot) {
  use sampled_at_ms <- decode.field("sampled_at_ms", decode.int)
  use working <- decode.field("working", group_decoder())
  use unattended <- decode.field("unattended", group_decoder())
  use waiting <- decode.field("waiting", group_decoder())
  use finished <- decode.field("finished", group_decoder())
  use approval <- decode.field("approval", group_decoder())
  use reconciliation <- decode.field("reconciliation", group_decoder())
  use unknown <- decode.field("unknown", group_decoder())
  use budget_records <- decode.field("budget_records", decode.int)
  use leases_per_node <- decode.field(
    "leases_per_node",
    decode.list({
      use node <- decode.field("node", decode.string)
      use count <- decode.field("count", decode.int)
      decode.success(NodeLeases(node, count))
    }),
  )
  use expired_leases <- decode.field("expired_leases", {
    use count <- decode.field("count", decode.int)
    use age <- decode.field("oldest_overdue_ms", decode.optional(decode.int))
    decode.success(ExpiredLeases(count, age))
  })
  decode.success(Snapshot(
    sampled_at_ms,
    working,
    unattended,
    waiting,
    finished,
    approval,
    reconciliation,
    unknown,
    budget_records,
    leases_per_node,
    expired_leases,
  ))
}

/// One SELECT supplies one MVCC snapshot and one clock sample. Only the small
/// diagnostic projection is read, never execution record bodies.
@internal
pub fn read(
  connection: pog.Connection,
  table: String,
) -> Result(Snapshot, String) {
  let sql =
    "WITH sample AS MATERIALIZED (SELECT clock_timestamp() AS at), rows AS MATERIALIZED ("
    <> "SELECT r.updated_at, r.lease_owner, r.lease_until, r.statistics, CASE WHEN "
    <> "r.statistics_revision = r.revision AND r.statistics->>'version' = $1 AND ("
    <> "r.statistics->>'kind' = 'budget' OR (r.statistics->>'kind' = 'run'"
    <> " AND r.statistics->>'execution' IN ('active','waiting','finished')"
    <> " AND r.statistics->>'approval' IN ('true','false')"
    <> " AND r.statistics->>'reconciliation' IN ('true','false')))"
    <> " THEN r.statistics->>'kind' ELSE 'unknown' END AS kind FROM "
    <> table
    <> " r)"
    <> " SELECT jsonb_build_object('sampled_at_ms', (SELECT floor(extract(epoch FROM at)*1000)::bigint FROM sample),"
    <> "'working', "
    <> group_sql(
      "kind = 'run' AND statistics->>'execution' = 'active' AND lease_until > at",
    )
    <> ","
    <> "'unattended', "
    <> group_sql(
      "kind = 'run' AND statistics->>'execution' = 'active' AND (lease_until IS NULL OR lease_until <= at)",
    )
    <> ","
    <> "'waiting', "
    <> group_sql("kind = 'run' AND statistics->>'execution' = 'waiting'")
    <> ","
    <> "'finished', "
    <> group_sql("kind = 'run' AND statistics->>'execution' = 'finished'")
    <> ","
    <> "'approval', "
    <> group_sql("kind = 'run' AND statistics->>'approval' = 'true'")
    <> ","
    <> "'reconciliation', "
    <> group_sql("kind = 'run' AND statistics->>'reconciliation' = 'true'")
    <> ","
    <> "'unknown', "
    <> group_sql("kind = 'unknown'")
    <> ","
    <> "'budget_records', (SELECT count(*) FROM rows WHERE kind = 'budget'),"
    <> "'leases_per_node', (SELECT coalesce(jsonb_agg(jsonb_build_object('node', node, 'count', count) ORDER BY node), '[]'::jsonb) FROM ("
    <> "SELECT split_part(lease_owner, '/', 1) AS node, count(*) FROM rows CROSS JOIN sample WHERE lease_until > at GROUP BY 1) owners),"
    <> "'expired_leases', (SELECT jsonb_build_object('count', count(*), 'oldest_overdue_ms', "
    <> "max(greatest(0, floor(extract(epoch FROM (at - lease_until))*1000)))::bigint)"
    <> " FROM rows CROSS JOIN sample WHERE lease_owner IS NOT NULL AND lease_until <= at))::text"
  use returned <- result.try(
    pog.query(sql)
    |> pog.parameter(pog.text(int.to_string(projection.version)))
    |> pog.returning(decode.field(0, decode.string, decode.success))
    |> pog.execute(connection)
    |> result.map_error(backend.describe),
  )
  case returned.rows {
    [encoded] ->
      json.parse(encoded, snapshot_decoder())
      |> result.replace_error("invalid database statistics result")
    _ -> Error("database statistics returned no single snapshot")
  }
}

fn group_sql(condition: String) -> String {
  "(SELECT jsonb_build_object('count', count(*), 'oldest_record_age_ms', "
  <> "max(greatest(0, floor(extract(epoch FROM (at - updated_at))*1000)))::bigint)"
  <> " FROM rows CROSS JOIN sample WHERE "
  <> condition
  <> ")"
}

/// Row locks and one transaction attach the projection to exactly the source
/// revision inspected. Unreadable rows receive the current unknown marker.
@internal
pub fn refresh(
  connection: pog.Connection,
  table: String,
  limit: Int,
) -> Result(Int, String) {
  pog.transaction(connection, fn(connection) {
    use returned <- result.try(
      pog.query(
        "SELECT run_id, revision, record FROM "
        <> table
        <> " WHERE statistics_revision IS DISTINCT FROM revision OR statistics->>'version' IS DISTINCT FROM $2"
        <> " ORDER BY run_id LIMIT $1 FOR UPDATE SKIP LOCKED",
      )
      |> pog.parameter(pog.int(limit))
      |> pog.parameter(pog.text(int.to_string(projection.version)))
      |> pog.returning({
        use id <- decode.field(0, decode.string)
        use revision <- decode.field(1, decode.int)
        use record <- decode.field(2, decode.string)
        decode.success(#(id, revision, record))
      })
      |> pog.execute(connection),
    )
    use Nil <- result.try(
      list.try_each(returned.rows, fn(row) {
        pog.query(
          "UPDATE "
          <> table
          <> " SET statistics = $3::jsonb, statistics_revision = revision WHERE run_id = $1 AND revision = $2",
        )
        |> pog.parameter(pog.text(row.0))
        |> pog.parameter(pog.int(row.1))
        |> pog.parameter(pog.text(projection.encode(row.0, row.2)))
        |> pog.execute(connection)
        |> result.replace(Nil)
      }),
    )
    Ok(list.length(returned.rows))
  })
  |> result.map_error(fn(error) {
    case error {
      pog.TransactionQueryError(error) | pog.TransactionRolledBack(error) ->
        backend.describe(error)
    }
  })
}

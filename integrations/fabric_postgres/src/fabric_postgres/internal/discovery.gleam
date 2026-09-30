//// Refresh scheduling metadata without changing execution bytes, revisions,
//// leases or retention ages. Row locks serialize refresh with ordinary writes.

import fabric/discovery
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import pog

pub fn refresh(
  connection: pog.Connection,
  table: String,
  limit: Int,
) -> Result(Int, String) {
  pog.transaction(connection, fn(connection) {
    let row = {
      use id <- decode.field(0, decode.string)
      use revision <- decode.field(1, decode.int)
      use encoded <- decode.field(2, decode.string)
      decode.success(#(id, revision, encoded))
    }
    use rows <- result.try(
      pog.query(
        "SELECT run_id, revision, record FROM "
        <> table
        <> " WHERE discovery_revision IS DISTINCT FROM revision OR discovery->>'version' IS DISTINCT FROM $2"
        <> " ORDER BY run_id LIMIT $1 FOR UPDATE SKIP LOCKED",
      )
      |> pog.parameter(pog.int(limit))
      |> pog.parameter(pog.text(int.to_string(discovery.version)))
      |> pog.returning(row)
      |> pog.execute(connection),
    )
    use Nil <- result.try(
      list.try_each(rows.rows, fn(row) {
        pog.query(
          "UPDATE "
          <> table
          <> " SET discovery = $3::jsonb, discovery_revision = revision, observed_key = NULL, observed_revision = NULL, discovery_checked_at = '-infinity' WHERE run_id = $1 AND revision = $2",
        )
        |> pog.parameter(pog.text(row.0))
        |> pog.parameter(pog.int(row.1))
        |> pog.parameter(pog.text(discovery.encode(row.0, row.2)))
        |> pog.execute(connection)
        |> result.replace(Nil)
      }),
    )
    Ok(list.length(rows.rows))
  })
  |> result.map_error(string.inspect)
}

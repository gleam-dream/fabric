//// A record comes back exactly as written, byte for byte, which is what
//// lets Fabric recognise its own write by its token after an
//// `Unavailable`; the `phase` column follows the record's phase tag.

import fabric/store
import fabric_postgres
import fabric_postgres/support
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import pog

fn phase(
  connection: pog.Connection,
  schema: String,
  run: String,
) -> Option(String) {
  let assert Ok(returned) =
    pog.query(
      "SELECT phase FROM \"" <> schema <> "\".fabric_runs WHERE run_id = $1",
    )
    |> pog.parameter(pog.text(run))
    |> pog.returning(decode.field(
      0,
      decode.optional(decode.string),
      decode.success,
    ))
    |> pog.execute(connection)
  let assert [phase] = returned.rows
  phase
}

pub fn records_come_back_byte_for_byte_test() {
  let connection = support.pool(2)
  let schema = support.schema()
  let backend =
    fabric_postgres.backend(support.migrated(connection, "a", schema))
  let records = [
    #("{\"phase\":{\"tag\":\"ended\"},\"text\":\"a\\u0000b\"}", Some("ended")),
    #("{ \"z\" : 1 ,\n\t\"phase\" :{\"tag\":\"acting\"} }\r\n", Some("acting")),
    #(
      "{\"phase\":{\"tag\":\"awaiting_model\"},\"text\":\"ção 🎉 \\\"q\\\" \\\\u0000\"}",
      Some("awaiting_model"),
    ),
    #("{\"phase\":\"ended\"}", None),
    #("not json at all", None),
    #("", None),
    #(
      "{\"phase\":{\"tag\":\"stopping\"},\"transcript\":\""
        <> string.repeat("0123456789abcdef", 131_072)
        <> "\"}",
      Some("stopping"),
    ),
  ]
  list.index_map(records, fn(entry, index) {
    let #(record, tag) = entry
    let run = "run-b" <> string.repeat("0", index)
    backend.insert(run, record, store.Release) |> should.equal(Ok(Nil))
    backend.get(run) |> should.equal(Ok(store.Current(1, record, store.Free)))
    phase(connection, schema, run) |> should.equal(tag)
    // The same record written again: a new revision, the same bytes.
    backend.compare_and_set(run, 1, record, store.Claim("o1", 60_000))
    |> should.equal(Ok(Nil))
    backend.get(run)
    |> should.equal(Ok(store.Current(2, record, store.Held("o1", True))))
    phase(connection, schema, run) |> should.equal(tag)
  })
}

/// A run id outside what the table accepts is refused by its CHECK, as an
/// `Unavailable` write that changed nothing.
pub fn a_malformed_run_id_is_refused_test() {
  let connection = support.pool(1)
  let backend =
    fabric_postgres.backend(support.migrated(connection, "a", support.schema()))
  let assert Error(store.Unavailable(_)) =
    backend.insert("run a1; --", "x", store.Release)
  backend.get("run a1; --") |> should.equal(Error(store.NotFound))
}

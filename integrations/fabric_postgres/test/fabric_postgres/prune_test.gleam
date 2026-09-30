//// `prune` deletes finished runs a whole family at a time, never an ended
//// sub-agent run on its own.

import fabric/retention
import fabric/store
import fabric_postgres
import fabric_postgres/internal/migrations
import fabric_postgres/support
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import pog

fn record(id: String, phase: String, parent, children: List(String)) -> String {
  let action_id = fn(id) {
    json.object([#("turn", json.int(1)), #("call_id", json.string(id))])
  }
  let encoded =
    json.object([
      #("format", json.string("fabric.run")),
      #("version", json.int(6)),
      #("run", json.string(id)),
      #(
        "agent",
        json.object([#("name", json.string("test")), #("version", json.int(1))]),
      ),
      #("incarnation", json.int(1)),
      #("depth", json.int(0)),
      #(
        "parent",
        json.nullable(parent, fn(parent) {
          json.object([
            #("tag", json.string("agent")),
            #("run", json.string(parent)),
            #("action", action_id(id)),
          ])
        }),
      ),
      #(
        "limits",
        json.object([
          #("max_turns", json.int(5)),
          #("token_budget", json.null()),
          #("max_children", json.int(10)),
          #("max_depth", json.int(10)),
        ]),
      ),
      #("turns_used", json.int(1)),
      #("approvals_issued", json.int(0)),
      #(
        "usage",
        json.object([
          #("input_tokens", json.int(0)),
          #("output_tokens", json.int(0)),
          #("unreported_replies", json.int(0)),
        ]),
      ),
      #("transcript", json.array([], fn(value) { value })),
      #(
        "history",
        json.array(children, fn(child) {
          json.object([
            #("id", action_id(child)),
            #(
              "call",
              json.object([
                #("id", json.string(child)),
                #("name", json.string("delegate")),
                #("arguments", json.string("{}")),
                #("provider_id", json.null()),
                #("provider_state", json.null()),
              ]),
            ),
            #(
              "state",
              json.object([
                #("tag", json.string("succeeded")),
                #("content", json.string("ok")),
              ]),
            ),
            #("approvals", json.array([], fn(value) { value })),
            #("child", json.string(child)),
          ])
        }),
      ),
      #(
        "phase",
        json.object([
          #("tag", json.string(phase)),
          #("outcome", json.object([#("tag", json.string("cancelled"))])),
          #("turn", json.int(2)),
          #("actions", json.array([], fn(value) { value })),
        ]),
      ),
    ])
    |> json.to_string
  let assert Ok(_) = retention.inspect(encoded)
  encoded
}

fn parent(id) {
  case string.split(id, "-") |> list.reverse {
    [_, _, _, ..] as parts ->
      Some(parts |> list.drop(1) |> list.reverse |> string.join("-"))
    _ -> None
  }
}

pub fn prune_deletes_only_whole_finished_families_test() {
  let settings = support.migrated(support.pool(2), "a", support.schema())
  let backend = fabric_postgres.backend(settings)
  let rows = [
    // A finished family: the root, a child and a grandchild ended, a
    // child that never started.
    #("run-aa", "ended", store.Release),
    #("run-aa-1", "ended", store.Release),
    #("run-aa-1-1", "ended", store.Release),
    #("run-aa-2", "never_started", store.Release),
    // An ended root whose child still works.
    #("run-bb", "ended", store.Release),
    #("run-bb-1", "acting", store.Claim("o1", 60_000)),
    // A working root whose child ended.
    #("run-cc", "acting", store.Claim("o1", 60_000)),
    #("run-cc-1", "ended", store.Release),
    // An ended root whose ended child still holds a live lease.
    #("run-dd", "ended", store.Release),
    #("run-dd-1", "ended", store.Claim("sweeper", 60_000)),
    // A finished run on its own.
    #("run-ee", "ended", store.Release),
  ]
  list.each(rows, fn(row) {
    let #(run, phase, lease) = row
    backend.insert(
      run,
      record(
        run,
        phase,
        parent(run),
        list.filter_map(rows, fn(row) {
          case parent(row.0) == Some(run) {
            True -> Ok(row.0)
            False -> Error(Nil)
          }
        }),
      ),
      lease,
    )
    |> should.equal(Ok(Nil))
  })
  // Nothing ended long enough ago.
  fabric_postgres.prune(settings, ended_for: 60_000, limit: 10)
  |> should.equal(Ok(0))
  process.sleep(50)
  fabric_postgres.prune(settings, ended_for: 20, limit: 10)
  |> should.equal(Ok(5))
  let present =
    list.filter(rows, fn(row) { backend.get(row.0) |> result_ok })
    |> list.map(fn(row) { row.0 })
  present
  |> should.equal([
    "run-bb", "run-bb-1", "run-cc", "run-cc-1", "run-dd", "run-dd-1",
  ])
  fabric_postgres.prune(settings, ended_for: 0, limit: 10)
  |> should.equal(Ok(0))
}

fn result_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// `limit` bounds the families deleted per call, oldest first.
pub fn prune_deletes_at_most_limit_families_oldest_first_test() {
  let settings = support.migrated(support.pool(2), "a", support.schema())
  let backend = fabric_postgres.backend(settings)
  list.each(["run-a1", "run-a2", "run-a3"], fn(run) {
    let assert Ok(Nil) =
      backend.insert(
        run,
        record(run, "ended", None, [run <> "-1"]),
        store.Release,
      )
    let assert Ok(Nil) =
      backend.insert(
        run <> "-1",
        record(run <> "-1", "ended", Some(run), []),
        store.Release,
      )
    process.sleep(5)
  })
  fabric_postgres.prune(settings, ended_for: 0, limit: 2) |> should.equal(Ok(4))
  backend.get("run-a1") |> should.equal(Error(store.NotFound))
  backend.get("run-a2-1") |> should.equal(Error(store.NotFound))
  let assert Ok(_) = backend.get("run-a3")
  fabric_postgres.prune(settings, ended_for: 0, limit: 2) |> should.equal(Ok(2))
}

/// Concurrent prunes delete each family once.
pub fn concurrent_prunes_delete_each_family_once_test() {
  let settings = support.migrated(support.pool(8), "a", support.schema())
  let backend = fabric_postgres.backend(settings)
  list.each(list.repeat(Nil, 40), fn(_) {
    let run = "run-f" <> int_text(support.unique())
    let assert Ok(Nil) =
      backend.insert(
        run,
        record(run, "ended", None, [run <> "-1"]),
        store.Release,
      )
    let assert Ok(Nil) =
      backend.insert(
        run <> "-1",
        record(run <> "-1", "ended", Some(run), []),
        store.Release,
      )
  })
  let results = process.new_subject()
  list.each(list.repeat(Nil, 6), fn(_) {
    process.spawn(fn() {
      process.send(
        results,
        fabric_postgres.prune(settings, ended_for: 0, limit: 10),
      )
    })
  })
  let racing =
    list.map(list.repeat(Nil, 6), fn(_) {
      let assert Ok(Ok(deleted)) = process.receive(results, 10_000)
      deleted
    })
    |> list.fold(0, fn(sum, deleted) { sum + deleted })
  // Whatever the racing prunes left, one more takes; each run was counted
  // once.
  let assert Ok(rest) =
    fabric_postgres.prune(settings, ended_for: 0, limit: 100)
  { racing + rest } |> should.equal(80)
  fabric_postgres.prune(settings, ended_for: 0, limit: 100)
  |> should.equal(Ok(0))
}

pub fn prune_checks_its_arguments_test() {
  let settings = support.migrated(support.pool(1), "a", support.schema())
  fabric_postgres.prune(settings, ended_for: -1, limit: 1)
  |> should.equal(Error(fabric_postgres.PruneAgeNegative(-1)))
  fabric_postgres.prune(settings, ended_for: 0, limit: 0)
  |> should.equal(Error(fabric_postgres.PruneLimitNotPositive(0)))
  fabric_postgres.refresh_retention(settings, 0)
  |> should.equal(Error(fabric_postgres.RefreshLimitNotPositive(0)))
}

pub fn missing_unreadable_and_unexpected_children_keep_the_entire_family_test() {
  list.each([0, 1, 2, 3], fn(kind) {
    let settings = support.migrated(support.pool(2), "a", support.schema())
    let backend = fabric_postgres.backend(settings)
    let children = case kind {
      3 -> []
      _ -> ["custom-1"]
    }
    let assert Ok(_) =
      backend.insert(
        "custom",
        record("custom", "ended", None, children),
        store.Release,
      )
    case kind {
      0 -> Nil
      _ -> {
        let child = record("custom-1", "ended", Some("custom"), [])
        let child = case kind {
          1 -> string.replace(child, "\"version\":6", "\"version\":999")
          2 -> string.replace(child, "\"turn\":1", "\"turn\":99")
          _ -> child
        }
        let assert Ok(_) = backend.insert("custom-1", child, store.Release)
        Nil
      }
    }
    fabric_postgres.prune(settings, ended_for: 0, limit: 10)
    |> should.equal(Ok(0))
    backend.get("custom") |> should.be_ok
  })
}

pub fn id_prefixes_do_not_define_families_and_a_blocked_root_does_not_starve_others_test() {
  let settings = support.migrated(support.pool(2), "a", support.schema())
  let backend = fabric_postgres.backend(settings)
  let assert Ok(_) =
    backend.insert(
      "run-aa",
      record("run-aa", "ended", None, ["run-aa-9"]),
      store.Release,
    )
  let assert Ok(_) =
    backend.insert(
      "run-aa-1",
      record("run-aa-1", "ended", None, []),
      store.Release,
    )
  fabric_postgres.prune(settings, ended_for: 0, limit: 1) |> should.equal(Ok(1))
  backend.get("run-aa-1") |> should.equal(Error(store.NotFound))
  backend.get("run-aa") |> should.be_ok
  let assert Ok(_) =
    backend.insert(
      "run-aa-9",
      record("run-aa-9", "never_started", Some("run-aa"), []),
      store.Release,
    )
  fabric_postgres.prune(settings, ended_for: 0, limit: 1) |> should.equal(Ok(2))
  // A delayed duplicate start cannot recreate an orphan after deletion.
  let assert Error(store.Unavailable(_)) =
    backend.insert(
      "run-aa-9",
      record("run-aa-9", "ended", Some("run-aa"), []),
      store.Release,
    )
  backend.get("run-aa-9") |> should.equal(Error(store.NotFound))
}

pub fn unresolved_agent_effects_and_recent_child_changes_prevent_pruning_test() {
  let connection = support.pool(2)
  let schema = support.schema()
  let settings = support.migrated(connection, "a", schema)
  let backend = fabric_postgres.backend(settings)
  let root = record("root", "ended", None, ["root-1"])
  let uncertain =
    string.replace(
      root,
      "\"tag\":\"succeeded\"",
      "\"tag\":\"uncertain\",\"evidence\":\"lost\"",
    )
  let assert Ok(_) = backend.insert("root", uncertain, store.Release)
  let assert Ok(_) =
    backend.insert(
      "root-1",
      record("root-1", "ended", Some("root"), []),
      store.Release,
    )
  fabric_postgres.prune(settings, ended_for: 0, limit: 1) |> should.equal(Ok(0))
  let assert Ok(_) = backend.compare_and_set("root", 1, root, store.Release)
  let assert Ok(_) =
    pog.query(
      "UPDATE \""
      <> schema
      <> "\".fabric_runs SET updated_at = clock_timestamp() - interval '1 hour' WHERE run_id = 'root'",
    )
    |> pog.execute(connection)
  fabric_postgres.prune(settings, ended_for: 30_000, limit: 1)
  |> should.equal(Ok(0))
  fabric_postgres.prune(settings, ended_for: 0, limit: 1) |> should.equal(Ok(2))
}

pub fn migration_refresh_preserves_bytes_and_old_writer_changes_invalidate_metadata_test() {
  let connection = support.pool(2)
  let schema = support.schema()
  let assert Ok(settings) =
    fabric_postgres.settings(connection, "a")
    |> fabric_postgres.with_schema(schema)
  let assert [first, ..] = migrations.all()
  let assert Ok(_) =
    pog.transaction(connection, fn(connection) {
      use _ <- result.try(
        pog.query("CREATE SCHEMA \"" <> schema <> "\"")
        |> pog.execute(connection),
      )
      use _ <- result.try(
        pog.query("SET LOCAL search_path TO \"" <> schema <> "\"")
        |> pog.execute(connection),
      )
      list.try_each(first.statements, fn(statement) {
        pog.query(statement) |> pog.execute(connection) |> result.replace(Nil)
      })
    })
  let root = record("old-root", "ended", None, ["old-root-1"])
  let child = record("old-root-1", "ended", Some("old-root"), [])
  list.each(
    [#("old-root", root), #("old-root-1", child), #("unreadable", "not json")],
    fn(row) {
      let assert Ok(_) =
        pog.query(
          "INSERT INTO \""
          <> schema
          <> "\".fabric_runs (run_id, revision, record, phase) VALUES ($1, 1, $2, 'ended')",
        )
        |> pog.parameter(pog.text(row.0))
        |> pog.parameter(pog.text(row.1))
        |> pog.execute(connection)
    },
  )
  fabric_postgres.migrate(settings) |> should.be_ok
  fabric_postgres.prune(settings, ended_for: 0, limit: 10)
  |> should.equal(Ok(0))
  fabric_postgres.refresh_retention(settings, 10) |> should.equal(Ok(3))
  fabric_postgres.refresh_retention(settings, 10) |> should.equal(Ok(0))
  let backend = fabric_postgres.backend(settings)
  backend.get("old-root")
  |> should.equal(Ok(store.Current(1, root, store.Free)))
  backend.get("old-root-1")
  |> should.equal(Ok(store.Current(1, child, store.Free)))
  // A pre-upgrade backend writes the bytes and revision but no projection.
  let assert Ok(_) =
    pog.query(
      "UPDATE \""
      <> schema
      <> "\".fabric_runs SET revision = revision + 1, record = $1 WHERE run_id = 'old-root-1'",
    )
    |> pog.parameter(
      pog.text(record("old-root-1", "acting", Some("old-root"), [])),
    )
    |> pog.execute(connection)
  fabric_postgres.prune(settings, ended_for: 0, limit: 10)
  |> should.equal(Ok(0))
  fabric_postgres.refresh_retention(settings, 10) |> should.equal(Ok(1))
  fabric_postgres.prune(settings, ended_for: 0, limit: 10)
  |> should.equal(Ok(0))
  backend.compare_and_set("old-root-1", 2, child, store.Release) |> should.be_ok
  fabric_postgres.prune(settings, ended_for: 0, limit: 10)
  |> should.equal(Ok(2))
  backend.get("unreadable") |> should.be_ok
}

fn waits_for_lock(connection, schema, left) {
  let assert Ok(rows) =
    pog.query(
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE $1)",
    )
    |> pog.parameter(pog.text("WITH RECURSIVE%" <> schema <> "%"))
    |> pog.returning(decode.field(0, decode.bool, decode.success))
    |> pog.execute(connection)
  case rows.rows, left {
    [True], _ -> True
    _, n if n > 0 -> {
      process.sleep(10)
      waits_for_lock(connection, schema, n - 1)
    }
    _, _ -> False
  }
}

pub fn pruning_cannot_delete_a_child_whose_lease_is_renewed_concurrently_test() {
  let connection = support.pool(4)
  let schema = support.schema()
  let settings = support.migrated(connection, "a", schema)
  let backend = fabric_postgres.backend(settings)
  let assert Ok(_) =
    backend.insert(
      "root",
      record("root", "ended", None, ["root-1"]),
      store.Release,
    )
  let assert Ok(_) =
    backend.insert(
      "root-1",
      record("root-1", "ended", Some("root"), []),
      store.Claim("owner", 0),
    )
  let ready = process.new_subject()
  let renewed = process.new_subject()
  process.spawn(fn() {
    let result =
      pog.transaction(connection, fn(connection) {
        use _ <- result.try(
          pog.query(
            "UPDATE \""
            <> schema
            <> "\".fabric_runs SET lease_until = clock_timestamp() + interval '1 hour' WHERE run_id = 'root-1'",
          )
          |> pog.execute(connection),
        )
        let release = process.new_subject()
        process.send(ready, release)
        process.receive_forever(release)
        Ok(Nil)
      })
    process.send(renewed, result)
  })
  let assert Ok(release) = process.receive(ready, 5000)
  let pruned = process.new_subject()
  process.spawn(fn() {
    process.send(
      pruned,
      fabric_postgres.prune(settings, ended_for: 0, limit: 1),
    )
  })
  waits_for_lock(connection, schema, 100) |> should.be_true
  process.send(release, Nil)
  let assert Ok(Ok(_)) = process.receive(renewed, 5000)
  process.receive(pruned, 5000) |> should.equal(Ok(Ok(0)))
  backend.get("root") |> should.be_ok
  backend.get("root-1") |> should.be_ok
}

pub fn attachment_keys_with_nul_survive_the_metadata_index_test() {
  let settings = support.migrated(support.pool(2), "a", support.schema())
  let backend = fabric_postgres.backend(settings)
  let with_nul = fn(encoded) {
    string.replace(
      encoded,
      "\"call_id\":\"root-1\"",
      "\"call_id\":\"call\\u0000id\"",
    )
  }
  let root = record("root", "ended", None, ["root-1"]) |> with_nul
  let child = record("root-1", "ended", Some("root"), []) |> with_nul
  let assert Ok(_) = backend.insert("root", root, store.Release)
  let assert Ok(_) = backend.insert("root-1", child, store.Release)
  backend.get("root") |> should.equal(Ok(store.Current(1, root, store.Free)))
  backend.get("root-1") |> should.equal(Ok(store.Current(1, child, store.Free)))
  fabric_postgres.prune(settings, ended_for: 0, limit: 1) |> should.equal(Ok(2))
}

@external(erlang, "erlang", "integer_to_binary")
fn int_text(value: Int) -> String

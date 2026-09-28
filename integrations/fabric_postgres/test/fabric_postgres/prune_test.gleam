//// `prune` deletes finished runs a whole family at a time, never an ended
//// sub-agent run on its own.

import fabric/store
import fabric_postgres
import fabric_postgres/support
import gleam/erlang/process
import gleam/list
import gleeunit/should

fn record(phase: String) -> String {
  "{\"format\":\"fabric.run\",\"phase\":{\"tag\":\"" <> phase <> "\"}}"
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
    backend.insert(run, record(phase), lease) |> should.equal(Ok(Nil))
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
    let assert Ok(Nil) = backend.insert(run, record("ended"), store.Release)
    let assert Ok(Nil) =
      backend.insert(run <> "-1", record("ended"), store.Release)
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
    let assert Ok(Nil) = backend.insert(run, record("ended"), store.Release)
    let assert Ok(Nil) =
      backend.insert(run <> "-1", record("ended"), store.Release)
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
}

@external(erlang, "erlang", "integer_to_binary")
fn int_text(value: Int) -> String

//// The store port contract, run against both implementations, and the
//// directory store's durability.

import fabric/store.{type Store}
import fabric/support/flaky
import fabric/support/restart
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit/should

fn contract(open: fn() -> Store) -> Nil {
  let store = open()
  let assert Error(store.NotFound) = store.get(store, "run-a")
  store.insert(store, "run-a", "one", store.Keep) |> should.equal(Ok(1))
  store.insert(store, "run-a", "again", store.Keep)
  |> should.equal(Error(store.AlreadyExists))
  store.commit(store, "run-a", 1, "two", store.Keep) |> should.equal(Ok(2))
  store.commit(store, "run-a", 1, "stale", store.Keep)
  |> should.equal(Error(store.Conflict(2)))
  store.commit(store, "run-a", 5, "ahead", store.Keep)
  |> should.equal(Error(store.Conflict(2)))
  let assert Ok(store.Entry(revision: 2, record: "two", ..)) =
    store.get(store, "run-a")
  store.commit(store, "run-missing", 1, "x", store.Keep)
  |> should.equal(Error(store.NotFound))
  // Runs are independent.
  store.insert(store, "run-b", "b", store.Keep) |> should.equal(Ok(1))
  let assert Ok(store.Entry(revision: 2, ..)) = store.get(store, "run-a")
  Nil
}

pub fn the_in_memory_store_meets_the_port_contract_test() {
  contract(store.in_memory)
}

pub fn the_directory_store_meets_the_port_contract_test() {
  let dir = restart.temp_dir()
  contract(fn() {
    let assert Ok(store) = store.directory(dir)
    store
  })
  restart.remove_dir(dir)
}

/// Eight writers race to commit the same revision; exactly one wins.
fn race(stores: List(Store)) -> Nil {
  let assert [first, ..] = stores
  let assert Ok(1) = store.insert(first, "run-race", "base", store.Keep)
  let results = process.new_subject()
  list.index_map(stores, fn(store, index) {
    process.spawn(fn() {
      process.send(
        results,
        store.commit(
          store,
          "run-race",
          1,
          "writer " <> string.inspect(index),
          store.Keep,
        ),
      )
    })
  })
  let outcomes = list.map(stores, fn(_) { process.receive_forever(results) })
  list.count(outcomes, fn(outcome) { outcome == Ok(2) }) |> should.equal(1)
  list.count(outcomes, fn(outcome) { outcome == Error(store.Conflict(2)) })
  |> should.equal(list.length(stores) - 1)
}

pub fn concurrent_commits_of_one_revision_have_one_winner_in_memory_test() {
  let store = store.in_memory()
  race(list.repeat(store, 8))
}

/// Separate store processes over one directory share nothing but the
/// files, so this is the filesystem's compare-and-set at work.
pub fn concurrent_commits_through_separate_directory_stores_have_one_winner_test() {
  let dir = restart.temp_dir()
  race(
    list.map(list.repeat(Nil, 8), fn(_) {
      let assert Ok(store) = store.directory(dir)
      store
    }),
  )
  restart.remove_dir(dir)
}

pub fn the_directory_store_keeps_every_revision_on_disk_test() {
  let dir = restart.temp_dir()
  let #(owner, _) =
    restart.owned(fn() {
      let assert Ok(store) = store.directory(dir)
      let assert Ok(1) = store.insert(store, "run-d", "first", store.Keep)
      let assert Ok(2) = store.commit(store, "run-d", 1, "second", store.Keep)
      Nil
    })
  restart.kill(owner)
  let assert Ok(reopened) = store.directory(dir)
  let assert Ok(store.Entry(revision: 2, record: "second", ..)) =
    store.get(reopened, "run-d")
  // No temporary file is left behind.
  restart.list_dir(dir <> "/run-d")
  |> should.equal(
    Ok(["00000000000000000001.json", "00000000000000000002.json"]),
  )
  restart.remove_dir(dir)
}

pub fn the_directory_store_refuses_run_ids_that_are_not_names_test() {
  let dir = restart.temp_dir()
  let assert Ok(store) = store.directory(dir <> "/nested/root")
  store.insert(store, "../escape", "x", store.Keep)
  |> should.equal(Error(store.Unavailable("invalid run id")))
  let assert Error(store.Unavailable(_)) = store.get(store, "a/b")
  restart.remove_dir(dir)
}

pub fn a_crashing_backend_is_unavailable_not_fatal_test() {
  let broken =
    store.new(
      get: fn(_) { panic as "database driver bug" },
      insert: fn(_, _) { Error(store.Unavailable("read-only replica")) },
      compare_and_set: fn(_, _, _) { Ok(Nil) },
    )
  let assert Error(store.Unavailable(reason)) = store.get(broken, "run-x")
  string.contains(reason, "database driver bug") |> should.be_true
  store.insert(broken, "run-x", "r", store.Keep)
  |> should.equal(Error(store.Unavailable("read-only replica")))
}

pub fn a_closed_store_is_unavailable_test() {
  let store = store.in_memory()
  store.close(store)
  let assert Error(store.Unavailable(_)) = store.get(store, "run-x")
}

/// A backend that committed but reported `Unavailable` is read back: the
/// write is confirmed when the stored record is the one written.
pub fn a_write_the_backend_made_despite_an_error_is_confirmed_test() {
  let flaky = flaky.new()
  let store = flaky.store(flaky)
  flaky.arm(flaky, [flaky.FailAfter, flaky.FailAfter, flaky.FailBefore])
  store.insert(store, "run-f", "one", store.Keep) |> should.equal(Ok(1))
  store.commit(store, "run-f", 1, "two", store.Keep) |> should.equal(Ok(2))
  store.commit(store, "run-f", 2, "three", store.Keep)
  |> should.equal(Error(store.Unavailable("the backend blinked")))
  let assert Ok(store.Entry(revision: 2, record: "two", ..)) =
    store.get(store, "run-f")
}

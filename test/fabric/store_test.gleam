//// The store port contract, run against both implementations, and the
//// directory store's durability.

import fabric/store.{type Store}
import fabric/support/flaky
import fabric/support/restart
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
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

/// Every revision name stays (so a stale writer can never publish a name
/// again), but revisions older than the previous one are emptied: disk use
/// grows with the latest record, not with every record ever written.
pub fn the_directory_store_empties_revisions_older_than_the_previous_test() {
  let dir = restart.temp_dir()
  let assert Ok(store) = store.directory(dir)
  let assert Ok(1) = store.insert(store, "run-p", "first", store.Keep)
  let assert Ok(2) = store.commit(store, "run-p", 1, "second", store.Keep)
  let assert Ok(3) = store.commit(store, "run-p", 2, "third", store.Keep)
  let assert Ok(4) = store.commit(store, "run-p", 3, "fourth", store.Keep)
  store.commit(store, "run-p", 1, "stale", store.Keep)
  |> should.equal(Error(store.Conflict(4)))
  list.map([1, 2, 3, 4], fn(revision) {
    restart.read_file(
      dir <> "/run-p/0000000000000000000" <> int.to_string(revision) <> ".json",
    )
  })
  |> should.equal([Ok(""), Ok(""), Ok("third"), Ok("fourth")])
  let assert Ok(store.Entry(revision: 4, record: "fourth", ..)) =
    store.get(store, "run-p")
  restart.remove_dir(dir)
}

/// Opening a directory store removes temporary files a crashed writer
/// left behind, once they are old enough not to belong to a live writer.
pub fn opening_a_directory_store_sweeps_stale_temporary_files_test() {
  let dir = restart.temp_dir()
  let assert Ok(store) = store.directory(dir)
  let assert Ok(1) = store.insert(store, "run-t", "first", store.Keep)
  let assert Ok(Nil) = restart.write_file(dir <> "/run-t/.tmp-stale", "x")
  let assert Ok(Nil) = restart.age_file(dir <> "/run-t/.tmp-stale", 3600)
  let assert Ok(Nil) = restart.write_file(dir <> "/run-t/.tmp-fresh", "x")
  let assert Ok(_) = store.directory(dir)
  restart.list_dir(dir <> "/run-t")
  |> should.equal(Ok([".tmp-fresh", "00000000000000000001.json"]))
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

/// A backend call that hangs holds up neither other runs nor the store: it
/// is abandoned after the store's backend deadline and reported
/// `Unavailable`, while calls for other runs complete meanwhile.
pub fn a_hung_backend_call_blocks_only_its_run_until_its_deadline_test() {
  let entered = process.new_subject()
  let memory = store.in_memory()
  let hanging =
    store.with_backend_timeout(
      store.new(
        get: fn(run) {
          case run {
            "run-hung" -> {
              process.send(entered, Nil)
              process.sleep_forever()
              Error(store.NotFound)
            }
            _ ->
              case store.get(memory, run) {
                Ok(entry) -> Ok(store.Stored(entry.revision, entry.record))
                Error(error) -> Error(error)
              }
          }
        },
        insert: fn(run, record) {
          store.insert(memory, run, record, store.Keep) |> result.replace(Nil)
        },
        compare_and_set: fn(run, expected, record) {
          store.commit(memory, run, expected, record, store.Keep)
          |> result.replace(Nil)
        },
      ),
      200,
    )
  let hung = process.new_subject()
  process.spawn(fn() { process.send(hung, store.get(hanging, "run-hung")) })
  let assert Ok(Nil) = process.receive(entered, 1000)
  // While run-hung's call hangs, another run is served.
  store.insert(hanging, "run-ok", "one", store.Keep) |> should.equal(Ok(1))
  let assert Ok(store.Entry(revision: 1, record: "one", ..)) =
    store.get(hanging, "run-ok")
  let assert Ok(Error(store.Unavailable(reason))) = process.receive(hung, 5000)
  string.contains(reason, "200 ms") |> should.be_true
}

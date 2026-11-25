//// A watch that ended leaves nothing in the store's process: neither an
//// `unwatch` nor the exit of the watcher's owner keeps an entry.

import fabric/internal/store as store_core
import fabric/store
import fabric/support
import gleam/erlang/process
import gleam/int
import gleeunit/should

const cycles = 200

fn times(n: Int, body: fn(Int) -> Nil) -> Nil {
  case n > 0 {
    False -> Nil
    True -> {
      body(n)
      times(n - 1, body)
    }
  }
}

/// Waits until the store keeps `expected` watch entries. The store learns
/// of an exit by a monitor message, which no call of this process orders.
fn settles(runs: store.Store, expected: Int, remaining: Int) -> Nil {
  case store_core.watched(runs) {
    Ok(count) if count == expected -> Nil
    found -> {
      should.be_true(remaining > 0 || found == Ok(expected))
      process.sleep(1)
      settles(runs, expected, remaining - 1)
    }
  }
}

pub fn an_unwatched_run_leaves_no_entry_test() {
  let runs = support.store()
  let watcher = process.new_subject()
  times(cycles, fn(n) {
    let run = "unwatched-" <> int.to_string(n)
    let assert Ok(Nil) = store_core.watch(runs, run, watcher)
    store_core.unwatch(runs, run, watcher)
  })
  store_core.watched(runs) |> should.equal(Ok(0))
}

pub fn an_unwatch_of_a_run_never_watched_leaves_no_entry_test() {
  let runs = support.store()
  let watcher = process.new_subject()
  times(cycles, fn(n) {
    store_core.unwatch(runs, "never-" <> int.to_string(n), watcher)
  })
  store_core.watched(runs) |> should.equal(Ok(0))
}

pub fn an_exited_watcher_leaves_no_entry_test() {
  let runs = support.store()
  times(cycles, fn(n) {
    let watching = process.new_subject()
    let pid =
      process.spawn(fn() {
        let watcher = process.new_subject()
        let assert Ok(Nil) =
          store_core.watch(runs, "exited-" <> int.to_string(n), watcher)
        process.send(watching, Nil)
      })
    let monitor = process.monitor(pid)
    let assert Ok(Nil) = process.receive(watching, 1000)
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive_forever
  })
  settles(runs, 0, 1000)
}

pub fn one_ended_watch_keeps_the_others_of_its_run_test() {
  let runs = support.store()
  let kept = process.new_subject()
  let ended = process.new_subject()
  let assert Ok(Nil) = store_core.watch(runs, "shared", kept)
  let assert Ok(Nil) = store_core.watch(runs, "shared", ended)
  store_core.unwatch(runs, "shared", ended)
  let assert Ok(1) = store_core.insert(runs, "shared", "one", store_core.Keep)
  let assert Ok(Nil) = process.receive(kept, 1000)
  let assert Error(Nil) = process.receive(ended, 0)
  store_core.unwatch(runs, "shared", kept)
  store_core.watched(runs) |> should.equal(Ok(0))
}

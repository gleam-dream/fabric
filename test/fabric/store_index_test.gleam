//// The store's process finds the runs of an exited runner and the parked
//// runs that wait for a committed run without reading its other runs.
//// These tests fix what it must still find.

import fabric/internal/live
import fabric/internal/store as store_core
import fabric/store
import fabric/support
import gleam/erlang/process
import gleam/option
import gleeunit/should
import sinal/correlation

fn launch(runner: process.Pid) -> store_core.Ownership {
  let mailbox: process.Subject(live.Message) = process.new_subject()
  store_core.Launch(
    runner,
    store_core.Live(1, mailbox, "root", correlation.from_key("index")),
    False,
  )
}

/// A process that stands for a runner until it is told to stop.
fn runner() -> #(process.Pid, process.Subject(Nil)) {
  let ready = process.new_subject()
  let pid =
    process.spawn(fn() {
      let stop = process.new_subject()
      process.send(ready, stop)
      process.receive_forever(stop)
    })
  let assert Ok(stop) = process.receive(ready, 1000)
  #(pid, stop)
}

fn has_runner(runs: store.Store, run: String) -> Bool {
  let assert Ok(entry) = store_core.get(runs, run)
  option.is_some(entry.live)
}

pub fn a_runner_exit_releases_its_runs_and_no_other_test() {
  let runs = support.store()
  let #(first, stop_first) = runner()
  let #(second, _) = runner()
  let assert Ok(1) = store_core.insert(runs, "first-a", "{}", launch(first))
  let assert Ok(1) = store_core.insert(runs, "first-b", "{}", launch(first))
  let assert Ok(1) = store_core.insert(runs, "second", "{}", launch(second))
  let watcher = process.new_subject()
  let assert Ok(Nil) = store_core.watch(runs, "first-a", watcher)
  let assert Ok(Nil) = store_core.watch(runs, "first-b", watcher)
  let assert Ok(Nil) = store_core.watch(runs, "second", watcher)
  process.send(stop_first, Nil)
  let assert Ok(Nil) = process.receive(watcher, 1000)
  let assert Ok(Nil) = process.receive(watcher, 1000)
  has_runner(runs, "first-a") |> should.be_false
  has_runner(runs, "first-b") |> should.be_false
  has_runner(runs, "second") |> should.be_true
  let assert Error(Nil) = process.receive(watcher, 0)
}

pub fn the_exit_of_a_replaced_runner_keeps_the_run_of_its_successor_test() {
  let runs = support.store()
  let #(old, stop_old) = runner()
  let #(new, _) = runner()
  let assert Ok(1) = store_core.insert(runs, "taken", "{}", launch(old))
  let assert Ok(1) = store_core.insert(runs, "kept", "{}", launch(old))
  let assert Ok(2) = store_core.commit(runs, "taken", 1, "{}", launch(new))
  let watcher = process.new_subject()
  let assert Ok(Nil) = store_core.watch(runs, "kept", watcher)
  process.send(stop_old, Nil)
  // The store has handled the exit once it reports the old runner's own run.
  let assert Ok(Nil) = process.receive(watcher, 1000)
  has_runner(runs, "kept") |> should.be_false
  has_runner(runs, "taken") |> should.be_true
}

pub fn a_parked_run_wakes_for_its_current_dependencies_test() {
  let runs = support.store()
  let woken = process.new_subject()
  let park = fn(dependency, label) {
    store_core.Park([dependency], fn() {
      process.send(woken, label)
      store_core.KeepWatching
    })
  }
  let assert Ok(1) =
    store_core.insert(runs, "parent", "{}", park("child-a", "first"))
  // Parking reads once.
  let assert Ok("first") = process.receive(woken, 1000)
  let assert Ok(1) = store_core.insert(runs, "child-a", "{}", store_core.Keep)
  let assert Ok("first") = process.receive(woken, 1000)
  let assert Ok(2) =
    store_core.commit(runs, "parent", 1, "{}", park("child-b", "second"))
  let assert Ok("second") = process.receive(woken, 1000)
  let assert Ok(1) = store_core.insert(runs, "child-b", "{}", store_core.Keep)
  let assert Ok("second") = process.receive(woken, 1000)
}

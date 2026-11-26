//// Measures what one monitored exit costs the store's process while it
//// keeps `size` watches, for two kinds of watch:
////
//// - `ended`: `size` watches that were ended with `unwatch`;
//// - `held`: `size` watches of other runs, still in force.
////
//// Each sample times `exits` cycles of: a process watches one run and
//// exits, and the store answers a call after it. The time per cycle
//// includes the spawn, the watch call and the answer, which the `size` 0
//// rows show.
////
//// Run with `gleam run -m fabric/bench/store_watchers`.

import fabric/internal/store as store_core
import fabric/store
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/string

const sizes = [0, 1000, 10_000, 100_000]

const exits = 200

const samples = 5

type Kind {
  Ended
  Held
}

pub fn main() -> Nil {
  io.println("kind,size,exits,microseconds per exit (one per sample)")
  list.each([Ended, Held], fn(kind) {
    list.each(sizes, fn(size) {
      let runs = store.in_memory(process.new_name("bench-watchers"))
      let assert Ok(Nil) = store.start(runs)
      let watcher = process.new_subject()
      times(size, fn(n) {
        let run = "kept-" <> int.to_string(n)
        let assert Ok(Nil) = store_core.watch(runs, run, watcher)
        case kind {
          Ended -> store_core.unwatch(runs, run, watcher)
          Held -> Nil
        }
      })
      let assert Ok(_) = store_core.watched(runs)
      let measured =
        list.repeat(Nil, samples)
        |> list.map(fn(_) { int.to_string(sample(runs)) })
      let assert Ok(Nil) = store.stop(runs)
      io.println(string.join(
        [
          case kind {
            Ended -> "ended"
            Held -> "held"
          },
          int.to_string(size),
          int.to_string(exits),
          ..measured
        ],
        ",",
      ))
    })
  })
}

fn sample(runs: store.Store) -> Int {
  let started = now()
  times(exits, fn(n) {
    let pid =
      process.spawn_unlinked(fn() {
        let watcher = process.new_subject()
        let assert Ok(Nil) =
          store_core.watch(runs, "exit-" <> int.to_string(n), watcher)
        Nil
      })
    let monitor = process.monitor(pid)
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive_forever
    let assert Ok(_) = store_core.watched(runs)
    Nil
  })
  { now() - started } / exits
}

fn times(n: Int, body: fn(Int) -> Nil) -> Nil {
  case n > 0 {
    False -> Nil
    True -> {
      body(n)
      times(n - 1, body)
    }
  }
}

fn now() -> Int {
  monotonic_time(atom.create("microsecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int

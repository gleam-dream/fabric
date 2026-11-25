//// Measures what one message costs the store's process while it serves
//// `size` other runs, in three cases:
////
//// - `exit`: `size` runs have a live runner; each cycle one more runner is
////   registered by a commit and exits;
//// - `exit-leased`: the same on a leased store, where each registration
////   also sets the time of the next lease check;
//// - `commit`: `size` parked runs each wait for a dependency of their own;
////   each cycle commits another run that nothing waits for.
////
//// Each sample times `cycles` cycles and ends with a call the store
//// answers. The time per cycle includes the backend call of the commit,
//// which the `size` 0 rows show.
////
//// Run with `gleam run -m fabric/bench/store_scans`.

import fabric/internal/live
import fabric/internal/store as store_core
import fabric/store
import fabric/store/conformance
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleam/time/duration
import sinal/correlation

const sizes = [0, 1000, 10_000]

const cycles = 200

const samples = 5

type Case {
  Exit
  ExitLeased
  Commit
}

pub fn main() -> Nil {
  io.println("case,size,cycles,microseconds per cycle (one per sample)")
  list.each([Exit, ExitLeased, Commit], fn(measured) {
    list.each(sizes, fn(size) {
      let runs = started(measured)
      let idle = prepare(runs, measured, size)
      let assert Ok(_) = store_core.watched(runs)
      let results =
        list.repeat(Nil, samples)
        |> list.index_map(fn(_, sample) {
          int.to_string(time(runs, measured, sample))
        })
      list.each(idle, process.kill)
      let assert Ok(Nil) = store.stop(runs)
      io.println(string.join(
        [
          case measured {
            Exit -> "exit"
            ExitLeased -> "exit-leased"
            Commit -> "commit"
          },
          int.to_string(size),
          int.to_string(cycles),
          ..results
        ],
        ",",
      ))
    })
  })
}

fn started(measured: Case) -> store.Store {
  let name = process.new_name("bench-scans")
  let runs = case measured {
    Exit | Commit -> store.in_memory(name)
    ExitLeased -> {
      let assert Ok(leased) =
        store.leased(
          name,
          node: "bench",
          lease: duration.minutes(30),
          backend: conformance.leased_memory().backend,
        )
      leased
    }
  }
  let assert Ok(Nil) = store.start(runs)
  runs
}

/// Registers `size` runs the measured cycles do not touch, and returns the
/// processes that stand for their runners.
fn prepare(runs: store.Store, measured: Case, size: Int) -> List(process.Pid) {
  list.repeat(Nil, size)
  |> list.index_map(fn(_, n) {
    let run = "kept-" <> int.to_string(n)
    case measured {
      Exit | ExitLeased -> {
        let runner = process.spawn_unlinked(process.sleep_forever)
        let assert Ok(1) = store_core.insert(runs, run, "{}", launch(runner))
        [runner]
      }
      Commit -> {
        let parked =
          store_core.Park(["dependency-of-" <> run], fn() {
            store_core.KeepWatching
          })
        let assert Ok(1) = store_core.insert(runs, run, "{}", parked)
        []
      }
    }
  })
  |> list.flatten
}

fn launch(runner: process.Pid) -> store_core.Ownership {
  let mailbox: process.Subject(live.Message) = process.new_subject()
  store_core.Launch(
    runner,
    store_core.Live(1, mailbox, "root", correlation.from_key("bench")),
    False,
  )
}

fn time(runs: store.Store, measured: Case, sample: Int) -> Int {
  let begun = now()
  times(cycles, fn(n) {
    let run = "cycle-" <> int.to_string(sample) <> "-" <> int.to_string(n)
    case measured {
      Exit | ExitLeased -> {
        let go = process.new_subject()
        let runner =
          process.spawn_unlinked(fn() {
            let subject = process.new_subject()
            process.send(go, subject)
            process.receive_forever(subject)
          })
        let assert Ok(stop) = process.receive(go, 1000)
        let monitor = process.monitor(runner)
        let assert Ok(1) = store_core.insert(runs, run, "{}", launch(runner))
        process.send(stop, Nil)
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Nil })
        |> process.selector_receive_forever
      }
      Commit -> {
        let assert Ok(1) = store_core.insert(runs, run, "{}", store_core.Keep)
        Nil
      }
    }
    let assert Ok(_) = store_core.watched(runs)
    Nil
  })
  { now() - begun } / cycles
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

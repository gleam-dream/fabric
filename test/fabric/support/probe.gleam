//// Test instruments owned by the test process: a synchronous effect ledger
//// (its order is the causal order) and barriers that hold a tool body until
//// the test releases it. Tests wait on these, never on sleeps.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string

pub opaque type Ledger {
  Ledger(subject: Subject(LedgerMessage))
}

type LedgerMessage {
  Record(String, Subject(Nil))
  Entries(Subject(List(String)))
}

pub type Arrival {
  Arrival(name: String, release: Subject(Nil))
}

pub type Probe {
  Probe(ledger: Ledger, arrivals: Subject(Arrival))
}

/// Must be called by the test process: it owns `arrivals`.
pub fn new() -> Probe {
  let ready = process.new_subject()
  process.spawn(fn() {
    let subject = process.new_subject()
    process.send(ready, subject)
    ledger_loop(subject, [])
  })
  let assert Ok(subject) = process.receive(ready, 30_000)
  Probe(Ledger(subject), process.new_subject())
}

pub fn record(probe: Probe, entry: String) -> Nil {
  process.call(probe.ledger.subject, 30_000, Record(entry, _))
}

pub fn entries(probe: Probe) -> List(String) {
  process.call(probe.ledger.subject, 30_000, Entries)
}

pub fn count(probe: Probe, entry: String) -> Int {
  entries(probe) |> list.count(fn(e) { e == entry })
}

/// Called from a tool body: announce arrival and block until released.
pub fn gate(probe: Probe, name: String) -> Nil {
  let release = process.new_subject()
  process.send(probe.arrivals, Arrival(name, release))
  let assert Ok(Nil) = process.receive(release, 60_000)
  Nil
}

/// Called from the test process: the next arrival at any barrier.
pub fn arrival(probe: Probe) -> Arrival {
  let assert Ok(arrival) = process.receive(probe.arrivals, 30_000)
  arrival
}

pub fn release(arrival: Arrival) -> Nil {
  process.send(arrival.release, Nil)
}

/// The largest number of bodies between their `start:` and `end:` entries
/// at the same time.
pub fn peak(probe: Probe) -> Int {
  let #(_, peak) =
    list.fold(entries(probe), #(0, 0), fn(acc, entry) {
      let #(now, peak) = acc
      case
        string.starts_with(entry, "start:"),
        string.starts_with(entry, "end:")
      {
        True, _ -> #(now + 1, case now + 1 > peak {
          True -> now + 1
          False -> peak
        })
        _, True -> #(now - 1, peak)
        _, _ -> acc
      }
    })
  peak
}

fn ledger_loop(subject: Subject(LedgerMessage), entries: List(String)) -> Nil {
  case process.receive_forever(subject) {
    Record(entry, reply) -> {
      process.send(reply, Nil)
      ledger_loop(subject, [entry, ..entries])
    }
    Entries(reply) -> {
      process.send(reply, list.reverse(entries))
      ledger_loop(subject, entries)
    }
  }
}

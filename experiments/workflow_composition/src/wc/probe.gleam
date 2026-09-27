//// THROWAWAY (workflow composition experiment). Test instruments owned by
//// the test process, so they survive a simulated runtime restart: an effect
//// ledger (synchronous, so its order is the causal order) and barriers.

import gleam/erlang/process.{type Subject}
import gleam/list

pub opaque type Ledger {
  Ledger(subject: Subject(LedgerMsg))
}

type LedgerMsg {
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
  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    process.send(ready, subject)
    ledger_loop(subject, [])
  })
  let assert Ok(subject) = process.receive(ready, 1000)
  Probe(Ledger(subject), process.new_subject())
}

pub fn record(probe: Probe, entry: String) -> Nil {
  process.call(probe.ledger.subject, 1000, Record(entry, _))
}

pub fn entries(probe: Probe) -> List(String) {
  process.call(probe.ledger.subject, 1000, Entries)
}

pub fn count(probe: Probe, entry: String) -> Int {
  entries(probe) |> list.count(fn(e) { e == entry })
}

/// Called from a tool body: announce arrival, block until released.
pub fn gate(probe: Probe, name: String) -> Nil {
  let release = process.new_subject()
  process.send(probe.arrivals, Arrival(name, release))
  let assert Ok(Nil) = process.receive(release, 10_000)
  Nil
}

/// Called from the test process: wait for the next arrival at a barrier.
pub fn arrival(probe: Probe) -> Arrival {
  let assert Ok(arrival) = process.receive(probe.arrivals, 5000)
  arrival
}

pub fn release(arrival: Arrival) -> Nil {
  process.send(arrival.release, Nil)
}

fn ledger_loop(subject: Subject(LedgerMsg), entries: List(String)) -> Nil {
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

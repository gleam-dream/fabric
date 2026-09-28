//// The leased backend contract, checked with `fabric/testing`'s
//// conformance checks: the in-memory leased backend passes them, and a
//// backend that breaks a lease condition fails them.

import fabric/store
import fabric/testing
import gleam/list
import gleeunit/should

fn failures(new: fn() -> store.LeasedBackend) -> List(#(String, String)) {
  testing.leased_backend_checks(new)
  |> list.filter_map(fn(check) {
    case check.run() {
      Ok(Nil) -> Error(Nil)
      Error(problem) -> Ok(#(check.name, problem))
    }
  })
}

pub fn the_in_memory_leased_backend_conforms_test() {
  failures(fn() { store.leased_memory().backend })
  |> should.equal([])
}

/// A backend whose claims ignore another owner's live lease fails the
/// claim check, and only that one.
pub fn a_backend_that_ignores_live_leases_fails_the_claim_check_test() {
  let broken = fn() {
    let backend = store.leased_memory().backend
    store.LeasedBackend(
      ..backend,
      compare_and_set: fn(run, expected, record, lease) {
        let lease = case lease {
          store.Claim(owner, ttl) -> store.Seize(owner, ttl)
          other -> other
        }
        backend.compare_and_set(run, expected, record, lease)
      },
    )
  }
  failures(broken)
  |> list.map(fn(failure) { failure.0 })
  |> should.equal(["claim waits for another owner's live lease"])
}

/// The in-memory backend's clock moves forward on demand: a live lease
/// expires once the clock passes its end.
pub fn the_in_memory_clock_expires_a_lease_when_advanced_test() {
  let memory = store.leased_memory()
  let assert Ok(Nil) =
    memory.backend.insert("run-a", "a", store.Claim("o1", 1000))
  memory.backend.get("run-a")
  |> should.equal(Ok(store.Current(1, "a", store.Held("o1", True))))
  memory.advance(1000)
  memory.backend.get("run-a")
  |> should.equal(Ok(store.Current(1, "a", store.Held("o1", False))))
  memory.backend.claim_expired("o2", 1000, 10)
  |> should.equal(Ok(["run-a"]))
}

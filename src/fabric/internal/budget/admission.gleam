//// Shared capacity is additional to the runner's ownership and effect fences.
//// Only verified ancestry supplies a root; missing or unreadable ledgers never
//// turn a bounded family into an unbounded run.

import fabric/budget
import fabric/internal/ancestry
import fabric/internal/budget/ledger
import fabric/internal/budget/model as reservations
import fabric/internal/store
import fabric/run
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Error {
  Limited(budget.Denial)
  Closed
  Unavailable(String)
}

pub fn work(
  runs: store.Store,
  id: String,
  parent: Option(run.Parent),
  declaration: Option(reservations.Declaration),
  claim: reservations.Claim,
) -> Result(Nil, Error) {
  use family <- result.try(scope(runs, id, parent, declaration))
  use Nil <- result.try(case claim {
    reservations.Child(..) ->
      Error(Unavailable("a work claim cannot reserve a child"))
    _ if claim.run != id ->
      Error(Unavailable("a work claim belongs to another run"))
    _ -> Ok(Nil)
  })
  reserve(runs, family, claim)
}

pub fn child(
  runs: store.Store,
  id: String,
  parent: Option(run.Parent),
  declaration: Option(reservations.Declaration),
  child: String,
) -> Result(Nil, Error) {
  use family <- result.try(scope(runs, id, parent, declaration))
  reserve(runs, family, reservations.Child(child, family.depth + 1))
}

fn scope(runs, id, parent, declaration) {
  use family <- result.try(
    ancestry.family(runs, id, parent, declaration, 64)
    |> result.map_error(fn(error) { Unavailable(string.inspect(error)) }),
  )
  case family {
    None -> Error(Closed)
    Some(family) -> Ok(family)
  }
}

fn reserve(
  runs: store.Store,
  family: ancestry.Family,
  claim: reservations.Claim,
) {
  case family.limits {
    None -> Ok(Nil)
    Some(limits) -> {
      use Nil <- result.try(case store.supports_family_budget(runs) {
        True -> Ok(Nil)
        False ->
          Error(Unavailable("family budgets require agent record writer 7"))
      })
      ledger.reserve(runs, family.root, limits, claim)
      |> result.replace(Nil)
      |> result.map_error(fn(error) {
        case error {
          ledger.Reservation(reservations.Denied(reason)) -> Limited(reason)
          _ -> Unavailable(string.inspect(error))
        }
      })
    }
  }
}

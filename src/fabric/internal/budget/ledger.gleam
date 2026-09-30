//// Durable reservation mechanism, not an admission API. The integration must
//// first persist the root's immutable limits and verify membership/ownership.
//// The graph/agent runners are not wired to this mechanism yet.

import fabric/internal/budget/model as budget
import fabric/internal/budget/record
import fabric/run
import fabric/store
import gleam/result

pub type Error {
  Storage(store.StoreError)
  Unreadable(record.Error)
  InvalidRoot
  ChangedLimits
  Reservation(budget.Error)
  Contended
}

pub fn ensure(
  runs: store.Store,
  root: String,
  limits: budget.Limits,
) -> Result(budget.State, Error) {
  use _ <- result.try(run.parse_id(root) |> result.replace_error(InvalidRoot))
  use initial <- result.try(budget.new(limits) |> result.map_error(Reservation))
  case read(runs, root) {
    Ok(#(_, state)) -> compatible(state, limits)
    Error(Storage(store.NotFound)) -> {
      let encoded = record.encode(record.Record(root, initial))
      case
        store.insert(
          runs,
          record.id(root),
          encoded,
          store.Detached(False, False),
        )
      {
        Ok(_) -> Ok(initial)
        Error(store.AlreadyExists) -> {
          use #(_, state) <- result.try(read(runs, root))
          compatible(state, limits)
        }
        Error(error) -> Error(Storage(error))
      }
    }
    Error(error) -> Error(error)
  }
}

fn compatible(state, limits) {
  case budget.limits(state) == limits {
    True -> Ok(state)
    False -> Error(ChangedLimits)
  }
}

pub fn read(
  runs: store.Store,
  root: String,
) -> Result(#(Int, budget.State), Error) {
  use entry <- result.try(
    store.get(runs, record.id(root)) |> result.map_error(Storage),
  )
  use saved <- result.try(
    record.decode(entry.record) |> result.map_error(Unreadable),
  )
  case saved.root == root {
    True -> Ok(#(entry.revision, saved.state))
    False -> Error(Unreadable(record.Corrupt("budget belongs to another root")))
  }
}

pub fn reserve(
  runs: store.Store,
  root: String,
  limits: budget.Limits,
  claim: budget.Claim,
) -> Result(budget.State, Error) {
  reserve_attempt(runs, root, limits, claim, 5)
}

fn reserve_attempt(runs, root, limits, claim, tries) {
  use #(revision, state) <- result.try(read(runs, root))
  use _ <- result.try(compatible(state, limits))
  use next <- result.try(
    budget.reserve(state, claim) |> result.map_error(Reservation),
  )
  case next == state {
    True -> Ok(state)
    False -> {
      let encoded = record.encode(record.Record(root, next))
      case
        store.commit(
          runs,
          record.id(root),
          revision,
          encoded,
          store.Detached(False, False),
        )
      {
        Ok(_) -> Ok(next)
        Error(store.Conflict(_)) if tries > 1 ->
          reserve_attempt(runs, root, limits, claim, tries - 1)
        Error(store.Conflict(_)) -> Error(Contended)
        Error(error) -> Error(Storage(error))
      }
    }
  }
}

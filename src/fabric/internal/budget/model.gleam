//// Monotonic family reservations. Runtime admission will supply identities
//// after checking the saved family attachment; a grant alone authorizes no
//// effect. Unused or uncertain reservations are never implicitly refunded.

import fabric/budget.{
  type Denial, type Limits, type Usage, ChildLimit, DepthLimit, Usage, WorkLimit,
}
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// Root-owned declaration. No work may start before the ledger exists and
/// `initialized` has been committed. Once initialized, a missing ledger is
/// data loss, never permission to create fresh capacity.
pub type Declaration {
  Declaration(limits: Limits, initialized: Bool)
}

pub type Claim {
  GraphAttempt(run: String, activation: Int, attempt: Int)
  ModelAttempt(run: String, incarnation: Int, turn: Int, attempt: Int)
  ToolAction(run: String, turn: Int, call: String)
  Child(run: String, depth: Int)
}

pub type Error {
  InvalidLimits
  InvalidClaim
  ConflictingClaim
  Denied(Denial)
}

pub opaque type State {
  State(limits: Limits, claims: List(Claim), usage: Usage)
}

pub fn new(limits: Limits) -> Result(State, Error) {
  case
    limits.work >= 0
    && limits.children >= 0
    && limits.depth >= 0
    && limits.depth <= 63
  {
    True -> Ok(State(limits, [], Usage(0, 0)))
    False -> Error(InvalidLimits)
  }
}

pub fn limits(state: State) -> Limits {
  state.limits
}

pub fn claims(state: State) -> List(Claim) {
  state.claims
}

pub fn usage(state: State) -> Usage {
  state.usage
}

/// Identity excludes a child's asserted depth: a repeated child ID with a
/// different depth is a conflict, not another child reservation.
pub fn identity(claim: Claim) -> String {
  let fields = case claim {
    GraphAttempt(run, activation, attempt) -> [
      json.string("graph"),
      json.string(run),
      json.int(activation),
      json.int(attempt),
    ]
    ModelAttempt(run, incarnation, turn, attempt) -> [
      json.string("model"),
      json.string(run),
      json.int(incarnation),
      json.int(turn),
      json.int(attempt),
    ]
    ToolAction(run, turn, call) -> [
      json.string("tool"),
      json.string(run),
      json.int(turn),
      json.string(call),
    ]
    Child(run, _) -> [json.string("child"), json.string(run)]
  }
  json.array(fields, fn(value) { value }) |> json.to_string
}

pub fn reserve(state: State, claim: Claim) -> Result(State, Error) {
  use Nil <- result.try(case valid(claim) {
    True -> Ok(Nil)
    False -> Error(InvalidClaim)
  })
  let key = identity(claim)
  case list.find(state.claims, fn(saved) { identity(saved) == key }) {
    Ok(saved) if saved == claim -> Ok(state)
    Ok(_) -> Error(ConflictingClaim)
    Error(Nil) -> {
      use used <- result.try(case claim {
        Child(_, depth) if depth > state.limits.depth ->
          Error(Denied(DepthLimit(state.limits.depth, depth)))
        Child(..) if state.usage.children >= state.limits.children ->
          Error(Denied(ChildLimit(state.limits.children)))
        Child(..) ->
          Ok(Usage(..state.usage, children: state.usage.children + 1))
        _ if state.usage.work >= state.limits.work ->
          Error(Denied(WorkLimit(state.limits.work)))
        _ -> Ok(Usage(..state.usage, work: state.usage.work + 1))
      })
      Ok(State(state.limits, list.append(state.claims, [claim]), used))
    }
  }
}

fn valid(claim: Claim) -> Bool {
  let id = claim.run
  let allowed =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
  let valid_id =
    string.length(id) >= 1
    && string.length(id) <= 128
    && list.all(string.to_graphemes(id), string.contains(allowed, _))
  valid_id
  && case claim {
    GraphAttempt(_, activation, attempt) -> activation > 0 && attempt > 0
    ModelAttempt(_, incarnation, turn, attempt) ->
      incarnation > 0 && turn > 0 && attempt > 0
    ToolAction(_, turn, _) -> turn > 0
    Child(_, depth) -> depth > 0
  }
}

/// Restore through the same reservation rules, refusing duplicate identities,
/// excessive usage or invalid bounds instead of trusting serialized counters.
pub fn restore(limits: Limits, claims: List(Claim)) -> Result(State, Error) {
  use initial <- result.try(new(limits))
  list.try_fold(claims, initial, fn(state, claim) {
    use next <- result.try(reserve(state, claim))
    case next == state {
      True -> Error(ConflictingClaim)
      False -> Ok(next)
    }
  })
}

//// A family counter has its own CAS record so reservations cannot invalidate
//// a live workflow runner's revision. It stores data and a fresh write token.

import fabric/internal/budget/config
import fabric/internal/budget/model as budget
import fabric/run
import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/string

pub type Record {
  Record(root: String, state: budget.State)
}

pub type Error {
  UnsupportedVersion(Int)
  Corrupt(String)
}

@external(erlang, "fabric_ffi", "family_budget_id")
pub fn id(root: String) -> String

@external(erlang, "fabric_ffi", "random_id")
fn write_token() -> String

pub fn encode(record: Record) -> String {
  let limits = budget.limits(record.state)
  json.object([
    #("format", json.string("fabric.budget")),
    #("version", json.int(1)),
    #("write", json.string(write_token())),
    #("run", json.string(id(record.root))),
    #("root", json.string(record.root)),
    #("limits", config.encode(limits)),
    #("claims", json.array(budget.claims(record.state), claim_json)),
  ])
  |> json.to_string
}

fn claim_json(claim: budget.Claim) -> json.Json {
  let fields = case claim {
    budget.GraphAttempt(_, activation, attempt) -> [
      #("kind", json.string("graph")),
      #("activation", json.int(activation)),
      #("attempt", json.int(attempt)),
    ]
    budget.ModelAttempt(_, incarnation, turn, attempt) -> [
      #("kind", json.string("model")),
      #("incarnation", json.int(incarnation)),
      #("turn", json.int(turn)),
      #("attempt", json.int(attempt)),
    ]
    budget.ToolAction(_, turn, call) -> [
      #("kind", json.string("tool")),
      #("turn", json.int(turn)),
      #("call", json.string(call)),
    ]
    budget.Child(_, depth) -> [
      #("kind", json.string("child")),
      #("depth", json.int(depth)),
    ]
  }
  json.object([#("run", json.string(claim.run)), ..fields])
}

pub fn decode(text: String) -> Result(Record, Error) {
  let header = {
    use format <- decode.field("format", decode.string)
    use version <- decode.field("version", decode.int)
    decode.success(#(format, version))
  }
  use #(format, version) <- result.try(
    json.parse(text, header)
    |> result.map_error(fn(error) { Corrupt(string.inspect(error)) }),
  )
  use Nil <- result.try(case format, version {
    "fabric.budget", 1 -> Ok(Nil)
    "fabric.budget", version -> Error(UnsupportedVersion(version))
    _, _ -> Error(Corrupt("not a family budget record"))
  })
  let decoder = {
    use stored_id <- decode.field("run", decode.string)
    use root <- decode.field("root", decode.string)
    use limits <- decode.field("limits", config.limits_decoder())
    use claims <- decode.field("claims", decode.list(claim_decoder()))
    decode.success(#(stored_id, root, limits, claims))
  }
  use #(stored_id, root, limits, claims) <- result.try(
    json.parse(text, decoder)
    |> result.map_error(fn(error) { Corrupt(string.inspect(error)) }),
  )
  use Nil <- result.try(
    case result.is_ok(run.parse_id(root)) && stored_id == id(root) {
      True -> Ok(Nil)
      False -> Error(Corrupt("budget record does not match its root identity"))
    },
  )
  use state <- result.try(
    budget.restore(limits, claims)
    |> result.map_error(fn(error) { Corrupt(string.inspect(error)) }),
  )
  Ok(Record(root, state))
}

fn claim_decoder() {
  use kind <- decode.field("kind", decode.string)
  use run <- decode.field("run", decode.string)
  case kind {
    "graph" -> {
      use activation <- decode.field("activation", decode.int)
      use attempt <- decode.field("attempt", decode.int)
      decode.success(budget.GraphAttempt(run, activation, attempt))
    }
    "model" -> {
      use incarnation <- decode.field("incarnation", decode.int)
      use turn <- decode.field("turn", decode.int)
      use attempt <- decode.field("attempt", decode.int)
      decode.success(budget.ModelAttempt(run, incarnation, turn, attempt))
    }
    "tool" -> {
      use turn <- decode.field("turn", decode.int)
      use call <- decode.field("call", decode.string)
      decode.success(budget.ToolAction(run, turn, call))
    }
    "child" -> {
      use depth <- decode.field("depth", decode.int)
      decode.success(budget.Child(run, depth))
    }
    _ -> decode.failure(budget.Child("", 0), "a budget reservation kind")
  }
}

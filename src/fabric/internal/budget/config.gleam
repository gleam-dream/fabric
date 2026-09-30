//// The root's immutable budget declaration. Old record formats may omit it;
//// they may never hide a non-null declaration that their writer cannot retain.

import fabric/internal/budget/model as budget
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn encode(limits: budget.Limits) -> json.Json {
  json.object([
    #("work", json.int(limits.work)),
    #("children", json.int(limits.children)),
    #("depth", json.int(limits.depth)),
  ])
}

pub fn limits_decoder() -> Decoder(budget.Limits) {
  use work <- decode.field("work", decode.int)
  use children <- decode.field("children", decode.int)
  use depth <- decode.field("depth", decode.int)
  let limits = budget.Limits(work, children, depth)
  case budget.new(limits) {
    Ok(_) -> decode.success(limits)
    Error(_) -> decode.failure(limits, "valid family budget limits")
  }
}

pub fn field(supported: Bool) -> Decoder(Option(budget.Limits)) {
  use limits <- decode.then(case supported {
    True ->
      decode.field(
        "family_budget",
        decode.optional(limits_decoder()),
        decode.success,
      )
    False ->
      decode.optional_field(
        "family_budget",
        None,
        decode.optional(limits_decoder()),
        decode.success,
      )
  })
  case supported, limits {
    False, Some(_) -> decode.failure(None, "a format supporting family budgets")
    _, _ -> decode.success(limits)
  }
}

pub fn validate(
  root: Bool,
  limits: Option(budget.Limits),
) -> Result(Nil, String) {
  case root, limits {
    _, None -> Ok(Nil)
    False, Some(_) -> Error("only a root run may declare family budget limits")
    True, Some(limits) ->
      budget.new(limits)
      |> result.replace(Nil)
      |> result.replace_error("invalid family budget limits")
  }
}

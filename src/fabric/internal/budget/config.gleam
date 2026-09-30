//// The root's immutable budget declaration. Old record formats may omit it;
//// they may never hide a non-null declaration that their writer cannot retain.

import fabric/budget as quota

import fabric/internal/budget/model as budget
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result

pub fn encode(limits: quota.Limits) -> json.Json {
  json.object([
    #("work", json.int(limits.work)),
    #("children", json.int(limits.children)),
    #("depth", json.int(limits.depth)),
  ])
}

pub fn encode_declaration(declaration: budget.Declaration) -> json.Json {
  let limits = declaration.limits
  json.object([
    #("work", json.int(limits.work)),
    #("children", json.int(limits.children)),
    #("depth", json.int(limits.depth)),
    #("initialized", json.bool(declaration.initialized)),
  ])
}

fn declaration_decoder() -> Decoder(budget.Declaration) {
  use limits <- decode.then(limits_decoder())
  use initialized <- decode.field("initialized", decode.bool)
  decode.success(budget.Declaration(limits, initialized))
}

pub fn limits_decoder() -> Decoder(quota.Limits) {
  use work <- decode.field("work", decode.int)
  use children <- decode.field("children", decode.int)
  use depth <- decode.field("depth", decode.int)
  let limits = quota.Limits(work, children, depth)
  case budget.new(limits) {
    Ok(_) -> decode.success(limits)
    Error(_) -> decode.failure(limits, "valid family budget limits")
  }
}

pub fn field(supported: Bool) -> Decoder(Option(budget.Declaration)) {
  use limits <- decode.then(case supported {
    True ->
      decode.field(
        "family_budget",
        decode.optional(declaration_decoder()),
        decode.success,
      )
    False ->
      decode.optional_field(
        "family_budget",
        None,
        decode.optional(declaration_decoder()),
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
  limits: Option(budget.Declaration),
) -> Result(Nil, String) {
  case root, limits {
    _, None -> Ok(Nil)
    False, Some(_) -> Error("only a root run may declare family budget limits")
    True, Some(declaration) ->
      budget.new(declaration.limits)
      |> result.replace(Nil)
      |> result.replace_error("invalid family budget limits")
  }
}

pub fn encode_denial(denial: quota.Denial) -> json.Json {
  let #(kind, limit, requested) = case denial {
    quota.WorkLimit(limit) -> #("work", limit, None)
    quota.ChildLimit(limit) -> #("children", limit, None)
    quota.DepthLimit(limit, requested) -> #("depth", limit, Some(requested))
  }
  json.object([
    #("kind", json.string(kind)),
    #("limit", json.int(limit)),
    #("requested", json.nullable(requested, json.int)),
  ])
}

pub fn denial_decoder() -> Decoder(quota.Denial) {
  use kind <- decode.field("kind", decode.string)
  use limit <- decode.field("limit", decode.int)
  case kind, limit >= 0 {
    "work", True -> decode.success(quota.WorkLimit(limit))
    "children", True -> decode.success(quota.ChildLimit(limit))
    "depth", True -> {
      use requested <- decode.field("requested", decode.int)
      case requested > limit && limit <= 63 {
        True -> decode.success(quota.DepthLimit(limit, requested))
        False ->
          decode.failure(quota.WorkLimit(0), "a depth beyond the family limit")
      }
    }
    _, _ -> decode.failure(quota.WorkLimit(0), "a valid family budget refusal")
  }
}

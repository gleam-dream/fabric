import gleam/float
import gleam/list
import gleam/result
import gleam/string
import json/blueprint/codec
import json/blueprint/json_text
import json/blueprint/number
import json/blueprint/parser
import json/blueprint/parser_limits
import json/blueprint/value.{type Value}

pub fn parse(raw: String) -> Result(Value, String) {
  parser.parse_value_from_string(parser_limits.default(), raw)
  |> result.map_error(fn(_) { "invalid or unbounded classifier JSON" })
}

pub fn content(raw: Value) -> Result(Value, String) {
  use value <- result.try(parse(json_text.render_value(raw)))
  case value {
    value.String(_) | value.Object(_) | value.Array(_) -> Ok(value)
    _ -> Error("classifier content must be text, an object or an array")
  }
}

pub fn object(raw: Value) -> Result(List(#(String, Value)), String) {
  case raw {
    value.Object(fields) ->
      value.object(fields, value.RejectDuplicates)
      |> result.map(fn(_) { fields })
      |> result.map_error(fn(_) { "duplicate classifier object key" })
    _ -> Error("expected classifier object")
  }
}

pub fn required(
  fields: List(#(String, Value)),
  key: String,
) -> Result(Value, String) {
  list.key_find(fields, key)
  |> result.map_error(fn(_) { "missing classifier field: " <> key })
}

pub fn text(raw: Value) -> Result(String, String) {
  case raw {
    value.String(text) ->
      require(string.trim(text) != "", "expected nonempty classifier text")
      |> result.map(fn(_) { text })
    _ -> Error("expected nonempty classifier text")
  }
}

pub fn integer(raw: Value) -> Result(Int, String) {
  codec.decode_int_value(raw)
  |> result.map_error(fn(_) { "expected classifier integer" })
}

pub fn between(
  raw: Value,
  minimum: Int,
  maximum: Int,
) -> Result(Float, String) {
  use n <- result.try(case raw {
    value.Number(n) -> Ok(n)
    _ -> Error("expected classifier number")
  })
  use low <- result.try(
    number.from_int(minimum)
    |> result.map_error(fn(_) { "invalid numeric lower bound" }),
  )
  use high <- result.try(
    number.from_int(maximum)
    |> result.map_error(fn(_) { "invalid numeric upper bound" }),
  )
  use Nil <- result.try(require(
    number.compare(n, low) != number.LessThan
      && number.compare(n, high) != number.GreaterThan,
    "classifier number is outside its valid range",
  ))
  let text = number.number_text(n)
  let native_text = case string.split(text, "e") {
    [coefficient, exponent] -> decimal(coefficient) <> "e" <> exponent
    _ -> decimal(text)
  }
  use projected <- result.try(
    float.parse(native_text)
    |> result.map_error(fn(_) {
      "classifier number cannot be represented natively"
    }),
  )
  use Nil <- result.map(require(
    !{
      minimum == 0
      && projected == 0.0
      && number.compare(n, low) == number.GreaterThan
    },
    "classifier number underflows native precision",
  ))
  projected
}

fn decimal(text: String) -> String {
  case string.contains(text, ".") {
    True -> text
    False -> text <> ".0"
  }
}

pub fn require(condition: Bool, error: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(error)
  }
}

pub fn keys(fields: List(#(String, a))) -> List(String) {
  list.map(fields, fn(field) { field.0 })
}

pub fn same_keys(fields: List(#(String, a)), expected: List(String)) -> Bool {
  list.length(fields) == list.length(expected)
  && list.all(fields, fn(field) { list.contains(expected, field.0) })
}

/// Object order has no semantic significance in structured rubrics.
pub fn canonical(raw: Value) -> Value {
  case raw {
    value.Object(fields) ->
      value.Object(
        fields
        |> list.map(fn(field) { #(field.0, canonical(field.1)) })
        |> list.sort(fn(left, right) { string.compare(left.0, right.0) }),
      )
    value.Array(items) -> value.Array(list.map(items, canonical))
    other -> other
  }
}

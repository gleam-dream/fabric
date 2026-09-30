//// Typed TypeSafe questions, independent of chat and graph scheduling.

import fabric_typesafe/internal/wire
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import json/blueprint/value.{type Value}

pub type Noul {
  Noul(yes: Float)
}

pub type Alternative(a) {
  Alternative(label: String, value: a, description: Value)
}

pub type Probability(a) {
  Probability(label: String, value: a, probability: Float)
}

pub type Choice(a) {
  Choice(
    selected: a,
    label: String,
    probabilities: List(Probability(a)),
    confidence: Float,
  )
}

pub type Score {
  Score(
    position: Float,
    probabilities: List(#(Int, Float)),
    confidence: Float,
    levels: List(Value),
  )
}

pub opaque type Question(a) {
  Question(definition: Value, decode: fn(Value) -> Result(a, String))
}

pub opaque type Batch(a) {
  Batch(
    definitions: List(#(String, Value)),
    decode: fn(List(#(String, Value))) -> Result(a, String),
  )
}

/// Keep a yes probability until application routing chooses its own threshold.
pub fn noul(
  instructions: Value,
  criteria: Option(#(Value, Value)),
) -> Result(Question(Noul), String) {
  use instructions <- result.try(wire.content(instructions))
  use criteria <- result.try(case criteria {
    None -> Ok([])
    Some(#(yes, no)) -> {
      use yes <- result.try(wire.content(yes))
      use no <- result.map(wire.content(no))
      [#("criteria", value.Object([#("true", yes), #("false", no)]))]
    }
  })
  Ok(
    Question(
      value.Object([
        #("type", value.String("noul")),
        #("instructions", instructions),
        ..criteria
      ]),
      fn(raw) {
        use fields <- result.try(answer_fields(raw, "noul"))
        use raw <- result.try(wire.required(fields, "noul"))
        wire.between(raw, 0, 1) |> result.map(Noul)
      },
    ),
  )
}

/// Labels map to application-native values. The original labels and complete
/// distribution remain available even when several labels map to the same value.
pub fn choice(
  instructions: Value,
  alternatives: List(Alternative(a)),
) -> Result(Question(Choice(a)), String) {
  use instructions <- result.try(wire.content(instructions))
  use Nil <- result.try(wire.require(
    list.length(alternatives) >= 2 && list.length(alternatives) <= 255,
    "a Choice requires 2–255 options",
  ))
  use criteria <- result.try(
    list.try_map(alternatives, fn(alternative) {
      use Nil <- result.try(wire.require(
        string.trim(alternative.label) != "",
        "empty Choice label",
      ))
      use description <- result.map(case alternative.description {
        value.Null -> Ok(value.Null)
        other -> wire.content(other)
      })
      #(alternative.label, description)
    }),
  )
  use _ <- result.try(
    value.object(criteria, value.RejectDuplicates)
    |> result.map_error(fn(_) { "duplicate Choice label" }),
  )
  let labels =
    list.map(alternatives, fn(option) { #(option.label, option.value) })
  Ok(
    Question(
      value.Object([
        #("type", value.String("choice")),
        #("instructions", instructions),
        #("criteria", value.Object(criteria)),
      ]),
      fn(raw) {
        use fields <- result.try(answer_fields(raw, "choice"))
        use selected <- result.try(
          wire.required(fields, "choice") |> result.try(wire.text),
        )
        use selected_value <- result.try(
          list.key_find(labels, selected)
          |> result.map_error(fn(_) { "unknown selected Choice label" }),
        )
        use probabilities <- result.try(distribution(fields, wire.keys(labels)))
        use selected_probability <- result.try(
          list.key_find(probabilities, selected)
          |> result.map_error(fn(_) { "missing selected Choice probability" }),
        )
        use Nil <- result.try(wire.require(
          list.all(probabilities, fn(p) {
            p.1 <=. selected_probability +. 0.00001
          }),
          "selected Choice label is not maximal",
        ))
        use confidence <- result.try(
          wire.required(fields, "confidence")
          |> result.try(fn(n) { wire.between(n, 0, 1) }),
        )
        use typed <- result.map(
          list.try_map(labels, fn(label) {
            use probability <- result.map(
              list.key_find(probabilities, label.0)
              |> result.map_error(fn(_) { "missing Choice probability" }),
            )
            Probability(label.0, label.1, probability)
          }),
        )
        Choice(selected_value, selected, typed, confidence)
      },
    ),
  )
}

/// The position belongs to the authored rubric, from 0 through levels - 1.
pub fn score(
  instructions: Value,
  levels: List(Value),
) -> Result(Question(Score), String) {
  use instructions <- result.try(wire.content(instructions))
  use Nil <- result.try(wire.require(
    list.length(levels) >= 2 && list.length(levels) <= 10,
    "a Score requires 2–10 levels",
  ))
  use levels <- result.try(list.try_map(levels, wire.content))
  let legend =
    list.index_map(levels, fn(level, index) { #(int.to_string(index), level) })
  Ok(
    Question(
      value.Object([
        #("type", value.String("score")),
        #("instructions", instructions),
        #("criteria", value.Array(levels)),
      ]),
      fn(raw) {
        use fields <- result.try(answer_fields(raw, "score"))
        use returned_legend <- result.try(wire.required(fields, "legend"))
        use _ <- result.try(wire.object(returned_legend))
        use Nil <- result.try(wire.require(
          wire.canonical(returned_legend)
            == wire.canonical(value.Object(legend)),
          "Score legend differs from the sent rubric",
        ))
        use probabilities <- result.try(distribution(fields, wire.keys(legend)))
        use position <- result.try(
          wire.required(fields, "score")
          |> result.try(fn(n) { wire.between(n, 0, list.length(levels) - 1) }),
        )
        // The distribution is in rubric order after admission.
        let indexed =
          list.index_map(probabilities, fn(p, index) { #(index, p.1) })
        let expected =
          list.fold(indexed, 0.0, fn(total, p) {
            total +. int.to_float(p.0) *. p.1
          })
        use Nil <- result.try(wire.require(
          float.absolute_value(position -. expected)
            <=. 0.00001 *. int.to_float(list.length(levels)),
          "Score disagrees with its distribution",
        ))
        use confidence <- result.map(
          wire.required(fields, "confidence")
          |> result.try(fn(n) { wire.between(n, 0, 1) }),
        )
        Score(position, indexed, confidence, levels)
      },
    ),
  )
}

pub fn ask(id: String, question: Question(a)) -> Result(Batch(a), String) {
  use Nil <- result.map(wire.require(
    string.trim(id) != "",
    "empty classifier question ID",
  ))
  let decode = question.decode
  Batch([#(id, question.definition)], fn(fields) {
    wire.required(fields, id) |> result.try(decode)
  })
}

/// Independent questions share one state and HTTP request, with native answers.
pub fn combine(
  left: Batch(a),
  right: Batch(b),
) -> Result(Batch(#(a, b)), String) {
  let entries = list.append(left.definitions, right.definitions)
  use Nil <- result.try(wire.require(
    list.length(entries) <= 256,
    "classifier question count exceeds 256",
  ))
  use _ <- result.try(
    value.object(entries, value.RejectDuplicates)
    |> result.map_error(fn(_) { "duplicate classifier question ID" }),
  )
  let decode_left = left.decode
  let decode_right = right.decode
  Ok(
    Batch(entries, fn(fields) {
      use left <- result.try(decode_left(fields))
      use right <- result.map(decode_right(fields))
      #(left, right)
    }),
  )
}

pub fn definitions(batch: Batch(a)) -> Value {
  value.Object(batch.definitions)
}

pub fn decode(batch: Batch(a), answers: Value) -> Result(a, String) {
  use fields <- result.try(wire.object(answers))
  use Nil <- result.try(wire.require(
    wire.same_keys(fields, wire.keys(batch.definitions)),
    "classifier answer IDs do not match its questions",
  ))
  batch.decode(fields)
}

fn answer_fields(
  raw: Value,
  kind: String,
) -> Result(List(#(String, Value)), String) {
  use fields <- result.try(wire.object(raw))
  use actual <- result.try(wire.required(fields, "type"))
  use Nil <- result.map(wire.require(
    actual == value.String(kind),
    "classifier answer kind differs from its question",
  ))
  fields
}

fn distribution(
  fields: List(#(String, Value)),
  labels: List(String),
) -> Result(List(#(String, Float)), String) {
  use raw <- result.try(wire.required(fields, "probabilities"))
  use fields <- result.try(wire.object(raw))
  use Nil <- result.try(wire.require(
    wire.same_keys(fields, labels),
    "classifier probability labels do not match criteria",
  ))
  use probabilities <- result.try(
    list.try_map(labels, fn(label) {
      use raw <- result.try(wire.required(fields, label))
      use p <- result.map(wire.between(raw, 0, 1))
      #(label, p)
    }),
  )
  let sum = list.fold(probabilities, 0.0, fn(total, p) { total +. p.1 })
  use Nil <- result.map(wire.require(
    float.absolute_value(sum -. 1.0) <=. 0.00001,
    "classifier probabilities do not sum to one",
  ))
  probabilities
}

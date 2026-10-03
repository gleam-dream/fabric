//// The representation behind `fabric_typesafe/question.Question` and
//// `fabric_typesafe/question.Batch`. Each carries a placeholder answer of
//// its type, which the receipt codec needs and which is never a real answer.

import json/blueprint/value.{type Value}

pub opaque type Question(a) {
  Question(
    definition: Value,
    decode: fn(Value) -> Result(a, String),
    placeholder: a,
  )
}

pub opaque type Batch(a) {
  Batch(
    definitions: List(#(String, Value)),
    decode: fn(List(#(String, Value))) -> Result(a, String),
    placeholder: a,
  )
}

pub fn question(
  definition: Value,
  decode: fn(Value) -> Result(a, String),
  placeholder: a,
) -> Question(a) {
  Question(definition:, decode:, placeholder:)
}

pub fn question_definition(question: Question(a)) -> Value {
  question.definition
}

pub fn question_decode(
  question: Question(a),
) -> fn(Value) -> Result(a, String) {
  question.decode
}

pub fn question_placeholder(question: Question(a)) -> a {
  question.placeholder
}

pub fn batch(
  definitions: List(#(String, Value)),
  decode: fn(List(#(String, Value))) -> Result(a, String),
  placeholder: a,
) -> Batch(a) {
  Batch(definitions:, decode:, placeholder:)
}

pub fn definitions(batch: Batch(a)) -> List(#(String, Value)) {
  batch.definitions
}

pub fn decode(
  batch: Batch(a),
) -> fn(List(#(String, Value))) -> Result(a, String) {
  batch.decode
}

/// An answer of the batch's type, for a codec that needs one.
pub fn placeholder(batch: Batch(a)) -> a {
  batch.placeholder
}

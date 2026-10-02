import fabric_typesafe/question
import gleam/list
import gleam/option.{None}
import gleeunit/should
import json/blueprint/value

type Decision {
  Approve
  Revise
}

pub fn typed_batch_preserves_boolean_choice_and_rubric_evidence_test() {
  let assert Ok(noul) =
    question.noul(value.String("Is the arithmetic correct?"), None)
  let assert Ok(choice) =
    question.choice(value.String("What should happen?"), [
      question.Alternative("approve", Approve, value.String("Correct")),
      question.Alternative("revise", Revise, value.String("Incorrect")),
    ])
  let levels = [
    value.String("incorrect"),
    value.String("partial"),
    value.String("correct"),
  ]
  let assert Ok(score) =
    question.score(value.String("How correct is the statement?"), levels)
  let assert Ok(first) = question.ask("correct", noul)
  let assert Ok(second) = question.ask("decision", choice)
  let assert Ok(third) = question.ask("quality", score)
  let assert Ok(combined) = question.combine(second, third)
  let assert Ok(batch) = question.combine(first, combined)
  let answers =
    json(
      "{\"correct\":{\"type\":\"noul\",\"noul\":0.8},\"decision\":{\"type\":\"choice\",\"choice\":\"approve\",\"probabilities\":{\"revise\":0.2,\"approve\":0.8},\"confidence\":0.7},\"quality\":{\"type\":\"score\",\"score\":1.8,\"probabilities\":{\"0\":0.0,\"1\":0.2,\"2\":0.8},\"legend\":{\"0\":\"incorrect\",\"1\":\"partial\",\"2\":\"correct\"},\"confidence\":0.7}}",
    )
  let assert Ok(#(yes, #(decision, rating))) = question.decode(batch, answers)
  yes |> should.equal(question.Noul(0.8))
  decision.selected |> should.equal(Approve)
  decision.label |> should.equal("approve")
  decision.probabilities
  |> should.equal([
    question.Probability("approve", Approve, 0.8),
    question.Probability("revise", Revise, 0.2),
  ])
  rating.position |> should.equal(1.8)
  rating.levels |> should.equal(levels)
  rating.probabilities |> should.equal([#(0, 0.0), #(1, 0.2), #(2, 0.8)])
}

fn json(raw: String) -> value.Value {
  let assert Ok(value) = value.parse(raw, value.default_limits())
  value
}

pub fn invalid_question_definitions_are_rejected_before_network_work_test() {
  question.noul(value.Bool(True), None) |> should.be_error
  question.noul(value.Object([#("a", value.Null), #("a", value.Null)]), None)
  |> should.be_error
  question.choice(value.String("choose"), []) |> should.be_error
  question.choice(value.String("choose"), [
    question.Alternative("same", Approve, value.Null),
    question.Alternative("same", Revise, value.Null),
  ])
  |> should.be_error
  question.score(value.String("score"), [value.String("only")])
  |> should.be_error
  question.score(value.String("score"), list.repeat(value.String("level"), 11))
  |> should.be_error
  let assert Ok(noul) = question.noul(value.String("yes?"), None)
  question.ask("", noul) |> should.be_error
  let assert Ok(batch) = question.ask("answer", noul)
  question.combine(batch, batch) |> should.be_error
}

pub fn a_probability_is_checked_before_float_rounding_and_underflow_test() {
  let assert Ok(noul) = question.noul(value.String("yes?"), None)
  let assert Ok(batch) = question.ask("answer", noul)
  list.each(
    ["1.00000000000000001", "-0.00000000000000001", "1e-500", "2", "\"0.8\""],
    fn(raw) {
      question.decode(
        batch,
        json("{\"answer\":{\"type\":\"noul\",\"noul\":" <> raw <> "}}"),
      )
      |> should.be_error
    },
  )
  question.decode(batch, json("{\"answer\":{\"type\":\"noul\",\"noul\":1}}"))
  |> should.equal(Ok(question.Noul(1.0)))
  question.decode(batch, json("{\"answer\":{\"type\":\"noul\",\"noul\":0}}"))
  |> should.equal(Ok(question.Noul(0.0)))
}

pub fn unknown_incomplete_and_inconsistent_choice_evidence_is_rejected_test() {
  let assert Ok(choice) =
    question.choice(value.String("choose"), [
      question.Alternative("approve", Approve, value.Null),
      question.Alternative("revise", Revise, value.Null),
    ])
  let assert Ok(batch) = question.ask("decision", choice)
  list.each(
    [
      "{\"type\":\"noul\",\"noul\":0.5}",
      "{\"type\":\"choice\",\"choice\":\"approve\",\"probabilities\":{\"approve\":1},\"confidence\":1}",
      "{\"type\":\"choice\",\"choice\":\"other\",\"probabilities\":{\"approve\":0.8,\"revise\":0.2},\"confidence\":0.7}",
      "{\"type\":\"choice\",\"choice\":\"revise\",\"probabilities\":{\"approve\":0.8,\"revise\":0.2},\"confidence\":0.7}",
      "{\"type\":\"choice\",\"choice\":\"approve\",\"probabilities\":{\"approve\":0.8,\"revise\":0.1},\"confidence\":0.7}",
      "{\"type\":\"choice\",\"choice\":\"approve\",\"probabilities\":{\"approve\":0.8,\"revise\":0.2},\"confidence\":1.1}",
    ],
    fn(answer) {
      question.decode(batch, json("{\"decision\":" <> answer <> "}"))
      |> should.be_error
    },
  )
  question.decode(batch, json("{}")) |> should.be_error
  question.decode(
    batch,
    value.Object([#("decision", value.Null), #("decision", value.Null)]),
  )
  |> should.be_error
}

pub fn a_score_cannot_change_the_rubric_or_disagree_with_its_distribution_test() {
  let assert Ok(score) =
    question.score(value.String("rate"), [
      value.String("low"),
      value.String("middle"),
      value.String("high"),
    ])
  let assert Ok(batch) = question.ask("rating", score)
  list.each(
    [
      "{\"type\":\"score\",\"score\":0.5,\"probabilities\":{\"0\":0,\"1\":0.5,\"2\":0.5},\"legend\":{\"0\":\"low\",\"1\":\"middle\",\"2\":\"high\"},\"confidence\":0.1}",
      "{\"type\":\"score\",\"score\":1.5,\"probabilities\":{\"0\":0,\"1\":0.5,\"2\":0.5},\"legend\":{\"0\":\"high\",\"1\":\"middle\",\"2\":\"low\"},\"confidence\":0.1}",
      "{\"type\":\"score\",\"score\":3,\"probabilities\":{\"0\":0,\"1\":0,\"2\":1},\"legend\":{\"0\":\"low\",\"1\":\"middle\",\"2\":\"high\"},\"confidence\":1}",
    ],
    fn(answer) {
      question.decode(batch, json("{\"rating\":" <> answer <> "}"))
      |> should.be_error
    },
  )
}

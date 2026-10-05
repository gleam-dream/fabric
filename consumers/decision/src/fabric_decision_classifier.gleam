//// Non-generative decisions on the same routes as the structured LLM example.
//// Main performs one live request; tests configure an explicit protocol fixture.

import fabric/graph
import fabric/graph/classify as decision
import fabric/run
import fabric/store
import fabric_decision_demo/routing
import gleam/erlang/process
import gleam/io
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun
import http_gun/config as http_config
import json/blueprint/codec
import json/blueprint/value
import llm_wire
import llm_wire/classify
import llm_wire/classify/question

pub type Answers =
  #(question.Noul, #(question.Choice(routing.Decision), question.Score))

pub fn questions() -> question.Batch(Answers) {
  let noul =
    question.noul(value.String("Is this arithmetic statement correct?"), None)
  let choice =
    question.choice(
      value.String("Choose how to handle this arithmetic statement."),
      [
        question.alternative(
          "approve",
          routing.Approve,
          value.String("The arithmetic is correct."),
        ),
        question.alternative(
          "revise",
          routing.Revise,
          value.String("The arithmetic is incorrect or cannot be assessed."),
        ),
      ],
    )
  let score =
    question.score(
      value.String("Rate the arithmetic statement's correctness."),
      [
        value.String("Incorrect"),
        value.String("Partially correct or unclear"),
        value.String("Correct"),
      ],
    )
  let first = question.ask("correct", noul)
  let second = question.ask("decision", choice)
  let third = question.ask("quality", score)
  let rest = question.combine(second, third)
  let batch = question.combine(first, rest)
  batch
}

pub fn runtime(
  runs: store.Store,
  http: http_gun.Client,
  config: classify.Config,
  model: String,
) -> graph.Runtime(http_gun.Client, String, String) {
  let reviewer =
    decision.decision(
      run.DefinitionId("arithmetic-classifier", 1),
      codec.string(),
      questions(),
      config,
      fn(http, input) { decision.call(http, model, value.String(input)) },
    )
  routing.runtime(
    run.DefinitionId("arithmetic-classifier-graph", 1),
    runs,
    fn(_) { http },
    reviewer,
    fn(receipt) { Ok(receipt.answer.1.0.selected) },
  )
}

@external(erlang, "fabric_decision_demo_ffi", "environment")
fn environment(name: String) -> Result(String, Nil)

pub fn main() -> Nil {
  let key = case environment("TYPESAFE_API_KEY") {
    Ok(key) -> key
    Error(Nil) ->
      panic as "TYPESAFE_API_KEY is missing or empty; no classifier request was sent"
  }
  let assert Ok(http) = http_gun.start(http_config.default())
  let settings =
    classify.typesafe(fn() { key })
    |> classify.with_timeout(llm_wire.After(duration.seconds(20)))
  let model =
    environment("FABRIC_CLASSIFIER_MODEL") |> result.unwrap("jev-latest")
  let runs = store.in_memory(process.new_name("classifier-decision-demo"))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(id) = run.parse_id("classifier-decision")
  let assert Ok(handle) =
    graph.start(
      runtime(runs, http, settings, model),
      id,
      "2 + 2 = 4",
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(30_000))
  let assert Ok(done) = graph.snapshot(handle)
  let assert graph.Completed("approved") = done.status
  let assert [review, terminal] = done.receipts
  io.println(terminal.node)
  let assert Ok(receipt) =
    codec.decode_json(
      classify.receipt_codec(settings, questions()),
      review.output_json,
    )
  io.println("requested model: " <> receipt.requested_model)
  io.println("resolved model: " <> receipt.resolved_model)
  io.println("typed answers: " <> string.inspect(receipt.answer))
  io.println("usage: " <> string.inspect(receipt.usage))
  http_gun.stop(http)
}

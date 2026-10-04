//// Non-generative decisions on the same routes as the structured LLM example.
//// Main performs one live request; tests configure an explicit protocol fixture.

import fabric/graph
import fabric/run
import fabric/store
import fabric_decision_demo/routing
import fabric_typesafe
import fabric_typesafe/client
import fabric_typesafe/question
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

pub type Answers =
  #(question.Noul, #(question.Choice(routing.Decision), question.Score))

pub fn questions() -> question.Batch(Answers) {
  let assert Ok(noul) =
    question.noul(value.String("Is this arithmetic statement correct?"), None)
  let assert Ok(choice) =
    question.choice(
      value.String("Choose how to handle this arithmetic statement."),
      [
        question.Alternative(
          "approve",
          routing.Approve,
          value.String("The arithmetic is correct."),
        ),
        question.Alternative(
          "revise",
          routing.Revise,
          value.String("The arithmetic is incorrect or cannot be assessed."),
        ),
      ],
    )
  let assert Ok(score) =
    question.score(
      value.String("Rate the arithmetic statement's correctness."),
      [
        value.String("Incorrect"),
        value.String("Partially correct or unclear"),
        value.String("Correct"),
      ],
    )
  let assert Ok(first) = question.ask("correct", noul)
  let assert Ok(second) = question.ask("decision", choice)
  let assert Ok(third) = question.ask("quality", score)
  let assert Ok(rest) = question.combine(second, third)
  let assert Ok(batch) = question.combine(first, rest)
  batch
}

pub fn runtime(
  runs: store.Store,
  config: client.Config,
  model: String,
) -> graph.Runtime(client.Config, String, String) {
  let reviewer =
    fabric_typesafe.new(
      run.DefinitionId("arithmetic-classifier", 1),
      codec.string(),
      questions(),
      fn(settings, input) {
        #(settings, fabric_typesafe.Request(model, value.String(input)))
      },
    )
  routing.runtime(
    run.DefinitionId("arithmetic-classifier-graph", 1),
    runs,
    fn(_) { config },
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
  let assert Ok(settings) =
    client.new(
      http |> http_gun.with_timeout(http_config.After(duration.seconds(20))),
      key:,
    )
  let model =
    environment("FABRIC_CLASSIFIER_MODEL") |> result.unwrap("jev-latest")
  let runs = store.in_memory(process.new_name("classifier-decision-demo"))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(id) = run.parse_id("classifier-decision")
  let assert Ok(handle) =
    graph.start(
      runtime(runs, settings, model),
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
      fabric_typesafe.receipt_codec(questions()),
      review.output_json,
    )
  io.println("requested model: " <> receipt.requested_model)
  io.println("resolved model: " <> receipt.resolved_model)
  io.println("typed answers: " <> string.inspect(receipt.answer))
  io.println("usage: " <> string.inspect(receipt.usage))
  http_gun.stop(http)
}

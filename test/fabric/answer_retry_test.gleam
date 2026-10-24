//// The corrective answer turn (`agent.with_answer_attempts`): a final
//// answer the answer codec refuses gets one more model turn by default,
//// within the run's turn and token budgets; the turn is stored, so a
//// recovered run goes on with it (`answer-correction-pending` fixture,
//// written by this slice).

import fabric
import fabric/agent
import fabric/internal/store as store_core
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/restart
import fabric/telemetry
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import sinal

pub type Weather {
  Weather(city: String, sunny: Bool)
}

fn weather_codec() -> codec.Codec(Weather) {
  use city <- codec.field("city", codec.string(), get: fn(w) { w.city })
  use sunny <- codec.field("sunny", codec.bool(), get: fn(w) { w.sunny })
  codec.success(Weather(city:, sunny:))
}

const valid = "{\"city\":\"Paris\",\"sunny\":true}"

/// A model that answers with `answers` in turn (the last one again once
/// they run out) and reports each request's messages to `seen`.
fn answering(
  answers: List(String),
  seen: process.Subject(List(model.Message)),
) -> model.Model {
  model.new(fn(request: model.Request) {
    process.send(seen, request.messages)
    let text = case list.drop(answers, request.turn - 1), list.last(answers) {
      [text, ..], _ -> text
      [], Ok(last) -> last
      [], Error(Nil) -> ""
    }
    Ok(model.FinalAnswer(text, Some(model.Usage(3, 4))))
  })
}

fn forecaster(model: model.Model) {
  agent.new("forecaster", model, [], policy.always_allow())
  |> agent.with_answer(weather_codec())
}

fn finish(spec) {
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      support.agent(spec),
      id: run.new_id(),
      context: Nil,
      prompt: "weather in Paris?",
      correlation: None,
    )
  let assert Ok(status) = fabric.await(handle, within: duration.seconds(5))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  #(status, snapshot)
}

fn drain(subject: process.Subject(a), seen: List(a)) -> List(a) {
  case process.receive(subject, 100) {
    Ok(item) -> drain(subject, [item, ..seen])
    Error(Nil) -> list.reverse(seen)
  }
}

fn correction(messages: List(model.Message)) -> String {
  let assert Ok(model.UserMessage(text)) = list.last(messages)
  text
}

pub fn a_refused_answer_gets_a_corrective_turn_test() {
  let seen = process.new_subject()
  let turns = process.new_subject()
  let attachment =
    sinal.observe(telemetry.model_turn(), fn(_, metadata) {
      process.send(turns, metadata.result)
    })
  let #(status, snapshot) =
    finish(forecaster(answering(["sunny, probably", valid], seen)))
  let _ = sinal.detach(attachment)
  status |> should.equal(run.Finished(run.Completed(Weather("Paris", True))))
  snapshot.turns_used |> should.equal(2)
  let assert [first, second] = drain(seen, [])
  list.length(first) |> should.equal(1)
  // The second request holds the refused answer and the correction, which
  // names the codec's complaint and repeats the schema.
  let assert [
    model.UserMessage("weather in Paris?"),
    model.AssistantMessage(model.AssistantTurn("sunny, probably", [], None)),
    model.UserMessage(text),
  ] = second
  string.contains(text, "Your final answer could not be read: ")
  |> should.be_true
  string.contains(text, "\"sunny\":{\"type\":\"boolean\"}") |> should.be_true
  drain(turns, [])
  |> should.equal([telemetry.AnswerRejected, telemetry.FinalAnswer])
}

pub fn one_attempt_ends_the_run_on_the_first_refused_answer_test() {
  let seen = process.new_subject()
  let #(status, snapshot) =
    forecaster(answering(["sunny, probably", valid], seen))
    |> agent.with_answer_attempts(1)
    |> finish
  status
  |> should.equal(
    run.Finished(run.AnswerInvalid(
      raw: "sunny, probably",
      reason: "invalid JSON at line 1, column 1: unexpected character",
    )),
  )
  snapshot.turns_used |> should.equal(1)
  list.length(drain(seen, [])) |> should.equal(1)
}

pub fn the_run_ends_with_the_last_refused_answer_test() {
  let seen = process.new_subject()
  let #(status, snapshot) =
    forecaster(answering(["cloudy", "rainy", "{\"city\":\"Paris\"}"], seen))
    |> agent.with_answer_attempts(3)
    |> finish
  let assert run.Finished(run.AnswerInvalid(raw: "{\"city\":\"Paris\"}", ..)) =
    status
  snapshot.turns_used |> should.equal(3)
  let assert [_, _, third] = drain(seen, [])
  // Each correction follows its own refused answer.
  list.length(third) |> should.equal(5)
  string.contains(correction(third), "Your final answer could not be read")
  |> should.be_true
}

/// The corrective turn is a model attempt: with no turn left, the run ends
/// on the refused answer, not on the turn budget.
pub fn no_correction_when_the_turn_budget_is_spent_test() {
  let seen = process.new_subject()
  let #(status, snapshot) =
    forecaster(answering(["cloudy", valid], seen))
    |> agent.with_max_turns(1)
    |> finish
  let assert run.Finished(run.AnswerInvalid(raw: "cloudy", ..)) = status
  snapshot.turns_used |> should.equal(1)
}

pub fn no_correction_when_the_token_budget_is_spent_test() {
  let seen = process.new_subject()
  let #(status, snapshot) =
    forecaster(answering(["cloudy", valid], seen))
    |> agent.with_token_budget(7)
    |> finish
  let assert run.Finished(run.AnswerInvalid(raw: "cloudy", ..)) = status
  snapshot.turns_used |> should.equal(1)
  // Within the budget, the same answers get their correction.
  let #(status, _) =
    forecaster(answering(["cloudy", valid], seen))
    |> agent.with_token_budget(100)
    |> finish
  status |> should.equal(run.Finished(run.Completed(Weather("Paris", True))))
}

pub fn a_plain_answer_is_never_corrected_test() {
  let seen = process.new_subject()
  let #(status, snapshot) =
    agent.new(
      "plain",
      answering(["sunny, probably"], seen),
      [],
      policy.always_allow(),
    )
    |> finish
  status |> should.equal(run.Finished(run.Completed("sunny, probably")))
  snapshot.turns_used |> should.equal(1)
}

pub fn build_checks_the_answer_attempts_test() {
  let seen = process.new_subject()
  let spec = forecaster(answering([valid], seen))
  spec
  |> agent.with_answer_attempts(0)
  |> agent.build
  |> should.equal(Error([agent.InvalidLimit(agent.AnswerAttempts, 0, 1, 100)]))
  spec
  |> agent.with_answer_attempts(101)
  |> agent.build
  |> should.equal(
    Error([agent.InvalidLimit(agent.AnswerAttempts, 101, 1, 100)]),
  )
  agent.describe_config_error(agent.InvalidLimit(
    agent.AnswerAttempts,
    0,
    1,
    100,
  ))
  |> string.contains("agent.with_answer_attempts")
  |> should.be_true
}

// --- recovery ------------------------------------------------------------------

/// A store holding a run whose first answer was refused and whose
/// corrective turn was in flight when its runner was lost.
fn pending_correction() {
  let assert Ok(text) =
    restart.read_file("test/fixtures/records/answer-correction-pending.json")
  let runs = support.store()
  let assert Ok(_) =
    store_core.insert(
      runs,
      "run-answer-correction",
      text,
      store_core.Detached(True, False),
    )
  runs
}

pub fn a_recovered_run_issues_its_corrective_turn_again_test() {
  let runs = pending_correction()
  let seen = process.new_subject()
  let assert Ok(handle) =
    fabric.recover(
      runs,
      support.agent(forecaster(answering(["unused", valid], seen))),
      Nil,
      support.id("run-answer-correction"),
    )
  let assert Ok(status) = fabric.await(handle, within: duration.seconds(5))
  status |> should.equal(run.Finished(run.Completed(Weather("Paris", True))))
  // The model sees the stored correction, as the lost call would have.
  let assert [messages] = drain(seen, [])
  list.length(messages) |> should.equal(3)
  string.contains(correction(messages), "invalid JSON") |> should.be_true
  let assert Ok(snapshot) = fabric.snapshot(handle)
  snapshot.turns_used |> should.equal(3)
}

/// The stored transcript counts the refused answers, so a recovered run
/// does not get its attempts back.
pub fn a_recovered_run_keeps_its_count_of_refused_answers_test() {
  let runs = pending_correction()
  let seen = process.new_subject()
  let assert Ok(handle) =
    fabric.recover(
      runs,
      support.agent(forecaster(answering(["still cloudy"], seen))),
      Nil,
      support.id("run-answer-correction"),
    )
  let assert Ok(status) = fabric.await(handle, within: duration.seconds(5))
  let assert run.Finished(run.AnswerInvalid(raw: "still cloudy", ..)) = status
  list.length(drain(seen, [])) |> should.equal(1)
}

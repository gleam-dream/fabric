//// Typed final answers (`agent.with_answer`): the schema in every model
//// request, the decoded answer of a completed run, an answer the codec
//// refuses, typed sub-agents, store-only reads, and the adapter's
//// structured output.

import fabric
import fabric/agent
import fabric/internal/controller
import fabric/internal/record
import fabric/internal/runner
import fabric/llm
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/fake_provider
import fabric/support/scripted
import fabric/telemetry
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import llm_wire/message
import llm_wire/testing
import sinal

pub type Weather {
  Weather(city: String, sunny: Bool)
}

fn weather_codec() -> codec.Codec(Weather) {
  use city <- codec.field("city", codec.string(), get: fn(w) { w.city })
  use sunny <- codec.field("sunny", codec.bool(), get: fn(w) { w.sunny })
  codec.success(Weather(city:, sunny:))
}

/// A model that answers `text` at once and reports each request's answer
/// schema to `seen`.
fn answering(
  text: String,
  seen: process.Subject(Option(codec.Schema)),
) -> model.Model {
  model.new(fn(request: model.Request) {
    process.send(seen, request.answer)
    Ok(model.FinalAnswer(text, Some(model.Usage(3, 4))))
  })
}

fn forecaster(model: model.Model) {
  agent.new("forecaster", model, [], policy.always_allow())
  |> agent.with_answer(weather_codec())
  |> support.agent
}

fn finish(agent, prompt: String) {
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt:,
      correlation: None,
    )
  let assert Ok(status) = fabric.await(handle, within: duration.seconds(5))
  #(handle, status)
}

// --- the answer ------------------------------------------------------------------

pub fn a_typed_answer_completes_with_the_decoded_value_test() {
  let seen = process.new_subject()
  let #(handle, status) =
    finish(
      forecaster(answering("{\"city\":\"Paris\",\"sunny\":true}", seen)),
      "weather in Paris?",
    )
  status |> should.equal(run.Finished(run.Completed(Weather("Paris", True))))
  // The model was given the answer's schema.
  process.receive(seen, 1000) |> should.equal(Ok(Some(schema(weather_codec()))))
  // The snapshot reads the same answer; the record keeps the model's text.
  let assert Ok(snapshot) = fabric.snapshot(handle)
  snapshot.status
  |> should.equal(run.Finished(run.Completed(Weather("Paris", True))))
  let assert [_, model.AssistantMessage(turn)] = snapshot.transcript
  turn.text |> should.equal("{\"city\":\"Paris\",\"sunny\":true}")
}

fn schema(answer: codec.Codec(a)) -> codec.Schema {
  let assert Ok(schema) = codec.schema(answer)
  schema
}

pub fn a_plain_agent_asks_for_no_schema_test() {
  let seen = process.new_subject()
  let plain =
    agent.new("plain", answering("hello", seen), [], policy.always_allow())
    |> support.agent
  let #(_, status) = finish(plain, "say hello")
  status |> should.equal(run.Finished(run.Completed("hello")))
  process.receive(seen, 1000) |> should.equal(Ok(None))
}

/// The run ends on the answer it got: the text is kept, the codec says
/// why, and the run's events report the invalid answer.
pub fn an_answer_the_codec_refuses_ends_the_run_test() {
  let finished = process.new_subject()
  let attachment =
    sinal.observe(telemetry.run_finished(), fn(_, metadata) {
      process.send(finished, metadata.outcome)
    })
  let seen = process.new_subject()
  let #(handle, status) =
    finish(forecaster(answering("sunny, probably", seen)), "weather?")
  let _ = sinal.detach(attachment)
  let assert run.Finished(run.AnswerInvalid(raw:, reason:)) = status
  raw |> should.equal("sunny, probably")
  { reason != "" } |> should.be_true
  list.contains(drain(finished, []), telemetry.AnswerInvalid)
  |> should.be_true
  // A finished run answers no more commands; its record reads back.
  fabric.cancel(handle) |> should.equal(Error(fabric.RunEnded))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  snapshot.status |> should.equal(status)
}

fn drain(subject: process.Subject(a), seen: List(a)) -> List(a) {
  case process.receive(subject, 200) {
    Ok(item) -> drain(subject, [item, ..seen])
    Error(Nil) -> seen
  }
}

pub fn a_codec_without_a_schema_is_refused_by_build_test() {
  let unschematic =
    codec.custom(
      encode: codec.encode(codec.string(), _),
      decode: codec.decode(codec.string(), _),
      schema: None,
      placeholder: "",
    )
  agent.new(
    "opaque",
    scripted.model(fn(_) { model.FinalAnswer("x", None) }),
    [],
    policy.always_allow(),
  )
  |> agent.with_answer(unschematic)
  |> agent.build
  |> should.equal(Error([agent.AnswerSchemaUnavailable]))
  agent.describe_config_error(agent.AnswerSchemaUnavailable)
  |> string.contains("agent.with_answer")
  |> should.be_true
}

// --- the record --------------------------------------------------------------------

/// An invalid answer is stored as a completion that names why its answer
/// is invalid: a reader that ignores the key reads the text answer.
pub fn an_invalid_answer_is_stored_as_a_marked_completion_test() {
  let runs = support.store()
  let seen = process.new_subject()
  let id = run.new_id()
  let assert Ok(handle) =
    fabric.start(
      runs,
      forecaster(answering("cloudy", seen)),
      id:,
      context: Nil,
      prompt: "weather in Oslo?",
      correlation: None,
    )
  let assert Ok(run.Finished(run.AnswerInvalid(raw: "cloudy", ..))) =
    fabric.await(handle, within: duration.seconds(5))
  let assert Ok(#(_, state)) = runner.load(runs, run.id_to_string(id))
  let encoded = record.encode(state)
  string.contains(encoded, "\"answer_invalid\"") |> should.be_true
  record.decode(encoded) |> should.equal(Ok(state))
  let stripped =
    string.replace(
      encoded,
      "\"answer_invalid\":",
      "\"ignored_by_old_readers\":",
    )
  let assert Ok(older) = record.decode(stripped)
  controller.status(older)
  |> should.equal(run.Finished(run.Completed("cloudy")))
}

// --- sub-agents ----------------------------------------------------------------------

fn lookup() -> tool.Definition(String, Weather) {
  tool.define(
    "forecast",
    "Ask the forecaster about a city.",
    {
      use city <- codec.field("city", codec.string(), get: fn(c) { c })
      codec.success(city)
    },
    weather_codec(),
  )
}

/// Delegates once to the forecaster, then answers with what it saw.
fn planner(child) {
  agent.new(
    "planner",
    scripted.model(fn(messages) {
      case scripted.results(messages) {
        [] ->
          model.ToolRequest(
            model.AssistantTurn(
              "",
              [scripted.call("c1", "forecast", "{\"city\":\"Paris\"}")],
              None,
            ),
            None,
          )
        [seen, ..] -> model.FinalAnswer("planned: " <> seen, None)
      }
    }),
    [],
    policy.always_allow(),
  )
  |> agent.with_sub_agent(lookup(), to: child, prompt: fn(city) {
    "weather in " <> city
  })
  |> support.agent
}

pub fn a_typed_child_answer_is_the_delegations_output_test() {
  let seen = process.new_subject()
  let child =
    forecaster(answering("{\"sunny\":false,\"city\":\"Paris\"}", seen))
  let #(handle, status) = finish(planner(child), "plan a picnic")
  // The output codec re-encodes the child's answer for the model.
  status
  |> should.equal(
    run.Finished(run.Completed("planned: {\"city\":\"Paris\",\"sunny\":false}")),
  )
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [
    run.ActionRecord(state: run.Succeeded(content), child: Some(id), ..),
  ] = snapshot.actions
  content |> should.equal("{\"city\":\"Paris\",\"sunny\":false}")
  // A child read through its parent's handle reads its stored text.
  let assert Ok(forecast) = fabric.child(handle, id)
  fabric.await(forecast, within: duration.milliseconds(100))
  |> should.equal(
    Ok(run.Finished(run.Completed("{\"sunny\":false,\"city\":\"Paris\"}"))),
  )
}

pub fn an_invalid_child_answer_is_a_failure_the_model_sees_test() {
  let seen = process.new_subject()
  let child = forecaster(answering("no idea", seen))
  let #(handle, _) = finish(planner(child), "plan a picnic")
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [run.ActionRecord(state: run.ToolFailed(content), ..)] =
    snapshot.actions
  string.contains(content, "the sub-agent's answer is invalid")
  |> should.be_true
}

// --- commands without an agent -----------------------------------------------------

pub fn store_only_commands_read_the_stored_text_test() {
  let runs = support.store()
  let seen = process.new_subject()
  let id = run.new_id()
  let assert Ok(handle) =
    fabric.start(
      runs,
      forecaster(answering("{\"city\":\"Rome\",\"sunny\":true}", seen)),
      id:,
      context: Nil,
      prompt: "weather in Rome?",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Completed(Weather("Rome", True)))) =
    fabric.await(handle, within: duration.seconds(5))
  let assert Ok(snapshot) = fabric.settle_stored(runs, id)
  snapshot.status
  |> should.equal(
    run.Finished(run.Completed("{\"city\":\"Rome\",\"sunny\":true}")),
  )
  fabric.cancel_stored(runs, id) |> should.equal(Error(fabric.RunEnded))
}

// --- the llm_wire adapter --------------------------------------------------------------

fn openai_forecaster(fake: fake_provider.Fake) {
  forecaster(llm.model(fake.client, fake_provider.openai(fake), "gpt-scripted"))
}

pub fn the_adapter_asks_the_provider_for_the_answer_schema_test() {
  let fake =
    fake_provider.start([
      testing.text("{\"city\":\"Paris\",\"sunny\":true}")
      |> testing.with_usage(message.Usage(5, 6, 11))
      |> testing.events_for(message.OpenAI, _),
    ])
  let #(_, status) = finish(openai_forecaster(fake), "weather in Paris?")
  status |> should.equal(run.Finished(run.Completed(Weather("Paris", True))))
  let assert [body] = fake_provider.bodies(fake)
  string.contains(body, "\"json_schema\"") |> should.be_true
  string.contains(body, "\"name\":\"answer\"") |> should.be_true
  string.contains(body, "\"sunny\"") |> should.be_true
  fake_provider.stop(fake)
}

/// llm_wire refuses the text against the schema; the adapter still returns
/// it. The model is asked once more, with the correction in the second
/// request, and the run ends with the last text kept.
pub fn an_answer_outside_the_schema_keeps_its_text_test() {
  let reply =
    testing.text("{\"city\":\"Paris\"}")
    |> testing.with_usage(message.Usage(5, 6, 11))
    |> testing.events_for(message.OpenAI, _)
  let fake = fake_provider.start([reply, reply])
  let #(handle, status) = finish(openai_forecaster(fake), "weather in Paris?")
  let assert run.Finished(run.AnswerInvalid(raw: "{\"city\":\"Paris\"}", ..)) =
    status
  let assert Ok(snapshot) = fabric.snapshot(handle)
  snapshot.usage |> should.equal(run.TokenUsage(10, 12, 0))
  snapshot.turns_used |> should.equal(2)
  let assert [_, second] = fake_provider.bodies(fake)
  string.contains(second, "Your final answer could not be read")
  |> should.be_true
  fake_provider.stop(fake)
}

// --- answers whose schema has no object root -------------------------------------

pub type Verdict {
  Approve
  Revise(reason: String)
}

fn verdict_codec() -> codec.Codec(Verdict) {
  codec.union({
    use approve <- codec.unit_variant("approve", Approve)
    use revise <- codec.variant("revise", of: codec.string(), construct: Revise)
    codec.match(fn(verdict) {
      case verdict {
        Approve -> approve
        Revise(reason) -> revise(reason)
      }
    })
  })
}

fn answering_with(
  answer: codec.Codec(a),
  model: model.Model,
) -> agent.Agent(Nil, a) {
  agent.new("typed", model, [], policy.always_allow())
  |> agent.with_answer(answer)
  |> support.agent
}

/// A `codec.union` answer is the caller's own type: a model answers the
/// union's JSON, the run completes with the variant, and the record keeps
/// that JSON.
pub fn a_union_answer_completes_with_its_variant_test() {
  let seen = process.new_subject()
  let #(handle, status) =
    finish(
      answering_with(
        verdict_codec(),
        answering("{\"tag\":\"revise\",\"value\":\"cite a source\"}", seen),
      ),
      "review this",
    )
  status |> should.equal(run.Finished(run.Completed(Revise("cite a source"))))
  process.receive(seen, 1000) |> should.equal(Ok(Some(schema(verdict_codec()))))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [_, model.AssistantMessage(turn)] = snapshot.transcript
  turn.text |> should.equal("{\"tag\":\"revise\",\"value\":\"cite a source\"}")
}

/// The adapter wraps an answer whose schema has no object root as
/// `{"answer": ..}` for the provider and unwraps the reply: the run stores
/// the answer's own JSON.
pub fn the_adapter_wraps_an_answer_without_an_object_root_test() {
  let fake =
    fake_provider.start([
      testing.text("{\"answer\":[\"Paris\",\"Rome\"]}")
      |> testing.with_usage(message.Usage(5, 6, 11))
      |> testing.events_for(message.OpenAI, _),
    ])
  let cities = codec.list(codec.string())
  let #(handle, status) =
    finish(
      answering_with(
        cities,
        llm.model(fake.client, fake_provider.openai(fake), "gpt-scripted"),
      ),
      "two cities?",
    )
  status |> should.equal(run.Finished(run.Completed(["Paris", "Rome"])))
  let assert [body] = fake_provider.bodies(fake)
  string.contains(body, "\"name\":\"answer\"") |> should.be_true
  string.contains(body, "\"required\":[\"answer\"]") |> should.be_true
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [_, model.AssistantMessage(turn)] = snapshot.transcript
  turn.text |> should.equal("[\"Paris\",\"Rome\"]")
  fake_provider.stop(fake)
}

/// A boolean answer is wrapped the same way.
pub fn the_adapter_wraps_a_boolean_answer_test() {
  let fake =
    fake_provider.start([
      testing.text("{\"answer\":true}")
      |> testing.events_for(message.OpenAI, _),
    ])
  let #(_, status) =
    finish(
      answering_with(
        codec.bool(),
        llm.model(fake.client, fake_provider.openai(fake), "gpt-scripted"),
      ),
      "is it sunny?",
    )
  status |> should.equal(run.Finished(run.Completed(True)))
  fake_provider.stop(fake)
}

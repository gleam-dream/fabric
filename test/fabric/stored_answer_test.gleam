//// Completed runs stored before typed answers (`pre-answer-*` fixtures,
//// written by fabric 23ae718): their text answers still read through the
//// facade.

import fabric
import fabric/agent
import fabric/internal/store as store_core
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/restart
import fabric/support/scripted
import fabric/tool
import gleam/list
import gleam/option.{None}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn fixture(name: String) -> String {
  let assert Ok(text) =
    restart.read_file("test/fixtures/records/pre-answer-" <> name <> ".json")
  text
}

/// A started store holding the fixtures `names`, each under its run id.
fn stored(names: List(String)) {
  let runs = support.store()
  list.each(names, fn(name) {
    let assert Ok(_) =
      store_core.insert(
        runs,
        name,
        fixture(name),
        store_core.Detached(False, False),
      )
  })
  runs
}

fn silent(name: String) {
  agent.new(
    name,
    scripted.model(fn(_) { model.FinalAnswer("unused", None) }),
    [],
    policy.always_allow(),
  )
}

fn research() {
  tool.define(
    "research",
    "Research a topic.",
    {
      use topic <- codec.field("topic", codec.string(), get: fn(t) { t })
      codec.success(topic)
    },
    codec.string(),
  )
}

pub fn a_stored_text_answer_reads_as_text_test() {
  let runs = stored(["run-text-answer"])
  let assert Ok(handle) =
    fabric.open(
      runs,
      support.agent(silent("desk")),
      Nil,
      support.id("run-text-answer"),
    )
  let assert Ok(snapshot) = fabric.snapshot(handle)
  snapshot.status |> should.equal(run.Finished(run.Completed("Sunny in Paris")))
  snapshot.turns_used |> should.equal(1)
}

pub fn a_stored_json_answer_reads_as_its_text_test() {
  let runs = stored(["run-json-answer"])
  let assert Ok(handle) =
    fabric.open(
      runs,
      support.agent(silent("desk")),
      Nil,
      support.id("run-json-answer"),
    )
  fabric.await(handle, within: duration.milliseconds(100))
  |> should.equal(
    Ok(run.Finished(run.Completed("{\"city\":\"Paris\",\"sunny\":true}"))),
  )
}

pub fn a_stored_delegation_reads_with_its_child_test() {
  let runs = stored(["run-delegated", "run-delegated-1"])
  let lead =
    silent("lead")
    |> agent.with_sub_agent(
      research(),
      to: support.agent(silent("researcher")),
      prompt: fn(topic) { topic },
    )
    |> support.agent
  let assert Ok(parent) =
    fabric.open(runs, lead, Nil, support.id("run-delegated"))
  let assert Ok(snapshot) = fabric.snapshot(parent)
  let assert run.Finished(run.Completed(_)) = snapshot.status
  let assert [run.ActionRecord(state: run.Succeeded(content), ..)] =
    snapshot.actions
  content |> should.equal("\"{\\\"summary\\\":\\\"Paris is sunny\\\"}\"")
  let assert Ok(researcher) =
    fabric.child(parent, support.id("run-delegated-1"))
  let assert Ok(child) = fabric.snapshot(researcher)
  child.status
  |> should.equal(
    run.Finished(run.Completed("{\"summary\":\"Paris is sunny\"}")),
  )
}

// --- read through a typed answer ---------------------------------------------------

pub type Weather {
  Weather(city: String, sunny: Bool)
}

fn weather_codec() -> codec.Codec(Weather) {
  use city <- codec.field("city", codec.string(), get: fn(w) { w.city })
  use sunny <- codec.field("sunny", codec.bool(), get: fn(w) { w.sunny })
  codec.success(Weather(city:, sunny:))
}

/// A stored JSON answer reads through a codec that matches it.
pub fn a_stored_json_answer_reads_through_a_matching_codec_test() {
  let runs = stored(["run-json-answer"])
  let forecaster =
    silent("desk") |> agent.with_answer(weather_codec()) |> support.agent
  let assert Ok(handle) =
    fabric.open(runs, forecaster, Nil, support.id("run-json-answer"))
  fabric.await(handle, within: duration.milliseconds(100))
  |> should.equal(Ok(run.Finished(run.Completed(Weather("Paris", True)))))
}

/// A stored text answer the codec does not read is an invalid answer that
/// keeps the text; the run is otherwise read as it was stored.
pub fn a_stored_text_answer_reads_as_invalid_through_a_codec_test() {
  let runs = stored(["run-text-answer"])
  let forecaster =
    silent("desk") |> agent.with_answer(weather_codec()) |> support.agent
  let assert Ok(handle) =
    fabric.open(runs, forecaster, Nil, support.id("run-text-answer"))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert run.Finished(run.AnswerInvalid(raw: "Sunny in Paris", ..)) =
    snapshot.status
  snapshot.turns_used |> should.equal(1)
}

pub type Summary {
  Summary(summary: String)
}

/// A delegation stored before typed answers reads under a typed child: its
/// settled result is the content it stored, and its child's answer reads
/// through the child's codec when opened with a typed agent.
pub fn a_stored_delegation_reads_under_a_typed_child_test() {
  let runs = stored(["run-delegated", "run-delegated-1"])
  let summary = {
    use summary <- codec.field("summary", codec.string(), get: fn(s: Summary) {
      s.summary
    })
    codec.success(Summary(summary))
  }
  let researcher =
    silent("researcher") |> agent.with_answer(summary) |> support.agent
  let lead =
    silent("lead")
    |> agent.with_sub_agent(
      tool.define(
        "research",
        "Research a topic.",
        {
          use topic <- codec.field("topic", codec.string(), get: fn(t) { t })
          codec.success(topic)
        },
        summary,
      ),
      to: researcher,
      prompt: fn(topic) { topic },
    )
    |> support.agent
  let assert Ok(parent) =
    fabric.open(runs, lead, Nil, support.id("run-delegated"))
  let assert Ok(snapshot) = fabric.snapshot(parent)
  let assert [run.ActionRecord(state: run.Succeeded(_), ..)] = snapshot.actions
  let assert Ok(child) =
    fabric.open(runs, researcher, Nil, support.id("run-delegated-1"))
  fabric.await(child, within: duration.milliseconds(100))
  |> should.equal(Ok(run.Finished(run.Completed(Summary("Paris is sunny")))))
}

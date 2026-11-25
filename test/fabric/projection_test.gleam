//// `projection.project` decodes a record once and returns exactly what the
//// separate projections return, with the phase tag the record carries.

import fabric/internal/graph/record as graph_record
import fabric/internal/record
import fabric/store/discovery
import fabric/store/projection
import fabric/store/retention
import fabric/store/statistics
import fabric/support/restart
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should

const fixtures = [
  "answer-correction-pending.json", "graph-awaiting-approval.json",
  "graph-blocked.json", "graph-completed.json", "graph-waiting-child-child.json",
  "graph-waiting-child.json", "graph-waiting-job.json",
  "graph-waiting-signal.json", "legacy-v7-model-failed.json",
  "legacy-v7-suspended.json", "legacy-v7-typed-reviewer-suspended.json",
  "pre-answer-run-delegated-1.json", "pre-answer-run-delegated.json",
  "pre-answer-run-json-answer.json", "pre-answer-run-text-answer.json",
  "published-0.2.0-parked.json",
]

/// The fixture re-encoded by the current encoder, as a backend receives
/// it on a write, with its run id.
fn current(name: String) -> #(String, String) {
  let assert Ok(text) = restart.read_file("test/fixtures/records/" <> name)
  case record.decode(text) {
    Ok(state) -> #(state.run, record.encode(state))
    Error(_) -> {
      let assert Ok(state) = graph_record.decode(text)
      let assert Ok(encoded) = graph_record.encode(state)
      #(state.run, encoded)
    }
  }
}

fn phase_tag(text: String) -> option.Option(String) {
  json.parse(text, decode.at(["phase", "tag"], decode.string))
  |> option.from_result
}

pub fn a_projection_equals_the_separate_projections_test() {
  list.each(fixtures, fn(name) {
    let #(run, text) = current(name)
    projection.project(run, text)
    |> should.equal(projection.Projection(
      phase: phase_tag(text),
      retention: retention.encode(run, text),
      discovery: discovery.encode(run, text),
      statistics: statistics.encode(run, text),
    ))
  })
}

pub fn a_projection_of_a_misfiled_or_unreadable_record_keeps_versions_only_test() {
  let #(run, text) = current("graph-completed.json")
  let misfiled = projection.project("run-elsewhere", text)
  misfiled.retention |> should.equal(retention.encode("run-elsewhere", text))
  misfiled.discovery |> should.equal(discovery.encode("run-elsewhere", text))
  misfiled.statistics |> should.equal(statistics.encode("run-elsewhere", text))
  { run != "run-elsewhere" } |> should.be_true
  let unreadable = projection.project(run, "{\"format\":\"other\"}")
  unreadable.phase |> should.equal(None)
  string.contains(unreadable.retention, "version") |> should.be_true
}

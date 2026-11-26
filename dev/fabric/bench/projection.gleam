//// Measures what a database backend spends deriving its index columns from
//// one record write, two ways:
////
//// - `separate`: the phase read from the record text, then
////   `retention.encode`, `discovery.encode` and `statistics.encode`, each
////   decoding the record again (what `fabric_postgres` did);
//// - `project`: `projection.project`, which decodes the record once.
////
//// Each sample times `writes` derivations of one record. The records are
//// the agent and graph fixtures under `test/fixtures/records`, re-encoded
//// by the current encoders, and the agent record again with its transcript
//// repeated 64 times (`agent-x64`).
////
//// Run with `gleam run -m fabric/bench/projection`.

import fabric/internal/controller
import fabric/internal/graph/record as graph_record
import fabric/internal/record
import fabric/store/discovery
import fabric/store/projection
import fabric/store/retention
import fabric/store/statistics
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/string
import simplifile

const writes = 200

const samples = 5

pub fn main() -> Nil {
  let records = [
    #("agent", agent("pre-answer-run-delegated.json", 1)),
    #("agent-x64", agent("pre-answer-run-delegated.json", 64)),
    #("graph", graph("graph-waiting-child.json")),
  ]
  io.println("record,bytes,way,writes,microseconds per write (one per sample)")
  list.each(records, fn(entry) {
    let #(name, #(run, text)) = entry
    list.each([#("separate", separate), #("project", together)], fn(way) {
      let #(label, derivation) = way
      let measured =
        list.repeat(Nil, samples)
        |> list.map(fn(_) { int.to_string(sample(run, text, derivation)) })
      io.println(string.join(
        [
          name,
          int.to_string(string.byte_size(text)),
          label,
          int.to_string(writes),
          ..measured
        ],
        ",",
      ))
    })
  })
}

fn separate(run: String, text: String) -> Nil {
  let _ = json.parse(text, decode.at(["phase", "tag"], decode.string))
  let _ = retention.encode(run, text)
  let _ = discovery.encode(run, text)
  let _ = statistics.encode(run, text)
  Nil
}

fn together(run: String, text: String) -> Nil {
  let _ = projection.project(run, text)
  Nil
}

fn sample(
  run: String,
  text: String,
  derivation: fn(String, String) -> Nil,
) -> Int {
  let started = now()
  times(writes, fn() { derivation(run, text) })
  { now() - started } / writes
}

/// The agent fixture `name`, its transcript repeated `copies` times.
fn agent(name: String, copies: Int) -> #(String, String) {
  let assert Ok(text) = simplifile.read("test/fixtures/records/" <> name)
  let assert Ok(state) = record.decode(text)
  let transcript = list.flatten(list.repeat(state.transcript, copies))
  #(state.run, record.encode(controller.State(..state, transcript:)))
}

fn graph(name: String) -> #(String, String) {
  let assert Ok(text) = simplifile.read("test/fixtures/records/" <> name)
  let assert Ok(state) = graph_record.decode(text)
  let assert Ok(encoded) = graph_record.encode(state)
  #(state.run, encoded)
}

fn times(n: Int, body: fn() -> Nil) -> Nil {
  case n > 0 {
    False -> Nil
    True -> {
      body()
      times(n - 1, body)
    }
  }
}

fn now() -> Int {
  monotonic_time(atom.create("microsecond"))
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int

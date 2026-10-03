import fabric/graph
import fabric/graph/llm
import fabric/run
import fabric/store
import fabric_decision_demo as demo
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import http_gun
import http_gun/config as http_config
import http_gun/testing as http_testing
import json/blueprint/codec
import llm_wire
import llm_wire/message
import llm_wire/openai
import llm_wire/testing

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn replacing_decision_production_preserves_typed_graph_routes_test() {
  [#("approve", "approved", "publish"), #("revise", "needs revision", "revise")]
  |> list.each(fn(example) {
    let raw = "{\"decision\":\"" <> example.0 <> "\"}"
    let usage = message.Usage(11, 6, 17)
    let model = "scripted-review"
    let request = demo.review_request(model, "2 + 2 = 4")
    // The scripted wire carries no token bound; a provider wire shows it.
    let assert Ok(openai_call) =
      llm_wire.prepare(openai.new("sk-test") |> openai.config, request)
    json.parse(
      llm_wire.request_json(openai_call),
      decode.at(["max_output_tokens"], decode.int),
    )
    |> should.equal(Ok(64))
    // The offline client answers exactly this request once; any other
    // request fails without network access.
    let assert Ok(expected) =
      llm_wire.prepare(
        testing.config(),
        request |> llm_wire.with_output("review", demo.decision_codec()),
      )
    let assert Ok(client) =
      http_testing.playback(
        http_testing.script([
          testing.exchange(
            expected,
            testing.text(raw) |> testing.with_usage(usage),
          ),
        ]),
        http_config.default(),
      )
    let runs = store.in_memory(process.new_name("decision-consumer"))
    let assert Ok(Nil) = store.start(runs)
    let runtime = demo.runtime(runs, client, testing.config(), model)
    let assert Ok(id) = run.parse_id("decision-consumer")
    let assert Ok(handle) = graph.start(runtime, id, "2 + 2 = 4")
    let assert Ok(done) = graph.await(handle, 5000)
    done.status |> should.equal(graph.Completed(example.1))
    let assert [review, terminal] = done.receipts
    terminal.node |> should.equal(example.2)
    let assert Ok(receipt) =
      codec.decode_json(
        llm.receipt_codec(demo.decision_codec()),
        review.output_json,
      )
    receipt.usage |> should.equal(Some(usage))
    let assert llm.Answer(_, original) = receipt.outcome
    original |> should.equal(raw)
    http_gun.stop(client)
  })
}

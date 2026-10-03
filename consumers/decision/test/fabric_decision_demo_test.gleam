import fabric/graph
import fabric/graph/llm
import fabric/run
import fabric/store
import fabric_decision_demo as demo
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import http_gun
import http_gun/config as http_config
import http_gun/testing as http_testing
import json/blueprint/codec
import llm_wire/session
import llm_wire/testing
import llm_wire/types

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn replacing_decision_production_preserves_typed_graph_routes_test() {
  [#("approve", "approved", "publish"), #("revise", "needs revision", "revise")]
  |> list.each(fn(example) {
    let raw = "{\"decision\":\"" <> example.0 <> "\"}"
    let usage = types.Usage(11, 6, 17)
    let assert Ok(model) = types.model_id("scripted-review")
    let request = demo.review_request(model, "2 + 2 = 4")
    request.max_tokens |> should.equal(Some(64))
    // The offline client answers exactly this request once; any other
    // request fails without network access.
    let assert Ok(expected) =
      session.prepare_structured(
        testing.config(),
        request,
        "review",
        demo.decision_codec(),
      )
    let assert Ok(client) =
      http_testing.playback(
        http_testing.script([
          testing.structured_exchange(
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

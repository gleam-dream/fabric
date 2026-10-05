import fabric/graph
import fabric/run
import fabric/store
import fabric_decision_classifier as demo
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/config as http_config
import json/blueprint/codec
import llm_wire/classify
import llm_wire/message

type Server

@external(erlang, "fabric_decision_test_ffi", "start_server")
fn start_server() -> #(Server, String)

@external(erlang, "fabric_decision_test_ffi", "stop_server")
fn stop_server(server: Server) -> Nil

pub fn non_generative_decisions_use_the_same_business_routes_test() {
  let #(server, url) = start_server()
  let assert Ok(http) =
    http_gun.start(http_config.default() |> http_config.allow_loopback)
  let settings = classify.config(fn() { "test-key" })
  let settings = classify.with_endpoint(settings, url <> "/v1/systemone")
  [#("approve", "approved", "publish"), #("revise", "needs revision", "revise")]
  |> list.each(fn(example) {
    let runs = store.in_memory(process.new_name("classifier-consumer"))
    let assert Ok(Nil) = store.start(runs)
    let assert Ok(id) = run.parse_id("classifier-consumer")
    let assert Ok(handle) =
      graph.start(
        demo.runtime(runs, http, settings, "fixture"),
        id,
        "fixture:" <> example.0,
        correlation: None,
      )
    let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
    let assert Ok(done) = graph.snapshot(handle)
    done.status |> should.equal(graph.Completed(example.1))
    let assert [review, terminal] = done.receipts
    terminal.node |> should.equal(example.2)
    let assert Ok(receipt) =
      codec.decode_json(
        classify.receipt_codec(classify.typesafe(), demo.questions()),
        review.output_json,
      )
    receipt.resolved_model |> should.equal("protocol-fixture-only")
    receipt.answer.1.0.label |> should.equal(example.0)
    receipt.answer.0.yes |> should.equal(0.9)
    receipt.answer.1.1.position |> should.equal(1.8)
    receipt.usage |> should.equal(Some(message.Usage(12, 8, 20)))
  })
  stop_server(server)
}

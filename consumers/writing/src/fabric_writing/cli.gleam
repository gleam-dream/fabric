//// Explicit live entry point. Configuration is read from the process environment;
//// the offline suite never invokes this module or loads a dotenv file.

import fabric/graph
import fabric/graph/llm
import fabric/graph/operation
import fabric/run
import fabric/store
import fabric_typesafe
import fabric_typesafe/client
import fabric_typesafe/question
import fabric_writing
import fabric_writing/domain
import fabric_writing/evaluation
import fabric_writing/file
import fabric_writing/provider
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun
import http_gun/config as http_config
import json/blueprint/codec
import llm_wire
import llm_wire/openai

@external(erlang, "fabric_writing_ffi", "environment")
fn environment(name: String) -> Result(String, Nil)

@external(erlang, "fabric_writing_ffi", "now")
fn now() -> Int

fn required(name: String) -> String {
  case environment(name) {
    Ok(value) -> value
    Error(Nil) -> panic as { "missing environment setting: " <> name }
  }
}

fn llm_settings() -> llm_wire.Config {
  openai.new(required("OPENAI_API_KEY"))
  |> openai.config
  |> llm_wire.with_call_timeout(llm_wire.After(duration.seconds(20)))
  |> llm_wire.with_first_token_timeout(llm_wire.After(duration.seconds(10)))
  |> llm_wire.with_idle_timeout(llm_wire.After(duration.seconds(10)))
}

fn model() -> String {
  environment("FABRIC_DECISION_MODEL")
  |> result.unwrap("gpt-4.1-nano-2025-04-14")
}

pub fn main() -> Nil {
  let mode = required("FABRIC_WRITING_MODE")
  // One HTTP client for every LLM request this process makes. Its default
  // 30-second ceiling covers the 20-second LLM deadline.
  let assert Ok(http) = http_gun.start(http_config.default())
  case required("FABRIC_WRITING_REVIEWER") {
    "llm" ->
      dispatch(
        mode,
        http,
        provider.llm_reviewer(http, llm_settings(), model()),
        llm_metadata,
      )
    "typesafe" -> {
      let assert Ok(settings) = client.new(required("TYPESAFE_API_KEY"))
      let model =
        environment("FABRIC_CLASSIFIER_MODEL") |> result.unwrap("jev-latest")
      dispatch(
        mode,
        http,
        provider.classifier(settings, model),
        classifier_metadata,
      )
    }
    _ -> panic as "reviewer must be llm or typesafe"
  }
  http_gun.stop(http)
  Nil
}

fn dispatch(
  mode: String,
  http: http_gun.Client,
  reviewer: provider.Reviewer(receipt),
  metadata: fn(receipt) -> List(#(String, json.Json)),
) -> Nil {
  case mode {
    "review" -> measure(reviewer, metadata)
    "start" | "inspect" | "approve" | "reject" -> workflow(mode, http, reviewer)
    _ -> panic as "mode must be review, start, inspect, approve or reject"
  }
}

fn measure(
  reviewer: provider.Reviewer(receipt),
  metadata: fn(receipt) -> List(#(String, json.Json)),
) -> Nil {
  let assert Ok(raw) = file.read(required("FABRIC_WRITING_INPUT"))
  let assert Ok(draft) = codec.decode_json(domain.draft_codec(), raw)
  let runs = store.in_memory(process.new_name("writing-evaluation"))
  let assert Ok(Nil) = store.start(runs)
  let runtime = evaluation.runtime(runs, reviewer)
  let assert Ok(id) = run.parse_id("review")
  let started = now()
  let assert Ok(handle) = graph.start(runtime, id, draft)
  let assert Ok(done) = graph.await(handle, 31_000)
  let elapsed = now() - started
  let fields = [#("elapsed_ms", json.int(elapsed))]
  let fields = case done.status, done.receipts {
    graph.Completed(decision), [receipt] -> {
      let assert Ok(decoded) =
        codec.decode_json(
          operation.output_codec(reviewer.operation),
          receipt.output_json,
        )
      list.append(
        [
          #("status", json.string("completed")),
          #("decision", json.string(domain.decision_text(decision))),
          #("receipt_json", json.string(receipt.output_json)),
          ..fields
        ],
        metadata(decoded),
      )
    }
    status, _ -> [
      #("status", json.string("failed")),
      #("problem", json.string(string.inspect(status))),
      ..fields
    ]
  }
  json.object(fields) |> json.to_string |> io.println
}

fn llm_metadata(receipt: llm.Receipt(a)) -> List(#(String, json.Json)) {
  [
    #("requested_model", json.string(receipt.model)),
    #("resolved_model", json.null()),
    #("usage", case receipt.usage {
      None -> json.null()
      Some(usage) ->
        json.object([
          #("input_tokens", json.int(usage.input_tokens)),
          #("output_tokens", json.int(usage.output_tokens)),
        ])
    }),
  ]
}

fn classifier_metadata(
  receipt: fabric_typesafe.Receipt(question.Choice(domain.Decision)),
) -> List(#(String, json.Json)) {
  [
    #("requested_model", json.string(receipt.requested_model)),
    #("resolved_model", json.string(receipt.resolved_model)),
    #(
      "usage",
      json.object([
        #("input_tokens", json.int(receipt.usage.input_tokens)),
        #("output_tokens", json.int(receipt.usage.output_tokens)),
      ]),
    ),
    #("request_json", json.string(receipt.request_json)),
    #("response_json", json.string(receipt.response_json)),
  ]
}

fn workflow(
  mode: String,
  http: http_gun.Client,
  reviewer: provider.Reviewer(receipt),
) -> Nil {
  let directory = required("FABRIC_WRITING_DIRECTORY")
  let runs =
    store.directory(process.new_name("writing-example"), directory <> "/runs")
  let assert Ok(Nil) = store.start(runs)
  let runtime =
    fabric_writing.runtime(
      runs,
      provider.generator(http, llm_settings(), model()),
      reviewer,
      file.publisher(directory <> "/published"),
    )
  let assert Ok(id) = run.parse_id(required("FABRIC_WRITING_ID"))
  let handle = case mode {
    "start" -> {
      let assert Ok(handle) =
        fabric_writing.start(
          runtime,
          run.id_to_string(id),
          required("FABRIC_WRITING_SOURCE"),
          required("FABRIC_WRITING_BRIEF"),
        )
      handle
    }
    _ -> graph.attach(runtime, id)
  }
  let assert Ok(before) = graph.await(handle, 120_000)
  case mode {
    "approve" | "reject" -> {
      let assert Ok(expected) =
        int.parse(required("FABRIC_WRITING_EXPECTED_REVISION"))
      let assert True = expected == before.revision
      Nil
    }
    _ -> Nil
  }
  case mode, before.status {
    "approve", graph.AwaitingApproval(approval) -> {
      let assert Ok(_) = graph.approve(handle, approval)
      Nil
    }
    "reject", graph.AwaitingApproval(approval) -> {
      let assert Ok(_) = graph.reject(handle, approval, "operator rejected")
      Nil
    }
    "approve", _ | "reject", _ -> panic as "run has no current approval request"
    _, _ -> Nil
  }
  let assert Ok(done) = graph.await(handle, 120_000)
  let status = case done.status {
    graph.AwaitingApproval(_) -> "awaiting_approval"
    graph.Completed(domain.Published(_)) -> "published"
    graph.Completed(domain.Rejected) -> "rejected"
    graph.Completed(domain.RevisionLimit) -> "revision_limit"
    _ -> "failed"
  }
  let assert Ok(state) = codec.encode_json(domain.state_codec(), done.value)
  let artifact = case done.status {
    graph.Completed(domain.Published(artifact)) ->
      json.object([
        #("path", json.string(artifact.path)),
        #("sha256", json.string(artifact.sha256)),
      ])
    _ -> json.null()
  }
  json.object([
    #("status", json.string(status)),
    #("state_json", json.string(state)),
    #("artifact", artifact),
    #("revision", json.int(done.revision)),
    #(
      "receipts",
      json.array(done.receipts, fn(receipt) {
        json.object([
          #("node", json.string(receipt.node)),
          #("activation", json.int(receipt.activation)),
          #("attempt", json.int(receipt.attempt)),
          #("output_json", json.string(receipt.output_json)),
        ])
      }),
    ),
  ])
  |> json.to_string
  |> io.println
}

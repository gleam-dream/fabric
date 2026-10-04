//// Non-generative, typed classifier operations with durable protocol receipts.

import fabric/graph/operation
import fabric/run
import fabric/tool
import fabric_typesafe/client
import fabric_typesafe/internal/batch
import fabric_typesafe/internal/transport
import fabric_typesafe/internal/wire
import fabric_typesafe/question
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec
import json/blueprint/value.{type Value}

pub type Request {
  Request(model: String, state: Value)
}

pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int)
}

pub type Receipt(answer) {
  Receipt(
    answer: answer,
    requested_model: String,
    resolved_model: String,
    usage: Usage,
    request_json: String,
    response_json: String,
  )
}

/// The builder describes one request after policy admission. It must be pure;
/// credentials belong in the returned live configuration, never the state.
/// The request goes through the configuration's HTTP Gun client view, tagged
/// with the graph run's correlation (`operation.Invocation.correlation`).
pub fn new(
  identity: run.DefinitionId,
  input: codec.Codec(input),
  questions: question.Batch(answer),
  request: fn(context, input) -> #(client.Config, Request),
) -> operation.Operation(context, input, Receipt(answer)) {
  operation.new(
    identity,
    input,
    receipt_codec(questions),
    fn(context, invocation: operation.Invocation, input) {
      let #(config, request) = request(context, input)
      use raw <- result.try(
        prepare(questions, request)
        |> result.map_error(tool.Explain),
      )
      use response <- result.try(
        transport.post(config, raw, Some(invocation.correlation))
        |> result.map_error(fn(error) {
          case error {
            transport.BeforeSend(reason) -> tool.Explain(reason)
            transport.AfterSend(reason) -> tool.Uncertain(reason)
          }
        }),
      )
      use Nil <- result.try(case response.status {
        200 -> Ok(Nil)
        status -> {
          let retry =
            list.key_find(response.headers, "retry-after")
            |> result.unwrap("not reported")
          Error(tool.Uncertain(
            "classifier HTTP status "
            <> int.to_string(status)
            <> "; retry-after: "
            <> retry,
          ))
        }
      })
      restore(questions, raw, response.body)
      |> result.map_error(tool.Uncertain)
    },
    fn(error) { error },
  )
}

fn prepare(
  questions: question.Batch(answer),
  request: Request,
) -> Result(String, String) {
  use Nil <- result.try(wire.require(
    string.trim(request.model) != "",
    "classifier model must be nonempty",
  ))
  use state <- result.map(wire.content(request.state))
  value.to_string(
    value.Object([
      #("model", value.String(request.model)),
      #("state", state),
      #("questions", question.definitions(questions)),
    ]),
  )
}

/// Original JSON and question semantics own the retained native answer. This
/// codec performs no I/O and does not capture live configuration or credentials.
pub fn receipt_codec(
  questions: question.Batch(answer),
) -> codec.Codec(Receipt(answer)) {
  codec.custom(
    encode: fn(receipt: Receipt(answer)) {
      use reconstructed <- result.try(
        restore(questions, receipt.request_json, receipt.response_json)
        |> result.map_error(codec.encode_failure),
      )
      use Nil <- result.map(
        wire.require(
          reconstructed == receipt,
          "native classifier receipt differs from its protocol evidence",
        )
        |> result.map_error(codec.encode_failure),
      )
      value.Array([
        value.String("fabric.typesafe.receipt.v1"),
        value.String(receipt.request_json),
        value.String(receipt.response_json),
      ])
    },
    decode: fn(saved) {
      case saved {
        value.Array([
          value.String("fabric.typesafe.receipt.v1"),
          value.String(request),
          value.String(response),
        ]) ->
          restore(questions, request, response)
          |> result.map_error(codec.decode_failure)
        _ -> Error(codec.decode_failure("invalid classifier receipt format"))
      }
    },
    schema: None,
    placeholder: Receipt(
      batch.placeholder(questions),
      "",
      "",
      Usage(0, 0),
      "",
      "",
    ),
  )
}

fn restore(
  questions: question.Batch(answer),
  request: String,
  response: String,
) -> Result(Receipt(answer), String) {
  use sent <- result.try(wire.parse(request) |> result.try(wire.object))
  use Nil <- result.try(wire.require(
    wire.same_keys(sent, ["model", "state", "questions"]),
    "invalid saved classifier request fields",
  ))
  use requested_model <- result.try(
    wire.required(sent, "model") |> result.try(wire.text),
  )
  use _ <- result.try(wire.required(sent, "state") |> result.try(wire.content))
  use sent_questions <- result.try(wire.required(sent, "questions"))
  use Nil <- result.try(wire.require(
    wire.canonical(sent_questions)
      == wire.canonical(question.definitions(questions)),
    "saved classifier questions differ from the deployed batch",
  ))
  use received <- result.try(wire.parse(response) |> result.try(wire.object))
  use resolved_model <- result.try(
    wire.required(received, "model") |> result.try(wire.text),
  )
  use answer <- result.try(
    wire.required(received, "answers")
    |> result.try(fn(answers) { question.decode(questions, answers) }),
  )
  use usage <- result.try(
    wire.required(received, "usage") |> result.try(wire.object),
  )
  use input <- result.try(
    wire.required(usage, "input_tokens") |> result.try(wire.integer),
  )
  use output <- result.try(
    wire.required(usage, "output_tokens") |> result.try(wire.integer),
  )
  use Nil <- result.map(wire.require(
    input >= 0 && output >= 0,
    "negative classifier token usage",
  ))
  Receipt(
    answer,
    requested_model,
    resolved_model,
    Usage(input, output),
    request,
    response,
  )
}

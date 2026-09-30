//// Example-service protocol. A receipt names acceptance; status names progress.

import fabric/graph/operation
import fabric/run
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import json/blueprint/codec

pub type Request {
  Request(text: String, delay_ms: Int)
}

pub opaque type Receipt {
  Receipt(id: String)
}

pub type Status {
  Queued
  Complete(digest: String)
}

pub type Error {
  Rejected(status: Int, detail: String)
  Uncertain(detail: String)
}

pub fn request_codec() -> codec.Codec(Request) {
  codec.pair(codec.string(), codec.int())
  |> codec.imap(fn(pair) { Request(pair.0, pair.1) }, fn(value) {
    #(value.text, value.delay_ms)
  })
}

pub fn receipt_codec() -> codec.Codec(Receipt) {
  codec.field("id", codec.string())
  |> codec.try_imap(
    fn(id) {
      case valid_id(id) {
        True -> Ok(Receipt(id))
        False ->
          Error(
            codec.CannotDecode(codec.CustomDecodeReason(
              "expected a job identifier",
            )),
          )
      }
    },
    fn(receipt) { Ok(receipt.id) },
  )
}

fn valid_id(id: String) -> Bool {
  string.length(id) == 64
  && list.all(string.to_graphemes(id), fn(character) {
    string.contains("0123456789abcdef", character)
  })
}

/// Attempts share a logical key; revisiting the node gets a new activation.
pub fn key(invocation: operation.Invocation) -> String {
  json.array(
    [
      json.string(run.id_to_string(invocation.run)),
      json.int(invocation.activation),
    ],
    fn(value) { value },
  )
  |> json.to_string
}

pub fn submit(
  url: String,
  invocation: operation.Invocation,
  request: Request,
) -> Result(Receipt, Error) {
  let body =
    json.object([
      #("key", json.string(key(invocation))),
      #("text", json.string(request.text)),
      #("delay_ms", json.int(request.delay_ms)),
    ])
    |> json.to_string
  use #(status, body) <- result.try(
    http("POST", url <> "/jobs", body) |> result.map_error(Uncertain),
  )
  case status {
    202 ->
      codec.decode_json(receipt_codec(), body)
      |> result.map_error(fn(error) {
        Uncertain(codec.render_json_decode_error(error))
      })
    400 | 409 -> Error(Rejected(status, body))
    _ ->
      Error(Uncertain(
        "unconfirmed submission: HTTP " <> int.to_string(status) <> " " <> body,
      ))
  }
}

pub fn classify(error: Error) -> operation.Failure {
  case error {
    Rejected(_, detail) -> operation.DefiniteFailure(detail)
    Uncertain(detail) -> operation.UncertainEffect(detail)
  }
}

fn get(url: String) -> Result(String, String) {
  use #(status, body) <- result.try(http("GET", url, ""))
  case status {
    200 -> Ok(body)
    _ -> Error("HTTP " <> int.to_string(status) <> ": " <> body)
  }
}

pub fn read(url: String, receipt: Receipt) -> Result(Status, String) {
  use body <- result.try(get(url <> "/jobs/" <> receipt.id))
  let decoder = {
    use id <- decode.field("id", decode.string)
    use state <- decode.field("state", decode.string)
    case id == receipt.id, state {
      True, "queued" -> decode.success(Queued)
      True, "complete" -> {
        use digest <- decode.field("digest", decode.string)
        case valid_id(digest) {
          True -> decode.success(Complete(digest))
          False -> decode.failure(Queued, "SHA-256 digest")
        }
      }
      _, _ -> decode.failure(Queued, "matching job and known status")
    }
  }
  json.parse(body, decoder) |> result.map_error(string.inspect)
}

pub fn artifact(url: String, receipt: Receipt) -> Result(String, String) {
  use body <- result.try(get(url <> "/jobs/" <> receipt.id <> "/artifact"))
  json.parse(body, decode.string) |> result.map_error(string.inspect)
}

pub fn count(url: String) -> Result(Int, String) {
  use body <- result.try(get(url <> "/count"))
  json.parse(body, decode.field("count", decode.int, decode.success))
  |> result.map_error(string.inspect)
}

@external(erlang, "fabric_jobs_http", "request")
fn http(
  method: String,
  url: String,
  body: String,
) -> Result(#(Int, String), String)

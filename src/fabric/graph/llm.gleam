//// One structured LLM decision as a policy-gated graph activity.
//// llm_wire owns the request; Fabric retains the receipt and its route.
//// Tool rounds belong to a managed agent, not this single-request binding.

import fabric/graph/operation
import fabric/run
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec
import llm_wire/config
import llm_wire/session
import llm_wire/types

pub type Outcome(output) {
  /// Both the validated application value and the provider's original JSON.
  Answer(value: output, raw_json: String)
  Refusal(reason: String)
  OutputLimited(partial_text: String)
}

pub type Receipt(output) {
  /// `model` is the requested model, not a resolved provider revision.
  /// Missing usage is not zero usage.
  Receipt(model: String, outcome: Outcome(output), usage: Option(types.Usage))
}

/// Version `identity` when the provider, prompt or output meaning changes.
/// The pure request builder runs only after policy admission; credentials
/// belong in fresh context, never in the persisted input or receipt.
///
/// Requests must have no tools. Preparation and proven unsent failures are
/// definite; potentially sent failures require reconciliation. No implicit
/// retry is made, even when llm_wire reports a transient error.
pub fn new(
  identity: run.Identity,
  input: codec.Codec(input),
  output: codec.Codec(output),
  output_name: String,
  request: fn(context, input) -> #(config.Config, types.Request),
) -> operation.Operation(context, input, Receipt(output)) {
  operation.new(
    identity,
    input,
    receipt_codec(output),
    fn(context, _, input) {
      let #(settings, request) = request(context, input)
      perform(settings, request, output_name, output)
    },
    fn(failure) { failure },
  )
}

fn perform(
  settings: config.Config,
  request: types.Request,
  output_name: String,
  output: codec.Codec(output),
) -> Result(Receipt(output), operation.Failure) {
  use Nil <- result.try(case request.tools {
    [] -> Ok(Nil)
    [_, ..] ->
      Error(operation.DefiniteFailure(
        "structured decision requests cannot declare tools; use a managed agent",
      ))
  })
  use prepared <- result.try(
    session.prepare_structured(settings, request, output_name, output)
    |> result.map_error(fn(error) { operation.DefiniteFailure(describe(error)) }),
  )
  use response <- result.try(
    session.run_structured(prepared) |> result.map_error(failure),
  )
  let model = types.model_id_to_string(request.model)
  case response {
    session.StructuredValue(value, raw, usage) ->
      Ok(Receipt(model, Answer(value, raw), usage))
    session.StructuredRefusal(reason, usage) ->
      Ok(Receipt(model, Refusal(reason), usage))
    session.StructuredOutputLimited(text, [], usage) ->
      Ok(Receipt(model, OutputLimited(text), usage))
    session.StructuredOutputLimited(_, [_, ..], _)
    | session.StructuredNeedsTools(..) ->
      Error(operation.UncertainEffect(
        "structured decision returned unexpected tools: "
        <> string.inspect(response),
      ))
  }
}

fn failure(failure: session.RunFailure) -> operation.Failure {
  let detail =
    describe(failure.error) <> " (" <> string.inspect(failure.retry) <> ")"
  case failure.retry.classification {
    types.NoRequestSent -> operation.DefiniteFailure(detail)
    types.RequestMayHaveReachedProvider | types.EffectUnknown ->
      operation.UncertainEffect(detail)
  }
}

fn describe(error: types.WireError) -> String {
  case error {
    types.HttpStatusError(status, _, hint) ->
      "HTTP status "
      <> int.to_string(status)
      <> "; retry hint "
      <> string.inspect(hint)
    other -> string.inspect(other)
  }
}

/// A versioned durable receipt, independent of the provider's output schema.
/// Native answers must agree with the original JSON. Restoration decodes that
/// JSON with the deployed output codec; it never contacts the provider.
pub fn receipt_codec(
  output: codec.Codec(output),
) -> codec.Codec(Receipt(output)) {
  // Compose the envelope inside the callback. Capturing the nested combinators
  // here amplifies their closure environments when OTP copies a graph's work
  // into its owned tasks. Only the application's output codec crosses that seam.
  codec.new(
    fn(receipt) { codec.encode(receipt_fields(output), receipt) },
    fn(saved) { codec.decode(receipt_fields(output), saved) },
  )
}

fn receipt_fields(output: codec.Codec(output)) -> codec.Codec(Receipt(output)) {
  let fields =
    codec.pair(
      codec.string(),
      codec.pair(
        codec.string(),
        codec.pair(outcome_codec(output), usage_codec()),
      ),
    )
  codec.try_imap(
    fields,
    fn(saved) {
      let #(format, #(model, #(outcome, usage))) = saved
      use Nil <- result.try(case format {
        "fabric.graph.llm.v1" -> Ok(Nil)
        _ -> Error(decode_error("unsupported LLM receipt format"))
      })
      let receipt = Receipt(model, outcome, usage)
      use Nil <- result.map(
        check_receipt(receipt) |> result.map_error(decode_error),
      )
      receipt
    },
    fn(receipt) {
      use Nil <- result.map(
        check_receipt(receipt) |> result.map_error(encode_error),
      )
      #(
        "fabric.graph.llm.v1",
        #(receipt.model, #(receipt.outcome, receipt.usage)),
      )
    },
  )
}

fn outcome_codec(output: codec.Codec(output)) -> codec.Codec(Outcome(output)) {
  codec.try_imap(
    codec.pair(codec.string(), codec.string()),
    fn(saved) {
      case saved {
        #("answer", raw) ->
          codec.decode_json(output, raw)
          |> result.map(fn(value) { Answer(value, raw) })
          |> result.map_error(fn(error) {
            decode_error(codec.render_json_decode_error(error))
          })
        #("refusal", reason) -> Ok(Refusal(reason))
        #("output_limited", partial) -> Ok(OutputLimited(partial))
        #(tag, _) -> Error(codec.CannotDecode(codec.DecodeUnknownTag(tag)))
      }
    },
    fn(outcome) {
      case outcome {
        Answer(value, raw) -> {
          use encoded <- result.try(codec.encode(output, value))
          use restored <- result.try(
            codec.decode_json(output, raw)
            |> result.map_error(fn(error) {
              encode_error(codec.render_json_decode_error(error))
            }),
          )
          use restored <- result.try(codec.encode(output, restored))
          case encoded == restored {
            True -> Ok(#("answer", raw))
            False ->
              Error(encode_error("answer differs from original output JSON"))
          }
        }
        Refusal(reason) -> Ok(#("refusal", reason))
        OutputLimited(partial) -> Ok(#("output_limited", partial))
      }
    },
  )
}

fn usage_codec() -> codec.Codec(Option(types.Usage)) {
  let counts = codec.pair(codec.int(), codec.pair(codec.int(), codec.int()))
  codec.imap(
    codec.nullable(counts),
    fn(usage) {
      case usage {
        codec.Null -> None
        codec.NonNull(#(input, #(output, total))) ->
          Some(types.Usage(input, output, total))
      }
    },
    fn(usage) {
      case usage {
        None -> codec.Null
        Some(usage) ->
          codec.NonNull(#(
            usage.input_tokens,
            #(usage.output_tokens, usage.total_tokens),
          ))
      }
    },
  )
}

fn check_receipt(receipt: Receipt(output)) -> Result(Nil, String) {
  use model <- result.try(
    types.model_id(receipt.model)
    |> result.map_error(fn(_) { "invalid requested model" }),
  )
  use Nil <- result.try(case types.model_id_to_string(model) == receipt.model {
    True -> Ok(Nil)
    False -> Error("noncanonical requested model")
  })
  case receipt.usage {
    Some(types.Usage(input, output, total))
      if input < 0 || output < 0 || total < 0
    -> Error("negative provider usage")
    Some(_) | None -> Ok(Nil)
  }
}

fn decode_error(reason: String) -> codec.DecodeError {
  codec.CannotDecode(codec.CustomDecodeReason(reason))
}

fn encode_error(reason: String) -> codec.EncodeError {
  codec.CannotEncode(codec.CustomEncodeReason(reason))
}

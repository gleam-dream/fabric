//// One structured LLM decision as a policy-gated graph activity.
//// llm_wire owns the request; Fabric retains the receipt and its route.
//// Tool rounds belong to a managed agent, not this single-request binding.

import fabric/graph/operation
import fabric/run
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import http_gun
import json/blueprint/codec
import json/blueprint/value
import llm_wire
import llm_wire/error
import llm_wire/message

pub type Outcome(output) {
  /// Both the validated application value and the provider's original JSON.
  Answer(value: output, raw_json: String)
  Refusal(reason: String)
  OutputLimited(partial_text: String)
}

pub type Receipt(output) {
  /// `model` is the requested model, not a resolved provider revision.
  /// Missing usage is not zero usage.
  Receipt(model: String, outcome: Outcome(output), usage: Option(message.Usage))
}

/// Version `identity` when the provider, prompt or output meaning changes.
/// The pure request builder runs only after policy admission. It returns the
/// caller's started HTTP Gun client, the llm_wire configuration and a plain
/// request; Fabric adds the structured output. Credentials and the client
/// belong in fresh context, never in the persisted input or receipt; Fabric
/// neither starts nor stops the client.
///
/// Requests must have no tools. Preparation and proven unsent failures are
/// definite; potentially sent failures require reconciliation. No implicit
/// retry is made, even when llm_wire reports a transient error.
pub fn new(
  identity: run.Identity,
  input: codec.Codec(input),
  output: codec.Codec(output),
  output_name: String,
  request: fn(context, input) ->
    #(http_gun.Client, llm_wire.Config, llm_wire.Request(String)),
) -> operation.Operation(context, input, Receipt(output)) {
  operation.new(
    identity,
    input,
    receipt_codec(output),
    fn(context, _, input) {
      let #(client, config, request) = request(context, input)
      perform(client, config, request, output_name, output)
    },
    fn(failure) { failure },
  )
}

fn perform(
  client: http_gun.Client,
  config: llm_wire.Config,
  request: llm_wire.Request(String),
  output_name: String,
  output: codec.Codec(output),
) -> Result(Receipt(output), operation.Failure) {
  use Nil <- result.try(case llm_wire.tools(request) {
    [] -> Ok(Nil)
    [_, ..] ->
      Error(operation.DefiniteFailure(
        "structured decision requests cannot declare tools; use a managed agent",
      ))
  })
  use prepared <- result.try(
    llm_wire.prepare(config, llm_wire.with_output(request, output_name, output))
    |> result.map_error(fn(error) {
      operation.DefiniteFailure(error.describe_prepare_error(error))
    }),
  )
  use response <- result.try(
    llm_wire.run(client, prepared) |> result.map_error(failure),
  )
  // llm_wire sends the trimmed name; the receipt records what was sent.
  let model = string.trim(llm_wire.model(request))
  case response {
    llm_wire.Answer(output:, text:, usage:) ->
      Ok(Receipt(model, Answer(output, text), usage))
    llm_wire.Refused(reason:, usage:) ->
      Ok(Receipt(model, Refusal(reason), usage))
    llm_wire.OutputLimited(partial_text:, partial_calls: [], usage:) ->
      Ok(Receipt(model, OutputLimited(partial_text), usage))
    llm_wire.OutputLimited(partial_calls: [_, ..], ..)
    | llm_wire.NeedsTools(..) ->
      Error(operation.UncertainEffect(
        "structured decision returned unexpected tools: "
        <> string.inspect(response),
      ))
  }
}

fn failure(failure: llm_wire.Failure) -> operation.Failure {
  let detail = llm_wire.describe_failure(failure)
  case failure.sent {
    llm_wire.NotSent -> operation.DefiniteFailure(detail)
    llm_wire.MaybeSent | llm_wire.Completed -> operation.UncertainEffect(detail)
  }
}

/// A versioned durable receipt, independent of the provider's output schema.
/// Native answers must agree with the original JSON. Restoration decodes that
/// JSON with the deployed output codec; it never contacts the provider.
///
/// A receipt is written as the `fabric.graph.llm.v2` object
/// `{"format", "model", "outcome", "usage"}`. A `fabric.graph.llm.v1`
/// receipt, the nested array an earlier release wrote, still decodes.
pub fn receipt_codec(
  output: codec.Codec(output),
) -> codec.Codec(Receipt(output)) {
  // Compose the envelope inside the callback. Capturing the nested combinators
  // here amplifies their closure environments when OTP copies a graph's work
  // into its owned tasks. Only the application's output codec crosses that seam.
  codec.custom(
    encode: fn(receipt) { codec.encode(receipt_fields(output), receipt) },
    decode: fn(saved) {
      case saved {
        value.Array(_) -> codec.decode(legacy_receipt_fields(output), saved)
        _ -> codec.decode(receipt_fields(output), saved)
      }
    },
    schema: None,
    placeholder: codec.placeholder(receipt_fields(output)),
  )
}

fn receipt_fields(output: codec.Codec(output)) -> codec.Codec(Receipt(output)) {
  let fields = {
    use Nil <- codec.field(
      "format",
      codec.string_enum([#("fabric.graph.llm.v2", Nil)]),
      get: fn(_) { Nil },
    )
    use model <- codec.field("model", codec.string(), get: fn(r) { r.model })
    use outcome <- codec.field("outcome", outcome_codec(output), get: fn(r) {
      r.outcome
    })
    use usage <- codec.field("usage", codec.nullable(usage_codec()), get: fn(r) {
      r.usage
    })
    codec.success(Receipt(model:, outcome:, usage:))
  }
  codec.try_map(
    fields,
    decode: checked_receipt,
    encode: checked_receipt,
    placeholder: codec.placeholder(fields),
  )
}

fn checked_receipt(
  receipt: Receipt(output),
) -> Result(Receipt(output), String) {
  check_receipt(receipt) |> result.replace(receipt)
}

fn outcome_codec(output: codec.Codec(output)) -> codec.Codec(Outcome(output)) {
  codec.union({
    use answer <- codec.variant("answer", answer_codec(output), fn(answer) {
      answer
    })
    use refusal <- codec.variant("refusal", codec.string(), Refusal)
    use limited <- codec.variant(
      "output_limited",
      codec.string(),
      OutputLimited,
    )
    codec.match(fn(outcome) {
      case outcome {
        Answer(..) -> answer(outcome)
        Refusal(reason) -> refusal(reason)
        OutputLimited(partial) -> limited(partial)
      }
    })
  })
}

/// An `Answer` as its original JSON text, checked against the output codec
/// in both directions.
fn answer_codec(output: codec.Codec(output)) -> codec.Codec(Outcome(output)) {
  codec.try_map(
    codec.string(),
    decode: fn(raw) { decode_answer(output, raw) },
    encode: fn(outcome) {
      case outcome {
        Answer(value, raw) -> encode_answer(output, value, raw)
        Refusal(_) | OutputLimited(_) -> Error("not an answer")
      }
    },
    placeholder: Refusal(""),
  )
}

fn decode_answer(
  output: codec.Codec(output),
  raw: String,
) -> Result(Outcome(output), String) {
  codec.decode_json(output, raw)
  |> result.map(fn(value) { Answer(value, raw) })
  |> result.map_error(codec.describe_decode_error)
}

/// The original JSON, provided the native value encodes as that JSON does.
fn encode_answer(
  output: codec.Codec(output),
  value: output,
  raw: String,
) -> Result(String, String) {
  use encoded <- result.try(
    codec.encode(output, value) |> result.map_error(codec.describe_encode_error),
  )
  use restored <- result.try(
    codec.decode_json(output, raw)
    |> result.map_error(codec.describe_decode_error),
  )
  use restored <- result.try(
    codec.encode(output, restored)
    |> result.map_error(codec.describe_encode_error),
  )
  case encoded == restored {
    True -> Ok(raw)
    False -> Error("answer differs from original output JSON")
  }
}

fn usage_codec() -> codec.Codec(message.Usage) {
  use input_tokens <- codec.field("input_tokens", codec.int(), get: fn(usage) {
    usage.input_tokens
  })
  use output_tokens <- codec.field("output_tokens", codec.int(), get: fn(usage) {
    usage.output_tokens
  })
  use total_tokens <- codec.field("total_tokens", codec.int(), get: fn(usage) {
    usage.total_tokens
  })
  codec.success(message.Usage(input_tokens, output_tokens, total_tokens))
}

/// The `fabric.graph.llm.v1` receipt, read only:
/// `[format, [model, [[tag, text], usage]]]` with `usage` either `null` or
/// `[input, [output, total]]`.
fn legacy_receipt_fields(
  output: codec.Codec(output),
) -> codec.Codec(Receipt(output)) {
  let counts = codec.pair(codec.int(), codec.pair(codec.int(), codec.int()))
  codec.pair(
    codec.string(),
    codec.pair(
      codec.string(),
      codec.pair(
        codec.pair(codec.string(), codec.string()),
        codec.nullable(counts),
      ),
    ),
  )
  |> codec.try_map(
    decode: fn(saved) {
      let #(format, #(model, #(#(tag, text), usage))) = saved
      use Nil <- result.try(case format {
        "fabric.graph.llm.v1" -> Ok(Nil)
        _ -> Error("unsupported LLM receipt format")
      })
      use outcome <- result.try(case tag {
        "answer" -> decode_answer(output, text)
        "refusal" -> Ok(Refusal(text))
        "output_limited" -> Ok(OutputLimited(text))
        _ -> Error("unknown LLM receipt outcome")
      })
      let usage =
        option.map(usage, fn(counts) {
          let #(input, #(generated, total)) = counts
          message.Usage(input, generated, total)
        })
      checked_receipt(Receipt(model, outcome, usage))
    },
    encode: fn(_) { Error("fabric.graph.llm.v1 receipts are read only") },
    placeholder: codec.placeholder(receipt_fields(output)),
  )
}

fn check_receipt(receipt: Receipt(output)) -> Result(Nil, String) {
  use Nil <- result.try(case string.trim(receipt.model) {
    "" -> Error("invalid requested model")
    trimmed if trimmed == receipt.model -> Ok(Nil)
    _ -> Error("noncanonical requested model")
  })
  case receipt.usage {
    Some(message.Usage(input, output, total))
      if input < 0 || output < 0 || total < 0
    -> Error("negative provider usage")
    Some(_) | None -> Ok(Nil)
  }
}

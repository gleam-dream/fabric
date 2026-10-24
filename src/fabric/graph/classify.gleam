//// A typed classification as one graph decision, after policy admission.
////
//// Each operation version fixes its pure wire and receipt bounds. The request
//// callback supplies current HTTP Gun and classification settings after policy
//// admission, including approval and recovery. Receipts retain
//// native answers, distributions, models, usage and protocol evidence;
//// replay needs no network or credentials. Confidence is concentration
//// evidence, not the probability that a decision is correct.

import fabric/graph/operation
import fabric/run
import fabric/tool
import gleam/result
import http_gun
import json/blueprint/codec
import json/blueprint/value.{type Value}
import llm_wire
import llm_wire/classify
import llm_wire/classify/question
import llm_wire/error

pub opaque type Call {
  Call(
    client: http_gun.Client,
    config: classify.Config,
    model: String,
    state: Value,
  )
}

/// Live request context; it is never written to the graph record.
pub fn call(
  client: http_gun.Client,
  config: classify.Config,
  model: String,
  state: Value,
) -> Call {
  Call(client:, config:, model:, state:)
}

/// `request` runs only after policy admission and should be pure. Derive live
/// settings from its fresh context; the wire and questions retain their meaning
/// for this operation version. A different protocol needs a new version.
/// Live byte limits above the wire's receipt bounds fail before credential
/// access or network I/O. Lower live limits do not affect stored receipts.
pub fn decision(
  identity: run.DefinitionId,
  input: codec.Codec(input),
  questions: question.Batch(answer),
  wire: classify.Wire,
  request: fn(context, input) -> Call,
) -> operation.Operation(context, input, classify.Outcome(answer)) {
  operation.new(
    identity,
    input,
    classify.receipt_codec(wire, questions),
    fn(context, invocation: operation.Invocation, input) {
      let call = request(context, input)
      use prepared <- result.try(
        classify.prepare(
          wire,
          call.config,
          classify.request(call.model, call.state, questions),
        )
        |> result.map_error(fn(problem) {
          tool.Explain(error.describe_prepare_error(problem))
        }),
      )
      classify.run(
        http_gun.with_correlation(call.client, invocation.correlation),
        prepared,
      )
      |> result.map_error(fn(failure) {
        let detail = llm_wire.describe_failure(failure)
        case failure.sent {
          llm_wire.NotSent -> tool.Explain(detail)
          llm_wire.MaybeSent | llm_wire.Completed -> tool.Uncertain(detail)
        }
      })
    },
    fn(failure) { failure },
  )
}

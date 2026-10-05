//// A typed classification as one graph decision, after policy admission.
////
//// The caller owns HTTP Gun and classification settings. Receipts retain
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
  Call(client: http_gun.Client, model: String, state: Value)
}

/// Live request context; it is never written to the graph record.
pub fn call(client: http_gun.Client, model: String, state: Value) -> Call {
  Call(client:, model:, state:)
}

/// `request` runs only after policy admission and should be pure.
pub fn decision(
  identity: run.DefinitionId,
  input: codec.Codec(input),
  questions: question.Batch(answer),
  config: classify.Config,
  request: fn(context, input) -> Call,
) -> operation.Operation(context, input, classify.Outcome(answer)) {
  operation.new(
    identity,
    input,
    classify.receipt_codec(config, questions),
    fn(context, invocation: operation.Invocation, input) {
      let call = request(context, input)
      use prepared <- result.try(
        classify.prepare(
          config,
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

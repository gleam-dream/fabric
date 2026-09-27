//// THROWAWAY (workflow composition experiment). Saga-as-tool: a typed Saga
//// workflow exposed as one Fabric tool. A cleanly compensated failure is a
//// model-visible typed failure; anything that leaves effects unresolved is
//// an uncertain effect for Fabric to escalate.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import saga
import saga/execution
import wc/codec.{type Codec, Codec}
import wc/tool

pub type Failure(e) {
  Failure(error: e, undone: List(String))
}

pub fn from_workflow(
  name: String,
  input: Codec(i),
  output: Codec(o),
  error: Codec(e),
  workflow: saga.Workflow(i, o, e, u),
  config: execution.Config,
) -> tool.Tool {
  tool.define_reporting(name, input, output, failure_codec(error), fn(value) {
    case execution.run(workflow, value, config) {
      Ok(execution.Completed(result)) -> tool.Done(Ok(result))
      Ok(execution.Failed(execution.StepFailed(_, e), settlement))
        if settlement.undo_failures == []
        && settlement.interrupted == []
        && settlement.compensation_failures == []
        && settlement.held == []
      ->
        tool.Done(
          Error(Failure(e, list.map(settlement.undone, saga.address_to_string))),
        )
      Ok(_) -> tool.EffectUncertain("workflow left effects unresolved")
      Error(_) -> tool.EffectUncertain("workflow run lost")
    }
  })
}

fn failure_codec(error: Codec(e)) -> Codec(Failure(e)) {
  // Only encoding matters for a tool error: it is rendered for the model.
  Codec(
    fn(failure: Failure(e)) {
      json.object([
        #("failure", error.encode(failure.error)),
        #("undone", json.array(failure.undone, json.string)),
      ])
    },
    decode.map(error.decoder, fn(e) { Failure(e, []) }),
  )
}

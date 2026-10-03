//// One application routing definition, independent of decision production.

import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/policy
import fabric/run
import fabric/store
import gleam/time/duration
import json/blueprint/codec

pub type Decision {
  Approve
  Revise
}

pub fn decision_codec() -> codec.Codec(Decision) {
  let choices =
    codec.string_enum([#("approve", Approve), #("revise", Revise)])
    |> codec.describe(
      "Approve only a correct arithmetic statement; otherwise revise.",
    )
  use decision <- codec.field("decision", choices, get: fn(decision) {
    decision
  })
  codec.success(decision)
}

pub fn runtime(
  identity: run.Identity,
  runs: store.Store,
  context: fn() -> context,
  reviewer: operation.Operation(context, String, receipt),
  interpret: fn(receipt) -> Result(Decision, String),
) -> graph.Runtime(context, String, String) {
  let review =
    definition.node(
      node_id("review"),
      reviewer,
      fn(state) { Ok(state) },
      fn(state, receipt) {
        case interpret(receipt) {
          Ok(Approve) -> Ok(definition.Continue(state, node_id("publish")))
          Ok(Revise) -> Ok(definition.Continue(state, node_id("revise")))
          Error(reason) -> Error(reason)
        }
      },
      [node_id("publish"), node_id("revise")],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      identity,
      node_id("review"),
      [
        review,
        finish("publish", "approved"),
        finish("revise", "needs revision"),
      ],
      codec.string(),
      codec.string(),
      2,
    ))
  let assert Ok(runtime) =
    graph.new(spec, runs, context, fn(_, _) { Ok(policy.Allow) })
    |> graph.with_timeouts(
      callbacks: duration.milliseconds(5000),
      operations: duration.milliseconds(30_000),
      commands: duration.milliseconds(1000),
    )
  runtime
}

fn finish(
  name: String,
  answer: String,
) -> definition.Node(context, String, String) {
  let op =
    operation.new(
      run.Identity(name, 1),
      codec.string(),
      codec.string(),
      fn(_, _, _) { Ok(answer) },
      fn(_error: Nil) {
        operation.DefiniteFailure("pure terminal operation cannot fail")
      },
    )
  definition.node(
    node_id(name),
    op,
    fn(state) { Ok(state) },
    fn(state, answer) { Ok(definition.Finish(state, answer)) },
    [],
  )
}

fn node_id(name: String) -> definition.NodeId {
  let assert Ok(id) = definition.node_id(name)
  id
}

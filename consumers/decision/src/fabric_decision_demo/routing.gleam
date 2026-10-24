//// One application routing definition, independent of decision production.

import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/policy
import fabric/run
import fabric/store
import fabric/tool
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
  identity: run.DefinitionId,
  runs: store.Store,
  context: fn(run.RunId) -> context,
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
    definition.build(
      definition.new(
        identity,
        entry: node_id("review"),
        nodes: [
          review,
          finish("publish", "approved"),
          finish("revise", "needs revision"),
        ],
        state: codec.string(),
        answer: codec.string(),
      )
      |> definition.with_max_activations(2),
    )
  // The bounds could come from configuration: `build` reports every one
  // out of range instead of panicking.
  case
    graph.new(spec, runs, context, fn(_, _) { Ok(policy.Allow) })
    |> graph.with_callback_timeout(duration.milliseconds(5000))
    |> graph.with_operation_timeout(run.After(duration.milliseconds(30_000)))
    |> graph.with_command_timeout(duration.milliseconds(1000))
    |> graph.build
  {
    Ok(runtime) -> runtime
    Error(errors) -> panic as graph.describe_config_errors(errors)
  }
}

fn finish(
  name: String,
  answer: String,
) -> definition.Node(context, String, String) {
  let op =
    operation.new(
      run.DefinitionId(name, 1),
      codec.string(),
      codec.string(),
      fn(_, _, _) { Ok(answer) },
      fn(_error: Nil) { tool.Explain("pure terminal operation cannot fail") },
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
  let id = definition.node_id(name)
  id
}

//// Source → generation → review → bounded revision → approval → local artifact.
//// `approvers` decide who may approve publishing.

import fabric/approvers.{type Approvers}
import fabric/graph
import fabric/graph/definition
import fabric/graph/llm
import fabric/graph/operation
import fabric/policy
import fabric/run
import fabric/store
import fabric_writing/domain.{
  type Artifact, type Draft, type Outcome, type State, Working,
}
import fabric_writing/file
import fabric_writing/provider
import gleam/option.{None}
import gleam/result
import gleam/time/duration

pub fn runtime(
  runs: store.Store,
  generator: operation.Operation(Nil, Draft, llm.Receipt(String)),
  reviewer: provider.Reviewer(receipt),
  publisher: operation.Operation(Nil, Draft, Artifact),
  approvers: Approvers(credential),
) -> graph.Runtime(Nil, State, Outcome) {
  let source =
    definition.node(
      node("source"),
      file.loader(),
      fn(state) {
        case state {
          domain.Loading(brief) -> Ok(brief)
          Working(..) -> Error("source already loaded")
        }
      },
      fn(_, draft) {
        Ok(definition.Continue(
          Working(domain.Generating, draft),
          node("generate"),
        ))
      },
      [node("generate")],
    )
  let generate =
    definition.node(
      node("generate"),
      generator,
      select(domain.Generating),
      fn(state, receipt) {
        use current <- result.try(select(domain.Generating)(state))
        use body <- result.map(provider.answer(receipt))
        let text = domain.Text(..current.text, body:)
        definition.Continue(
          Working(domain.Reviewing, domain.Draft(text, current.generation + 1)),
          node("review"),
        )
      },
      [node("review")],
    )
  let review =
    definition.node(
      node("review"),
      reviewer.operation,
      select(domain.Reviewing),
      fn(state, receipt) {
        use current <- result.try(select(domain.Reviewing)(state))
        use decision <- result.map(reviewer.interpret(receipt))
        case decision {
          domain.Approve ->
            definition.Continue(
              Working(domain.Publishing, current),
              node("publish"),
            )
          domain.Revise if current.generation < 3 ->
            definition.Continue(
              Working(domain.Generating, current),
              node("generate"),
            )
          domain.Revise -> definition.Finish(state, domain.RevisionLimit)
          domain.Reject -> definition.Finish(state, domain.Rejected)
        }
      },
      [node("generate"), node("publish")],
    )
  let publish =
    definition.node(
      node("publish"),
      publisher,
      select(domain.Publishing),
      fn(state, artifact) {
        Ok(definition.Finish(state, domain.Published(artifact)))
      },
      [],
    )
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("source-writing", 1),
        entry: node("source"),
        nodes: [source, generate, review, publish],
        state: domain.state_codec(),
        answer: domain.outcome_codec(),
      )
      |> definition.with_max_activations(8),
    )
  let assert Ok(runtime) =
    graph.new(spec, runs, fn(_) { Nil }, fn(_, action) {
      case action.target {
        policy.RunOperation(node: "publish", ..) ->
          Ok(policy.RequireApproval(run.Requirement("publish-artifact", 1)))
        _ -> Ok(policy.Allow)
      }
    })
    |> graph.with_callback_timeout(duration.milliseconds(5000))
    |> graph.with_operation_timeout(run.After(duration.milliseconds(30_000)))
    |> graph.with_command_timeout(duration.milliseconds(1000))
    |> graph.with_approvers(approvers)
    |> graph.build
  runtime
}

pub fn start(
  runtime: graph.Runtime(Nil, State, Outcome),
  id: String,
  source: String,
  brief: String,
) -> Result(graph.Handle(Nil, State, Outcome), graph.Error) {
  use id <- result.try(
    run.parse_id(id)
    |> result.replace_error(graph.WrongReference),
  )
  graph.start(
    runtime,
    id,
    domain.Loading(domain.Brief(source, brief)),
    correlation: None,
  )
}

fn select(stage: domain.Stage) -> fn(State) -> Result(Draft, String) {
  fn(state) {
    case state {
      Working(found, draft) if found == stage -> Ok(draft)
      _ -> Error("unexpected writing stage")
    }
  }
}

fn node(name: String) -> definition.NodeId {
  let id = definition.node_id(name)
  id
}

//// Source → generation → review → bounded revision → approval → local artifact.

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
import gleam/result
import gleam/time/duration

pub fn runtime(
  runs: store.Store,
  generator: operation.Operation(Nil, Draft, llm.Receipt(String)),
  reviewer: provider.Reviewer(receipt),
  publisher: operation.Operation(Nil, Draft, Artifact),
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
    definition.build(definition.Spec(
      run.Identity("source-writing", 1),
      node("source"),
      [source, generate, review, publish],
      domain.state_codec(),
      domain.outcome_codec(),
      8,
    ))
  let assert Ok(runtime) =
    graph.new(spec, runs, fn() { Nil }, fn(_, action) {
      case action.node {
        "publish" ->
          Ok(policy.RequireApproval(run.Requirement("publish-artifact", 1)))
        _ -> Ok(policy.Allow)
      }
    })
    |> graph.with_timeouts(
      callbacks: duration.milliseconds(5000),
      operations: duration.milliseconds(30_000),
      commands: duration.milliseconds(1000),
    )
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
    |> result.map_error(fn(_) { graph.CommandRefused("invalid run id") }),
  )
  graph.start(runtime, id, domain.Loading(domain.Brief(source, brief)))
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
  let assert Ok(id) = definition.node_id(name)
  id
}

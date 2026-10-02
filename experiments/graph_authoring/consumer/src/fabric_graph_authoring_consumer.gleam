//// Independently authored application: only the experiment's public API.

import fabric_graph_authoring as graph
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import json/blueprint/codec.{type Codec}

pub type Draft {
  Draft(revision: Int, text: String)
}

pub type Review {
  Revise
  Accept
}

pub type State {
  Drafting(revision: Int)
  Reviewing(Draft)
}

pub type Context {
  Context(accept_revision: Int)
}

pub fn draft_codec() -> Codec(Draft) {
  use revision <- codec.field("revision", codec.int(), fn(draft: Draft) {
    draft.revision
  })
  use text <- codec.field("text", codec.string(), fn(draft: Draft) {
    draft.text
  })
  codec.success(Draft(revision:, text:))
}

pub fn state_codec() -> Codec(State) {
  codec.union({
    use drafting <- codec.variant("drafting", codec.int(), Drafting)
    use reviewing <- codec.variant("reviewing", draft_codec(), Reviewing)
    codec.match(fn(state) {
      case state {
        Drafting(revision) -> drafting(revision)
        Reviewing(draft) -> reviewing(draft)
      }
    })
  })
}

pub fn definition(
  limit: Int,
) -> Result(graph.Graph(Context, State, Draft), graph.BuildError) {
  let assert Ok(generate) = graph.node_id("draft.generate")
  let assert Ok(review) = graph.node_id("draft.review")
  let review_codec =
    codec.string_enum([#("revise", Revise), #("accept", Accept)])
  let generate_operation =
    graph.operation(
      graph.Identity("generate", 1),
      codec.int(),
      draft_codec(),
      fn(_context: Context, revision) {
        Ok(Draft(revision, "draft " <> int.to_string(revision)))
      },
      impossible_error,
    )
  let review_operation =
    graph.operation(
      graph.Identity("review", 1),
      draft_codec(),
      review_codec,
      fn(context: Context, draft) {
        Ok(case draft.revision >= context.accept_revision {
          True -> Accept
          False -> Revise
        })
      },
      impossible_error,
    )
  graph.build(
    graph.Spec(
      identity: graph.Identity("draft-and-review", 1),
      entry: generate,
      state: state_codec(),
      answer: draft_codec(),
      max_activations: limit,
      nodes: [
        graph.node(
          generate,
          generate_operation,
          select: fn(state) {
            case state {
              Drafting(revision) -> Ok(revision)
              Reviewing(_) -> Error("generation requires the drafting phase")
            }
          },
          accept: fn(_state, draft) {
            Ok(graph.Continue(Reviewing(draft), review))
          },
          destinations: [review],
        ),
        graph.node(
          review,
          review_operation,
          select: fn(state) {
            case state {
              Reviewing(draft) -> Ok(draft)
              Drafting(_) -> Error("review requires a generated draft")
            }
          },
          accept: fn(state, decision) {
            case state {
              Drafting(_) -> Error("cannot accept a review without a draft")
              Reviewing(draft) ->
                case decision {
                  Accept -> Ok(graph.Finish(state, draft))
                  Revise ->
                    Ok(graph.Continue(Drafting(draft.revision + 1), generate))
                }
            }
          },
          destinations: [generate],
        ),
      ],
    ),
  )
}

fn impossible_error(_error: Nil) -> graph.Failure {
  graph.DefiniteFailure("script cannot fail")
}

pub fn run(limit: Int) -> Result(graph.Report(State, Draft), graph.BuildError) {
  use definition <- result.try(definition(limit))
  Ok(graph.run(definition, Context(3), Drafting(1)))
}

/// The result contract changes without widening the graph's state or answer.
/// `choose` is ordinary typed application code, independent of the producer.
pub fn decision_graph(
  output: Codec(decision),
  produce: fn(Nil, Int) -> Result(decision, Nil),
  choose: fn(decision) -> Review,
) -> Result(graph.Graph(Nil, Int, String), graph.BuildError) {
  let assert Ok(decide) = graph.node_id("decide")
  let assert Ok(accept) = graph.node_id("accept")
  let assert Ok(revise) = graph.node_id("revise")
  let decision =
    graph.operation(
      graph.Identity("scripted-decision", 1),
      codec.int(),
      output,
      produce,
      impossible_error,
    )
  graph.build(
    graph.Spec(
      identity: graph.Identity("decision-routing", 1),
      entry: decide,
      state: codec.int(),
      answer: codec.string(),
      max_activations: 2,
      nodes: [
        graph.node(
          decide,
          decision,
          select: fn(state) { Ok(state) },
          accept: fn(state, decision) {
            Ok(
              graph.Continue(state, case choose(decision) {
                Accept -> accept
                Revise -> revise
              }),
            )
          },
          destinations: [accept, revise],
        ),
        finish_node(accept, "accepted"),
        finish_node(revise, "needs revision"),
      ],
    ),
  )
}

fn finish_node(
  id: graph.NodeId,
  answer: String,
) -> graph.Node(Nil, Int, String) {
  let operation =
    graph.operation(
      graph.Identity(graph.node_name(id), 1),
      codec.int(),
      codec.string(),
      fn(_, _) { Ok(answer) },
      impossible_error,
    )
  graph.node(
    id,
    operation,
    select: fn(state) { Ok(state) },
    accept: fn(state, answer) { Ok(graph.Finish(state, answer)) },
    destinations: [],
  )
}

pub fn main() -> Nil {
  let assert Ok(report) = run(6)
  case report.outcome {
    Ok(draft) -> io.println("Accepted: " <> draft.text)
    Error(_) -> io.println("Graph stopped before an accepted answer")
  }
  list.each(report.trace, fn(receipt) {
    io.println(
      int.to_string(receipt.activation.ordinal)
      <> ": "
      <> graph.node_name(receipt.activation.node)
      <> " => "
      <> receipt.output_json,
    )
  })
}

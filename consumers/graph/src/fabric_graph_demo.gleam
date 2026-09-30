//// A typed generation/review loop using the production graph runtime.
//// Decisions are scripted; changing their producer does not change routing.

import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/graph/signal
import fabric/policy
import fabric/run
import fabric/store
import gleam/erlang/process
import gleam/io
import gleam/string
import json/blueprint/codec

fn infallible(_error: Nil) -> operation.Failure {
  operation.DefiniteFailure("cannot fail")
}

pub fn execute(limit: Int) -> graph.Snapshot(Int, Int) {
  let reviewer =
    operation.new(
      run.Identity("scripted-reviewer", 1),
      codec.int(),
      codec.bool(),
      fn(_, _, revision) { Ok(revision >= 3) },
      infallible,
    )
  let handle = start_with_reviewer(limit, reviewer)
  let assert Ok(snapshot) = graph.await(handle, 5000)
  snapshot
}

/// The graph's state, routes and bounds are identical; only the source of
/// its boolean decision changes. A caller supplies it through `graph.deliver`.
pub fn start_manual(
  limit: Int,
) -> #(graph.Handle(Nil, Int, Int), signal.Signal(Bool)) {
  let decision = signal.new(run.Identity("human-review", 1), codec.bool())
  #(
    start_with_reviewer(limit, operation.await_signal(codec.int(), decision)),
    decision,
  )
}

fn start_with_reviewer(
  limit: Int,
  reviewer: operation.Operation(Nil, Int, Bool),
) -> graph.Handle(Nil, Int, Int) {
  let assert Ok(generate) = definition.node_id("generate")
  let assert Ok(review) = definition.node_id("review")
  let generator =
    operation.new(
      run.Identity("scripted-generator", 1),
      codec.int(),
      codec.int(),
      fn(_, _, revision) { Ok(revision + 1) },
      infallible,
    )
  let generate_node =
    definition.node(
      generate,
      generator,
      fn(revision) { Ok(revision) },
      fn(_, next_revision) { Ok(definition.Continue(next_revision, review)) },
      [review],
    )
  let review_node =
    definition.node(
      review,
      reviewer,
      fn(revision) { Ok(revision) },
      fn(revision, approved) {
        case approved {
          True -> Ok(definition.Finish(revision, revision))
          False -> Ok(definition.Continue(revision, generate))
        }
      },
      [generate],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("generation-review", 1),
      generate,
      [generate_node, review_node],
      codec.int(),
      codec.int(),
      limit,
    ))
  let runs = store.in_memory(process.new_name("graph-demo"))
  let assert Ok(Nil) = store.start(runs)
  let runtime =
    graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(id) = run.parse_id("demo")
  let assert Ok(handle) = graph.start(runtime, id, 0)
  handle
}

pub fn main() -> Nil {
  let snapshot = execute(6)
  io.println(string.inspect(snapshot.status))
  io.println(string.inspect(snapshot.receipts))
}

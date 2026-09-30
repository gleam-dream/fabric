//// A typed generation/review loop using the production graph runtime.
//// Decisions are scripted; changing their producer does not change routing.

import fabric/agent
import fabric/graph
import fabric/graph/agent as agent_node
import fabric/graph/definition
import fabric/graph/operation
import fabric/graph/signal
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
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

/// The same boolean decision is supplied by an ordinary managed agent. This
/// model is scripted; the graph binding does not depend on its producer.
pub fn execute_agent(limit: Int) -> graph.Snapshot(Int, Int) {
  let runs = store.in_memory(process.new_name("agent-review-demo"))
  let assert Ok(Nil) = store.start(runs)
  let model =
    model.new(fn(request) {
      let assert Ok(model.UserMessage(prompt)) = list.last(request.messages)
      let assert Ok(revision) = int.parse(prompt)
      Ok(model.FinalAnswer(
        case revision >= 3 {
          True -> "approve"
          False -> "revise"
        },
        None,
      ))
    })
  let assert Ok(agent) =
    agent.new("reviewer", model, [], policy.always_allow()) |> agent.build
  let assert Ok(reviewer) =
    agent_node.new(
      agent_node.Definition(
        run.Identity("agent-reviewer", 1),
        agent,
        codec.int(),
        codec.bool(),
        int.to_string,
        fn(answer) {
          case answer {
            "approve" -> Ok(True)
            "revise" -> Ok(False)
            _ -> Error("expected approve or revise")
          }
        },
      ),
      runs,
      fn() { Nil },
    )
  let handle = start_on(runs, limit, agent_node.as_operation(reviewer))
  let assert Ok(done) = graph.await(handle, 5000)
  done
}

fn start_with_reviewer(
  limit: Int,
  reviewer: operation.Operation(Nil, Int, Bool),
) -> graph.Handle(Nil, Int, Int) {
  let runs = store.in_memory(process.new_name("graph-demo"))
  let assert Ok(Nil) = store.start(runs)
  start_on(runs, limit, reviewer)
}

fn start_on(
  runs: store.Store,
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

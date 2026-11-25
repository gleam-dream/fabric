//// A graph's own stored values (its state, an activation's input and
//// output, its answer) are read back from the trusted record store without
//// the parse limits that guard untrusted input: a run whose state grew past
//// them still completes and recovers.

import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/policy
import fabric/run
import fabric/support
import fabric/testing
import fabric/tool
import gleam/option.{None}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

/// Bigger than the default parse limit of 1 MiB.
fn large() -> String {
  string.repeat("abcdefgh", 160_000)
}

fn runtime() -> graph.Runtime(Nil, String, String) {
  let op =
    operation.new(
      run.DefinitionId("echo", 1),
      codec.string(),
      codec.string(),
      fn(_, _, text) { Ok(text <> "!") },
      fn(_: Nil) { tool.Explain("unreachable") },
    )
  let node = definition.node_id("echo")
  let assert Ok(d) =
    definition.build(definition.new(
      run.DefinitionId("large-state", 1),
      entry: node,
      nodes: [
        definition.node(
          node,
          op,
          fn(state) { Ok(state) },
          fn(_, out) { Ok(definition.Finish(out, out)) },
          [],
        ),
      ],
      state: codec.string(),
      answer: codec.string(),
    ))
  let assert Ok(runtime) =
    graph.new(d, support.store(), fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
    |> graph.with_approvers(testing.trusting_approvers())
    |> graph.build
  runtime
}

pub fn a_state_beyond_the_default_parse_limit_completes_and_recovers_test() {
  let assert Ok(handle) =
    graph.start(runtime(), run.new_id(), large(), correlation: None)
  let assert Ok(done) = graph.await(handle, within: duration.seconds(30))
  done |> should.equal(graph.Completed(large() <> "!"))
  let assert Ok(snapshot) = graph.snapshot(handle)
  snapshot.value |> should.equal(large() <> "!")
  graph.recover(handle) |> should.equal(Ok(graph.Completed(large() <> "!")))
}

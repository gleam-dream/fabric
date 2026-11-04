//// Crash evidence. A tool body, a graph operation or a policy that crashes
//// with a term holding a secret (a credential in the context it was
//// called with) leaves evidence that names the crash's class, its kind and
//// where it happened, and never the term: the evidence is durable and is
//// returned to callers.

import fabric
import fabric/agent
import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/internal/executor
import fabric/internal/store as store_core
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/codecs
import fabric/support/scripted
import fabric/testing
import fabric/tool
import gleam/option.{None}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

const sentinel = "sk-live-SENTINEL-7f3a"

pub type Credentials {
  Credentials(api_key: String)
}

/// Fails an assertion on a value that carries `credentials`, as a handler
/// that asserts on a call made with its context does.
fn use_credentials(credentials: Credentials) -> String {
  let assert Ok(text) = refuse(credentials)
  text
}

fn refuse(credentials: Credentials) -> Result(String, Credentials) {
  Error(credentials)
}

fn leaky_tool() -> tool.Tool(Credentials) {
  tool.define(
    "lookup",
    "Looks something up with the context's credentials.",
    codecs.one_field("x", codec.string()),
    codec.string(),
  )
  |> tool.bind(
    fn(credentials: Credentials, _call, _x: String) -> Result(String, Nil) {
      Ok(use_credentials(credentials))
    },
    fn(_) { tool.Explain("failed") },
  )
}

fn names_the_crash(evidence: String) -> Nil {
  string.contains(evidence, sentinel) |> should.be_false
  string.contains(evidence, "error") |> should.be_true
  string.contains(evidence, "let_assert") |> should.be_true
  string.contains(evidence, "fabric@crash_evidence_test:use_credentials/1")
  |> should.be_true
}

pub fn a_tool_crash_keeps_its_terms_out_of_the_evidence_test() {
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.call("x", "lookup", "{\"x\":\"q\"}")]),
      [leaky_tool()],
      policy.always_allow(),
    )
    |> support.agent
  let runs = support.store()
  let assert Ok(run) =
    fabric.start(
      runs,
      agent,
      id: run.new_id(),
      context: Credentials(sentinel),
      prompt: "look it up",
      correlation: None,
    )
  let assert Ok(run.Suspended([], [crashed])) =
    fabric.await(run, within: duration.milliseconds(5000))
  string.starts_with(crashed.evidence, "tool crashed") |> should.be_true
  names_the_crash(crashed.evidence)
  let assert Ok(stored) = store_core.get(runs, support.text(fabric.id(run)))
  string.contains(stored.record, sentinel) |> should.be_false
}

pub fn a_policy_crash_keeps_its_terms_out_of_the_failure_test() {
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.call("x", "lookup", "{\"x\":\"q\"}")]),
      [leaky_tool()],
      fn(credentials: Credentials, _) -> Result(policy.Decision, String) {
        Ok(policy.Deny(use_credentials(credentials)))
      },
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Credentials(sentinel),
      prompt: "look it up",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Failed(run.PolicyFailed(_, reason)))) =
    fabric.await(run, within: duration.milliseconds(5000))
  string.starts_with(reason, "policy crashed") |> should.be_true
  names_the_crash(reason)
}

pub fn a_graph_operation_crash_keeps_its_terms_out_of_the_evidence_test() {
  let node =
    definition.node(
      definition.node_id("only"),
      operation.new(
        run.DefinitionId("leaky", 1),
        codec.int(),
        codec.int(),
        fn(credentials: Credentials, _, n) -> Result(Int, Nil) {
          let _ = use_credentials(credentials)
          Ok(n)
        },
        fn(_) { tool.Explain("cannot fail") },
      ),
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.new(
      run.DefinitionId("single", 1),
      entry: definition.node_id("only"),
      nodes: [node],
      state: codec.int(),
      answer: codec.int(),
    ))
  let runs = support.store()
  let assert Ok(runtime) =
    graph.new(spec, runs, fn(_) { Credentials(sentinel) }, fn(_, _) {
      Ok(policy.Allow)
    })
    |> graph.with_approvers(testing.trusting_approvers())
    |> graph.build
  let assert Ok(id) = run.parse_id("leaky-graph")
  let assert Ok(handle) = graph.start(runtime, id, 0, correlation: None)
  let assert Ok(graph.Blocked(_, graph.EffectUncertain(evidence))) =
    graph.await(handle, within: duration.milliseconds(5000))
  names_the_crash(evidence)
  let assert Ok(stored) = store_core.get(runs, "leaky-graph")
  string.contains(stored.record, sentinel) |> should.be_false
}

@external(erlang, "fabric_test_ffi", "raise_atom")
fn raise_atom(text: String) -> Nil

@external(erlang, "fabric_test_ffi", "raise_tagged")
fn raise_tagged(text: String) -> Nil

/// An atom made from data is not a known exception kind: the evidence
/// names the crash as an exception and never prints the atom.
pub fn an_atom_made_from_data_stays_out_of_the_evidence_test() {
  let assert Error(evidence) = executor.rescue(fn() { raise_atom(sentinel) })
  string.contains(evidence, sentinel) |> should.be_false
  string.starts_with(evidence, "error: exception in ") |> should.be_true
  let assert Error(evidence) = executor.rescue(fn() { raise_tagged(sentinel) })
  string.contains(evidence, sentinel) |> should.be_false
  string.starts_with(evidence, "error: exception in ") |> should.be_true
}

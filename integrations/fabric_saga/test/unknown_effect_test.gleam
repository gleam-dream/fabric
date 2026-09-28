//// Effects Saga's report does not prove absent: a step that paid and then
//// crashed must never reach the model as a definite failure it could
//// retry. Steps report to the test, which waits on those reports and on
//// Saga's own step events, never on sleeps.

import fabric
import fabric/agent
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/tool
import fabric_saga
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import saga
import saga/execution
import saga/observation
import sinal

pub type Failure {
  Declined
  Bad
}

fn definition() -> tool.Definition(String, String) {
  tool.define(
    "workflow",
    "Runs the workflow.",
    codec.field("x", codec.string()),
    codec.field("y", codec.string()),
  )
}

/// Calls the tool once, then answers with every result it saw.
fn model_once() -> model.Model {
  let assert Ok(call) = tool.call(definition(), "c1", "go")
  model.new(fn(request: model.Request) {
    let results =
      list.filter_map(request.messages, fn(message) {
        case message {
          model.ToolResultMessage(_, content) -> Ok(content)
          _ -> Error(Nil)
        }
      })
    case results {
      [] -> Ok(model.ToolRequest("", [call], None))
      seen -> Ok(model.FinalAnswer(string.join(seen, " | "), None))
    }
  })
}

fn start(
  workflow: saga.Workflow(String, String, Failure, Nil),
) -> fabric.Run(Nil) {
  let assert Ok(tool) =
    fabric_saga.tool(
      definition(),
      workflow,
      execution.Config(
        ..execution.config(),
        max_concurrency: 2,
        settle_timeout: 5000,
      ),
      explain: fn(failure) { "typed error: " <> string.inspect(failure) },
      rollback_within: 5000,
    )
  let agent = agent.new(model_once(), [tool], policy.always_allow())
  let assert Ok(run) = fabric.start(store.in_memory(), agent, Nil, "go")
  run
}

fn next_gate(
  gates: Subject(#(String, Subject(Nil))),
) -> #(String, Subject(Nil)) {
  let assert Ok(gate) = process.receive(gates, 5000)
  gate
}

fn next(reports: Subject(String)) -> String {
  let assert Ok(report) = process.receive(reports, 5000)
  report
}

/// The step's only attempt pays and then crashes, and its recovery decider
/// aborts with a typed error: Saga reports `StepFailed`, but the payment
/// happened. The call is an uncertain effect, not a typed failure.
pub fn a_crash_its_decider_aborted_is_uncertain_test() {
  let reports = process.new_subject()
  let pay =
    saga.step("pay", fn(_: String) -> Result(String, Failure) {
      process.send(reports, "paid")
      panic as "crashed after paying"
    })
    |> saga.compensate(max_attempts: 1, with: fn(_, _, _) {
      saga.Abort(Declined)
    })
  let assert Ok(workflow) = saga.define("pay_once", saga.perform(_, pay))

  let run = start(workflow)
  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(run, 5000)
  string.contains(uncertain.evidence, "pay") |> should.be_true
  string.contains(uncertain.evidence, "Declined") |> should.be_false
  next(reports) |> should.equal("paid")
}

/// Step `a` fails with a typed error while step `b` is in flight; `b` pays
/// and crashes in the settle window, so Saga lists it only among the
/// sibling failures. The call is an uncertain effect naming `b`.
pub fn a_sibling_that_crashed_while_settling_is_uncertain_test() {
  let reports = process.new_subject()
  let gates = process.new_subject()
  // Each step hands the test a gate and waits until the test opens it.
  let gate = fn(name) {
    let open = process.new_subject()
    process.send(gates, #(name, open))
    let assert Ok(Nil) = process.receive(open, 5000)
    Nil
  }
  let a =
    saga.step("a", fn(_: String) -> Result(String, Failure) {
      gate("a")
      Error(Bad)
    })
  let b =
    saga.step("b", fn(_: String) -> Result(String, Failure) {
      gate("b")
      process.send(reports, "b paid")
      panic as "b crashed after paying"
    })
  let join =
    saga.step("join", fn(pair: #(String, String)) -> Result(String, Failure) {
      Ok(pair.0 <> pair.1)
    })
  let assert Ok(workflow) =
    saga.define("sibling_crash", fn(x) {
      saga.perform(saga.both(saga.perform(x, a), saga.perform(x, b)), join)
    })

  // Release `b` only once Saga has recorded `a`'s failure, so that `b`
  // crashes while the run settles.
  let a_failed = process.new_subject()
  let assert Ok(id) =
    sinal.handler_id("sibling-crash-" <> int.to_string(int.random(1_000_000)))
  let assert Ok(attached) =
    sinal.observe(id, observation.step_stopped(), fn(_, stopped) {
      case stopped.workflow, stopped.step, stopped.result {
        "sibling_crash", "a", observation.AttemptFailed ->
          process.send(a_failed, Nil)
        _, _, _ -> Nil
      }
    })
  let run = start(workflow)
  // Both steps are in flight; `a` fails first.
  let opened = [next_gate(gates), next_gate(gates)]
  let assert Ok(a_gate) = list.key_find(opened, "a")
  let assert Ok(b_gate) = list.key_find(opened, "b")
  process.send(a_gate, Nil)
  let assert Ok(Nil) = process.receive(a_failed, 5000)
  process.send(b_gate, Nil)

  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(run, 5000)
  let _ = sinal.detach(attached)
  string.contains(uncertain.evidence, "b crashed") |> should.be_true
  next(reports) |> should.equal("b paid")
}

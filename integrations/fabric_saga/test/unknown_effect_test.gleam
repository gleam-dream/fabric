//// Effects Saga's report does not prove absent: a step that paid and then
//// crashed must never reach the model as a definite failure it could
//// retry, whatever its recovery decider did next, and neither may a
//// recovery decision or an undo that crashed, nor a typed error its step
//// marks with `saga.unknown_when`. Steps report to the test,
//// which waits on those reports and on Saga's own step events, never on
//// sleeps.

import fabric
import fabric/agent
import fabric/model
import fabric/policy
import fabric/run
import fabric/testing
import fabric/tool
import fabric_saga
import fabric_saga/support/watched
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import saga
import saga/execution
import saga/telemetry
import sinal

pub type Failure {
  Declined
  Bad
  /// The provider did not answer after the request was sent.
  PaymentOutcomeUnknown
}

fn definition() -> tool.Definition(String, String) {
  tool.define("workflow", "Runs the workflow.", one_field("x"), one_field("y"))
}

fn one_field(name: String) -> codec.Codec(String) {
  use value <- codec.field(name, codec.string(), get: fn(value) { value })
  codec.success(value)
}

/// Calls the tool once, then answers with every result it saw.
fn model_once() -> model.Model {
  let assert Ok(call) = testing.call(definition(), "c1", "go")
  model.new(fn(request: model.Request) {
    let results =
      list.filter_map(request.messages, fn(message) {
        case message {
          model.ToolResultMessage(_, content) -> Ok(content)
          _ -> Error(Nil)
        }
      })
    case results {
      [] -> Ok(model.ToolRequest(model.AssistantTurn("", [call], None), None))
      seen -> Ok(model.FinalAnswer(string.join(seen, " | "), None))
    }
  })
}

fn start(
  workflow: saga.Workflow(String, String, Failure, Nil),
) -> fabric.Run(Nil) {
  let tool =
    fabric_saga.tool(
      definition(),
      workflow,
      execution.config()
        |> execution.with_max_concurrency(2)
        |> execution.with_settle_timeout(5000),
      explain: fn(failure) { "typed error: " <> string.inspect(failure) },
      rollback_within: 5000,
    )
  let assert Ok(agent) =
    agent.new("agent", model_once(), [tool], policy.always_allow())
    |> agent.build
  let assert Ok(run) = fabric.start(watched.memory(), agent, Nil, "go")
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
    |> saga.compensate(max_attempts: 1, with: fn(_) { saga.Abort(Declined) })
  let workflow = saga.define("pay_once", saga.perform(_, pay))

  let run = start(workflow)
  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(run, 5000)
  string.contains(uncertain.evidence, "attempt 1 of step pay crashed")
  |> should.be_true
  string.contains(uncertain.evidence, "Declined") |> should.be_false
  string.contains(uncertain.evidence, "after paying") |> should.be_false
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
  let workflow =
    saga.define("sibling_crash", fn(x) {
      saga.perform(saga.both(saga.perform(x, a), saga.perform(x, b)), join)
    })

  // Release `b` only once Saga has recorded `a`'s failure, so that `b`
  // crashes while the run settles.
  let a_failed = process.new_subject()
  let attached =
    sinal.observe(telemetry.step_stopped(), fn(_, stopped) {
      case stopped.workflow, stopped.step, stopped.result {
        "sibling_crash", "a", telemetry.AttemptFailed ->
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
  string.contains(uncertain.evidence, "attempt 1 of step b crashed")
  |> should.be_true
  next(reports) |> should.equal("b paid")
}

/// The first attempt pays and crashes; the decider retries and the second
/// attempt succeeds. Saga reaches the output, but the first payment's
/// effect is unknown: the call is an uncertain effect naming it.
pub fn a_crash_retried_to_success_is_uncertain_test() {
  let reports = process.new_subject()
  let attempts = process.new_subject()
  let pay =
    saga.step("pay", fn(_: String) -> Result(String, Failure) {
      // The test answers whether this attempt crashes after paying.
      let crashes = process.new_subject()
      process.send(attempts, crashes)
      let assert Ok(crash) = process.receive(crashes, 5000)
      process.send(reports, "paid")
      case crash {
        True -> panic as "crashed after paying"
        False -> Ok("receipt")
      }
    })
    |> saga.compensate(max_attempts: 2, with: fn(_) { saga.Retry })
  let workflow = saga.define("pay_retried", saga.perform(_, pay))

  let run = start(workflow)
  let assert Ok(first) = process.receive(attempts, 5000)
  process.send(first, True)
  let assert Ok(second) = process.receive(attempts, 5000)
  process.send(second, False)

  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(run, 5000)
  string.contains(uncertain.evidence, "attempt 1 of step pay crashed")
  |> should.be_true
  string.contains(uncertain.evidence, "attempt 2") |> should.be_false
  string.contains(uncertain.evidence, "after paying") |> should.be_false
  [next(reports), next(reports)] |> should.equal(["paid", "paid"])
}

/// The attempt returns a typed error and its recovery decider crashes: the
/// decision's effect (a cleanup it may have begun) is unknown.
pub fn a_crashed_recovery_decision_is_uncertain_test() {
  let pay =
    saga.step("pay", fn(_: String) -> Result(String, Failure) {
      Error(Declined)
    })
    |> saga.compensate(max_attempts: 1, with: fn(_) {
      panic as "crashed while cleaning up"
    })
  let workflow = saga.define("decision_crash", saga.perform(_, pay))

  let run = start(workflow)
  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(run, 5000)
  string.contains(
    uncertain.evidence,
    "the recovery decision on attempt 1 of step pay crashed",
  )
  |> should.be_true
  string.contains(uncertain.evidence, "cleaning up") |> should.be_false
}

/// `hold` completes, then `pay` fails with a typed error; undoing `hold`
/// crashes, so whether the hold was released is unknown.
pub fn a_crashed_undo_is_uncertain_test() {
  let reports = process.new_subject()
  let hold =
    saga.step("hold", fn(x: String) -> Result(String, Failure) { Ok(x) })
    |> saga.undo(fn(_) {
      process.send(reports, "releasing")
      panic as "crashed while releasing"
    })
  let pay =
    saga.step("pay", fn(_: String) -> Result(String, Failure) {
      Error(Declined)
    })
  let workflow =
    saga.define("undo_crash", fn(x) { saga.perform(saga.perform(x, hold), pay) })

  let run = start(workflow)
  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(run, 5000)
  string.contains(uncertain.evidence, "the undo of step hold crashed")
  |> should.be_true
  string.contains(uncertain.evidence, "while releasing") |> should.be_false
  next(reports) |> should.equal("releasing")
}

/// The refund reaches the provider, which takes it but does not answer: the
/// step returns `PaymentOutcomeUnknown`, which it marks with
/// `saga.unknown_when`. With no decision to settle it, Saga ends the run
/// `Unresolved` and undoes nothing, and names the attempt among its unknown
/// effects, so the call is an uncertain effect a person reconciles, never a
/// definite failure the model could retry into a second refund (SD-1).
pub fn a_refund_the_provider_may_have_taken_is_uncertain_test() {
  let reports = process.new_subject()
  let refund =
    saga.step("refund", fn(_: String) -> Result(String, Failure) {
      process.send(reports, "refund sent")
      Error(PaymentOutcomeUnknown)
    })
    |> saga.unknown_when(fn(failure) { failure == PaymentOutcomeUnknown })
  let workflow = saga.define("refund", saga.perform(_, refund))

  let run = start(workflow)
  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(run, 5000)
  uncertain.tool |> should.equal("workflow")
  string.contains(
    uncertain.evidence,
    "attempt 1 of step refund returned an error after which its effect is unknown",
  )
  |> should.be_true
  string.contains(
    uncertain.evidence,
    "the workflow held the effects of step refund unresolved",
  )
  |> should.be_true
  string.contains(uncertain.evidence, "Saga reported unresolved at refund")
  |> should.be_true
  string.contains(uncertain.evidence, "typed error:") |> should.be_false
  string.contains(uncertain.evidence, "PaymentOutcomeUnknown")
  |> should.be_false
  next(reports) |> should.equal("refund sent")
}

/// A step that opts into rolling back on an unknown effect ends the run
/// `Failed` with the same error, and the call is still uncertain: Saga
/// names the attempt among its unknown effects.
pub fn a_rolled_back_unknown_effect_is_uncertain_test() {
  let refund =
    saga.step("refund", fn(_: String) -> Result(String, Failure) {
      Error(PaymentOutcomeUnknown)
    })
    |> saga.unknown_when(fn(failure) { failure == PaymentOutcomeUnknown })
    |> saga.on_unknown(saga.RollBack)
  let workflow = saga.define("refund", saga.perform(_, refund))

  let run = start(workflow)
  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(run, 5000)
  uncertain.tool |> should.equal("workflow")
  string.contains(
    uncertain.evidence,
    "attempt 1 of step refund returned an error after which its effect is unknown",
  )
  |> should.be_true
  string.contains(uncertain.evidence, "Saga reported failed:")
  |> should.be_true
  string.contains(uncertain.evidence, "PaymentOutcomeUnknown")
  |> should.be_false
}

/// The same error without `unknown_when` is a typed failure the model sees:
/// the classifier is what makes the difference.
pub fn an_unmarked_typed_error_is_definite_test() {
  let refund =
    saga.step("refund", fn(_: String) -> Result(String, Failure) {
      Error(PaymentOutcomeUnknown)
    })
  let workflow = saga.define("refund", saga.perform(_, refund))

  let run = start(workflow)
  fabric.await(run, 5000)
  |> should.equal(
    Ok(
      run.Finished(run.Completed(
        "{\"error\":\"typed error: PaymentOutcomeUnknown\"}",
      )),
    ),
  )
}

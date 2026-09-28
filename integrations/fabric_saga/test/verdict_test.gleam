//// The mapping from Saga's report to a definite or uncertain tool result
//// (`fabric_saga/internal/verdict`), one row of the module's table per
//// test, over the descriptors of real workflows.

import fabric_saga/internal/verdict
import gleam/string
import gleeunit/should
import saga
import saga/execution

/// `reserve`, then `charge` on its output; `note` runs on the input alone.
/// Only `charge` has a recovery decider when `decider` is set.
fn steps(decider: Bool) -> List(saga.StepDescriptor) {
  let reserve =
    saga.step("reserve", fn(x: String) -> Result(String, String) { Ok(x) })
  let note =
    saga.step("note", fn(x: String) -> Result(String, String) { Ok(x) })
  let charge =
    saga.step("charge", fn(x: String) -> Result(String, String) { Ok(x) })
  let charge = case decider {
    True ->
      saga.compensate(charge, max_attempts: 2, with: fn(_, _, _) { saga.Retry })
    False -> charge
  }
  let assert Ok(workflow) =
    saga.define("trip", fn(input) {
      let reserved = saga.perform(input, reserve)
      let noted = saga.perform(input, note)
      saga.perform(
        saga.both(reserved, noted),
        saga.step("join", fn(pair: #(String, String)) -> Result(String, String) {
          Ok(pair.0)
        }),
      )
      |> saga.perform(charge)
    })
  saga.describe(workflow)
}

fn at(name: String) -> saga.StepAddress {
  saga.StepAddress([], name, 1)
}

fn clean() -> execution.Settlement(String, String) {
  execution.Settlement(
    undone: [at("reserve")],
    undo_failures: [],
    not_undoable: [],
    held: [],
    interrupted: [],
    compensation_failures: [],
    sibling_failures: [],
  )
}

fn explain(error: String) -> String {
  "explained " <> error
}

fn uncertain(result: Result(a, verdict.Stopped), mentions: String) -> Nil {
  let assert Error(verdict.Unknown(evidence)) = result
  string.contains(evidence, mentions) |> should.be_true
}

pub fn a_completed_workflow_without_a_decider_is_its_output_test() {
  verdict.classify(execution.Completed("out"), steps(False), explain)
  |> should.equal(Ok("out"))
}

pub fn a_completed_workflow_with_a_decider_is_uncertain_test() {
  verdict.classify(execution.Completed("out"), steps(True), explain)
  |> uncertain("charge")
}

pub fn a_typed_error_of_a_single_attempt_is_definite_test() {
  // `charge` depends on the failed `reserve`, so it was never attempted.
  verdict.classify(
    execution.Failed(execution.StepFailed(at("reserve"), "full"), clean()),
    steps(True),
    explain,
  )
  |> should.equal(Error(verdict.Definitely("explained full")))
}

pub fn a_typed_error_of_a_step_with_a_decider_is_uncertain_test() {
  // The decider may have aborted with this error after a crash.
  verdict.classify(
    execution.Failed(execution.StepFailed(at("charge"), "declined"), clean()),
    steps(True),
    explain,
  )
  |> uncertain("charge")
}

pub fn a_sibling_crash_is_uncertain_test() {
  let settlement =
    execution.Settlement(..clean(), sibling_failures: [
      execution.StepCrashed(at("note"), saga.Crash(saga.ErrorClass, "boom")),
    ])
  verdict.classify(
    execution.Failed(execution.StepFailed(at("reserve"), "full"), settlement),
    steps(False),
    explain,
  )
  |> uncertain("note crashed")
}

pub fn a_sibling_typed_error_is_definite_test() {
  let settlement =
    execution.Settlement(..clean(), sibling_failures: [
      execution.StepFailed(at("note"), "also"),
    ])
  verdict.classify(
    execution.Failed(execution.StepFailed(at("reserve"), "full"), settlement),
    steps(False),
    explain,
  )
  |> should.equal(Error(verdict.Definitely("explained full")))
}

pub fn a_missed_deadline_with_everything_undone_is_definite_test() {
  verdict.classify(
    execution.Failed(execution.DeadlineExceeded, clean()),
    steps(False),
    explain,
  )
  |> should.equal(Error(verdict.Definitely("the workflow missed its deadline")))
}

pub fn a_cancellation_that_undid_everything_is_definite_test() {
  verdict.classify(
    execution.Cancelled(execution.CancelRequested, clean()),
    steps(False),
    explain,
  )
  |> should.equal(
    Error(verdict.Definitely(
      "the workflow was cancelled; every completed step was undone",
    )),
  )
}

pub fn a_cancellation_with_a_sibling_crash_is_uncertain_test() {
  let settlement =
    execution.Settlement(..clean(), sibling_failures: [
      execution.StepTimedOut(at("note")),
    ])
  verdict.classify(
    execution.Cancelled(execution.OwnerExited, settlement),
    steps(False),
    explain,
  )
  |> uncertain("note crashed or timed out")
}

pub fn a_cancellation_after_a_decider_ran_is_uncertain_test() {
  verdict.classify(
    execution.Cancelled(execution.OwnerExited, clean()),
    steps(True),
    explain,
  )
  |> uncertain("charge")
}

pub fn an_interrupted_step_is_uncertain_test() {
  let settlement = execution.Settlement(..clean(), interrupted: [at("note")])
  verdict.classify(
    execution.Cancelled(execution.CancelRequested, settlement),
    steps(False),
    explain,
  )
  |> uncertain("interrupted note")
}

/// The evidence names kinds and steps only: a typed error or a crash
/// reason may carry application data.
pub fn the_evidence_carries_no_application_data_test() {
  let settlement =
    execution.Settlement(..clean(), sibling_failures: [
      execution.StepCrashed(at("note"), saga.Crash(saga.ErrorClass, "secret")),
    ])
  let assert Error(verdict.Unknown(evidence)) =
    verdict.classify(
      execution.Failed(execution.StepFailed(at("charge"), "secret"), settlement),
      steps(True),
      explain,
    )
  string.contains(evidence, "secret") |> should.be_false
}

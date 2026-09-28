//// What a Saga outcome proves about the workflow's effects.
////
//// A result is definite only when Saga's report proves that no attempt of
//// any step has an effect of unknown status. A typed error that a step's
//// single attempt returned is known; a crash, an exit, a timeout, or an
//// interruption is not. Saga reports a run's outcome and its settlement,
//// and describes the workflow's steps (`saga.describe`). From these:
////
//// - A step with no recovery decider (`saga.compensate`) makes exactly one
////   attempt. A typed error it returned is reported as `StepFailed`, a
////   crash as `StepCrashed`, a timeout as `StepTimedOut`, a kill as
////   `interrupted`.
//// - A step with a recovery decider may have crashed or timed out on an
////   attempt Saga does not report: its decider can retry, continue, or
////   abort with a typed error (reported as `StepFailed`) after a crash, and
////   Saga reports only a retried timeout (`CompletedWithUnknownEffects`).
////   So any outcome in which such a step may have been attempted is
////   uncertain.
//// - A step may have been attempted unless it depends, directly or through
////   other steps, on a step that failed: that step produced no output for
////   it. Every step of a completed run was attempted.
////
//// | Saga outcome | Result |
//// | --- | --- |
//// | `Completed(output)`, no step with a recovery decider | the output |
//// | `Failed(StepFailed(step, error))` of a step with no recovery decider, every sibling failure such a typed error, nothing left in place, no step with a recovery decider attempted | definite: `explain(error)` |
//// | `Failed(DeadlineExceeded)`, with the same conditions | definite |
//// | `Cancelled`, with the same conditions | definite: cancelled, every completed step undone |
//// | a step with a recovery decider that may have been attempted, a crash, timeout, or retry cause (as the cause or a sibling failure), an undo or compensation that failed, a step interrupted, held, or without an undo, `CompletedWithUnknownEffects`, `Unresolved` | uncertain, with a summary of Saga's report |
////
//// The summary names outcome kinds and step addresses only: never a step's
//// typed error, output, or crash reason, which may carry application data.

import gleam/list
import gleam/set.{type Set}
import gleam/string
import saga.{type StepAddress, type StepDescriptor}
import saga/execution

/// Why the workflow did not produce its output.
pub type Stopped {
  /// Nothing the workflow did is left in place; the model may see this.
  Definitely(message: String)
  /// An effect may be left in place or be of unknown status.
  Unknown(evidence: String)
}

/// The tool result that `outcome` proves, for a workflow whose steps are
/// `steps` (`saga.describe`).
pub fn classify(
  outcome: execution.Outcome(output, error, undo_error),
  steps: List(StepDescriptor),
  explain: fn(error) -> String,
) -> Result(output, Stopped) {
  let report = summary(outcome)
  case outcome {
    execution.Completed(output) ->
      case recoverable(steps, attempted(steps, [])) {
        [] -> Ok(output)
        risky -> Error(unknown([decided(risky)], report))
      }
    execution.CompletedWithUnknownEffects(_, interrupted) ->
      Error(unknown(
        [
          "these steps were interrupted and their effect is unknown: "
          <> addresses(interrupted),
        ],
        report,
      ))
    execution.Unresolved(step, _, _) ->
      Error(unknown(
        [
          "the workflow held the effects of step "
          <> saga.address_to_string(step)
          <> " unresolved",
        ],
        report,
      ))
    execution.Failed(cause, settlement) ->
      case stopped(steps, [cause, ..settlement.sibling_failures], settlement) {
        [] ->
          Error(
            Definitely(case cause {
              execution.StepFailed(_, error) -> explain(error)
              _ -> "the workflow missed its deadline"
            }),
          )
        reasons -> Error(unknown(reasons, report))
      }
    execution.Cancelled(_, settlement) ->
      case stopped(steps, settlement.sibling_failures, settlement) {
        [] ->
          Error(Definitely(
            "the workflow was cancelled; every completed step was undone",
          ))
        reasons -> Error(unknown(reasons, report))
      }
  }
}

/// Why a stopped run whose failures are `causes` left an effect unknown or
/// in place; `[]` when nothing.
fn stopped(
  steps: List(StepDescriptor),
  causes: List(execution.Cause(error)),
  settlement: execution.Settlement(error, undo_error),
) -> List(String) {
  let failed = list.filter_map(causes, cause_step)
  list.flatten([
    list.filter_map(causes, unknown_cause),
    left_in_place(settlement),
    case recoverable(steps, attempted(steps, failed)) {
      [] -> []
      risky -> [decided(risky)]
    },
  ])
}

fn unknown(reasons: List(String), report: String) -> Stopped {
  Unknown(
    "the workflow's effects are not known: "
    <> string.join(reasons, "; ")
    <> " (Saga reported "
    <> report
    <> ")",
  )
}

fn decided(steps: List(StepAddress)) -> String {
  "steps with a recovery decider may have crashed or timed out on an attempt Saga does not report: "
  <> addresses(steps)
}

/// The step a cause names, if any.
fn cause_step(cause: execution.Cause(error)) -> Result(StepAddress, Nil) {
  case cause {
    execution.StepFailed(step, _)
    | execution.StepCrashed(step, _)
    | execution.StepTimedOut(step)
    | execution.RetryLimitReached(step, _)
    | execution.RetrySuperseded(step, _) -> Ok(step)
    execution.OutputCrashed(_) | execution.DeadlineExceeded -> Error(Nil)
  }
}

/// Why a cause leaves an effect unknown; `Error(Nil)` for a typed error or
/// a missed deadline, which are known. A typed error of a step with a
/// recovery decider is judged by `recoverable`.
fn unknown_cause(cause: execution.Cause(error)) -> Result(String, Nil) {
  case cause {
    execution.StepFailed(..) | execution.DeadlineExceeded -> Error(Nil)
    execution.StepCrashed(step, _) | execution.StepTimedOut(step) ->
      Ok(
        "step "
        <> saga.address_to_string(step)
        <> " crashed or timed out; its effect is unknown",
      )
    execution.RetryLimitReached(step, _) | execution.RetrySuperseded(step, _) ->
      Ok(
        "step "
        <> saga.address_to_string(step)
        <> " failed after retries; an earlier attempt may have crashed or timed out",
      )
    execution.OutputCrashed(_) -> Ok("the workflow's output crashed")
  }
}

/// What the settlement left in place or of unknown status.
fn left_in_place(
  settlement: execution.Settlement(error, undo_error),
) -> List(String) {
  let undo_failed =
    list.map(settlement.undo_failures, fn(failure) {
      case failure {
        execution.UndoFailed(step, _)
        | execution.UndoCrashed(step, _)
        | execution.UndoTimedOut(step) -> step
      }
    })
  let compensation_failed =
    list.map(settlement.compensation_failures, fn(failure) {
      case failure {
        execution.CleanupFailed(step, _)
        | execution.CompensationCrashed(step, _)
        | execution.CompensationTimedOut(step) -> step
      }
    })
  [
    #("not undone", undo_failed),
    #("compensation failed", compensation_failed),
    #("interrupted", settlement.interrupted),
    #("held", settlement.held),
    #("without an undo", settlement.not_undoable),
  ]
  |> list.filter_map(fn(entry) {
    case entry.1 {
      [] -> Error(Nil)
      steps -> Ok(entry.0 <> " " <> addresses(steps))
    }
  })
}

/// The steps that may have been attempted: every step except those that
/// depend, directly or through other steps, on a step in `failed`.
fn attempted(
  steps: List(StepDescriptor),
  failed: List(StepAddress),
) -> List(StepAddress) {
  let blocked = downstream(steps, set.from_list(failed), set.new())
  list.filter_map(steps, fn(step) {
    case set.contains(blocked, step.address) {
      True -> Error(Nil)
      False -> Ok(step.address)
    }
  })
}

/// The steps that depend on `failed` or on a step in `blocked`, to a fixed
/// point.
fn downstream(
  steps: List(StepDescriptor),
  failed: Set(StepAddress),
  blocked: Set(StepAddress),
) -> Set(StepAddress) {
  let next =
    list.fold(steps, blocked, fn(blocked, step) {
      case
        list.any(step.depends_on, fn(dependency) {
          set.contains(failed, dependency) || set.contains(blocked, dependency)
        })
      {
        True -> set.insert(blocked, step.address)
        False -> blocked
      }
    })
  case set.size(next) == set.size(blocked) {
    True -> next
    False -> downstream(steps, failed, next)
  }
}

/// The steps among `attempted` with a recovery decider.
fn recoverable(
  steps: List(StepDescriptor),
  attempted: List(StepAddress),
) -> List(StepAddress) {
  list.filter_map(steps, fn(step) {
    case step.compensates && list.contains(attempted, step.address) {
      True -> Ok(step.address)
      False -> Error(Nil)
    }
  })
}

/// Saga's report without application data: the outcome's kind, its cause's
/// kind and step, and the settlement's steps.
pub fn summary(
  outcome: execution.Outcome(output, error, undo_error),
) -> String {
  case outcome {
    execution.Completed(_) -> "completed"
    execution.CompletedWithUnknownEffects(_, steps) ->
      "completed with unknown effects of " <> addresses(steps)
    execution.Failed(cause, settlement) ->
      "failed: " <> describe_cause(cause) <> settled(settlement)
    execution.Cancelled(reason, settlement) ->
      "cancelled ("
      <> case reason {
        execution.CancelRequested -> "requested"
        execution.OwnerExited -> "owner exited"
      }
      <> ")"
      <> settled(settlement)
    execution.Unresolved(step, _, settlement) ->
      "unresolved at " <> saga.address_to_string(step) <> settled(settlement)
  }
}

fn describe_cause(cause: execution.Cause(error)) -> String {
  case cause {
    execution.StepFailed(step, _) ->
      "typed error of " <> saga.address_to_string(step)
    execution.StepCrashed(step, _) ->
      "crash of " <> saga.address_to_string(step)
    execution.StepTimedOut(step) ->
      "timeout of " <> saga.address_to_string(step)
    execution.RetryLimitReached(step, _) ->
      "retry limit of " <> saga.address_to_string(step)
    execution.RetrySuperseded(step, _) ->
      "retry superseded of " <> saga.address_to_string(step)
    execution.OutputCrashed(_) -> "output crash"
    execution.DeadlineExceeded -> "deadline exceeded"
  }
}

fn settled(settlement: execution.Settlement(error, undo_error)) -> String {
  [
    #("undone", settlement.undone),
    #(
      "sibling failures",
      list.filter_map(settlement.sibling_failures, cause_step),
    ),
  ]
  |> list.filter_map(fn(entry) {
    case entry.1 {
      [] -> Error(Nil)
      steps -> Ok("; " <> entry.0 <> " " <> addresses(steps))
    }
  })
  |> string.concat
}

fn addresses(steps: List(StepAddress)) -> String {
  string.join(list.map(steps, saga.address_to_string), ", ")
}

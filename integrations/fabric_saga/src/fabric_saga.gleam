//// A Saga workflow as one typed Fabric tool.
////
//// The workflow takes the tool's decoded input and produces its output,
//// so the model sees one tool while Saga orders the steps, retries them as
//// the workflow says, and compensates what completed when a step fails.
//// Saga's outcome becomes the tool's result:
////
//// | Saga outcome | Tool result |
//// | --- | --- |
//// | `Completed(output)` | the output |
//// | `Failed` by a step's typed error, every completed step undone | a definite failure the model sees: `explain(error)` |
//// | `Failed` past the deadline, every completed step undone | a definite failure the model sees |
//// | `Cancelled` by another holder of the run, every completed step undone | a definite failure the model sees |
//// | anything that left an effect in place or unknown: an undo that failed, a step interrupted, crashed, held, or without an undo, `CompletedWithUnknownEffects`, `Unresolved`, a lost run | an uncertain effect |
////
//// Cancelling the Fabric run (or any stop of the tool's task) cancels the
//// Saga run: the workflow runs inside the tool's task, which owns it, and
//// Saga cancels a run whose owner exits, compensating the steps that
//// completed. Fabric records the action as an uncertain effect, because the
//// task is stopped before it can learn how that compensation ended.

import fabric/tool
import gleam/list
import gleam/result
import gleam/string
import saga
import saga/execution

/// Why the workflow did not produce its output.
type Stopped {
  /// Nothing the workflow did is left in place; the model may see this.
  Definitely(message: String)
  /// An effect may be left in place.
  Unknown(evidence: String)
}

/// A tool bound to `workflow`, run with `config` for every call. `explain`
/// renders a step's typed error for the model. The configuration is
/// validated here, before any call.
pub fn tool(
  definition: tool.Definition(input, output),
  workflow: saga.Workflow(input, output, error, undo_error),
  config: execution.Config,
  explain explain: fn(error) -> String,
) -> Result(tool.Tool(context), List(execution.ConfigError)) {
  use config <- result.map(execution.validate(config))
  tool.bind(
    definition,
    fn(_context, input) { run(workflow, input, config, explain) },
    fn(stopped) {
      case stopped {
        Definitely(message) -> tool.Explain(message)
        Unknown(evidence) -> tool.Uncertain(evidence)
      }
    },
  )
}

fn run(
  workflow: saga.Workflow(input, output, error, undo_error),
  input: input,
  config: execution.Config,
  explain: fn(error) -> String,
) -> Result(output, Stopped) {
  case execution.run(workflow, input, config) {
    Ok(execution.Completed(output)) -> Ok(output)
    Ok(execution.CompletedWithUnknownEffects(_, steps)) ->
      Error(Unknown(
        "the workflow completed, but these steps were interrupted and their effect is unknown: "
        <> addresses(steps),
      ))
    Ok(execution.Failed(cause, settlement)) ->
      case left_in_place(settlement) {
        Error(evidence) -> Error(Unknown(evidence))
        Ok(Nil) -> Error(failed(cause, explain))
      }
    Ok(execution.Cancelled(_, settlement)) ->
      case left_in_place(settlement) {
        Error(evidence) -> Error(Unknown(evidence))
        Ok(Nil) -> Error(Definitely("the workflow was cancelled"))
      }
    Ok(execution.Unresolved(step, _, _)) ->
      Error(Unknown(
        "the workflow held the effects of step "
        <> saga.address_to_string(step)
        <> " unresolved",
      ))
    Error(execution.ExecutionLost(crash)) ->
      Error(Unknown("the workflow run was lost: " <> string.inspect(crash)))
    Error(execution.InvalidConfig(_)) ->
      Error(Definitely("the workflow is misconfigured"))
  }
}

/// A failure's cause, when compensation completed. A step that crashed or
/// timed out may have had its effect, so only typed errors and a missed
/// deadline are definite.
fn failed(
  cause: execution.Cause(error),
  explain: fn(error) -> String,
) -> Stopped {
  case cause {
    execution.StepFailed(_, error) -> Definitely(explain(error))
    execution.RetryLimitReached(_, saga.Returned(error))
    | execution.RetrySuperseded(_, saga.Returned(error)) ->
      Definitely(explain(error))
    execution.DeadlineExceeded -> Definitely("the workflow missed its deadline")
    execution.StepCrashed(step, _)
    | execution.StepTimedOut(step)
    | execution.RetryLimitReached(step, _)
    | execution.RetrySuperseded(step, _) ->
      Unknown(
        "step "
        <> saga.address_to_string(step)
        <> " crashed or timed out; its effect is unknown",
      )
    execution.OutputCrashed(crash) ->
      Unknown("the workflow's output crashed: " <> string.inspect(crash))
  }
}

/// `Error(evidence)` when the settlement left an effect in place or of
/// unknown status.
fn left_in_place(
  settlement: execution.Settlement(error, undo_error),
) -> Result(Nil, String) {
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
  let problems =
    [
      #("not undone", undo_failed),
      #("compensation failed", compensation_failed),
      #("interrupted", settlement.interrupted),
      #("held", settlement.held),
      #("without an undo", settlement.not_undoable),
    ]
    |> list.filter(fn(entry) { entry.1 != [] })
  case problems {
    [] -> Ok(Nil)
    _ ->
      Error(
        "the workflow left effects in place: "
        <> string.join(
          list.map(problems, fn(entry) { entry.0 <> " " <> addresses(entry.1) }),
          "; ",
        ),
      )
  }
}

fn addresses(steps: List(saga.StepAddress)) -> String {
  string.join(list.map(steps, saga.address_to_string), ", ")
}

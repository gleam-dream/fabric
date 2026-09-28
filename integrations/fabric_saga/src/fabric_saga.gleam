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
//// | `Cancelled`, every completed step undone | a definite failure the model sees: the workflow was cancelled and every completed step undone |
//// | anything that left an effect in place or unknown: an undo that failed, a step interrupted, crashed, held, or without an undo, `CompletedWithUnknownEffects`, `Unresolved`, a lost run | an uncertain effect |
////
//// Cancelling the Fabric run (or any stop of the tool's task) cancels the
//// Saga run: the workflow is started by the tool's task, which owns it, and
//// Saga cancels a run whose owner exits, compensating the steps that
//// completed. Its outcome goes to a receiver process that the call starts
//// (unlinked, so it outlives the task): while the task lives, the receiver
//// forwards the outcome to it; once the task was stopped, the receiver
//// settles the call with the outcome (`tool.bind_settling`), and the
//// stopped Fabric run waits for that settlement, up to `rollback_within`
//// milliseconds, before it ends. A settlement that arrives later is refused
//// and changes nothing; the action stays an uncertain effect.

import fabric/tool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
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
/// renders a step's typed error for the model. When the call's task is
/// stopped, Fabric waits up to `rollback_within` milliseconds for Saga's
/// outcome (its settle window and the undo steps it runs) before recording
/// an uncertain effect. The configuration is validated here, before any
/// call.
pub fn tool(
  definition: tool.Definition(input, output),
  workflow: saga.Workflow(input, output, error, undo_error),
  config: execution.Config,
  explain explain: fn(error) -> String,
  rollback_within rollback_within: Int,
) -> Result(tool.Tool(context), List(execution.ConfigError)) {
  use config <- result.map(execution.validate(config))
  tool.bind_settling(
    definition,
    fn(_context, input, settlement) {
      run(workflow, input, config, explain, settlement, rollback_within)
    },
    failure,
    within: rollback_within,
  )
}

fn failure(stopped: Stopped) -> tool.Failure {
  case stopped {
    Definitely(message) -> tool.Explain(message)
    Unknown(evidence) -> tool.Uncertain(evidence)
  }
}

/// What the receiver learns about the Saga run.
type Delivery(o, e, u) {
  Delivered(execution.Outcome(o, e, u))
  /// The coordinator exited without an outcome.
  RunLost
}

/// What the task tells the receiver after starting the Saga run.
type Start {
  Started(coordinator: Pid)
  NotStarted
}

/// Runs the workflow in the calling task, which owns the Saga run, and
/// waits for its outcome through the receiver.
fn run(
  workflow: saga.Workflow(input, output, error, undo_error),
  input: input,
  config: execution.Config,
  explain: fn(error) -> String,
  settlement: tool.Settlement(output),
  rollback_within: Int,
) -> Result(output, Stopped) {
  let task = process.self()
  let forward = process.new_subject()
  let ready = process.new_subject()
  let receiver =
    process.spawn_unlinked(fn() {
      let report = process.new_subject()
      let start = process.new_subject()
      process.send(ready, #(report, start))
      receive(Receiver(
        task_monitor: Some(process.monitor(task)),
        forward:,
        report:,
        start:,
        coordinator: None,
        settle: fn(delivery) {
          let _ =
            tool.settle(
              settlement,
              outcome(delivery, explain) |> result.map_error(failure),
            )
          Nil
        },
        rollback_within:,
      ))
    })
  let receiver_monitor = process.monitor(receiver)
  let assert Ok(#(report, start)) = process.receive(ready, 5000)
  case execution.start_reporting(workflow, input, config, to: report) {
    Error(execution.InvalidConfig(_)) -> {
      process.send(start, NotStarted)
      Error(Definitely("the workflow is misconfigured"))
    }
    Error(execution.ExecutionLost(crash)) -> {
      process.send(start, NotStarted)
      Error(Unknown("the workflow run was lost: " <> string.inspect(crash)))
    }
    Ok(started) -> {
      process.send(start, Started(execution.pid(started)))
      let delivered =
        process.new_selector()
        |> process.select_map(forward, Ok)
        |> process.select_specific_monitor(receiver_monitor, fn(_) {
          Error(Nil)
        })
        |> process.selector_receive_forever
      case delivered {
        Ok(delivery) -> outcome(delivery, explain)
        Error(Nil) -> Error(Unknown("the workflow's outcome was lost"))
      }
    }
  }
}

type Receiver(o, e, u) {
  Receiver(
    /// `None` once the task has exited.
    task_monitor: Option(process.Monitor),
    forward: Subject(Delivery(o, e, u)),
    report: Subject(execution.Outcome(o, e, u)),
    start: Subject(Start),
    coordinator: Option(process.Monitor),
    settle: fn(Delivery(o, e, u)) -> Nil,
    rollback_within: Int,
  )
}

type Event(o, e, u) {
  Reported(execution.Outcome(o, e, u))
  Starting(Start)
  TaskExited(process.ExitReason)
  CoordinatorExited
}

/// Owns the report subject. Forwards what it learns to the task while the
/// task lives; once the task was stopped, settles the call with it. Saga
/// sends the outcome before its coordinator exits, so a coordinator exit
/// with no outcome means the run was lost. When the task was stopped before
/// telling whether a run started, the receiver waits `rollback_within` for
/// an outcome and then gives up; Fabric's own bound records the uncertain
/// effect.
fn receive(receiver: Receiver(o, e, u)) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(receiver.report, Reported)
    |> process.select_map(receiver.start, Starting)
  let selector = case receiver.task_monitor {
    Some(monitor) ->
      process.select_specific_monitor(selector, monitor, fn(down) {
        case down {
          process.ProcessDown(reason:, ..) -> TaskExited(reason)
          process.PortDown(reason:, ..) -> TaskExited(reason)
        }
      })
    None -> selector
  }
  let selector = case receiver.coordinator {
    Some(monitor) ->
      process.select_specific_monitor(selector, monitor, fn(_) {
        CoordinatorExited
      })
    None -> selector
  }
  let event = case receiver.task_monitor, receiver.coordinator {
    // The task is gone and never said whether a run started.
    None, None ->
      process.selector_receive(selector, receiver.rollback_within)
      |> result.replace_error(Nil)
    _, _ -> Ok(process.selector_receive_forever(selector))
  }
  case event {
    Error(Nil) -> Nil
    Ok(Starting(NotStarted)) -> Nil
    Ok(Starting(Started(pid))) ->
      receive(Receiver(..receiver, coordinator: Some(process.monitor(pid))))
    Ok(Reported(outcome)) -> deliver(receiver, Delivered(outcome))
    Ok(CoordinatorExited) -> deliver(receiver, RunLost)
    // The task returned: it had the outcome.
    Ok(TaskExited(process.Normal)) -> Nil
    Ok(TaskExited(_)) -> receive(Receiver(..receiver, task_monitor: None))
  }
}

/// Hands `delivery` to the task if it lives. A task that then exits
/// abnormally may not have reported it, so the call is settled with it: a
/// settlement after the task reported is refused and changes nothing.
fn deliver(receiver: Receiver(o, e, u), delivery: Delivery(o, e, u)) -> Nil {
  case receiver.task_monitor {
    None -> receiver.settle(delivery)
    Some(monitor) -> {
      process.send(receiver.forward, delivery)
      let exited =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) {
          case down {
            process.ProcessDown(reason:, ..) -> reason
            process.PortDown(reason:, ..) -> reason
          }
        })
        |> process.selector_receive_forever
      case exited {
        process.Normal -> Nil
        _ -> receiver.settle(delivery)
      }
    }
  }
}

fn outcome(
  delivery: Delivery(output, error, undo_error),
  explain: fn(error) -> String,
) -> Result(output, Stopped) {
  case delivery {
    RunLost -> Error(Unknown("the workflow run was lost"))
    Delivered(execution.Completed(output)) -> Ok(output)
    Delivered(execution.CompletedWithUnknownEffects(_, steps)) ->
      Error(Unknown(
        "the workflow completed, but these steps were interrupted and their effect is unknown: "
        <> addresses(steps),
      ))
    Delivered(execution.Failed(cause, settlement)) ->
      case left_in_place(settlement) {
        Error(evidence) -> Error(Unknown(evidence))
        Ok(Nil) -> Error(failed(cause, explain))
      }
    Delivered(execution.Cancelled(_, settlement)) ->
      case left_in_place(settlement) {
        Error(evidence) -> Error(Unknown(evidence))
        Ok(Nil) ->
          Error(Definitely(
            "the workflow was cancelled; every completed step was undone",
          ))
      }
    Delivered(execution.Unresolved(step, _, _)) ->
      Error(Unknown(
        "the workflow held the effects of step "
        <> saga.address_to_string(step)
        <> " unresolved",
      ))
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

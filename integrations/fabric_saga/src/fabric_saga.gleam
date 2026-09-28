//// A Saga workflow as one typed Fabric tool.
////
//// The workflow takes the tool's decoded input and produces its output,
//// so the model sees one tool while Saga orders the steps, retries them as
//// the workflow says, and compensates what completed when a step fails.
//// Saga's outcome becomes the tool's result. A result is definite only
//// when Saga's report proves that no attempt of any step has an effect of
//// unknown status: a typed error that a step's single attempt returned is
//// known, while a crash, an exit, a timeout, or an interruption is not.
//// Saga does not report a crashed attempt of a step with a recovery
//// decider (`saga.compensate`), so an outcome in which such a step may
//// have been attempted is uncertain:
////
//// | Saga outcome | Tool result |
//// | --- | --- |
//// | `Completed(output)`, and no step has a recovery decider | the output |
//// | `Failed` by a typed error of a step with no recovery decider, or past the deadline; every sibling failure such a typed error; nothing left in place; no step with a recovery decider attempted | a definite failure the model sees: `explain(error)` (or the missed deadline) |
//// | `Cancelled`, with the same conditions | a definite failure the model sees: the workflow was cancelled and every completed step undone |
//// | anything else: a step with a recovery decider that may have been attempted (a step is not attempted when it depends on a step that failed), a crash, timeout, or retry cause or sibling failure, an undo or compensation that failed, a step interrupted, held, or without an undo, `CompletedWithUnknownEffects`, `Unresolved`, a lost run | an uncertain effect whose evidence summarizes Saga's report (outcome kinds and step addresses, never application data) |
////
//// Cancelling the Fabric run (or any stop of the tool's task) cancels the
//// Saga run: the workflow is started by the tool's task, which owns it, and
//// Saga cancels a run whose owner exits, compensating the steps that
//// completed. Its outcome goes to a receiver process that the call starts
//// (unlinked, so it outlives the task): while the task lives, the receiver
//// forwards the outcome to it; once the task was stopped, the receiver
//// settles the call with the outcome (`tool.bind_settling`), and the
//// stopped Fabric run waits for that settlement, up to `rollback_within`
//// milliseconds after the call's task was confirmed stopped, before it
//// ends. A settlement that arrives later is refused and changes nothing;
//// the action stays an uncertain effect.

import fabric/tool
import fabric_saga/internal/verdict.{type Stopped, Definitely, Unknown}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import saga
import saga/execution

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
  let judge = fn(delivery) {
    outcome(delivery, saga.describe(workflow), explain)
  }
  tool.bind_settling(
    definition,
    fn(_context, input, settlement) {
      run(workflow, input, config, judge, settlement, rollback_within)
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
  judge: fn(Delivery(output, error, undo_error)) -> Result(output, Stopped),
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
              judge(delivery) |> result.map_error(failure),
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
        Ok(delivery) -> judge(delivery)
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
  steps: List(saga.StepDescriptor),
  explain: fn(error) -> String,
) -> Result(output, Stopped) {
  case delivery {
    RunLost -> Error(Unknown("the workflow run was lost"))
    Delivered(outcome) -> verdict.classify(outcome, steps, explain)
  }
}

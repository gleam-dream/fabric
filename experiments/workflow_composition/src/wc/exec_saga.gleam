//// THROWAWAY (workflow composition experiment). Variant B's executor: every
//// dispatched batch runs as one runtime-defined Saga workflow (one step per
//// action, combined with `saga.all`). Saga supplies the concurrency limit,
//// step timeout, crash containment, and cancellation settlement; Fabric
//// keeps policy, approval, the fence, and the durable record.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import saga
import saga/execution
import wc/agent.{type ActionId}
import wc/model.{type ToolCall}
import wc/runtime.{type ExecutorHandle, type Hooks, ExecutorHandle}
import wc/tool

pub type Settings {
  Settings(step_timeout: Int, settle_timeout: Int)
}

/// What one step returns: `None` when the fence refused the start.
type StepResult {
  Ran(ActionId, tool.Outcome)
  Refused
}

type Batch =
  execution.Execution(List(StepResult), Nil, Nil)

type Msg {
  Submit(List(#(ActionId, ToolCall)))
  Stop
  BatchStarted(Int, Batch)
  BatchDone(Int, List(#(ActionId, tool.Outcome)))
}

pub fn executor(settings: Settings) -> runtime.Executor {
  fn(hooks: Hooks) -> ExecutorHandle {
    let ready = process.new_subject()
    process.spawn(fn() {
      let self = process.new_subject()
      process.send(ready, self)
      loop(settings, hooks, self, 0, dict.new())
    })
    let assert Ok(subject) = process.receive(ready, 1000)
    ExecutorHandle(
      submit: fn(actions) { process.send(subject, Submit(actions)) },
      stop: fn() { process.send(subject, Stop) },
    )
  }
}

fn loop(
  settings: Settings,
  hooks: Hooks,
  self: Subject(Msg),
  next: Int,
  active: Dict(Int, Batch),
) -> Nil {
  case process.receive_forever(self) {
    Submit(actions) -> {
      // `execution.await` is owner-only and cannot join this process's
      // selector, so each Saga run needs its own owner process.
      start_batch(settings, hooks, self, next, actions)
      loop(settings, hooks, self, next + 1, active)
    }
    BatchStarted(number, batch) ->
      loop(settings, hooks, self, next, dict.insert(active, number, batch))
    BatchDone(number, reports) -> {
      list.each(reports, fn(r) { hooks.emit(runtime.Reported(r.0, r.1)) })
      loop(settings, hooks, self, next, dict.delete(active, number))
    }
    Stop -> {
      dict.each(active, fn(_, batch) { execution.cancel(batch) })
      drain(hooks, self, active)
      hooks.emit(runtime.Stopped)
    }
  }
}

fn drain(hooks: Hooks, self: Subject(Msg), active: Dict(Int, Batch)) -> Nil {
  case dict.is_empty(active) {
    True -> Nil
    False ->
      case process.receive_forever(self) {
        BatchDone(number, reports) -> {
          list.each(reports, fn(r) { hooks.emit(runtime.Reported(r.0, r.1)) })
          drain(hooks, self, dict.delete(active, number))
        }
        BatchStarted(number, batch) -> {
          execution.cancel(batch)
          drain(hooks, self, dict.insert(active, number, batch))
        }
        Submit(_) | Stop -> drain(hooks, self, active)
      }
  }
}

fn start_batch(
  settings: Settings,
  hooks: Hooks,
  parent: Subject(Msg),
  number: Int,
  actions: List(#(ActionId, ToolCall)),
) -> Nil {
  process.spawn(fn() {
    let assert [first, ..rest] =
      list.map(actions, fn(a) { action_step(hooks, a) })
    let workflow =
      saga.define("tool-batch-" <> int.to_string(number), fn(input) {
        saga.all(
          saga.perform(input, first),
          list.map(rest, saga.perform(input, _)),
        )
      })
    let config =
      execution.config()
      |> execution.with_max_concurrency(hooks.max_in_flight)
      |> execution.with_step_timeout(settings.step_timeout)
      |> execution.with_settle_timeout(settings.settle_timeout)
    let assert Ok(batch) = execution.start(workflow, Nil, config)
    process.send(parent, BatchStarted(number, batch))
    let reports = case await(batch) {
      execution.Completed(results)
      | execution.CompletedWithUnknownEffects(results, _) ->
        list.filter_map(results, fn(result) {
          case result {
            Ran(id, outcome) -> Ok(#(id, outcome))
            Refused -> Error(Nil)
          }
        })
      // A cancelled Saga run discards the outputs of steps that completed:
      // their effects happened but their results are gone. Steps killed in
      // flight are reported by the controller as uncertain on `ToolsStopped`.
      execution.Cancelled(_, settlement) ->
        list.filter_map(settlement.not_undoable, fn(address) {
          case find(actions, address) {
            Ok(id) ->
              Ok(#(
                id,
                tool.Uncertain("completed, result discarded by Saga cancel"),
              ))
            Error(Nil) -> Error(Nil)
          }
        })
      execution.Failed(..) | execution.Unresolved(..) -> []
    }
    process.send(parent, BatchDone(number, reports))
  })
  Nil
}

fn await(batch: Batch) -> execution.Outcome(List(StepResult), Nil, Nil) {
  case execution.await(batch, timeout: 60_000) {
    Ok(outcome) -> outcome
    Error(execution.AwaitTimedOut) -> await(batch)
    Error(_) -> execution.Completed([])
  }
}

fn step_name(id: ActionId) -> String {
  int.to_string(id.turn) <> ":" <> id.call_id
}

fn find(
  actions: List(#(ActionId, ToolCall)),
  address: saga.StepAddress,
) -> Result(ActionId, Nil) {
  list.find(actions, fn(a) { step_name(a.0) == address.name })
  |> result_map(fn(a) { a.0 })
}

fn result_map(r: Result(a, Nil), f: fn(a) -> b) -> Result(b, Nil) {
  case r {
    Ok(a) -> Ok(f(a))
    Error(Nil) -> Error(Nil)
  }
}

fn action_step(
  hooks: Hooks,
  action: #(ActionId, ToolCall),
) -> saga.Step(Nil, StepResult, Nil, Nil) {
  let #(id, call) = action
  saga.step(step_name(id), fn(_: Nil) {
    case hooks.fence(id) {
      False -> Ok(Refused)
      True ->
        case tool.lookup(hooks.tools, call.name) {
          Error(Nil) -> Ok(Ran(id, tool.BoundaryFailure("tool vanished")))
          Ok(t) -> Ok(Ran(id, tool.invoke(t, call.arguments)))
        }
    }
  })
  // One crashing or timed-out tool must not fail its siblings' batch:
  // Saga's recovery decision turns it into an uncertain effect.
  |> saga.compensate(max_attempts: 1, with: fn(failed) {
    case failed.failure {
      saga.Crashed(crash) ->
        saga.Continue(
          Ran(id, tool.Uncertain("tool crashed: " <> crash.reason)),
          saga.NoUndo,
        )
      saga.TimedOut ->
        saga.Continue(Ran(id, tool.Uncertain("tool timed out")), saga.NoUndo)
      saga.Returned(Nil) -> saga.Abort(Nil)
    }
  })
}

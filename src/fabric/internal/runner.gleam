//// The runner: the one process that drives a run while work is in flight.
////
//// It applies each event to the pure controller, commits the next state to
//// the store with compare-and-set, and only then performs the effects. A
//// runner exists only while a model call or a tool is in flight; when the
//// run finishes or suspends it gives the run up in that same commit and
//// exits, and the stored record is all that remains. A runner whose commit
//// fails stops: a newer owner exists, or the store is gone.
////
//// A runner is claimed in the same commit that hands it work (`launch`),
//// so there is never a moment where the record needs a runner and the
//// store knows none. Ownership: the runner is linked to nobody above it; it
//// monitors the store and exits when the store goes. It traps exits, so a
//// crash of its model task or executor becomes a message; killing the
//// runner kills both.

import fabric/internal/controller.{type Effect, type Event, type State}
import fabric/internal/executor.{type Executor}
import fabric/internal/live.{type Message}
import fabric/internal/record
import fabric/internal/registry
import fabric/model.{type Model}
import fabric/run
import fabric/store.{type Store}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Setup(context) {
  Setup(
    env: controller.Env(context),
    model: Model,
    max_concurrency: Int,
    /// Milliseconds before the first retry of a retryable model failure.
    model_retry_delay: Int,
    store: Store,
  )
}

type Runner(context) {
  Runner(
    setup: Setup(context),
    self: Subject(Message),
    state: State,
    revision: Int,
    executor: Option(Executor),
    /// The model task and the turn it answers.
    model_task: Option(#(Pid, Int)),
    /// Consecutive retryable model failures; the next call waits longer.
    model_failures: Int,
  )
}

type Go {
  Go(revision: Int, state: State, effects: List(Effect))
}

/// Commits `state` over `expected` (`None`: inserts the run) and, when the
/// state has work in flight, claims a new runner in the same commit and
/// hands it `effects`. Without work in flight nothing is performed:
/// `effects` can then only ask to stop work that no longer exists.
pub fn launch(
  setup: Setup(context),
  expected: Option(Int),
  state: State,
  effects: List(Effect),
) -> Result(Int, store.StoreError) {
  let encoded = record.encode(state)
  case controller.needs_runner(state) {
    False -> write(setup.store, state.run, expected, encoded, store.Keep)
    True -> {
      let #(pid, mailbox, go) = prepare(setup)
      let claim = store.Claim(pid, store.Live(state.incarnation, mailbox))
      case write(setup.store, state.run, expected, encoded, claim) {
        Ok(revision) -> {
          process.send(go, Go(revision, state, effects))
          Ok(revision)
        }
        Error(error) -> {
          process.kill(pid)
          Error(error)
        }
      }
    }
  }
}

fn write(
  store: Store,
  run: String,
  expected: Option(Int),
  encoded: String,
  ownership: store.Ownership,
) -> Result(Int, store.StoreError) {
  case expected {
    None -> store.insert(store, run, encoded, ownership)
    Some(revision) -> store.commit(store, run, revision, encoded, ownership)
  }
}

/// Spawns a runner that waits for its first committed state. It exits
/// without doing anything if the caller or the store goes first.
fn prepare(setup: Setup(context)) -> #(Pid, Subject(Message), Subject(Go)) {
  let ready = process.new_subject()
  let caller = process.self()
  let pid =
    process.spawn_unlinked(fn() {
      let self = process.new_subject()
      let go = process.new_subject()
      process.send(ready, #(self, go))
      let _ = process.monitor(store.pid(setup.store))
      let caller_monitor = process.monitor(caller)
      let first =
        process.new_selector()
        |> process.select_map(go, Ok)
        |> process.select_monitors(fn(_) { Error(Nil) })
        |> process.selector_receive_forever
      case first {
        Error(Nil) -> Nil
        Ok(Go(revision, state, effects)) -> {
          process.demonitor_process(caller_monitor)
          process.trap_exits(True)
          Runner(setup, self, state, revision, None, None, 0)
          |> perform(effects)
          |> serve
        }
      }
    })
  let #(mailbox, go) = process.receive_forever(ready)
  #(pid, mailbox, go)
}

fn serve(runner: Runner(context)) -> Nil {
  case controller.needs_runner(runner.state) {
    False -> shutdown(runner)
    True -> {
      let selector =
        process.new_selector()
        |> process.select(runner.self)
        |> process.select_monitors(fn(_) { live.StoreDown })
        |> process.select_trapped_exits(fn(exit) {
          live.Exited(exit.pid, exit.reason)
        })
      let next = case process.selector_receive_forever(selector) {
        live.StoreDown -> Error(Superseded)
        live.Command(step, reply) -> {
          let outcome = commit(runner, step(runner.state))
          process.send(reply, case outcome {
            Ok(runner) -> live.Applied(runner.state)
            Error(Refused(rejection)) -> live.Refused(rejection)
            Error(Superseded) -> live.Superseded
          })
          outcome
        }
        live.ModelDone(turn, result) -> {
          let model_failures = case result {
            Error(model.ModelError(retryable: True, ..)) ->
              runner.model_failures + 1
            _ -> 0
          }
          let runner = Runner(..runner, model_task: None, model_failures:)
          apply(runner, case result {
            Ok(reply) -> controller.ModelReplied(turn, reply)
            Error(error) -> controller.ModelFailed(turn, error)
          })
        }
        live.Fence(id, reply) -> {
          let outcome = apply(runner, controller.ToolStarting(id))
          process.send(reply, result.is_ok(outcome))
          outcome
        }
        live.Executed(executor.Reported(id, outcome)) ->
          apply(runner, controller.ToolReported(id, outcome))
        live.Executed(executor.Lost(id, reason)) ->
          apply(runner, controller.ToolLost(id, reason))
        live.Executed(executor.Stopped) ->
          apply(Runner(..runner, executor: None), controller.ToolsStopped)
        live.Exited(pid, reason) -> exited(runner, pid, reason)
      }
      case next {
        Ok(runner) -> serve(runner)
        // A refused event changes nothing.
        Error(Refused(_)) -> serve(runner)
        Error(Superseded) -> shutdown(runner)
      }
    }
  }
}

/// A linked process exited. A normal exit follows its last report; an
/// abnormal one means its work is lost.
fn exited(
  runner: Runner(context),
  pid: Pid,
  reason: process.ExitReason,
) -> Result(Runner(context), ApplyError) {
  let executor_pid = option.map(runner.executor, executor.pid)
  case reason, runner.model_task, executor_pid {
    process.Normal, _, _ -> Ok(runner)
    _, Some(#(task, turn)), _ if task == pid ->
      apply(
        Runner(..runner, model_task: None),
        controller.ModelFailed(
          turn,
          model.ModelError(
            "the model task exited: " <> string.inspect(reason),
            retryable: False,
          ),
        ),
      )
    _, _, Some(lost) if lost == pid ->
      lose_all(
        Runner(..runner, executor: None),
        "the executor exited: " <> string.inspect(reason),
      )
    // An exit signal from anyone else (a supervisor shutting down) stops
    // the runner, and with it the executor and the model task.
    _, _, _ -> Error(Superseded)
  }
}

/// Every action the dead executor held is lost.
fn lose_all(
  runner: Runner(context),
  reason: String,
) -> Result(Runner(context), ApplyError) {
  let held = case runner.state.phase {
    controller.Acting(_, actions) | controller.Stopping(_, actions, _) ->
      list.filter(actions, fn(action) {
        action.state == run.Queued || action.state == run.Running
      })
    controller.AwaitingModel(_) | controller.Ended(_) -> []
  }
  case held {
    [] ->
      case runner.state.phase {
        controller.Stopping(..) -> apply(runner, controller.ToolsStopped)
        _ -> Ok(runner)
      }
    _ ->
      list.try_fold(held, runner, fn(runner, action) {
        apply(runner, controller.ToolLost(action.id, reason))
      })
  }
}

type ApplyError {
  Refused(controller.Rejection)
  Superseded
}

fn apply(
  runner: Runner(context),
  event: Event,
) -> Result(Runner(context), ApplyError) {
  commit(runner, controller.step(runner.setup.env, runner.state, event))
}

/// Commit before effect: the next state is stored before any of its effects
/// run, so a lost runner never leaves an effect the record does not know.
fn commit(
  runner: Runner(context),
  transition: Result(#(State, List(Effect)), controller.Rejection),
) -> Result(Runner(context), ApplyError) {
  use #(state, effects) <- result.try(transition |> result.map_error(Refused))
  let ownership = case controller.needs_runner(state) {
    True -> store.Keep
    False -> store.Release(process.self())
  }
  case persist(runner.setup.store, state, runner.revision, ownership, 0) {
    Error(_) -> Error(Superseded)
    Ok(revision) -> Ok(perform(Runner(..runner, state:, revision:), effects))
  }
}

/// How often a commit the store reports `Unavailable` is tried again, and
/// the first wait in milliseconds (doubled per attempt).
const unavailable_retries = 6

const unavailable_backoff = 10

/// Commits `state` over `expected`. A conflict means a newer owner exists:
/// stop. `Unavailable` may be transient, so it is tried again after a
/// bounded backoff (the store has already read back a write that happened
/// despite the error).
fn persist(
  store: Store,
  state: State,
  expected: Int,
  ownership: store.Ownership,
  attempt: Int,
) -> Result(Int, store.StoreError) {
  let encoded = record.encode(state)
  case store.commit(store, state.run, expected, encoded, ownership) {
    Error(store.Unavailable(_)) if attempt < unavailable_retries -> {
      process.sleep(unavailable_backoff * int.bitwise_shift_left(1, attempt))
      persist(store, state, expected, ownership, attempt + 1)
    }
    // An earlier attempt that was reported unavailable may have landed
    // after all: the conflict is then with this runner's own write.
    Error(store.Conflict(current)) as conflict
      if attempt > 0 && current == expected + 1
    ->
      case store.get(store, state.run) {
        Ok(entry) if entry.revision == current && entry.record == encoded ->
          Ok(current)
        _ -> conflict
      }
    outcome -> outcome
  }
}

fn perform(runner: Runner(context), effects: List(Effect)) -> Runner(context) {
  use runner, effect <- list.fold(effects, runner)
  case effect {
    controller.CallModel(turn, request) -> {
      let self = runner.self
      let model = runner.setup.model
      let delay =
        retry_delay(runner.setup.model_retry_delay, runner.model_failures)
      // Linked: the task dies with the runner, and the runner (trapping
      // exits) learns of a task that dies without answering. A retry waits
      // inside the task, so aborting the call also ends the wait.
      let pid =
        process.spawn(fn() {
          case delay > 0 {
            True -> process.sleep(delay)
            False -> Nil
          }
          let result = case
            executor.rescue(fn() { model.call(model, request) })
          {
            Ok(result) -> result
            Error(crash) ->
              Error(model.ModelError(
                "model crashed: " <> crash,
                retryable: False,
              ))
          }
          process.send(self, live.ModelDone(turn, result))
        })
      Runner(..runner, model_task: Some(#(pid, turn)))
    }
    controller.AbortModel -> abort_model(runner)
    controller.Dispatch(actions) -> {
      let executor = case runner.executor {
        Some(executor) -> executor
        None -> start_executor(runner)
      }
      executor.submit(executor, actions)
      Runner(..runner, executor: Some(executor))
    }
    controller.StopTools ->
      case runner.executor {
        Some(executor) -> {
          executor.stop(executor)
          runner
        }
        None -> {
          process.send(runner.self, live.Executed(executor.Stopped))
          runner
        }
      }
  }
}

/// Exponential backoff: `initial` doubled per consecutive failure after the
/// first, at most six times.
fn retry_delay(initial: Int, failures: Int) -> Int {
  case failures {
    0 -> 0
    n -> initial * int.bitwise_shift_left(1, int.min(n - 1, 6))
  }
}

fn start_executor(runner: Runner(context)) -> Executor {
  let self = runner.self
  let env = runner.setup.env
  executor.start(
    executor.Hooks(
      max_in_flight: runner.setup.max_concurrency,
      fence: fn(id) { process.call_forever(self, live.Fence(id, _)) },
      invoke: fn(call) {
        registry.invoke(
          env.registry,
          env.context,
          call.name,
          call.arguments_json,
        )
      },
      report: fn(report) { process.send(self, live.Executed(report)) },
    ),
  )
}

fn abort_model(runner: Runner(context)) -> Runner(context) {
  case runner.model_task {
    Some(#(pid, _)) -> {
      process.unlink(pid)
      process.kill(pid)
      Runner(..runner, model_task: None)
    }
    None -> runner
  }
}

/// Exiting normally does not take linked processes down, so the model task
/// is killed explicitly; the executor sees the exit and kills its tasks.
fn shutdown(runner: Runner(context)) -> Nil {
  let _ = abort_model(runner)
  Nil
}

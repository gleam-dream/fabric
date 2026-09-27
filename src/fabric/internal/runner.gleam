//// The runner: the one process that drives a run while work is in flight.
////
//// It applies each event to the pure controller, commits the next state to
//// the store with compare-and-set, and only then performs the effects. A
//// runner exists only while a model call or a tool is in flight; when the
//// run finishes or suspends it exits and the stored record is all that
//// remains. A runner whose commit loses a race stops: a newer owner exists.
////
//// Ownership: the runner is not linked to the process that spawned it. It
//// monitors the store and exits when the store goes. The executor and the
//// model task are linked to it.

import fabric/internal/controller.{type Effect, type Event, type State}
import fabric/internal/executor.{type Executor}
import fabric/internal/registry
import fabric/internal/store.{type Revision, type Store}
import fabric/model.{type Model, type ModelError, type Reply}
import fabric/policy.{type ActionId}
import fabric/run.{type Status}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Message {
  Command(Event, reply: Subject(Result(Status, controller.Rejection)))
  ModelDone(turn: Int, result: Result(Reply, ModelError))
  Fence(ActionId, reply: Subject(Bool))
  Executed(executor.Report)
  StoreDown
}

pub type RunStore =
  Store(State, Subject(Message))

pub type Setup(context) {
  Setup(
    env: controller.Env(context),
    model: Model,
    max_concurrency: Int,
    store: RunStore,
  )
}

type Runner(context) {
  Runner(
    setup: Setup(context),
    self: Subject(Message),
    state: State,
    revision: Revision,
    executor: Option(Executor),
    model_task: Option(Pid),
  )
}

/// Spawns a runner for a state already committed at `revision`, and
/// performs `effects`, the effects of that committed transition.
pub fn spawn(
  setup: Setup(context),
  state: State,
  revision: Revision,
  effects: List(Effect),
) -> Nil {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let self = process.new_subject()
    let _ = process.monitor(store.pid(setup.store))
    let _ = store.attach(setup.store, state.run, process.self(), self)
    process.send(ready, Nil)
    Runner(setup, self, state, revision, None, None)
    |> perform(effects)
    |> serve
  })
  let assert Ok(Nil) = process.receive(ready, 5000)
    as "the runner did not start"
  Nil
}

fn serve(runner: Runner(context)) -> Nil {
  case controller.needs_runner(runner.state) {
    False -> shutdown(runner)
    True -> {
      let selector =
        process.new_selector()
        |> process.select(runner.self)
        |> process.select_monitors(fn(_) { StoreDown })
      let next = case process.selector_receive_forever(selector) {
        StoreDown -> Error(Superseded)
        Command(event, reply) -> {
          let outcome = apply(runner, event)
          process.send(reply, case outcome {
            Ok(runner) -> Ok(controller.status(runner.state))
            Error(Refused(rejection)) -> Error(rejection)
            Error(Superseded) -> Error(controller.StaleEvent)
          })
          outcome
        }
        ModelDone(turn, result) -> {
          let runner = Runner(..runner, model_task: None)
          apply(runner, case result {
            Ok(reply) -> controller.ModelReplied(turn, reply)
            Error(error) -> controller.ModelFailed(turn, error)
          })
        }
        Fence(id, reply) -> {
          let outcome = apply(runner, controller.ToolStarting(id))
          process.send(reply, result.is_ok(outcome))
          outcome
        }
        Executed(executor.Reported(id, outcome)) ->
          apply(runner, controller.ToolReported(id, outcome))
        Executed(executor.Lost(id, reason)) ->
          apply(runner, controller.ToolLost(id, reason))
        Executed(executor.Stopped) ->
          apply(Runner(..runner, executor: None), controller.ToolsStopped)
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

type ApplyError {
  Refused(controller.Rejection)
  Superseded
}

/// Commit before effect: the next state is stored before any of its effects
/// run, so a lost runner never leaves an effect the record does not know.
fn apply(
  runner: Runner(context),
  event: Event,
) -> Result(Runner(context), ApplyError) {
  use #(state, effects) <- result.try(
    controller.step(runner.setup.env, runner.state, event)
    |> result.map_error(Refused),
  )
  case
    store.compare_and_set(
      runner.setup.store,
      state.run,
      runner.revision,
      state,
      release: !controller.needs_runner(state),
    )
  {
    Error(_) -> Error(Superseded)
    Ok(revision) -> Ok(perform(Runner(..runner, state:, revision:), effects))
  }
}

fn perform(runner: Runner(context), effects: List(Effect)) -> Runner(context) {
  use runner, effect <- list.fold(effects, runner)
  case effect {
    controller.CallModel(turn, request) -> {
      let self = runner.self
      let model = runner.setup.model
      let pid =
        process.spawn(fn() {
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
          process.send(self, ModelDone(turn, result))
        })
      Runner(..runner, model_task: Some(pid))
    }
    controller.AbortModel -> abort_model(runner)
    controller.Dispatch(actions) -> {
      let runner = ensure_executor(runner)
      let assert Some(executor) = runner.executor
        as "ensure_executor always starts one"
      executor.submit(executor, actions)
      runner
    }
    controller.StopTools ->
      case runner.executor {
        Some(executor) -> {
          executor.stop(executor)
          runner
        }
        None -> {
          process.send(runner.self, Executed(executor.Stopped))
          runner
        }
      }
  }
}

fn ensure_executor(runner: Runner(context)) -> Runner(context) {
  case runner.executor {
    Some(_) -> runner
    None -> {
      let self = runner.self
      let env = runner.setup.env
      let hooks =
        executor.Hooks(
          max_in_flight: runner.setup.max_concurrency,
          fence: fn(id) { process.call_forever(self, Fence(id, _)) },
          invoke: fn(call) {
            registry.invoke(
              env.registry,
              env.context,
              call.name,
              call.arguments_json,
            )
          },
          report: fn(report) { process.send(self, Executed(report)) },
        )
      Runner(..runner, executor: Some(executor.start(hooks)))
    }
  }
}

fn abort_model(runner: Runner(context)) -> Runner(context) {
  case runner.model_task {
    Some(pid) -> {
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

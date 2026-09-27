//// THROWAWAY (workflow composition experiment). The thin OTP runtime for the
//// Fabric-owned controller (variants A and B). One runner process exists per
//// run only while work is in flight; it commits the controller state to the
//// store (compare-and-set) after every accepted transition, before
//// performing the transition's effects. A paused run has no process.
////
//// Tool execution is delegated to an `Executor`: plain tasks (variant A,
//// `wc/exec_tasks`) or one Saga run per dispatched batch (variant B,
//// `wc/exec_saga`).

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import wc/agent.{type ActionId, type Event, type RunStatus, type State}
import wc/ffi
import wc/model.{type Model, type Reply, type ToolCall}
import wc/store.{type Revision, type Store}
import wc/tool

// --- executor seam -----------------------------------------------------------

pub type ExecEvent {
  Reported(ActionId, tool.Outcome)
  /// Every task of this runner is dead; no further reports will follow.
  Stopped
}

pub type Hooks {
  Hooks(
    tools: tool.Registry,
    max_in_flight: Int,
    /// Must be called, and must return `True`, before a tool body runs.
    fence: fn(ActionId) -> Bool,
    emit: fn(ExecEvent) -> Nil,
  )
}

pub type ExecutorHandle {
  ExecutorHandle(
    submit: fn(List(#(ActionId, ToolCall))) -> Nil,
    stop: fn() -> Nil,
  )
}

pub type Executor =
  fn(Hooks) -> ExecutorHandle

// --- environment -------------------------------------------------------------

pub type Observation {
  Committed(run: String, revision: Revision, status: RunStatus)
  /// The run's runner process has exited; only the stored record remains.
  Released(run: String)
}

pub type Env {
  Env(
    store: Store,
    model: Model,
    tools: tool.Registry,
    policy: agent.Policy,
    executor: Executor,
    max_in_flight: Int,
    observer: Option(Subject(Observation)),
  )
}

pub type CommandError {
  Rejected(agent.Rejection)
  NoSuchRun
  CorruptRecord
  InvalidRun(String)
  LostRace
}

// --- runtime process ---------------------------------------------------------

pub opaque type Runtime {
  Runtime(pid: Pid, subject: Subject(Request))
}

type Request {
  StartRun(
    run: String,
    prompt: String,
    max_turns: Int,
    reply: Subject(Result(Nil, CommandError)),
  )
  Command(
    run: String,
    event: Event,
    reply: Subject(Result(RunStatus, CommandError)),
  )
  IsLive(run: String, reply: Subject(Bool))
  RunnerDown(pid: Pid)
}

/// Starts an unlinked runtime. Runners, executors, and tool tasks are linked
/// beneath it, so `kill` takes all of them down: that models a node restart.
pub fn start(env: Env) -> Runtime {
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      runtime_loop(env, subject, dict.new())
    })
  let assert Ok(subject) = process.receive(ready, 1000)
  Runtime(pid, subject)
}

pub fn kill(runtime: Runtime) -> Nil {
  let monitor = process.monitor(runtime.pid)
  process.kill(runtime.pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  Nil
}

pub fn start_run(
  runtime: Runtime,
  run: String,
  prompt: String,
  max_turns: Int,
) -> Result(Nil, CommandError) {
  process.call(runtime.subject, 5000, StartRun(run, prompt, max_turns, _))
}

pub fn answer(
  runtime: Runtime,
  run: String,
  ref: agent.ApprovalRef,
  answer: agent.Answer,
) -> Result(RunStatus, CommandError) {
  command(runtime, run, agent.ApprovalAnswered(ref, answer))
}

pub fn reconcile(
  runtime: Runtime,
  run: String,
  action: ActionId,
  content: String,
) -> Result(RunStatus, CommandError) {
  command(runtime, run, agent.Reconcile(action, content))
}

pub fn cancel(
  runtime: Runtime,
  run: String,
) -> Result(RunStatus, CommandError) {
  command(runtime, run, agent.Cancel)
}

/// After a restart: take over a run whose runner was lost. In-flight actions
/// become uncertain effects; queued actions and a lost model call resume.
pub fn recover(
  runtime: Runtime,
  run: String,
) -> Result(RunStatus, CommandError) {
  command(runtime, run, agent.Recover)
}

pub fn is_live(runtime: Runtime, run: String) -> Bool {
  process.call(runtime.subject, 1000, IsLive(run, _))
}

pub fn load(
  store: Store,
  run: String,
) -> Result(#(Revision, State), CommandError) {
  use #(revision, record) <- result.try(
    store.get(store, run) |> result.replace_error(NoSuchRun),
  )
  agent.decode(record)
  |> result.map(fn(state) { #(revision, state) })
  |> result.replace_error(CorruptRecord)
}

fn command(
  runtime: Runtime,
  run: String,
  event: Event,
) -> Result(RunStatus, CommandError) {
  process.call(runtime.subject, 5000, Command(run, event, _))
}

type Live =
  Dict(String, #(Pid, Subject(RunnerMsg)))

fn runtime_loop(env: Env, subject: Subject(Request), live: Live) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_monitors(fn(down) {
      case down {
        process.ProcessDown(pid:, ..) -> RunnerDown(pid)
        process.PortDown(..) -> RunnerDown(process.self())
      }
    })
  case process.selector_receive_forever(selector) {
    StartRun(run, prompt, max_turns, reply) ->
      case agent.new(run, prompt, max_turns) {
        Error(reason) -> {
          process.send(reply, Error(InvalidRun(reason)))
          runtime_loop(env, subject, live)
        }
        Ok(#(state, effects)) ->
          case store.insert(env.store, run, agent.encode(state)) {
            Error(_) -> {
              process.send(reply, Error(InvalidRun("run already exists")))
              runtime_loop(env, subject, live)
            }
            Ok(revision) -> {
              observe(env, run, revision, state)
              let live = spawn_runner(env, live, state, revision, effects)
              process.send(reply, Ok(Nil))
              runtime_loop(env, subject, live)
            }
          }
      }
    Command(run, event, reply) -> {
      let #(outcome, live) = route(env, live, run, event)
      process.send(reply, outcome)
      runtime_loop(env, subject, live)
    }
    IsLive(run, reply) -> {
      process.send(reply, dict.has_key(live, run))
      runtime_loop(env, subject, live)
    }
    RunnerDown(pid) -> {
      let gone = dict.filter(live, fn(_, entry) { entry.0 == pid })
      dict.each(gone, fn(run, _) { notify(env, Released(run)) })
      runtime_loop(env, subject, dict.drop(live, dict.keys(gone)))
    }
  }
}

/// A command goes to the live runner when one exists; otherwise it is
/// applied to the stored record, and a runner starts only if the accepted
/// transition produced work.
fn route(
  env: Env,
  live: Live,
  run: String,
  event: Event,
) -> #(Result(RunStatus, CommandError), Live) {
  case dict.get(live, run) {
    Ok(#(pid, runner)) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      process.send(runner, RunnerCommand(event, reply))
      let answer =
        process.new_selector()
        |> process.select_map(reply, Some)
        |> process.select_specific_monitor(monitor, fn(_) { None })
        |> process.selector_receive_forever
      process.demonitor_process(monitor)
      case answer {
        Some(outcome) -> #(result.map_error(outcome, Rejected), live)
        None -> apply_offline(env, dict.delete(live, run), run, event, 2)
      }
    }
    Error(Nil) -> apply_offline(env, live, run, event, 2)
  }
}

fn apply_offline(
  env: Env,
  live: Live,
  run: String,
  event: Event,
  tries: Int,
) -> #(Result(RunStatus, CommandError), Live) {
  let config = agent.Config(env.policy, env.tools)
  let attempt = {
    use #(revision, state) <- result.try(load(env.store, run))
    use #(state, effects) <- result.try(
      agent.step(config, state, event) |> result.map_error(Rejected),
    )
    case store.compare_and_set(env.store, run, revision, agent.encode(state)) {
      Ok(revision) -> Ok(#(revision, state, effects))
      Error(_) -> Error(LostRace)
    }
  }
  case attempt {
    // Another owner committed first: re-validate against the newer record.
    Error(LostRace) if tries > 1 ->
      apply_offline(env, live, run, event, tries - 1)
    Error(error) -> #(Error(error), live)
    Ok(#(revision, state, effects)) -> {
      observe(env, run, revision, state)
      let live = case effects {
        [] -> live
        _ -> spawn_runner(env, live, state, revision, effects)
      }
      #(Ok(agent.status(state)), live)
    }
  }
}

fn observe(env: Env, run: String, revision: Revision, state: State) -> Nil {
  notify(env, Committed(run, revision, agent.status(state)))
}

fn notify(env: Env, observation: Observation) -> Nil {
  case env.observer {
    Some(observer) -> process.send(observer, observation)
    None -> Nil
  }
}

// --- runner process ----------------------------------------------------------

type RunnerMsg {
  RunnerCommand(Event, Subject(Result(RunStatus, agent.Rejection)))
  ModelDone(turn: Int, result: Result(Reply, String))
  Exec(ExecEvent)
  Fence(ActionId, Subject(Bool))
}

type Runner {
  Runner(
    env: Env,
    self: Subject(RunnerMsg),
    state: State,
    revision: Revision,
    executor: Option(ExecutorHandle),
    model_task: Option(Pid),
  )
}

fn spawn_runner(
  env: Env,
  live: Live,
  state: State,
  revision: Revision,
  effects: List(agent.Effect),
) -> Live {
  let ready = process.new_subject()
  let pid =
    process.spawn(fn() {
      let self = process.new_subject()
      process.send(ready, self)
      Runner(env, self, state, revision, None, None)
      |> perform(effects)
      |> runner_loop
    })
  process.monitor(pid)
  let assert Ok(subject) = process.receive(ready, 1000)
  dict.insert(live, state.run, #(pid, subject))
}

fn runner_loop(runner: Runner) -> Nil {
  case agent.needs_runner(runner.state) {
    False -> stop_executor(runner)
    True -> {
      let message = process.receive_forever(runner.self)
      let next = case message {
        RunnerCommand(event, reply) -> {
          let outcome = apply(runner, event)
          process.send(reply, case outcome {
            Ok(runner) -> Ok(agent.status(runner.state))
            Error(Refused(rejection)) -> Error(rejection)
            Error(Superseded) -> Error(agent.RunEnded)
          })
          outcome
        }
        ModelDone(turn, Ok(reply)) ->
          apply(
            Runner(..runner, model_task: None),
            agent.ModelReplied(turn, reply),
          )
        ModelDone(turn, Error(reason)) ->
          apply(
            Runner(..runner, model_task: None),
            agent.ModelFailed(turn, reason),
          )
        Fence(id, reply) -> {
          let outcome = apply(runner, agent.ToolStarting(id))
          process.send(reply, result.is_ok(outcome))
          outcome
        }
        Exec(Reported(id, outcome)) ->
          apply(runner, agent.ToolReported(id, outcome))
        Exec(Stopped) ->
          apply(Runner(..runner, executor: None), agent.ToolsStopped)
      }
      case next {
        Ok(runner) -> runner_loop(runner)
        // A stale event changes nothing; keep running.
        Error(Refused(_)) -> runner_loop(runner)
        // Someone else committed a newer revision: this runner is no owner.
        Error(Superseded) -> stop_executor(runner)
      }
    }
  }
}

type ApplyError {
  Refused(agent.Rejection)
  Superseded
}

fn apply(runner: Runner, event: Event) -> Result(Runner, ApplyError) {
  let config = agent.Config(runner.env.policy, runner.env.tools)
  use #(state, effects) <- result.try(
    agent.step(config, runner.state, event) |> result.map_error(Refused),
  )
  let env = runner.env
  case
    store.compare_and_set(
      env.store,
      state.run,
      runner.revision,
      agent.encode(state),
    )
  {
    Error(_) -> Error(Superseded)
    Ok(revision) -> {
      observe(env, state.run, revision, state)
      let runner = Runner(..runner, state: state, revision: revision)
      let runner = case state.phase, runner.model_task {
        agent.Ended(_), Some(pid) -> {
          process.unlink(pid)
          process.kill(pid)
          Runner(..runner, model_task: None)
        }
        _, _ -> runner
      }
      Ok(perform(runner, effects))
    }
  }
}

fn perform(runner: Runner, effects: List(agent.Effect)) -> Runner {
  use runner, effect <- list.fold(effects, runner)
  case effect {
    agent.CallModel(turn, transcript) -> {
      let self = runner.self
      let model = runner.env.model
      let pid =
        process.spawn(fn() {
          let result = case ffi.rescue(fn() { model(transcript) }) {
            Ok(result) -> result
            Error(crash) -> Error("model crashed: " <> crash)
          }
          process.send(self, ModelDone(turn, result))
        })
      Runner(..runner, model_task: Some(pid))
    }
    agent.Dispatch(actions) -> {
      let runner = ensure_executor(runner)
      let assert Some(handle) = runner.executor
      handle.submit(actions)
      runner
    }
    agent.StopTools ->
      case runner.executor {
        Some(handle) -> {
          handle.stop()
          runner
        }
        None -> {
          process.send(runner.self, Exec(Stopped))
          runner
        }
      }
  }
}

fn ensure_executor(runner: Runner) -> Runner {
  case runner.executor {
    Some(_) -> runner
    None -> {
      let self = runner.self
      let hooks =
        Hooks(
          tools: runner.env.tools,
          max_in_flight: runner.env.max_in_flight,
          fence: fn(id) { process.call(self, 5000, Fence(id, _)) },
          emit: fn(event) { process.send(self, Exec(event)) },
        )
      Runner(..runner, executor: Some(runner.env.executor(hooks)))
    }
  }
}

fn stop_executor(runner: Runner) -> Nil {
  case runner.executor {
    Some(handle) -> handle.stop()
    None -> Nil
  }
}

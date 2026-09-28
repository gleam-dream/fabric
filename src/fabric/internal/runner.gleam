//// The runner: the one process that drives a run while work is in flight.
////
//// It applies each event to the pure controller, commits the next state to
//// the store with compare-and-set, and only then performs the effects. A
//// runner exists only while a model call or a tool is in flight; when the
//// run finishes or suspends it gives the run up in that same commit and
//// exits, and the stored record is all that remains. A runner whose commit
//// fails stops: a newer owner exists, or the store is gone.
////
//// Effects run with the context of the step that produced them: the
//// runner's own events with the run's context (its `Setup`), a command
//// with the context it was given (`command`). An answer's recheck context
//// thus reaches exactly the tool or child run the answer approved, and the
//// runner keeps the run's context for everything else.
////
//// A runner is claimed in the same commit that hands it work (`launch`),
//// so there is never a moment where the record needs a runner and the
//// store knows none. Ownership: the runner is linked to nobody above it; it
//// monitors the store and exits when the store goes. It traps exits, so a
//// crash of its model task or executor becomes a message; killing the
//// runner kills both.

import fabric/agent
import fabric/internal/bounded
import fabric/internal/controller.{type Effect, type Event, type State}
import fabric/internal/executor.{type Executor}
import fabric/internal/invocation
import fabric/internal/live.{type Message, type Work}
import fabric/internal/observe
import fabric/internal/record
import fabric/internal/registry
import fabric/model.{type Model}
import fabric/policy.{type ActionId}
import fabric/run
import fabric/store.{type Store}
import gleam/dict.{type Dict}
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
    identity: run.Identity,
    /// The agent's own limits; a child's depth is further bounded by its
    /// parent's.
    limits: controller.Limits,
    /// The admitted sub-agent of each delegation, by delegation name.
    children: Dict(String, agent.Admitted(context)),
    policy_timeout: Int,
    /// For a sub-agent run: where its end is delivered.
    parent: Option(Parent(context)),
  )
}

/// The delegation of a parent run that a sub-agent run reports its end to.
pub type Parent(context) {
  Parent(setup: Setup(context), run: String, action: ActionId)
}

/// The runtime setup of an admitted agent with `context`.
pub fn setup(
  store: Store,
  admitted: agent.Admitted(context),
  context: context,
  parent: Option(Parent(context)),
) -> Setup(context) {
  Setup(
    env: controller.Env(
      registry: admitted.registry,
      policy: contain_policy(admitted.policy, admitted.policy_timeout),
      context:,
      system: admitted.system_prompt,
    ),
    model: admitted.model,
    max_concurrency: admitted.max_concurrency,
    model_retry_delay: admitted.model_retry_delay,
    store:,
    identity: admitted.identity,
    limits: controller.Limits(
      max_turns: admitted.max_turns,
      token_budget: admitted.token_budget,
      max_children: admitted.max_children,
      max_depth: admitted.max_depth,
    ),
    children: admitted.children,
    policy_timeout: admitted.policy_timeout,
    parent:,
  )
}

/// The work of `setup`'s run performed with `context`: tool bodies are
/// invoked with it, and a child run is started with it (while the child's
/// link back to the run keeps `setup`).
pub fn work(setup: Setup(context), context: context) -> Work {
  live.Work(
    invoke: fn(call: model.ToolCall) {
      registry.invoke(
        setup.env.registry,
        context,
        call.name,
        call.arguments_json,
      )
    },
    start_child: fn(parent, id, child, call) {
      start_child(setup, context, parent, id, child, call)
    },
  )
}

/// The setup of the sub-agent that the delegation `name` of `run` starts,
/// linked back to that action.
pub fn child_setup(
  setup: Setup(context),
  name: String,
  run: String,
  action: ActionId,
) -> Result(Setup(context), Nil) {
  use admitted <- result.map(dict.get(setup.children, name))
  self_setup(setup, admitted, run, action)
}

fn self_setup(
  parent: Setup(context),
  admitted: agent.Admitted(context),
  run: String,
  action: ActionId,
) -> Setup(context) {
  setup(
    parent.store,
    admitted,
    parent.env.context,
    Some(Parent(parent, run, action)),
  )
}

/// A policy that crashes or gives no decision in time has failed: the run
/// stops closed.
fn contain_policy(
  policy: policy.Policy(context),
  timeout: Int,
) -> policy.Policy(context) {
  fn(context, action) {
    case bounded.call(timeout, fn() { policy(context, action) }) {
      Ok(decision) -> decision
      Error(bounded.Crashed(crash)) -> Error("policy crashed: " <> crash)
      Error(bounded.TimedOut) ->
        Error(
          "policy gave no decision within " <> int.to_string(timeout) <> " ms",
        )
    }
  }
}

/// The first state of the root run `id`.
pub fn root_state(
  setup: Setup(context),
  id: String,
  prompt: String,
) -> #(State, List(Effect)) {
  controller.start(setup.env, id, setup.identity, setup.limits, prompt, None, 0)
}

/// The first state of the child run `id` that `parent`'s delegation
/// `action` starts: one level deeper, and nested no deeper than the parent
/// allows.
pub fn child_state(
  setup: Setup(context),
  id: String,
  prompt: String,
  parent: State,
  action: ActionId,
) -> #(State, List(Effect)) {
  let depth = parent.depth + 1
  let max_depth =
    int.min(parent.limits.max_depth, depth + setup.limits.max_depth)
  controller.start(
    setup.env,
    id,
    setup.identity,
    controller.Limits(..setup.limits, max_depth:),
    prompt,
    Some(run.Parent(parent.run, action)),
    depth,
  )
}

type Runner(context) {
  Runner(
    setup: Setup(context),
    /// The run's own work, for the events the runner applies itself.
    work: Work,
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
  Go(revision: Int, state: State, effects: List(Effect), work: Work)
}

/// Commits `state` over `expected` (`None`: inserts the run) and, when the
/// state has work in flight, claims a new runner in the same commit and
/// hands it `effects`. Without work in flight nothing is performed:
/// `effects` can then only ask to stop work that no longer exists. A run
/// that ended is delivered to its parent.
///
/// `before` is the state the commit replaces (`None` for a new run), for
/// the observations of the transition.
pub fn launch(
  setup: Setup(context),
  before: Option(#(Int, State)),
  state: State,
  effects: List(Effect),
) -> Result(Int, store.StoreError) {
  launch_with(setup, work(setup, setup.env.context), before, state, effects)
}

/// `launch`, with `effects` performed with `work`; the runner keeps
/// `setup`'s context for everything after them.
fn launch_with(
  setup: Setup(context),
  work: Work,
  before: Option(#(Int, State)),
  state: State,
  effects: List(Effect),
) -> Result(Int, store.StoreError) {
  let encoded = record.encode(state)
  let expected = option.map(before, fn(before) { before.0 })
  let observed = option.map(before, fn(before) { before.1 })
  case controller.needs_runner(state) {
    False -> {
      use revision <- result.map(write(
        setup.store,
        state.run,
        expected,
        encoded,
        store.Keep,
      ))
      observe.committed(observed, state)
      deliver(setup, state)
      revision
    }
    True -> {
      let #(pid, mailbox, go) = prepare(setup)
      let claim = store.Claim(pid, store.Live(state.incarnation, mailbox))
      case write(setup.store, state.run, expected, encoded, claim) {
        Ok(revision) -> {
          observe.committed(observed, state)
          process.send(go, Go(revision, state, effects, work))
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
        Ok(Go(revision, state, effects, first)) -> {
          process.demonitor_process(caller_monitor)
          process.trap_exits(True)
          let own = work(setup, setup.env.context)
          Runner(setup, own, self, state, revision, None, None, 0)
          |> perform(effects, first)
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
        live.Command(step, work, reply) -> {
          let work = option.unwrap(work, runner.work)
          let outcome = commit(runner, step(runner.state), work)
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
        live.Apply(event) -> apply(runner, event)
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
        action.child == None
        && { action.state == run.Queued || action.state == run.Running }
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
  commit(
    runner,
    controller.step(runner.setup.env, runner.state, event),
    runner.work,
  )
}

/// Commit before effect: the next state is stored before any of its effects
/// run, so a lost runner never leaves an effect the record does not know.
/// The effects are performed with `work`, the context of the step.
fn commit(
  runner: Runner(context),
  transition: Result(#(State, List(Effect)), controller.Rejection),
  work: Work,
) -> Result(Runner(context), ApplyError) {
  use #(state, effects) <- result.try(transition |> result.map_error(Refused))
  // A sub-agent run that ended keeps its registration until it has
  // delivered its end to its parent and exited, so that nobody sees the
  // child ended, unreported, and without a runner.
  let delivering = case state.phase, runner.setup.parent {
    controller.Ended(_), Some(_) -> True
    _, _ -> False
  }
  let ownership = case controller.needs_runner(state) || delivering {
    True -> store.Keep
    False -> store.Release(process.self())
  }
  case persist(runner.setup.store, state, runner.revision, ownership, 0) {
    Error(_) -> Error(Superseded)
    Ok(revision) -> {
      observe.committed(Some(runner.state), state)
      let runner = perform(Runner(..runner, state:, revision:), effects, work)
      deliver(runner.setup, state)
      Ok(runner)
    }
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

fn perform(
  runner: Runner(context),
  effects: List(Effect),
  work: Work,
) -> Runner(context) {
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
      executor.submit(
        executor,
        list.map(actions, fn(action) {
          let #(id, call) = action
          executor.Job(id, fn() { work.invoke(call) })
        }),
      )
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
    controller.StartChild(id, child, call) -> {
      let report = case work.start_child(runner.state, id, child, call) {
        Ok(Nil) -> controller.ChildStarted(id)
        Error(detail) ->
          controller.ToolReported(id, invocation.ArgumentsRejected(detail))
      }
      process.send(runner.self, live.Apply(report))
      runner
    }
    controller.CancelChildren(children) -> {
      let setup = runner.setup
      let state = runner.state
      // Each child is cancelled from its own process: the child's runner
      // may be delivering to this runner at the same moment.
      list.each(children, fn(entry) {
        let #(action, child) = entry
        process.spawn_unlinked(fn() {
          cancel_child(setup, state, action, child)
        })
      })
      runner
    }
  }
}

/// Stores and starts the child run `child` of the delegation `call`, with
/// `context`. A child that already exists (started before a restart) is
/// left alone: recovery reattaches it. `Error` when the delegation no
/// longer accepts the arguments or no longer exists.
fn start_child(
  setup: Setup(context),
  context: context,
  parent: State,
  id: ActionId,
  child: String,
  call: model.ToolCall,
) -> Result(Nil, String) {
  use child_setup <- result.try(
    child_setup(setup, call.name, parent.run, id)
    |> result.replace_error("no sub-agent is delegated as " <> call.name),
  )
  let child_setup =
    Setup(
      ..child_setup,
      env: controller.Env(..child_setup.env, context: context),
    )
  use prompt <- result.map(registry.prompt(
    setup.env.registry,
    call.name,
    call.arguments_json,
  ))
  let #(state, effects) = child_state(child_setup, child, prompt, parent, id)
  // AlreadyExists: an earlier start stored it. Any other failure leaves
  // the child missing, which recovery repairs.
  let _ = launch(child_setup, None, state, effects)
  Nil
}

/// Cancels the child run `child` of `parent`'s delegation `action`. Its
/// end reaches the parent through delivery; a child that was never stored
/// is reported missing.
fn cancel_child(
  setup: Setup(context),
  parent: State,
  action: ActionId,
  child: String,
) -> Nil {
  let name =
    list.find(controller.active_children(parent), fn(entry) {
      entry.0 == action
    })
  let child_setup = case name {
    Ok(#(_, name, _)) -> child_setup(setup, name, parent.run, action)
    Error(Nil) -> Error(Nil)
  }
  case child_setup {
    Error(Nil) -> Nil
    Ok(child_setup) -> {
      let _ = command(child_setup, child, child_setup.env, controller.Cancel, 8)
      // Whatever the cancel returned, report an ended, missing, or
      // unreadable child: a delivery of its end may have been lost, and a
      // duplicate is refused by the parent.
      case load(child_setup.store, child) {
        Error(NotFound) -> notify_parent(child_setup, controller.ChildMissing)
        Error(problem) ->
          notify_parent(
            child_setup,
            controller.ChildLost(describe_read(problem)),
          )
        Ok(#(_, state)) ->
          case controller.child_result(state) {
            Ok(result) -> notify_parent(child_setup, result)
            // Still stopping: its runner delivers its end.
            Error(Nil) -> Nil
          }
      }
    }
  }
}

/// Delivers the end of a sub-agent run to its parent's delegation.
pub fn deliver(setup: Setup(context), state: State) -> Nil {
  case setup.parent, controller.child_result(state) {
    Some(_), Ok(result) -> notify_parent(setup, result)
    _, _ -> Nil
  }
}

/// Applies a child's end to its parent. A refusal (already applied, the
/// parent ended) or an unreachable parent is left to recovery, which reads
/// the child again.
pub fn notify_parent(
  setup: Setup(context),
  result: controller.ChildResult,
) -> Nil {
  case setup.parent {
    None -> Nil
    Some(link) -> {
      let _ =
        command(
          link.setup,
          link.run,
          link.setup.env,
          controller.ChildEnded(link.action, result),
          16,
        )
      Nil
    }
  }
}

// --- commands --------------------------------------------------------------------

/// Why a stored run could not be read or continued.
pub type ReadError {
  NotFound
  StoreFailed(store.StoreError)
  UnsupportedVersion(found: Int)
  Corrupt(detail: String)
  Incompatible(List(run.Incompatibility))
}

pub type Failure {
  CommandRefused(controller.Rejection)
  /// Valid for the stored record, but it needs a runner this store does
  /// not know.
  OwnerUnknown
  Contended
  Unreadable(ReadError)
}

pub fn describe_read(error: ReadError) -> String {
  case error {
    NotFound -> "the record does not exist"
    StoreFailed(error) -> "the store failed: " <> string.inspect(error)
    UnsupportedVersion(found) ->
      "the record has unsupported version " <> int.to_string(found)
    Corrupt(detail) -> "the record is corrupt: " <> detail
    Incompatible(problems) ->
      "the record does not fit its agent: " <> string.inspect(problems)
  }
}

/// Sends `event` to the run's live runner, or applies it to the stored
/// record and starts a runner if the transition produced work. A lost race
/// reads the newer record and checks the command again. `env` is the
/// environment the event is stepped with (an answer's recheck context),
/// and the work that step starts runs with `env`'s context too; the runner
/// keeps `setup`'s (the run's) context for everything else.
pub fn command(
  setup: Setup(context),
  id: String,
  env: controller.Env(context),
  event: Event,
  tries: Int,
) -> Result(State, Failure) {
  // Cancelling needs nothing from the agent, so it is not refused when
  // the record no longer fits it.
  let loaded = case event {
    controller.Cancel -> load(setup.store, id)
    _ -> load_checked(setup, id)
  }
  use #(entry, state) <- result.try(loaded |> result.map_error(Unreadable))
  let retry = fn() {
    case tries > 1 {
      True -> command(setup, id, env, event, tries - 1)
      False -> Error(Contended)
    }
  }
  let work = work(setup, env.context)
  case live_runner(entry, state) {
    Some(mailbox) ->
      case
        send_live(
          mailbox,
          fn(state) { controller.step(env, state, event) },
          Some(work),
        )
      {
        Ok(live.Applied(state)) -> Ok(state)
        Ok(live.Refused(rejection)) -> Error(CommandRefused(rejection))
        Ok(live.Superseded) | Error(Nil) -> retry()
      }
    None -> {
      let orphaned = controller.needs_runner(state)
      // Cancelling starts nothing, so it needs no runner: the work of a
      // lost runner is abandoned first. Any other command is checked
      // against the stored record first, so a refusal is reported as such
      // whoever drives the run.
      let transition = case orphaned, event {
        True, controller.Cancel -> controller.cancel_abandoned(state)
        _, _ -> controller.step(env, state, event)
      }
      use #(next, effects) <- result.try(
        transition |> result.map_error(CommandRefused),
      )
      use Nil <- result.try(case orphaned, event {
        True, controller.Cancel | False, _ -> Ok(Nil)
        True, _ -> Error(OwnerUnknown)
      })
      case
        launch_with(setup, work, Some(#(entry.revision, state)), next, effects)
      {
        Ok(_) -> Ok(next)
        Error(store.Conflict(_)) -> retry()
        Error(error) -> Error(Unreadable(StoreFailed(error)))
      }
    }
  }
}

/// Applies `step` through the live runner; the effects of the step are
/// performed with `work`, or with the run's own work (`None`). `Error(Nil)`
/// when the runner exited before answering.
pub fn send_live(
  mailbox: Subject(live.Message),
  step: fn(State) ->
    Result(#(State, List(controller.Effect)), controller.Rejection),
  work: Option(Work),
) -> Result(live.CommandReply, Nil) {
  case process.subject_owner(mailbox) {
    Error(Nil) -> Error(Nil)
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      process.send(mailbox, live.Command(step, work, reply))
      let answer =
        process.new_selector()
        |> process.select_map(reply, Ok)
        |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
        |> process.selector_receive_forever
      process.demonitor_process(monitor)
      answer
    }
  }
}

/// The stored record of `id`.
pub fn load(
  store: Store,
  id: String,
) -> Result(#(store.Entry, State), ReadError) {
  use Nil <- result.try(case issued_id(id) {
    True -> Ok(Nil)
    False -> Error(NotFound)
  })
  use entry <- result.try(
    store.get(store, id)
    |> result.map_error(fn(error) {
      case error {
        store.NotFound -> NotFound
        other -> StoreFailed(other)
      }
    }),
  )
  use state <- result.map(
    record.decode(entry.record)
    |> result.map_error(fn(error) {
      case error {
        record.UnsupportedVersion(found) -> UnsupportedVersion(found)
        record.Corrupt(detail) -> Corrupt(detail)
      }
    }),
  )
  #(entry, state)
}

/// `load`, and the record must be able to continue under `setup`'s agent.
pub fn load_checked(
  setup: Setup(context),
  id: String,
) -> Result(#(store.Entry, State), ReadError) {
  use #(entry, state) <- result.try(load(setup.store, id))
  record.check(state, setup.identity, setup.env.registry)
  |> result.map(fn(state) { #(entry, state) })
  |> result.map_error(Incompatible)
}

/// The runner registered for the record's current incarnation. A runner of
/// an older incarnation lost the run to a recovery elsewhere; its commits
/// will fail.
pub fn live_runner(
  entry: store.Entry,
  state: State,
) -> Option(Subject(live.Message)) {
  case entry.live {
    Some(store.Live(incarnation, mailbox)) if incarnation == state.incarnation ->
      Some(mailbox)
    _ -> None
  }
}

/// Whether `id` has the shape of the run ids Fabric issues: 1 to 128
/// letters, digits, `-` and `_`. Anything else names no run.
fn issued_id(id: String) -> Bool {
  let length = string.length(id)
  length >= 1
  && length <= 128
  && string.to_graphemes(id)
  |> list.all(fn(grapheme) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_",
      grapheme,
    )
  })
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
  executor.start(
    executor.Hooks(
      max_in_flight: runner.setup.max_concurrency,
      fence: fn(id) { process.call_forever(self, live.Fence(id, _)) },
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

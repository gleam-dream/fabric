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
//// store knows none. Ownership: the runner is a temporary child of its
//// store's runner factory (`store.supervised`); it monitors the store
//// process it was claimed through and exits when that process goes. It
//// traps exits, so a crash of its model task or executor becomes a
//// message; killing the runner kills both.
////
//// Drain: the factory's `shutdown` makes the runner start nothing new (no
//// model call, tool body or child run; the committed state keeps that
//// work) while it goes on applying what arrives: the reports of the tool
//// bodies running, the model reply in flight, commands. Once no tool body
//// runs and no reply is awaited, it commits `controller.hand_off` of its
//// state, giving the run up, and exits. A runner the factory kills at the
//// end of its drain window leaves its record as a lost runner does.

import fabric/internal/ancestry
import fabric/internal/bounded
import fabric/internal/budget/admission as capacity
import fabric/internal/budget/bootstrap
import fabric/internal/budget/model as reservations
import fabric/internal/checked_agent
import fabric/internal/claim
import fabric/internal/controller.{type Effect, type Event, type State}
import fabric/internal/executor.{type Executor}
import fabric/internal/invocation
import fabric/internal/live.{type Message, type Work}
import fabric/internal/model_port
import fabric/internal/observe
import fabric/internal/record
import fabric/internal/registry
import fabric/internal/run_id
import fabric/internal/runner_host
import fabric/internal/store.{type Store}
import fabric/model.{type Model}
import fabric/policy
import fabric/run.{type ActionId}
import fabric/store/backend
import fabric/tool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sinal/correlation.{type Correlation}

pub type Setup(context) {
  Setup(
    env: controller.Env(context),
    model: Model,
    max_concurrency: Int,
    /// Milliseconds before the first retry of a retryable model failure.
    model_retry_delay: Int,
    store: Store,
    identity: run.DefinitionId,
    /// The agent's own limits; a child's depth is further bounded by its
    /// parent's.
    limits: controller.Limits,
    /// The admitted sub-agent of each delegation, by delegation name.
    children: Dict(String, checked_agent.Admitted(context)),
    policy_timeout: Int,
    /// How long a command waits for this run's live runner to take it.
    command_timeout: Int,
    /// Milliseconds a model call may take once issued; `None`: unbounded.
    model_timeout: Option(Int),
    /// Milliseconds a tool body may run, unless the tool sets its own;
    /// `None`: unbounded.
    tool_timeout: Option(Int),
    /// The largest tool result content a run keeps, in bytes.
    max_result_bytes: Int,
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
  admitted: checked_agent.Admitted(context),
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
    command_timeout: admitted.command_timeout,
    model_timeout: admitted.model_timeout,
    tool_timeout: admitted.tool_timeout,
    max_result_bytes: admitted.max_result_bytes,
    parent:,
  )
}

/// The work of `setup`'s run performed with `context`: tool bodies are
/// invoked with it, and a child run is started with it (while the child's
/// link back to the run keeps `setup`).
pub fn work(setup: Setup(context), context: context) -> Work {
  live.Work(
    invoke: fn(
      run_id: String,
      correlation: Correlation,
      id: ActionId,
      call: model.ToolCall,
    ) {
      // Invoked in the action's task.
      let task = process.self()
      registry.invoke(
        setup.env.registry,
        context,
        tool.Call(run: run_id.from_string(run_id), action: id, correlation:),
        call.name,
        call.arguments_json,
        fn(outcome, summary) {
          settle_late(
            setup,
            run_id,
            correlation,
            id,
            call.name,
            task,
            bounded_outcome(setup, outcome),
            summary,
          )
        },
      )
      |> bounded_outcome(setup, _)
    },
    start_child: fn(parent, id, child, call) {
      start_child(setup, context, parent, id, child, call)
    },
  )
}

/// Applies a late settlement of the action `id` of `run`, a call of the
/// tool `name` whose body runs in `task` (`tool.bind_settling`). A
/// settlement offered while the action's task may still run (its report
/// or its stop is not committed yet) is offered again after each commit of
/// the run; it is given up when no commit comes within the tool's bound,
/// and at once when `task` itself offers it. A runner busy past the command
/// timeout is asked again a few times. A refusal is observed with
/// `summary`.
fn settle_late(
  setup: Setup(context),
  run: String,
  correlation: Correlation,
  id: ActionId,
  name: String,
  task: Pid,
  outcome: invocation.Outcome,
  summary: String,
) -> Result(Nil, tool.SettleError) {
  let within =
    registry.settles_within(setup.env.registry, name) |> option.unwrap(0)
  let offer =
    Offer(
      setup,
      run,
      id,
      outcome,
      process.new_subject(),
      process.self() == task,
      within,
    )
  let settled = offer_settlement(offer, False, 3)
  store.unwatch(setup.store, run, offer.watcher)
  case settled {
    Ok(Nil) -> Nil
    Error(error) ->
      observe.settlement_refused(
        run,
        correlation,
        id,
        name,
        outcome,
        summary,
        error,
      )
  }
  settled
}

/// A result over the agent's `max_result_bytes` is not kept: it becomes a
/// host failure that names the limit, and the run stops.
fn bounded_outcome(
  setup: Setup(context),
  outcome: invocation.Outcome,
) -> invocation.Outcome {
  let content = case outcome {
    invocation.Returned(content) | invocation.FailedVisibly(content) ->
      Some(content)
    _ -> None
  }
  case content {
    Some(content) ->
      case string.byte_size(content) {
        size if size > setup.max_result_bytes ->
          invocation.OutputUnencodable(
            "the tool's result is "
            <> int.to_string(size)
            <> " bytes, more than the run keeps ("
            <> int.to_string(setup.max_result_bytes)
            <> " bytes, agent.Limits.max_result_bytes)",
          )
        _ -> outcome
      }
    None -> outcome
  }
}

type Offer(context) {
  Offer(
    setup: Setup(context),
    run: String,
    id: ActionId,
    outcome: invocation.Outcome,
    watcher: Subject(Nil),
    /// The action's own task offers it: it cannot wait for itself.
    from_task: Bool,
    within: Int,
  )
}

fn offer_settlement(
  offer: Offer(context),
  watching: Bool,
  tries: Int,
) -> Result(Nil, tool.SettleError) {
  let Offer(setup:, run:, id:, outcome:, watcher:, ..) = offer
  case command(setup, run, setup.env, controller.Settled(id, outcome), 8) {
    Ok(_) -> Ok(Nil)
    Error(CommandRefused(controller.SettlementEarly(_))) if offer.from_task ->
      Error(tool.NotAwaited)
    // Watch the run first, then offer again, so that the commit that
    // settles the question is never missed.
    Error(CommandRefused(controller.SettlementEarly(_))) if !watching ->
      case store.watch(setup.store, run, watcher) {
        Ok(Nil) -> offer_settlement(offer, True, tries)
        Error(error) -> Error(tool.SettleUnconfirmed(string.inspect(error)))
      }
    Error(CommandRefused(controller.SettlementEarly(_))) ->
      case process.receive(watcher, offer.within) {
        Ok(Nil) -> offer_settlement(offer, True, tries)
        Error(Nil) -> Error(tool.NotAwaited)
      }
    Error(CommandRefused(controller.SettlementRecorded(_))) ->
      Error(tool.AlreadyRecorded)
    Error(CommandRefused(_)) -> Error(tool.NotAwaited)
    Error(Busy) if tries > 1 -> offer_settlement(offer, watching, tries - 1)
    Error(Busy) -> Error(tool.SettleUnconfirmed("the run's runner is busy"))
    Error(Contended) ->
      Error(tool.SettleUnconfirmed("every commit lost a race"))
    Error(OwnerUnknown) ->
      Error(tool.SettleUnconfirmed(
        "no runner known to this store drives the run",
      ))
    Error(Unreadable(problem)) ->
      Error(tool.SettleUnconfirmed(describe_read(problem)))
  }
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
  admitted: checked_agent.Admitted(context),
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
  correlation: Correlation,
) -> #(State, List(Effect)) {
  controller.start_correlated(
    setup.env,
    id,
    setup.identity,
    setup.limits,
    prompt,
    None,
    0,
    correlation,
  )
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
  // A sub-agent run carries its parent's correlation.
  controller.start_correlated(
    setup.env,
    id,
    setup.identity,
    controller.Limits(..setup.limits, max_depth:),
    prompt,
    Some(run.AgentParent(run_id.from_string(parent.run), action)),
    depth,
    parent.correlation,
  )
}

type Runner(context) {
  Runner(
    setup: Setup(context),
    /// The run's own work, for the events the runner applies itself.
    work: Work,
    self: Subject(Message),
    /// The events that report effects the runner performed (a child run
    /// was started): a draining runner applies them before its handoff.
    reports: Subject(Event),
    state: State,
    revision: Int,
    executor: Option(Executor(ActionId, invocation.Outcome)),
    /// The model task, the turn it answers, and its claim: the task takes
    /// it just before it calls the model, so a draining runner that takes
    /// it first knows the call was never issued (`serve`).
    model_task: Option(#(Pid, Int, claim.Claim)),
    /// Consecutive retryable model failures; the next call waits longer.
    model_failures: Int,
    /// One linked reader of durable child outcomes; it never holds up
    /// the runner's receive loop or drain.
    child_reader: Option(Pid),
    /// The factory the runner was started under: its `shutdown` drains
    /// the runner.
    factory: Pid,
    /// Draining: the runner starts nothing new and hands its run off once
    /// its work in flight has finished (`serve`).
    draining: Bool,
  )
}

/// What a prepared runner is told once its first state's commit is known.
type Go {
  Go(revision: Int, state: State, effects: List(Effect), work: Work)
  /// The commit failed: exit without doing anything.
  Abandon
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
) -> Result(Int, backend.StoreError) {
  launch_with(
    setup,
    work(setup, setup.env.context),
    before,
    state,
    effects,
    False,
  )
}

/// `launch`, with `effects` performed with `work`; the runner keeps
/// `setup`'s context for everything after them. A leased store claims the
/// run's lease, or with `seize` (a cancellation) takes it whoever holds
/// it.
fn launch_with(
  setup: Setup(context),
  work: Work,
  before: Option(#(Int, State)),
  state: State,
  effects: List(Effect),
  seize: Bool,
) -> Result(Int, backend.StoreError) {
  use encoded <- result.try(store.encode(setup.store, state))
  launch_encoded(setup, work, before, state, encoded, effects, seize)
}

/// Stores and starts the new root run `state`. A backend that reports the
/// run taken is read back: finding exactly the record this call wrote (a
/// backend that stored it and still reported it taken) confirms the
/// insert, and the run is started over it. Any other record is another
/// run's, and the error stays `AlreadyExists`.
pub fn launch_new(
  setup: Setup(context),
  state: State,
  effects: List(Effect),
) -> Result(Int, backend.StoreError) {
  let work = work(setup, setup.env.context)
  use encoded <- result.try(store.encode(setup.store, state))
  case launch_encoded(setup, work, None, state, encoded, effects, False) {
    Error(backend.AlreadyExists) ->
      case store.get(setup.store, state.run) {
        Ok(store.Entry(revision: 1, record: stored, live: None, ..))
          if stored == encoded
        -> {
          use encoded <- result.try(store.encode(setup.store, state))
          launch_over(
            setup,
            work,
            Some(1),
            None,
            state,
            encoded,
            effects,
            False,
          )
        }
        _ -> Error(backend.AlreadyExists)
      }
    other -> other
  }
}

/// `launch_with`, writing `state` as `encoded` (`store.encode`),
/// so that every attempt of one write carries one write token.
fn launch_encoded(
  setup: Setup(context),
  work: Work,
  before: Option(#(Int, State)),
  state: State,
  encoded: String,
  effects: List(Effect),
  seize: Bool,
) -> Result(Int, backend.StoreError) {
  let expected = option.map(before, fn(before) { before.0 })
  let observed = option.map(before, fn(before) { before.1 })
  launch_over(setup, work, expected, observed, state, encoded, effects, seize)
}

/// Writes `state` as `encoded` over the revision `expected` (`None`: a new
/// run) and starts its runner if it needs one. `observed` is the state the
/// observations of the transition start from.
fn launch_over(
  setup: Setup(context),
  work: Work,
  expected: Option(Int),
  observed: Option(State),
  state: State,
  encoded: String,
  effects: List(Effect),
  seize: Bool,
) -> Result(Int, backend.StoreError) {
  case controller.needs_runner(state) {
    False -> {
      use #(revision, state) <- result.map(write_initialized(
        setup.store,
        state,
        expected,
        encoded,
        store.Detached(in_flight: False, seize:),
      ))
      observe.committed(observed, state)
      deliver(setup, state)
      revision
    }
    True ->
      case prepare(setup) {
        // No runner can start (the store's runners are shutting down): the
        // work is committed and started by nobody, as if its runner had been
        // lost at once. It is `Unattended` until recovered.
        Error(Nil) -> {
          use #(revision, state) <- result.map(write_initialized(
            setup.store,
            state,
            expected,
            encoded,
            store.Detached(in_flight: True, seize:),
          ))
          observe.committed(observed, state)
          revision
        }
        Ok(#(pid, mailbox, go)) -> {
          let claim =
            store.Launch(pid, store.Live(state.incarnation, mailbox), seize:)
          case write_initialized(setup.store, state, expected, encoded, claim) {
            Ok(#(revision, state)) -> {
              // The runner starts before this commit's events are emitted: a
              // handler running here does not hold up the work.
              process.send(go, Go(revision, state, effects, work))
              observe.committed(observed, state)
              Ok(revision)
            }
            Error(error) -> {
              process.send(go, Abandon)
              Error(error)
            }
          }
        }
      }
  }
}

fn write_initialized(
  runs: Store,
  state: State,
  expected: Option(Int),
  encoded: String,
  ownership: store.Ownership,
) -> Result(#(Int, State), backend.StoreError) {
  use revision <- result.try(write(
    runs,
    state.run,
    expected,
    encoded,
    ownership,
  ))
  use declaration <- result.try(bootstrap.prepare(
    runs,
    state.run,
    state.parent,
    state.family_budget,
  ))
  case declaration == state.family_budget {
    True -> Ok(#(revision, state))
    False -> {
      let initialized = controller.State(..state, family_budget: declaration)
      use encoded <- result.try(store.encode(runs, initialized))
      use revision <- result.map(store.commit(
        runs,
        state.run,
        revision,
        encoded,
        ownership,
      ))
      #(revision, initialized)
    }
  }
}

fn write(
  store: Store,
  run: String,
  expected: Option(Int),
  encoded: String,
  ownership: store.Ownership,
) -> Result(Int, backend.StoreError) {
  case expected {
    None -> store.insert(store, run, encoded, ownership)
    Some(revision) -> store.commit(store, run, revision, encoded, ownership)
  }
}

/// Starts a runner under the store's runner factory, waiting for its first
/// committed state. `Error` when no runner can start: no store process
/// runs, or its runners are shutting down.
///
/// The runner belongs to the store process running now: once that process
/// stops, even if a supervisor restarts it, the runner stops, and its store
/// calls reach that process only, so a runner that has not yet noticed the
/// stop never commits through the next process. It exits without doing
/// anything if the caller or the store goes before its first state.
///
/// A caller that is itself a runner of the factory (starting a child run,
/// or delivering its end to an idle parent) never waits for a factory that
/// is stopping, which waits for that caller in turn: the start is made by
/// a helper process, and a shutdown the caller receives meanwhile gives it
/// up (`Error`) and is put back for the caller's own receive loop, which
/// takes it before any other message and drains. Exactly one side decides (`claim`): a runner the helper
/// started after the caller gave up is abandoned before its first state.
fn prepare(
  setup: Setup(context),
) -> Result(#(Pid, Subject(Message), Subject(Go)), Nil) {
  runner_host.prepare(
    setup.store,
    fn(pinned, owners, ready) { begin(setup, pinned, owners, ready) },
    Abandon,
  )
}

/// The runner's life, in the process its factory linked to it. `owners`
/// are the store process it belongs to, its factory, and the caller that
/// commits its first state. It traps exits from the start, so that a
/// shutdown arriving before its first state drains it rather than killing
/// it after its claim was committed.
fn begin(
  setup: Setup(context),
  pinned: Store,
  owners: #(Pid, Pid, Pid),
  ready: Subject(#(Subject(Message), Subject(Go))),
) -> Nil {
  let #(store_pid, factory, caller) = owners
  process.trap_exits(True)
  let self = process.new_subject()
  let go = process.new_subject()
  process.send(ready, #(self, go))
  let _ = process.monitor(store_pid)
  let caller_monitor = process.monitor(caller)
  case runner_host.first_state(go, pinned, factory, False) {
    Error(Nil) | Ok(#(Abandon, _)) -> Nil
    Ok(#(Go(revision, state, effects, first), draining)) -> {
      process.demonitor_process(caller_monitor)
      let setup = Setup(..setup, store: pinned)
      let own = work(setup, setup.env.context)
      Runner(
        setup:,
        work: own,
        self:,
        reports: process.new_subject(),
        state:,
        revision:,
        executor: None,
        model_task: None,
        model_failures: 0,
        child_reader: None,
        factory:,
        draining:,
      )
      |> perform(effects, first)
      |> schedule_children
      |> serve
    }
  }
}

fn serve(runner: Runner(context)) -> Nil {
  case controller.needs_runner(runner.state), runner.draining {
    False, _ -> shutdown(runner)
    // Draining: a model call not yet issued (its task may be waiting out a
    // retry backoff) never is, and the run is handed off once no tool body
    // runs and no model reply is awaited, with the reports of the effects
    // it performed applied.
    True, True -> {
      let runner = withhold_model_call(runner)
      case runner.model_task, controller.tools_running(runner.state) {
        None, False ->
          case process.receive(runner.reports, 0) {
            Error(Nil) -> hand_off(runner)
            Ok(event) ->
              case apply(runner, event) {
                Ok(runner) -> serve(runner)
                Error(Refused(_)) -> serve(runner)
                Error(Superseded) -> shutdown(runner)
              }
          }
        _, _ -> receive(runner)
      }
    }
    True, False -> receive(runner)
  }
}

/// Stops the model task if it has not issued its call yet: the call is
/// then never issued, and the handoff gives its turn back.
fn withhold_model_call(runner: Runner(context)) -> Runner(context) {
  case runner.model_task {
    Some(#(_, _, issue)) ->
      case claim.withdraw(issue) {
        True -> abort_model(runner)
        False -> runner
      }
    None -> runner
  }
}

/// Hands the run off: commits `controller.hand_off` of its state, giving
/// the run up in the same step, and stops. The run is then `Unattended`,
/// or idle if only approvals are left, and `recover` goes on with it. A
/// commit that is not confirmed leaves recovery to inspect the saved record,
/// as after a lost runner. If it did not land, a model call never issued
/// then still counts its turn, so
/// the run uses one turn more than without the stop. The store retains
/// confirmation or failure for its shutdown summary.
fn hand_off(runner: Runner(context)) -> Nil {
  let state = controller.hand_off(runner.state)
  let written = {
    use encoded <- result.try(store.encode(runner.setup.store, state))
    persist(
      runner.setup.store,
      state.run,
      encoded,
      runner.revision,
      store.HandOff(process.self()),
      0,
    )
  }
  case written {
    Ok(_) -> {
      observe.committed(Some(runner.state), state)
      observe.handed_off(state)
    }
    Error(_) -> store.handoff_failed(runner.setup.store, process.self())
  }
  shutdown(runner)
}

/// Its factory is shutting its runners down: the runner drains. Its
/// store's process hands the factory out no more, so no runner is started
/// under it meanwhile, not even by this one delivering an end to a parent.
fn drain(runner: Runner(context)) -> Runner(context) {
  store.draining(runner.setup.store, runner.factory)
  Runner(..runner, draining: True)
}

/// Waits for the next message and applies it. A shutdown from the factory
/// is taken first, wherever it waits in the mailbox (behind a report, or
/// put back behind the messages that arrived while a start was given up
/// for it): the runner drains before it applies anything else, so it
/// starts nothing that the shutdown would have withheld.
fn receive(runner: Runner(context)) -> Nil {
  case !runner.draining && take_shutdown(runner.factory) {
    True -> serve(drain(runner))
    False -> receive_next(runner)
  }
}

/// Receives the exit signal `shutdown` from `factory` if one is queued,
/// without waiting.
@external(erlang, "fabric_ffi", "take_shutdown")
fn take_shutdown(factory: Pid) -> Bool

fn receive_next(runner: Runner(context)) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(runner.self)
    |> process.select_map(runner.reports, live.Apply)
    |> process.select_monitors(fn(_) { live.StoreDown })
    |> process.select_trapped_exits(fn(exit) {
      live.Exited(exit.pid, exit.reason)
    })
  let next = case process.selector_receive_forever(selector) {
    live.StoreDown -> Error(Superseded)
    live.PollChildren -> Ok(read_children(runner))
    live.ChildrenRead(results) -> {
      let runner = Runner(..runner, child_reader: None) |> schedule_children
      case runner.draining {
        True -> Ok(runner)
        False ->
          list.try_fold(results, runner, fn(runner, child) {
            case apply(runner, controller.ChildEnded(child.0, child.1)) {
              Error(Refused(_)) -> Ok(runner)
              outcome -> outcome
            }
          })
      }
    }
    live.Command(step, work, command_claim, reply) ->
      case claim.accept(command_claim) {
        // The caller has withdrawn it: the command changes nothing.
        False -> Ok(runner)
        True -> {
          process.send(reply, live.Accepted)
          let work = option.unwrap(work, runner.work)
          commit_answering(runner, step(runner.state), work, fn(answer) {
            process.send(reply, answer)
          })
        }
      }
    live.CapacityUnavailable(_) -> Error(Superseded)
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
    // Nothing starts once an ancestor stops: a run that finds one
    // stopping or ended cancels itself. The ancestors are read before
    // the start is stored and again after it: an ancestor that stops
    // after the second read does so after the start was stored, and its
    // cancellation reaches this run with the tool running, so the tool
    // is recorded uncertain. The body starts as soon as that second
    // read finds them open: a handler of this commit does not hold it
    // past a later cancellation.
    // A draining runner starts no tool body: the action stays queued.
    live.Fence(_, reply) if runner.draining -> {
      process.send(reply, False)
      Ok(runner)
    }
    live.Fence(id, reply) -> fence(runner, id, reply)
    live.Executed(executor.Reported(id, outcome)) ->
      apply(runner, controller.ToolReported(id, outcome))
    live.Executed(executor.Crashed(id, reason)) ->
      apply(
        runner,
        controller.ToolReported(
          id,
          invocation.EffectUncertain("tool crashed: " <> reason),
        ),
      )
    live.Executed(executor.TimedOut(id, after)) ->
      apply(
        runner,
        controller.ToolReported(
          id,
          invocation.EffectUncertain(
            "the tool body was stopped after its "
            <> int.to_string(after)
            <> " ms timeout (agent.Limits.tool_timeout or tool.with_timeout)",
          ),
        ),
      )
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

fn fence(
  runner: Runner(context),
  id: ActionId,
  reply: Subject(Bool),
) -> Result(Runner(context), ApplyError) {
  let transition =
    controller.step(runner.setup.env, runner.state, controller.ToolStarting(id))
  case transition {
    Error(reason) -> {
      process.send(reply, False)
      Error(Refused(reason))
    }
    Ok(_) ->
      case
        capacity.work(
          runner.setup.store,
          runner.state.run,
          runner.state.parent,
          runner.state.family_budget,
          reservations.ToolAction(runner.state.run, id.turn, id.call_id),
        )
      {
        Error(error) -> {
          process.send(reply, False)
          case error {
            capacity.Limited(reason) ->
              apply(runner, controller.FamilyBudgetReached(reason))
            capacity.Closed -> apply(runner, controller.Cancel)
            capacity.Unavailable(_) -> Error(Superseded)
          }
        }
        Ok(Nil) -> {
          let open_after = process.new_subject()
          let started =
            commit_answering(runner, transition, runner.work, fn(answer) {
              let start = case answer {
                live.Applied(_) -> {
                  let open =
                    ancestors_open(
                      runner.setup.store,
                      runner.state.run,
                      runner.state.parent,
                    )
                  process.send(open_after, open)
                  open
                }
                _ -> False
              }
              process.send(reply, start)
            })
          case started, process.receive(open_after, 0) {
            Ok(runner), Ok(False) -> apply(runner, controller.Cancel)
            started, _ -> started
          }
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
  let shutdown = pid == runner.factory && runner_host.is_shutdown(reason)
  case reason, runner.model_task, executor_pid {
    _, _, _ if shutdown -> Ok(drain(runner))
    _, _, _ if runner.child_reader == Some(pid) ->
      Ok(Runner(..runner, child_reader: None) |> schedule_children)
    process.Normal, _, _ -> Ok(runner)
    _, Some(#(task, turn, _)), _ if task == pid ->
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
    // Any other exit signal (its factory crashed) stops the runner, and with
    // it the executor and the model task.
    _, _, _ -> Error(Superseded)
  }
}

/// Every action the dead executor held is lost.
fn lose_all(
  runner: Runner(context),
  reason: String,
) -> Result(Runner(context), ApplyError) {
  let held = case runner.state.phase {
    controller.Acting(_, actions) | controller.Stopping(actions:, ..) ->
      list.filter(actions, fn(action) {
        action.child == None
        && { action.state == run.Queued || action.state == run.Running }
      })
    controller.AwaitingModel(_)
    | controller.Ended(_)
    | controller.NeverStarted -> []
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
  commit_answering(runner, transition, work, fn(_) { Nil })
}

/// `commit`, calling `answer` as soon as the outcome is known: right after
/// the commit is stored, before its observations and effects, so that
/// neither a slow handler nor an effect holds whoever waits for it (a
/// command's caller, or a tool task at its fence).
fn commit_answering(
  runner: Runner(context),
  transition: Result(#(State, List(Effect)), controller.Rejection),
  work: Work,
  answer: fn(live.CommandReply) -> Nil,
) -> Result(Runner(context), ApplyError) {
  use #(state, effects) <- result.try(
    transition
    |> result.map_error(fn(rejection) {
      answer(live.Refused(rejection))
      Refused(rejection)
    }),
  )
  // A sub-agent run that ended keeps its registration until it has
  // delivered its end to its parent and exited, so that nobody sees the
  // child ended, unreported, and without a runner.
  let delivering = case state.phase, runner.setup.parent {
    controller.Ended(_), Some(_) -> True
    _, _ -> False
  }
  let ownership = case controller.needs_runner(state) || delivering {
    True -> store.Keep
    False -> store.Leave(process.self())
  }
  let written = {
    use encoded <- result.try(store.encode(runner.setup.store, state))
    persist(
      runner.setup.store,
      state.run,
      encoded,
      runner.revision,
      ownership,
      0,
    )
  }
  case written {
    Error(_) -> {
      answer(live.Superseded)
      Error(Superseded)
    }
    Ok(revision) -> {
      answer(live.Applied(state))
      observe.committed(Some(runner.state), state)
      let runner = Runner(..runner, state:, revision:)
      case current(runner, effects) {
        // A handler of this commit, running in this process, cancelled the
        // run through its record: the work is abandoned.
        False -> Error(Superseded)
        True -> {
          let runner = perform(runner, effects, work)
          deliver(runner.setup, state)
          Ok(runner)
        }
      }
    }
  }
}

/// Whether the runner may perform `effects`. A model call and a child
/// start have no fence of their own (a tool body's start is committed
/// first), so before them the record is read: one that moved past this
/// runner's commit abandoned its work. A failed read does not stop the
/// runner; its next commit decides.
fn current(runner: Runner(context), effects: List(Effect)) -> Bool {
  let unfenced =
    list.any(effects, fn(effect) {
      case effect {
        controller.CallModel(..) | controller.StartChild(..) -> True
        _ -> False
      }
    })
  case unfenced {
    False -> True
    True ->
      case store.get(runner.setup.store, runner.state.run) {
        Ok(entry) -> entry.revision == runner.revision && !held_elsewhere(entry)
        Error(_) -> True
      }
  }
}

/// How often a commit the store reports `Unavailable` is tried again, and
/// the first wait in milliseconds (doubled per attempt).
const unavailable_retries = 6

const unavailable_backoff = 10

/// Commits the encoded state over `expected`, every attempt with the same
/// text (one write token). A conflict means a newer owner exists:
/// stop. `Unavailable` may be transient, so it is tried again after a
/// bounded backoff (the store has already read back a write that happened
/// despite the error).
fn persist(
  store: Store,
  run: String,
  encoded: String,
  expected: Int,
  ownership: store.Ownership,
  attempt: Int,
) -> Result(Int, backend.StoreError) {
  case store.commit(store, run, expected, encoded, ownership) {
    Error(backend.Unavailable(_)) if attempt < unavailable_retries -> {
      process.sleep(unavailable_backoff * int.bitwise_shift_left(1, attempt))
      persist(store, run, encoded, expected, ownership, attempt + 1)
    }
    // An earlier attempt that was reported unavailable may have landed
    // after all: the conflict is then with this runner's own write, which
    // its write token identifies.
    Error(backend.Conflict(current)) as conflict
      if attempt > 0 && current == expected + 1
    ->
      case store.get(store, run) {
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
    // A draining runner starts nothing new: the committed state keeps the
    // work, and its handoff leaves it to recovery.
    controller.CallModel(..)
      | controller.Dispatch(_)
      | controller.StartChild(..)
      if runner.draining
    -> runner
    controller.CallModel(turn, request) -> {
      let self = runner.self
      let model = runner.setup.model
      let runs = runner.setup.store
      let parent = runner.state.parent
      let id = runner.state.run
      let reservation =
        reservations.ModelAttempt(
          id,
          runner.state.incarnation,
          turn,
          runner.model_failures + 1,
        )
      let declaration = runner.state.family_budget
      let delay =
        retry_delay(runner.setup.model_retry_delay, runner.model_failures)
      let model_timeout = runner.setup.model_timeout
      let issue = claim.new()
      // Linked: the task dies with the runner, and the runner (trapping
      // exits) learns of a task that dies without answering. A retry waits
      // inside the task, so aborting the call also ends the wait. The task
      // takes `issue` before it calls the model; a draining runner that
      // took it first stops the task (`withhold_model_call`).
      let pid =
        process.spawn(fn() {
          case delay > 0 {
            True -> process.sleep(delay)
            False -> Nil
          }
          case ancestors_open(runs, id, parent), claim.accept(issue) {
            _, False -> Nil
            False, True -> process.send(self, live.Apply(controller.Cancel))
            True, True -> {
              case capacity.work(runs, id, parent, declaration, reservation) {
                Error(capacity.Limited(reason)) ->
                  process.send(
                    self,
                    live.Apply(controller.FamilyBudgetReached(reason)),
                  )
                Error(capacity.Closed) ->
                  process.send(self, live.Apply(controller.Cancel))
                Error(capacity.Unavailable(reason)) ->
                  process.send(self, live.CapacityUnavailable(reason))
                Ok(Nil) ->
                  case ancestors_open(runs, id, parent) {
                    False -> process.send(self, live.Apply(controller.Cancel))
                    True -> {
                      let result = call_model(model, request, model_timeout)
                      process.send(self, live.ModelDone(turn, result))
                    }
                  }
              }
            }
          }
        })
      Runner(..runner, model_task: Some(#(pid, turn, issue)))
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
          let state = runner.state
          executor.Job(
            id,
            fn() { work.invoke(state.run, state.correlation, id, call) },
            registry.timeout(
              runner.setup.env.registry,
              call.name,
              runner.setup.tool_timeout,
            ),
          )
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
      case work.start_child(runner.state, id, child, call) {
        Ok(report) -> process.send(runner.reports, report)
        Error(reason) ->
          process.send(runner.self, live.CapacityUnavailable(reason))
      }
      runner
    }
    controller.AwaitSettlement(id, within) -> {
      process.send_after(
        runner.self,
        within,
        live.Apply(controller.SettlementDue(id)),
      )
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
/// `context`, and returns the event that reports it: `ChildStarted` once
/// the child is stored (by this start or an earlier one, which recovery
/// reattaches; or as a cancelled tombstone, which cancellation applies);
/// rejected arguments when the delegation no longer accepts them or no
/// longer exists; and a lost child when the store keeps failing, since the
/// last write's outcome is unknown.
fn start_child(
  setup: Setup(context),
  context: context,
  parent: State,
  id: ActionId,
  child: String,
  call: model.ToolCall,
) -> Result(controller.Event, String) {
  let rejected = fn(detail) {
    controller.ToolReported(id, invocation.ArgumentsRejected(detail))
  }
  case reserve_child(setup, parent, id, child) {
    // An ancestor stopped: the run cancels itself, and with it this start.
    Error(capacity.Closed) -> Ok(controller.Cancel)
    Error(capacity.Limited(reason)) ->
      Ok(controller.FamilyBudgetReached(reason))
    Error(capacity.Unavailable(reason)) -> Error(reason)
    Ok(Nil) ->
      Ok(store_started_child(setup, context, parent, id, child, call, rejected))
  }
}

pub fn reserve_child(
  setup: Setup(context),
  parent: State,
  action: ActionId,
  child: String,
) -> Result(Nil, capacity.Error) {
  use Nil <- result.try(capacity.work(
    setup.store,
    parent.run,
    parent.parent,
    parent.family_budget,
    reservations.ToolAction(parent.run, action.turn, action.call_id),
  ))
  capacity.child(
    setup.store,
    parent.run,
    parent.parent,
    parent.family_budget,
    child,
  )
}

fn store_started_child(
  setup: Setup(context),
  context: context,
  parent: State,
  id: ActionId,
  child: String,
  call: model.ToolCall,
  rejected: fn(String) -> controller.Event,
) -> controller.Event {
  case child_setup(setup, call.name, parent.run, id) {
    Error(Nil) -> rejected("no sub-agent is delegated as " <> call.name)
    Ok(child_setup) ->
      case registry.prompt(setup.env.registry, call.name, call.arguments_json) {
        Error(detail) -> rejected(detail)
        Ok(prompt) -> {
          let child_setup =
            Setup(
              ..child_setup,
              env: controller.Env(..child_setup.env, context: context),
            )
          let #(state, effects) =
            child_state(child_setup, child, prompt, parent, id)
          let stored = {
            use encoded <- result.try(store.encode(child_setup.store, state))
            // Keep these exact bytes for adopting a confirmed late insert.
            Ok(#(encoded, store_child(child_setup, state, encoded, effects, 0)))
          }
          case stored {
            Ok(#(_, Ok(Nil))) -> controller.ChildStarted(id)
            Ok(#(encoded, Error(backend.AlreadyExists))) ->
              adopt_child(child_setup, id, #(state, encoded, effects), 3)
            Error(error) | Ok(#(_, Error(error))) ->
              controller.ChildEnded(
                id,
                controller.ChildLost(
                  "it could not be stored: " <> string.inspect(error),
                ),
              )
          }
        }
      }
  }
}

/// Inserts and starts a child run, as `encoded`, trying an `Unavailable`
/// insert again after the runner's bounded backoff with the same text.
/// `AlreadyExists` means an earlier attempt, an earlier start, or another
/// writer stored it (see `adopt_child`).
fn store_child(
  setup: Setup(context),
  state: State,
  encoded: String,
  effects: List(Effect),
  attempt: Int,
) -> Result(Nil, backend.StoreError) {
  let work = work(setup, setup.env.context)
  case launch_encoded(setup, work, None, state, encoded, effects, False) {
    Ok(_) -> Ok(Nil)
    Error(backend.Unavailable(_)) if attempt < unavailable_retries -> {
      process.sleep(unavailable_backoff * int.bitwise_shift_left(1, attempt))
      store_child(setup, state, encoded, effects, attempt + 1)
    }
    Error(error) -> Error(error)
  }
}

/// The child run `first` was already stored: by an earlier insert of this
/// start that was reported unavailable and landed afterwards, by an earlier
/// start, by another writer, or as a tombstone by a cancelling parent. A
/// child that needs a runner and has none is given one: this start's own
/// first record, which carries its write token (`encoded`), gets the
/// runner it would have had (its first model call, no new incarnation);
/// any other record, even one equal to `first` written by someone else, is
/// taken over as a recovery would, as a new incarnation. An ended child's
/// end is applied; a tombstone is left to the cancellation that stored it.
fn adopt_child(
  setup: Setup(context),
  id: ActionId,
  start: #(State, String, List(Effect)),
  tries: Int,
) -> controller.Event {
  let #(first, encoded, first_effects) = start
  let lost = fn(detail) {
    controller.ChildEnded(id, controller.ChildLost(detail))
  }
  case load(setup.store, first.run) {
    Error(problem) -> lost(describe_read(problem))
    Ok(#(entry, stored)) ->
      case driven(entry, stored), controller.child_result(stored) {
        True, _ | False, Ok(controller.ChildMissing) ->
          controller.ChildStarted(id)
        False, Ok(ended) -> controller.ChildEnded(id, ended)
        False, Error(Nil) -> {
          let #(next, effects) = case entry.record == encoded {
            True -> #(first, first_effects)
            False -> controller.recover(setup.env, stored)
          }
          case launch(setup, Some(#(entry.revision, stored)), next, effects) {
            // Started, or another node's runner drives it.
            Ok(_) | Error(backend.LeaseRefused(_)) ->
              controller.ChildStarted(id)
            Error(backend.Conflict(_)) if tries > 1 ->
              adopt_child(setup, id, start, tries - 1)
            Error(error) ->
              lost("it could not be started: " <> string.inspect(error))
          }
        }
      }
  }
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
    // This agent no longer delegates the call (it may be a plain tool
    // now): the child is cancelled with no agent, and its end is applied
    // with nothing to map it. A child still stopping delivers its end
    // itself.
    Error(Nil) ->
      case
        end_child(setup.store, parent, action, child, setup.command_timeout, 3)
      {
        controller.ChildStopping -> Nil
        ended -> {
          let _ =
            command(
              setup,
              parent.run,
              setup.env,
              controller.ChildEnded(action, ended),
              16,
            )
          Nil
        }
      }
    Ok(child_setup) ->
      case cancel_until_stopping(child_setup, parent, action, child, 0) {
        Error(detail) ->
          notify_parent(
            child_setup,
            controller.ChildLost("it could not be cancelled: " <> detail),
          )
        Ok(Nil) -> report_cancelled(child_setup, child)
      }
  }
}

/// Cancels `child` until its record reads stopping or ended; a child that
/// does not exist is buried (`bury`). A child runner that is held is not
/// waited for: the cancellation is committed to its record (`command`). A
/// failure that may be transient (the store failed, every retry lost a
/// race, or the child appeared meanwhile) is tried again after a bounded
/// backoff; `Error` describes the last one.
fn cancel_until_stopping(
  setup: Setup(context),
  parent: State,
  action: ActionId,
  child: String,
  attempt: Int,
) -> Result(Nil, String) {
  let again = fn(detail) {
    case attempt < unavailable_retries {
      True -> {
        process.sleep(unavailable_backoff * int.bitwise_shift_left(1, attempt))
        cancel_until_stopping(setup, parent, action, child, attempt + 1)
      }
      False -> Error(detail)
    }
  }
  case command(setup, child, setup.env, controller.Cancel, 8) {
    // Committed, or already ended.
    Ok(_) | Error(CommandRefused(_)) -> Ok(Nil)
    Error(Unreadable(NotFound)) ->
      case bury(setup.store, parent, action, child, setup.identity) {
        Ok(Buried) -> Ok(Nil)
        Ok(Exists) -> again("the child run was being stored")
        Error(error) -> again(describe_read(StoreFailed(error)))
      }
    Error(Unreadable(StoreFailed(_) as problem)) ->
      again(describe_read(problem))
    // Unreadable: reported as such once read.
    Error(Unreadable(_)) -> Ok(Nil)
    Error(Contended) -> again("every commit lost a race")
    Error(OwnerUnknown) -> again("no runner drives it")
    Error(Busy) -> again("its runner is busy")
  }
}

pub type Burial {
  Buried
  /// The child run exists after all: cancel it instead.
  Exists
}

/// Stores the record of a child run that was cancelled before it was ever
/// stored (`controller.never_started`), unless a record exists. A start or
/// recovery of the child that races the cancellation then finds the run
/// ended and never runs it; the tombstone reads as a missing child.
pub fn bury(
  store: Store,
  parent: State,
  action: ActionId,
  child: String,
  agent: run.DefinitionId,
) -> Result(Burial, backend.StoreError) {
  let state = controller.never_started(parent, action, child, agent)
  use encoded <- result.try(store.encode(store, state))
  case
    store.insert(
      store,
      child,
      encoded,
      store.Detached(in_flight: False, seize: False),
    )
  {
    Ok(_) -> Ok(Buried)
    Error(backend.AlreadyExists) -> Ok(Exists)
    Error(error) -> Error(error)
  }
}

/// Reports an ended, missing, or unreadable child once its cancellation was
/// committed: a delivery of its end may have been lost, and a duplicate is
/// refused by the parent. A child still stopping delivers its end itself.
fn report_cancelled(child_setup: Setup(context), child: String) -> Nil {
  case load(child_setup.store, child) {
    Error(NotFound) -> notify_parent(child_setup, controller.ChildMissing)
    Error(problem) ->
      notify_parent(child_setup, controller.ChildLost(describe_read(problem)))
    Ok(#(_, state)) ->
      case controller.child_result(state) {
        Ok(result) -> notify_parent(child_setup, result)
        // Still stopping: its runner delivers its end.
        Error(Nil) -> Nil
      }
  }
}

/// Cancels the stored run `id` with no agent (`fabric.cancel_stored`): through
/// its live runner in this store, or else by abandoning a lost runner's
/// work, ending its children first (`end_child`), and ending the run in one
/// commit. A live runner must take the cancellation within `within`
/// milliseconds. Returns the state committed.
pub fn cancel_unattended(
  store: Store,
  id: String,
  within: Int,
  tries: Int,
) -> Result(State, Failure) {
  use #(entry, state) <- result.try(
    load(store, id) |> result.map_error(Unreadable),
  )
  let retry = fn() {
    case tries > 1 {
      True -> cancel_unattended(store, id, within, tries - 1)
      False -> Error(Contended)
    }
  }
  // Abandons the work of a lost or held runner, ends the children first,
  // and ends the run in one commit.
  let end_stored = fn() {
    let ended =
      list.map(controller.active_children(state), fn(active) {
        let #(action, _, child) = active
        #(action, end_child(store, state, action, child, within, tries))
      })
    use #(next, _) <- result.try(
      controller.cancel_unattended(state, ended)
      |> result.map_error(CommandRefused),
    )
    let detached =
      store.Detached(in_flight: controller.needs_runner(next), seize: True)
    use encoded <- result.try(
      store.encode(store, next)
      |> result.map_error(fn(error) { Unreadable(StoreFailed(error)) }),
    )
    case
      write_initialized(store, next, Some(entry.revision), encoded, detached)
    {
      Ok(#(_, next)) -> {
        observe.committed(Some(state), next)
        Ok(next)
      }
      Error(backend.Conflict(_)) -> retry()
      Error(error) -> Error(Unreadable(StoreFailed(error)))
    }
  }
  case live_runner(entry, state) {
    Some(mailbox) ->
      case send_live(mailbox, controller.cancel, None, within) {
        Ok(state) -> Ok(state)
        Error(LiveRefused(rejection)) -> Error(CommandRefused(rejection))
        // A held runner does not delay the cancellation: its next commit
        // conflicts and it stops.
        Error(LiveBusy) -> end_stored()
        Error(LiveGone) -> retry()
      }
    None -> end_stored()
  }
}

/// Cancels the child run `child` of `parent`'s delegation `action` with no
/// agent, and reads its end. A child that does not exist is buried in
/// place (`bury`, naming no agent), so that a start or recovery racing this
/// cancellation never runs it; one that appears meanwhile is cancelled in
/// turn.
pub fn end_child(
  store: Store,
  parent: State,
  action: ActionId,
  child: String,
  within: Int,
  tries: Int,
) -> controller.ChildResult {
  let _ = cancel_unattended(store, child, within, tries)
  case load(store, child) {
    Error(NotFound) ->
      case bury(store, parent, action, child, run.DefinitionId("", 0)) {
        Ok(Buried) -> controller.ChildMissing
        Ok(Exists) if tries > 1 ->
          end_child(store, parent, action, child, within, tries - 1)
        Ok(Exists) -> controller.ChildLost("it was being stored")
        Error(error) -> controller.ChildLost(describe_read(StoreFailed(error)))
      }
    Error(problem) -> controller.ChildLost(describe_read(problem))
    Ok(#(_, child_state)) ->
      case controller.child_result(child_state) {
        Ok(result) -> result
        Error(Nil) -> controller.ChildStopping
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

/// Applies a child's end to its parent. A parent runner that is busy is
/// asked again a few times. A refusal (already applied, the parent ended)
/// or an unreachable parent is left to recovery, which reads the child
/// again.
pub fn notify_parent(
  setup: Setup(context),
  result: controller.ChildResult,
) -> Nil {
  notify_parent_tries(setup, result, 3)
}

fn notify_parent_tries(
  setup: Setup(context),
  result: controller.ChildResult,
  tries: Int,
) -> Nil {
  case setup.parent {
    None -> Nil
    Some(link) ->
      case
        command(
          link.setup,
          link.run,
          link.setup.env,
          controller.ChildEnded(link.action, result),
          16,
        )
      {
        Error(Busy) if tries > 1 -> notify_parent_tries(setup, result, tries - 1)
        _ -> Nil
      }
  }
}

/// Whether every ancestor above `parent` (a run's parent link) still
/// accepts its work: `False` once one is stopping or has ended. A chain
/// that cannot be read after the store's bounded retries counts as closed:
/// nothing starts that the ancestors may have stopped.
pub fn ancestors_open(
  store: Store,
  id: String,
  parent: Option(run.Parent),
) -> Bool {
  case read_ancestors(store, id, parent, max_links, 0) {
    Ok(open) -> open
    Error(_) -> False
  }
}

/// More parent links than a valid family has; a longer chain is corrupt.
const max_links = 64

/// Reads the ancestors above `parent`: whether each still accepts its
/// work. A failed read is tried again after the runner's bounded backoff.
pub fn read_ancestors(
  store: Store,
  id: String,
  parent: Option(run.Parent),
  links: Int,
  attempt: Int,
) -> Result(Bool, ReadError) {
  case ancestry.read(store, id, parent, links) {
    Error(ancestry.StoreFailed(backend.NotFound)) -> Error(NotFound)
    Error(ancestry.StoreFailed(_)) if attempt < unavailable_retries -> {
      process.sleep(unavailable_backoff * int.bitwise_shift_left(1, attempt))
      read_ancestors(store, id, parent, links, attempt + 1)
    }
    Error(ancestry.StoreFailed(problem)) -> Error(StoreFailed(problem))
    Error(ancestry.UnsupportedVersion(version)) ->
      Error(UnsupportedVersion(version))
    Error(ancestry.Corrupt(detail)) -> Error(Corrupt(detail))
    Ok(open) -> Ok(open)
  }
}

// --- commands --------------------------------------------------------------------

/// Why a stored run could not be read or continued.
pub type ReadError {
  NotFound
  StoreFailed(backend.StoreError)
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
  /// The run's live runner did not take the command in time (or the
  /// command was sent from the runner's own process); nothing changed.
  Busy
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
  // Applies the event to the stored record. A run that needs a runner
  // (`orphaned`: its runner was lost, or is held) accepts only a
  // cancellation, which abandons that runner's work: `held`, the runner
  // that did not take the command, is killed once the cancellation is
  // stored, and with it its model call and tool tasks. A runner that is
  // the caller itself (a handler of its own commit) cannot be; its next
  // commit conflicts, and it performs no unfenced effect of a record that
  // moved on (`commit_answering`). Any other command is checked against
  // the stored record first, so a refusal is reported as such whoever
  // drives the run.
  let apply_stored = fn(orphaned, held: Option(Pid)) {
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
      launch_with(
        setup,
        work,
        Some(#(entry.revision, state)),
        next,
        effects,
        event == controller.Cancel,
      )
    {
      Ok(_) -> {
        option.map(held, process.kill)
        Ok(next)
      }
      Error(backend.Conflict(_)) -> retry()
      // The work needs a lease that another node's runner holds.
      Error(backend.LeaseRefused(_)) -> Error(OwnerUnknown)
      Error(error) -> Error(Unreadable(StoreFailed(error)))
    }
  }
  case live_runner(entry, state) {
    Some(mailbox) ->
      case
        send_live(
          mailbox,
          fn(state) { controller.step(env, state, event) },
          Some(work),
          setup.command_timeout,
        )
      {
        Ok(state) -> Ok(state)
        Error(LiveRefused(rejection)) -> Error(CommandRefused(rejection))
        // A held runner does not delay a cancellation: it is committed to
        // the record, and the held runner is stopped.
        Error(LiveBusy) ->
          case event {
            controller.Cancel -> {
              let caller = process.self()
              apply_stored(True, case process.subject_owner(mailbox) {
                Ok(pid) if pid != caller -> Some(pid)
                _ -> None
              })
            }
            _ -> Error(Busy)
          }
        Error(LiveGone) -> retry()
      }
    None -> apply_stored(controller.needs_runner(state), None)
  }
}

pub type LiveError {
  LiveRefused(controller.Rejection)
  /// The runner did not take the command within the timeout, or the
  /// caller is the runner itself (a synchronous observation handler): the
  /// command was not and will not be applied.
  LiveBusy
  /// The runner exited or lost the run before answering: read the record
  /// again.
  LiveGone
}

/// Applies `step` through the live runner and returns the committed state;
/// the effects of the step are performed with `work`, or with the run's
/// own work (`None`). The runner must take the command within `within`
/// milliseconds; once it has, the caller waits for the outcome, which the
/// runner sends as soon as the commit is stored. Exactly one of the two
/// decides (`claim`): a caller that stops waiting withdraws the command
/// before reporting `LiveBusy`, so a command reported busy is never
/// applied, and one the runner took is always waited for.
pub fn send_live(
  mailbox: Subject(live.Message),
  step: fn(State) ->
    Result(#(State, List(controller.Effect)), controller.Rejection),
  work: Option(Work),
  within: Int,
) -> Result(State, LiveError) {
  let caller = process.self()
  case process.subject_owner(mailbox) {
    Error(Nil) -> Error(LiveGone)
    Ok(pid) if pid == caller -> Error(LiveBusy)
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      let command_claim = claim.new()
      process.send(mailbox, live.Command(step, work, command_claim, reply))
      let receive = fn(timeout) {
        let selector =
          process.new_selector()
          |> process.select_map(reply, Ok)
          |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
        case timeout {
          Some(timeout) -> process.selector_receive(selector, timeout)
          None -> Ok(process.selector_receive_forever(selector))
        }
      }
      let outcome = fn() {
        case receive(None) {
          Ok(Ok(live.Applied(state))) -> Ok(state)
          Ok(Ok(live.Refused(rejection))) -> Error(LiveRefused(rejection))
          _ -> Error(LiveGone)
        }
      }
      let result = case receive(Some(within)) {
        Error(Nil) ->
          case claim.withdraw(command_claim) {
            True -> Error(LiveBusy)
            // The runner took it meanwhile: its `Accepted` is on the way.
            False ->
              case receive(None) {
                Ok(Ok(live.Accepted)) -> outcome()
                _ -> Error(LiveGone)
              }
          }
        Ok(Error(Nil)) -> Error(LiveGone)
        Ok(Ok(live.Accepted)) -> outcome()
        Ok(Ok(_)) -> Error(LiveGone)
      }
      process.demonitor_process(monitor)
      result
    }
  }
}

/// The stored record of `id`.
pub fn load(
  store: Store,
  id: String,
) -> Result(#(store.Entry, State), ReadError) {
  // An id in any other shape names no run (`run.parse_id`).
  use _ <- result.try(run.parse_id(id) |> result.replace_error(NotFound))
  use entry <- result.try(
    store.get(store, id)
    |> result.map_error(fn(error) {
      case error {
        backend.NotFound -> NotFound
        other -> StoreFailed(other)
      }
    }),
  )
  use state <- result.try(
    record.decode(entry.record)
    |> result.map_error(fn(error) {
      case error {
        record.UnsupportedVersion(found) -> UnsupportedVersion(found)
        record.Corrupt(detail) -> Corrupt(detail)
      }
    }),
  )
  case state.run == id {
    True -> Ok(#(entry, state))
    False -> Error(Corrupt("the record's run id differs from its storage key"))
  }
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

/// Whether another node's runner holds the run: a live lease of another
/// owner (a leased store).
pub fn held_elsewhere(entry: store.Entry) -> Bool {
  case entry.holding {
    store.HeldElsewhere(live: True, ..) -> True
    store.HeldElsewhere(live: False, ..) | store.HeldHere | store.Unheld ->
      False
  }
}

/// Whether the run's work has an owner: a runner of this store for its
/// current incarnation, or another node's runner (`held_elsewhere`).
pub fn driven(entry: store.Entry, state: State) -> Bool {
  live_runner(entry, state) != None || held_elsewhere(entry)
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

/// Calls the model in the calling task, bounded by `timeout` milliseconds
/// when there is one. A call still running at its timeout is stopped and
/// is a retryable failure; a crash is a non-retryable one.
fn call_model(
  model: Model,
  request: model.Request,
  timeout: Option(Int),
) -> Result(model.Reply, model.ModelError) {
  let crashed = fn(crash) {
    Error(model.ModelError("model crashed: " <> crash, retryable: False))
  }
  case timeout {
    None ->
      case executor.rescue(fn() { model_port.call(model, request) }) {
        Ok(result) -> result
        Error(crash) -> crashed(crash)
      }
    Some(ms) ->
      case bounded.call(ms, fn() { model_port.call(model, request) }) {
        Ok(result) -> result
        Error(bounded.Crashed(crash)) -> crashed(crash)
        Error(bounded.TimedOut) ->
          Error(model.ModelError(
            "the model call did not finish within "
              <> int.to_string(ms)
              <> " ms (agent.Limits.model_timeout)",
            retryable: True,
          ))
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

fn start_executor(
  runner: Runner(context),
) -> Executor(ActionId, invocation.Outcome) {
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
    Some(#(pid, _, _)) -> {
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
  option.map(runner.child_reader, process.kill)
  let _ = abort_model(runner)
  Nil
}

/// Only leased parents need to receive results written on another node.
/// Schedule after each completed read so slow storage cannot queue polls.
fn schedule_children(runner: Runner(context)) -> Runner(context) {
  case
    store.poll_interval(runner.setup.store),
    !runner.draining && dict.size(runner.setup.children) > 0
  {
    Some(interval), True -> {
      process.send_after(runner.self, interval, live.PollChildren)
      runner
    }
    _, _ -> runner
  }
}

fn read_children(runner: Runner(context)) -> Runner(context) {
  case
    runner.draining,
    runner.child_reader,
    controller.active_children(runner.state)
  {
    True, _, _ | _, Some(_), _ -> runner
    False, None, [] -> schedule_children(runner)
    False, None, children -> {
      let reader =
        process.spawn(fn() {
          let results =
            list.filter_map(children, fn(child) {
              let #(action, _, id) = child
              use #(_, state) <- result.try(
                load(runner.setup.store, id)
                |> result.map_error(fn(_) { Nil }),
              )
              case
                state.parent
                == Some(run.AgentParent(
                  run_id.from_string(runner.state.run),
                  action,
                ))
              {
                False -> Error(Nil)
                True ->
                  controller.child_result(state)
                  |> result.map(fn(outcome) { #(action, outcome) })
              }
            })
          process.send(runner.self, live.ChildrenRead(results))
        })
      Runner(..runner, child_reader: Some(reader))
    }
  }
}

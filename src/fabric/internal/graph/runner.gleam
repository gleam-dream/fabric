//// Serial graph execution over the shared store, supervised host, bounded
//// callbacks and fenced executor. No effect is released by an unconfirmed
//// commit. Every runner pins the store process that owns its lifetime.

import fabric/budget
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/fork
import fabric/graph/job
import fabric/graph/operation
import fabric/internal/ancestry
import fabric/internal/bounded
import fabric/internal/budget/admission as capacity
import fabric/internal/budget/bootstrap
import fabric/internal/budget/model as reservations
import fabric/internal/claim
import fabric/internal/executor
import fabric/internal/graph/attachment
import fabric/internal/graph/child_driver
import fabric/internal/graph/controller as g
import fabric/internal/graph/fork as scope
import fabric/internal/graph/fork_driver
import fabric/internal/graph/live
import fabric/internal/graph/observe
import fabric/internal/graph/record
import fabric/internal/run_id
import fabric/internal/runner_host as host
import fabric/internal/store
import fabric/policy
import fabric/run
import fabric/store/backend
import fabric/tool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sinal/correlation.{type Correlation}

/// A runtime's bounds, in milliseconds: one call of a definition's pure
/// callbacks, one operation body (`None`: unbounded), how long a command
/// waits for the live runner, and how long an approval request waits
/// (`None`: never expires).
pub type Options {
  Options(
    callback_timeout: Int,
    operation_timeout: Option(Int),
    command_timeout: Int,
    approval_expiry: Option(Int),
  )
}

pub type Error {
  StoreFailed(backend.StoreError)
  Unreadable(record.DecodeError)
  Incompatible(definition.Error)
  CallbackFailed(String)
  Refused(g.Rejection)
  /// An ancestor of the run is stopping or has ended: it accepts no child
  /// work.
  AncestorClosed
  Busy
  Contended
  OwnerUnknown
}

/// The deadline of an approval request issued now, by the store's clock.
pub fn approval_deadline(
  runs: store.Store,
  options: Options,
) -> Result(Option(Int), Error) {
  case options.approval_expiry {
    None -> Ok(None)
    Some(expiry) ->
      store.now(runs)
      |> result.map(fn(now) { Some(now + expiry) })
      |> result.map_error(StoreFailed)
  }
}

/// The deadline an event issuing `decision` gives a new approval request.
pub fn deadline_for(
  runs: store.Store,
  options: Options,
  decision: Result(policy.Decision, String),
) -> Result(Option(Int), Error) {
  case decision {
    Ok(policy.RequireApproval(_)) -> approval_deadline(runs, options)
    _ -> Ok(None)
  }
}

/// The correlation and root a child of the run `parent` inherits, and
/// whether that root is exact: the parent's, read from its record (derived
/// from the parent's id, not exact, when it cannot be read).
pub fn lineage(
  runs: store.Store,
  parent: String,
) -> #(Correlation, String, Bool) {
  case load_raw(runs, parent) {
    Ok(#(_, state)) -> #(state.correlation, state.root, state.root_exact)
    Error(_) -> #(correlation.from_key(parent), parent, False)
  }
}

/// The approval request of a run that waits on one whose deadline passed
/// by the store's clock, with that time.
pub fn approval_due(
  runs: store.Store,
  state: g.State,
) -> Result(Option(#(g.Approval, Int)), Error) {
  case state.phase {
    g.AwaitingApproval(_, approval) ->
      case approval.expires {
        None -> Ok(None)
        Some(due) -> {
          use now <- result.map(
            store.now(runs) |> result.map_error(StoreFailed),
          )
          case now >= due {
            True -> Some(#(approval, now))
            False -> None
          }
        }
      }
    _ -> Ok(None)
  }
}

pub fn load(
  runs: store.Store,
  work: live.Work,
  options: Options,
  id: String,
) -> Result(#(store.Entry, g.State), Error) {
  use #(entry, state) <- result.try(load_raw(runs, id))
  use checked <- result.try(
    bounded.call(options.callback_timeout, fn() { work().validate(state) })
    |> result.map_error(fn(error) { CallbackFailed(string.inspect(error)) }),
  )
  use _ <- result.try(checked |> result.map_error(Incompatible))
  Ok(#(entry, state))
}

pub fn load_raw(
  runs: store.Store,
  id: String,
) -> Result(#(store.Entry, g.State), Error) {
  use entry <- result.try(store.get(runs, id) |> result.map_error(StoreFailed))
  use state <- result.try(
    record.decode(entry.record) |> result.map_error(Unreadable),
  )
  use _ <- result.try(case state.run == id {
    True -> Ok(Nil)
    False ->
      Error(Unreadable(record.Corrupt("record belongs to a different run")))
  })
  // A child record written before roots were stored: its root is derived
  // from its ancestors (`ancestry.settle_root`).
  use #(root, root_exact) <- result.map(
    ancestry.settle_root(
      runs,
      id,
      state.parent,
      #(state.root, state.root_exact),
      state.correlation,
    )
    |> result.map_error(StoreFailed),
  )
  #(entry, g.State(..state, root:, root_exact:))
}

pub type AdmissionError {
  PolicyRejected(String)
  /// An ancestor stopped admitting this run's work after the run started:
  /// it is stopping or has ended, and is cancelling this run. Not a policy
  /// failure: the run stops as cancelled, as that cancellation would.
  AncestorStopping
  BudgetLimited(budget.Denial)
  BudgetUnavailable(String)
}

fn capacity_error(error: capacity.Error) -> AdmissionError {
  case error {
    capacity.Limited(reason) -> BudgetLimited(reason)
    capacity.Closed -> AncestorStopping
    capacity.Unavailable(reason) -> BudgetUnavailable(reason)
  }
}

pub fn admit(
  runs: store.Store,
  work: live.Work,
  options: Options,
  state: g.State,
  activation: g.Activation,
) -> Result(live.Admission, AdmissionError) {
  use _ <- result.try(
    capacity.work(
      runs,
      state.run,
      state.parent,
      state.family_budget,
      reservations.GraphAttempt(state.run, activation.id, activation.attempt),
    )
    |> result.map_error(capacity_error),
  )
  use admitted <- result.try(
    bounded.call(options.callback_timeout, fn() {
      use _ <- result.try(case activation.prepared.kind {
        operation.Subgraph | operation.Agent ->
          checked_child(runs, work, activation) |> result.replace(Nil)
        operation.Fork(..) ->
          checked_fork(runs, work, activation) |> result.replace(Nil)
        operation.Activity
        | operation.Signal
        | operation.Job(_)
        | operation.OwnedJob(_) -> Ok(Nil)
      })
      work().admit(state, activation)
    })
    |> result.map_error(string.inspect)
    |> result.flatten
    |> result.map_error(PolicyRejected),
  )
  let starts = case admitted.decision, state.phase {
    policy.Allow, _ -> True
    policy.RequireApproval(requirement), g.AwaitingApproval(_, approval) ->
      requirement == approval.requirement
    _, _ -> False
  }
  use _ <- result.try(case starts, activation.prepared.kind {
    True, operation.Agent | True, operation.Subgraph ->
      capacity.child(
        runs,
        state.run,
        state.parent,
        state.family_budget,
        attachment.reserved_id(state.run, activation.id),
      )
      |> result.map_error(capacity_error)
    _, _ -> Ok(Nil)
  })
  Ok(admitted)
}

pub fn check_ancestry(runs: store.Store, state: g.State) -> Result(Nil, Error) {
  case ancestry.read(runs, state.run, state.parent, 64) {
    Ok(True) -> Ok(Nil)
    Ok(False) -> Error(AncestorClosed)
    Error(error) -> Error(CallbackFailed(string.inspect(error)))
  }
}

pub fn owner(
  entry: store.Entry,
  state: g.State,
) -> Option(Subject(live.Message)) {
  case entry.live {
    Some(store.GraphLive(incarnation:, mailbox:, ..))
      if incarnation == state.incarnation
    -> Some(mailbox)
    _ -> None
  }
}

pub fn held_elsewhere(entry: store.Entry) -> Bool {
  case entry.holding {
    store.HeldElsewhere(_, True) -> True
    _ -> False
  }
}

pub fn driven(entry: store.Entry, state: g.State) -> Bool {
  owner(entry, state) != None || held_elsewhere(entry)
}

type Go {
  Go(revision: Int, state: g.State)
  Abandon
}

type Runner {
  Runner(
    runs: store.Store,
    work: live.Work,
    options: Options,
    state: g.State,
    revision: Int,
    self: Subject(live.Message),
    factory: Pid,
    executor: Option(executor.Executor(g.Reference, live.Execution)),
    body: Option(live.Body),
    draining: Bool,
  )
}

/// Commits `state` (over `before`, at revision `expected`; a new record
/// when `None`), emits the commit's events, and starts a runner for its
/// `effects` when it needs one.
pub fn launch(
  runs: store.Store,
  work: live.Work,
  options: Options,
  expected: Option(#(Int, g.State)),
  state: g.State,
  effects: List(g.Effect),
  body: Option(live.Body),
  seize: Bool,
) -> Result(Int, Error) {
  let before = option.map(expected, fn(pair) { pair.1 })
  let expected = option.map(expected, fn(pair) { pair.0 })
  use encoded <- result.try(
    record.encode(state)
    |> result.map_error(fn(error) { CallbackFailed(string.inspect(error)) }),
  )
  case g.needs_runner(state) {
    False -> {
      let ownership = case state.phase {
        g.WaitingFork(a, _) -> park_fork(runs, work, options, state, a)
        g.WaitingChild(_, child) -> park(runs, work, options, state.run, child)
        _ -> store.Detached(False, seize)
      }
      write_initialized(runs, state, expected, encoded, ownership)
      |> result.map(fn(entry) {
        observe.committed(before, entry.1)
        entry.0
      })
    }
    True -> {
      let prepared =
        host.prepare(
          runs,
          fn(pinned, owners, ready) {
            begin(pinned, work, options, effects, body, owners, ready)
          },
          Abandon,
        )
      case prepared {
        Error(Nil) ->
          write_initialized(
            runs,
            state,
            expected,
            encoded,
            store.Detached(True, seize),
          )
          |> result.map(fn(entry) {
            observe.committed(before, entry.1)
            entry.0
          })
        Ok(#(pid, mailbox, go)) -> {
          let ownership =
            store.Launch(
              pid,
              store.GraphLive(
                state.incarnation,
                mailbox,
                state.root,
                state.correlation,
              ),
              seize,
            )
          case write_initialized(runs, state, expected, encoded, ownership) {
            Ok(#(revision, state)) -> {
              observe.committed(before, state)
              process.send(go, Go(revision, state))
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
}

fn write_initialized(
  runs: store.Store,
  state: g.State,
  expected: Option(Int),
  encoded: String,
  ownership: store.Ownership,
) -> Result(#(Int, g.State), Error) {
  use revision <- result.try(
    write(runs, state.run, expected, encoded, ownership)
    |> result.map_error(StoreFailed),
  )
  use declaration <- result.try(
    bootstrap.prepare(runs, state.run, state.parent, state.family_budget)
    |> result.map_error(StoreFailed),
  )
  case declaration == state.family_budget {
    True -> Ok(#(revision, state))
    False -> {
      let initialized = g.State(..state, family_budget: declaration)
      use encoded <- result.try(
        record.encode(initialized)
        |> result.map_error(fn(error) { CallbackFailed(string.inspect(error)) }),
      )
      use revision <- result.map(
        store.commit(runs, state.run, revision, encoded, ownership)
        |> result.map_error(StoreFailed),
      )
      #(revision, initialized)
    }
  }
}

fn write(
  runs: store.Store,
  id: String,
  expected: Option(Int),
  encoded: String,
  ownership: store.Ownership,
) -> Result(Int, backend.StoreError) {
  case expected {
    None -> store.insert(runs, id, encoded, ownership)
    Some(revision) -> store.commit(runs, id, revision, encoded, ownership)
  }
}

fn begin(
  runs: store.Store,
  work: live.Work,
  options: Options,
  effects: List(g.Effect),
  body: Option(live.Body),
  owners: #(Pid, Pid, Pid),
  ready: Subject(#(Subject(live.Message), Subject(Go))),
) -> Nil {
  let #(store_pid, factory, caller) = owners
  process.trap_exits(True)
  let self = process.new_subject()
  let go = process.new_subject()
  let _ = process.monitor(store_pid)
  let caller_monitor = process.monitor(caller)
  process.send(ready, #(self, go))
  case host.first_state(go, runs, factory, False) {
    Error(Nil) | Ok(#(Abandon, _)) -> Nil
    Ok(#(Go(revision, state), draining)) -> {
      process.demonitor_process(caller_monitor)
      let runner =
        Runner(
          runs,
          work,
          options,
          state,
          revision,
          self,
          factory,
          None,
          body,
          draining,
        )
      case perform(runner, effects) {
        Ok(runner) -> serve(runner)
        Error(_) -> stop(runner)
      }
    }
  }
}

fn stop(runner: Runner) -> Nil {
  case runner.executor {
    Some(executor) -> executor.stop(executor)
    None -> Nil
  }
}

fn draining(runner: Runner) -> Runner {
  case runner.draining || !host.take_shutdown(runner.factory) {
    True -> runner
    False -> {
      store.draining(runner.runs, runner.factory)
      Runner(..runner, draining: True)
    }
  }
}

fn active_body(state: g.State) -> Bool {
  case state.phase {
    g.Running(_) | g.Stopping(_) | g.StoppingJob(_, job.RequestStarted, _) ->
      True
    _ -> False
  }
}

fn serve(runner: Runner) -> Nil {
  let runner = draining(runner)
  case
    g.needs_runner(runner.state),
    runner.draining && !active_body(runner.state)
  {
    False, _ -> stop(runner)
    True, True -> {
      case persist(runner, runner.state, store.HandOff(process.self())) {
        Ok(_) -> Nil
        Error(_) -> store.handoff_failed(runner.runs, process.self())
      }
      stop(runner)
    }
    True, False -> receive(runner)
  }
}

fn persist(
  runner: Runner,
  state: g.State,
  ownership: store.Ownership,
) -> Result(Runner, Error) {
  use encoded <- result.try(
    record.encode(state)
    |> result.map_error(fn(error) { CallbackFailed(string.inspect(error)) }),
  )
  use revision <- result.try(
    store.commit(runner.runs, state.run, runner.revision, encoded, ownership)
    |> result.map_error(StoreFailed),
  )
  observe.committed(Some(runner.state), state)
  Ok(Runner(..runner, state:, revision:))
}

fn transition(
  runner: Runner,
  event: g.Event,
) -> Result(#(Runner, List(g.Effect)), Error) {
  use #(state, effects) <- result.try(
    g.step(runner.state, event) |> result.map_error(Refused),
  )
  let ownership = case state.phase, g.needs_runner(state) {
    g.WaitingFork(a, _), _ ->
      park_fork(runner.runs, runner.work, runner.options, state, a)
    g.WaitingChild(_, id), _ ->
      park(runner.runs, runner.work, runner.options, state.run, id)
    _, True -> store.Keep
    _, False -> store.Leave(process.self())
  }
  use runner <- result.try(persist(runner, state, ownership))
  Ok(#(runner, effects))
}

fn apply(runner: Runner, event: g.Event) -> Result(Runner, Error) {
  use #(runner, effects) <- result.try(transition(runner, event))
  perform(runner, effects)
}

fn perform(runner: Runner, effects: List(g.Effect)) -> Result(Runner, Error) {
  list.try_fold(effects, runner, fn(runner, effect) {
    let runner = draining(runner)
    case effect, runner.draining {
      g.Inspect(_), True
      | g.ArmWait(_), True
      | g.Dispatch(_), True
      | g.ObserveChild(_, _), True
      | g.CancelChild(_, _), True
      | g.RequestJobStop(_), True
      | g.PrepareFork(_), True
      | g.ObserveFork(_), True
      -> Ok(runner)
      g.PrepareFork(a), False -> {
        use <- with_wait_deadline(runner, a, False)
        let prepared =
          bounded.call(runner.options.callback_timeout, fn() {
            use driver <- result.try(checked_fork(runner.runs, runner.work, a))
            driver.prepare(a.prepared.input)
          })
          |> result.map_error(string.inspect)
          |> result.flatten
        use <- with_wait_deadline(runner, a, False)
        apply(runner, g.ForkPrepared(g.reference(runner.state, a), prepared))
      }
      g.ObserveFork(_), False -> {
        process.send(runner.self, live.PollFork)
        Ok(runner)
      }
      g.ArmWait(activation), False -> {
        use now <- result.try(
          store.now(runner.runs) |> result.map_error(StoreFailed),
        )
        apply(runner, g.WaitArmed(g.reference(runner.state, activation), now))
      }
      g.Inspect(activation), False -> {
        use #(event, body) <- result.try(
          case
            admit(
              runner.runs,
              runner.work,
              runner.options,
              runner.state,
              activation,
            )
          {
            Ok(live.Admission(decision, body)) -> {
              use expires <- result.map(deadline_for(
                runner.runs,
                runner.options,
                Ok(decision),
              ))
              #(
                g.Inspected(
                  g.reference(runner.state, activation),
                  Ok(decision),
                  expires,
                ),
                Some(body),
              )
            }
            Error(PolicyRejected(reason)) ->
              Ok(#(
                g.Inspected(
                  g.reference(runner.state, activation),
                  Error(reason),
                  None,
                ),
                None,
              ))
            // The ancestor closed between this run's start and its
            // admission: its cancellation is on its way, and the run ends
            // the same way now instead of failing its policy.
            Error(AncestorStopping) -> Ok(#(g.Cancel, None))
            Error(BudgetLimited(reason)) ->
              Ok(#(
                g.BudgetRefused(g.reference(runner.state, activation), reason),
                None,
              ))
            Error(BudgetUnavailable(reason)) ->
              Error(StoreFailed(backend.Unavailable(reason)))
          },
        )
        apply(Runner(..runner, body:), event)
      }
      g.Dispatch(activation), False -> {
        use body <- result.try(case runner.body {
          Some(body) -> Ok(body)
          None -> Error(CallbackFailed("admitted operation has no bound body"))
        })
        let executor = case runner.executor {
          Some(executor) -> executor
          None -> start_executor(runner)
        }
        executor.submit(executor, [
          // The executor kills a body still running at the operation
          // timeout and reports it `TimedOut`: an uncertain effect.
          executor.Job(
            g.reference(runner.state, activation),
            fn() { live.Returned(body()) },
            runner.options.operation_timeout,
          ),
        ])
        Ok(Runner(..runner, executor: Some(executor), body: None))
      }
      g.RequestJobStop(activation), False -> {
        use body <- result.try(
          bounded.call(runner.options.callback_timeout, fn() {
            use _ <- result.try(runner.work().validate(runner.state))
            Ok(runner.work().cancel_job(runner.state, activation))
          })
          |> result.map_error(fn(error) {
            CallbackFailed(string.inspect(error))
          })
          |> result.try(fn(reply) { reply |> result.map_error(Incompatible) }),
        )
        perform(Runner(..runner, body: Some(body)), [g.Dispatch(activation)])
      }
      g.ObserveChild(_, _), False | g.CancelChild(_, _), False -> {
        process.send(runner.self, live.PollChild)
        Ok(runner)
      }
      g.Stop, _ -> {
        case runner.executor {
          Some(executor) -> {
            executor.stop(executor)
            Ok(runner)
          }
          None -> apply(runner, g.Stopped)
        }
      }
    }
  })
}

fn start_executor(
  runner: Runner,
) -> executor.Executor(g.Reference, live.Execution) {
  let mailbox = runner.self
  executor.start(
    executor.Hooks(
      1,
      fn(ref) {
        let reply = process.new_subject()
        process.send(mailbox, live.Fence(ref, reply))
        process.receive_forever(reply)
      },
      fn(report) { process.send(mailbox, live.Executed(report)) },
    ),
  )
}

fn receive(runner: Runner) -> Nil {
  let received =
    process.new_selector()
    |> process.select(runner.self)
    |> process.select_monitors(fn(_) { live.StoreDown })
    |> process.select_trapped_exits(fn(exit) {
      live.Exited(exit.pid, exit.reason)
    })
    |> process.selector_receive_forever
  let runner = draining(runner)
  let next = case received {
    live.PollFork -> poll_fork(runner)
    live.PollChild -> poll_child(runner)
    live.StoreDown -> Error(OwnerUnknown)
    live.Exited(pid, reason) if pid == runner.factory -> {
      case host.is_shutdown(reason) {
        True -> {
          store.draining(runner.runs, runner.factory)
          Ok(Runner(..runner, draining: True))
        }
        False -> Error(OwnerUnknown)
      }
    }
    live.Exited(_, process.Normal) -> Ok(runner)
    live.Exited(_, reason) -> {
      case runner.state.phase {
        g.Running(a)
        | g.Stopping(a)
        | g.StoppingJob(a, job.RequestStarted, _) ->
          apply(
            Runner(..runner, executor: None),
            g.Unresolved(
              g.reference(runner.state, a),
              g.Uncertain("executor lost: " <> string.inspect(reason)),
            ),
          )
        _ -> Error(OwnerUnknown)
      }
    }
    live.Fence(_, reply) if runner.draining -> {
      process.send(reply, False)
      Ok(runner)
    }
    live.Fence(ref, reply) -> {
      let next = {
        use _ <- result.try(case runner.state.phase {
          // The retained owned admission authorizes cleanup after ancestors
          // close. The start fence still requires compatible deployed code.
          g.StoppingJob(_, job.RequestQueued, _) ->
            bounded.call(runner.options.callback_timeout, fn() {
              runner.work().validate(runner.state)
            })
            |> result.map_error(fn(error) {
              CallbackFailed(string.inspect(error))
            })
            |> result.try(fn(reply) { reply |> result.map_error(Incompatible) })
          _ -> check_ancestry(runner.runs, runner.state)
        })
        transition(runner, g.BodyStarted(ref))
      }
      process.send(reply, result.is_ok(next))
      next |> result.map(fn(next) { next.0 })
    }
    live.Executed(executor.Reported(ref, execution)) ->
      settle(runner, ref, execution)
    live.Executed(executor.Crashed(ref, reason))
    | live.Executed(executor.Lost(ref, reason)) ->
      apply(runner, g.Unresolved(ref, g.Uncertain(reason)))
    live.Executed(executor.TimedOut(ref, after)) ->
      apply(
        runner,
        g.Unresolved(
          ref,
          g.Uncertain("timed out after " <> int.to_string(after) <> " ms"),
        ),
      )
    live.Executed(executor.Stopped) ->
      apply(Runner(..runner, executor: None), g.Stopped)
    live.Cancel(command, reply) -> {
      case claim.accept(command) {
        False -> Ok(runner)
        True -> {
          process.send(reply, live.Accepted)
          case transition(runner, g.Cancel) {
            Ok(#(runner, effects)) -> {
              process.send(reply, live.Applied(runner.state))
              perform(runner, effects)
            }
            Error(Refused(reason)) -> {
              process.send(reply, live.Refused(reason))
              Error(Refused(reason))
            }
            Error(error) -> {
              process.send(reply, live.Superseded)
              Error(error)
            }
          }
        }
      }
    }
  }
  case next {
    Ok(runner) -> serve(runner)
    Error(Refused(_)) -> serve(runner)
    Error(_) -> stop(runner)
  }
}

fn with_wait_deadline(
  runner: Runner,
  a: g.Activation,
  stopping: Bool,
  next: fn() -> Result(Runner, Error),
) -> Result(Runner, Error) {
  use due <- result.try(case stopping {
    True -> Ok(None)
    False -> wait_due(runner.runs, a)
  })
  case due {
    None -> next()
    Some(now) -> apply(runner, g.ExpireWait(g.reference(runner.state, a), now))
  }
}

fn poll_child(runner: Runner) -> Result(Runner, Error) {
  let state = runner.state
  use #(a, id, stopping) <- result.try(case state.phase {
    g.Joining(a, id) -> Ok(#(a, id, False))
    g.StoppingChild(a, id, _) -> Ok(#(a, id, True))
    _ -> Error(Refused(g.WrongPhase))
  })
  use <- with_wait_deadline(runner, a, stopping)
  let parent = child.Parent(state.run, a.id)
  let checked =
    bounded.call(runner.options.callback_timeout, fn() {
      use driver <- result.try(checked_child(runner.runs, runner.work, a))
      use _ <- result.try(
        driver.reserve(parent, id, a.prepared.input, case stopping {
          True -> child_driver.Cancel
          False -> child_driver.Start
        }),
      )
      driver.read(parent, id, case stopping {
        True -> child_driver.Settle
        False -> child_driver.Observe
      })
    })
    |> result.map_error(string.inspect)
    |> result.flatten
  use <- with_wait_deadline(runner, a, stopping)
  let ref = g.reference(state, a)
  case checked, stopping {
    Ok(child.Approval(_)), False
    | Ok(child.AgentInput(..)), False
    | Ok(child.Signal(_)), False
    | Ok(child.Job(_)), False
    | Ok(child.Fork(_)), False
    -> apply(runner, g.ChildWaiting(ref, id))
    Error(reason), False
    | Ok(child.Uncertain(reason)), False
    | Ok(child.FinishedUncertain(reason)), False
    -> apply(runner, g.ChildUnavailable(ref, id, reason))
    Ok(child.Cancelled(True)), False ->
      apply(
        runner,
        g.ChildUnavailable(
          ref,
          id,
          "child cancellation retains uncertain effects",
        ),
      )
    Ok(child.Succeeded(output)), False -> {
      let accepted =
        bounded.call(runner.options.callback_timeout, fn() {
          runner.work().accept(state, a, output)
        })
      use <- with_wait_deadline(runner, a, False)
      case accepted {
        Ok(Ok(decision)) ->
          apply(runner, g.ChildReturned(ref, id, output, decision))
        error ->
          apply(
            runner,
            g.ChildMappingFailed(ref, id, output, string.inspect(error)),
          )
      }
    }
    Ok(child.InvalidOutput(output, reason)), False ->
      apply(runner, g.ChildMappingFailed(ref, id, output, reason))
    Ok(child.Failed(reason)), False ->
      apply(runner, g.ChildFailed(ref, id, reason))
    Ok(child.Cancelled(False)), False ->
      apply(runner, g.ChildFailed(ref, id, "child was cancelled"))
    Ok(child.Cancelled(uncertain)), True ->
      apply(runner, g.ChildStopped(ref, id, uncertain))
    Ok(child.FinishedUncertain(_)), True ->
      apply(runner, g.ChildStopped(ref, id, True))
    Ok(child.Fork(_)), True -> apply(runner, g.ChildStopped(ref, id, True))
    Ok(child.InvalidOutput(..)), True ->
      apply(runner, g.ChildStopped(ref, id, False))
    Ok(child.Succeeded(_)), True | Ok(child.Failed(_)), True ->
      apply(runner, g.ChildStopped(ref, id, False))
    _, _ -> {
      let _ = process.send_after(runner.self, 100, live.PollChild)
      Ok(runner)
    }
  }
}

fn settle(
  runner: Runner,
  ref: g.Reference,
  execution: live.Execution,
) -> Result(Runner, Error) {
  case runner.state.phase {
    g.Running(a) | g.Stopping(a) | g.StoppingJob(a, job.RequestStarted, _) ->
      case ref == g.reference(runner.state, a) {
        True ->
          apply(
            runner,
            result_event(
              runner.work,
              runner.options,
              runner.state,
              a,
              ref,
              execution,
            ),
          )
        False -> Error(Refused(g.StaleInvocation))
      }
    _ -> Error(Refused(g.StaleInvocation))
  }
}

pub fn checked_fork(
  runs: store.Store,
  work: live.Work,
  activation: g.Activation,
) -> Result(fork_driver.Driver, String) {
  use driver <- result.try(
    work().fork(activation) |> result.map_error(string.inspect),
  )
  use parent_store <- result.try(
    store.pid(runs) |> result.replace_error("parent store unavailable"),
  )
  case list.all(driver.stores(), fn(found) { found == Ok(parent_store) }) {
    True -> Ok(driver)
    False -> Error("every fork member must use its parent's store")
  }
}

fn poll_fork(runner: Runner) -> Result(Runner, Error) {
  use a <- result.try(case runner.state.phase {
    g.Forking(a, _) -> Ok(a)
    _ -> Error(Refused(g.WrongPhase))
  })
  use driver <- result.try(
    checked_fork(runner.runs, runner.work, a)
    |> result.map_error(CallbackFailed),
  )
  use members <- result.try(
    g.current_fork(runner.state, a.id) |> result.map_error(Refused),
  )
  use #(runner, working) <- result.try(
    list.try_fold(scope.unsettled(members), #(runner, False), fn(acc, member) {
      use #(runner, working) <- result.map(observe_fork_member(
        acc.0,
        a,
        driver,
        member,
      ))
      #(runner, acc.1 || working)
    }),
  )
  use #(runner, working) <- result.try(admit_fork_members(
    runner,
    a,
    driver,
    working,
  ))
  use runner <- result.try(expire_fork_if_due(runner, a))
  let assert g.Forking(_, mode) = runner.state.phase
  use members <- result.try(
    g.current_fork(runner.state, a.id) |> result.map_error(Refused),
  )
  case scope.join(members), mode {
    scope.Ready(_), g.ClosingFork(_) ->
      apply(runner, g.ForkStopped(g.reference(runner.state, a)))
    scope.Ready(_), g.JoiningFork -> {
      let encoded =
        bounded.call(runner.options.callback_timeout, fn() {
          fork_driver.encode_join(scope.snapshot(members), driver.output)
        })
        |> result.map_error(string.inspect)
        |> result.flatten
      use <- with_wait_deadline(runner, a, False)
      case encoded {
        Error(reason) ->
          apply(
            runner,
            g.ForkMappingFailed(g.reference(runner.state, a), "", reason),
          )
        Ok(output) -> {
          let accepted =
            bounded.call(runner.options.callback_timeout, fn() {
              runner.work().accept(runner.state, a, output)
            })
          use <- with_wait_deadline(runner, a, False)
          case accepted {
            Ok(Ok(decision)) ->
              apply(
                runner,
                g.ForkReturned(g.reference(runner.state, a), output, decision),
              )
            error ->
              apply(
                runner,
                g.ForkMappingFailed(
                  g.reference(runner.state, a),
                  output,
                  string.inspect(error),
                ),
              )
          }
        }
      }
    }
    _, _ ->
      case working {
        True -> {
          let _ = process.send_after(runner.self, 100, live.PollFork)
          Ok(runner)
        }
        False -> apply(runner, g.ForkWaiting(g.reference(runner.state, a)))
      }
  }
}

fn admit_fork_members(
  runner: Runner,
  a: g.Activation,
  driver: fork_driver.Driver,
  working: Bool,
) -> Result(#(Runner, Bool), Error) {
  use runner <- result.try(expire_fork_if_due(runner, a))
  use members <- result.try(
    g.current_fork(runner.state, a.id) |> result.map_error(Refused),
  )
  case scope.next(members) {
    None -> Ok(#(runner, working))
    Some(member) -> {
      use _ <- result.try(check_ancestry(runner.runs, runner.state))
      let capacity =
        capacity.child(
          runner.runs,
          runner.state.run,
          runner.state.parent,
          runner.state.family_budget,
          attachment.branch_id(runner.state.run, a.id, member.member),
        )
      case capacity {
        Error(error) ->
          case capacity_error(error) {
            BudgetLimited(reason) -> {
              use runner <- result.map(apply(
                runner,
                g.ForkRejected(
                  g.reference(runner.state, a),
                  member,
                  string.inspect(reason),
                ),
              ))
              // Re-observe admitted siblings under the now-retained stop intent.
              let _ = process.send_after(runner.self, 0, live.PollFork)
              #(runner, True)
            }
            BudgetUnavailable(reason) | PolicyRejected(reason) ->
              Error(CallbackFailed(reason))
            AncestorStopping -> Error(AncestorClosed)
          }
        Ok(_) -> {
          use runner <- result.try(expire_fork_if_due(runner, a))
          case runner.state.phase {
            g.Forking(_, g.ClosingFork(_)) -> Ok(#(runner, True))
            _ -> {
              use runner <- result.try(apply(
                runner,
                g.ForkAdmitted(g.reference(runner.state, a), member),
              ))
              use #(runner, active) <- result.try(observe_fork_member(
                runner,
                a,
                driver,
                member,
              ))
              admit_fork_members(runner, a, driver, working || active)
            }
          }
        }
      }
    }
  }
}

fn observe_fork_member(
  runner: Runner,
  a: g.Activation,
  driver: fork_driver.Driver,
  reference: fork.Reference,
) -> Result(#(Runner, Bool), Error) {
  use runner <- result.try(expire_fork_if_due(runner, a))
  use members <- result.try(
    g.current_fork(runner.state, a.id) |> result.map_error(Refused),
  )
  use member <- result.try(
    scope.member(members, reference)
    |> result.map_error(fn(error) { CallbackFailed(string.inspect(error)) }),
  )
  let stopping = scope.snapshot(members).stop != None
  let id = attachment.branch_id(runner.state.run, a.id, reference.member)
  let parent = child.Branch(runner.state.run, a.id, reference.member)
  use progress <- result.try(
    bounded.call(runner.options.callback_timeout, fn() {
      use child_driver <- result.try(driver.member(reference.member))
      use _ <- result.try(driver.check(reference.member, member.request))
      use _ <- result.try(case member.status {
        // Only an unacknowledged reservation may create a missing child.
        fork.Reserved -> Ok(Nil)
        _ ->
          store.get(runner.runs, id)
          |> result.replace(Nil)
          |> result.map_error(string.inspect)
      })
      use _ <- result.try(
        child_driver.reserve(parent, id, member.request.input, case stopping {
          True -> child_driver.Cancel
          False -> child_driver.Start
        }),
      )
      use _ <- result.try(
        store.get(runner.runs, id) |> result.map_error(string.inspect),
      )
      child_driver.read(parent, id, case stopping {
        True -> child_driver.Settle
        False -> child_driver.Observe
      })
    })
    |> result.map_error(string.inspect)
    |> result.flatten
    |> result.map_error(CallbackFailed),
  )
  let observed = fork_driver.progress(progress)
  use runner <- result.map(case member.status == fork.Admitted(observed) {
    True -> Ok(runner)
    False ->
      apply(
        runner,
        g.ForkObserved(g.reference(runner.state, a), reference, observed),
      )
  })
  let stopped_now =
    !stopping
    && case g.current_fork(runner.state, a.id) {
      Ok(scope) -> scope.snapshot(scope).stop != None
      Error(_) -> False
    }
  #(runner, progress == child.Working || stopped_now)
}

/// Close admission before inspecting or starting another member. A recorded
/// first member failure does not replace the parent's eventual deadline cause.
fn expire_fork_if_due(
  runner: Runner,
  a: g.Activation,
) -> Result(Runner, Error) {
  case runner.state.phase {
    g.Forking(_, g.JoiningFork) ->
      with_wait_deadline(runner, a, False, fn() { Ok(runner) })
    _ -> Ok(runner)
  }
}

fn park_fork(
  runs: store.Store,
  work: live.Work,
  options: Options,
  state: g.State,
  a: g.Activation,
) -> store.Ownership {
  let dependencies = case g.current_fork(state, a.id) {
    Ok(members) ->
      scope.unsettled(members)
      |> list.map(fn(ref) { attachment.branch_id(state.run, a.id, ref.member) })
    Error(_) -> []
  }
  store.Park(dependencies, fn() {
    wake_fork(runs, work, options, state.run)
    |> result.unwrap(store.KeepWatching)
  })
}

/// Read-only inspection shared by local wakeups and the public waiting view.
pub fn fork_has_activity(
  runs: store.Store,
  work: live.Work,
  state: g.State,
  a: g.Activation,
) -> Result(Bool, String) {
  use members <- result.try(
    g.current_fork(state, a.id) |> result.map_error(string.inspect),
  )
  use driver <- result.try(checked_fork(runs, work, a))
  use observed <- result.map(
    list.try_map(scope.unsettled(members), fn(ref) {
      use member <- result.try(
        scope.member(members, ref) |> result.map_error(string.inspect),
      )
      use driver <- result.try(driver.member(ref.member))
      let child = attachment.branch_id(state.run, a.id, ref.member)
      use _ <- result.try(
        store.get(runs, child) |> result.map_error(string.inspect),
      )
      use progress <- result.map(
        driver.read(
          child.Branch(state.run, a.id, ref.member),
          child,
          case scope.snapshot(members).stop {
            None -> child_driver.Observe
            Some(_) -> child_driver.Settle
          },
        ),
      )
      progress == child.Working
      || member.status != fork.Admitted(fork_driver.progress(progress))
    }),
  )
  list.any(observed, fn(changed) { changed })
}

fn wake_fork(
  runs: store.Store,
  work: live.Work,
  options: Options,
  id: String,
) -> Result(store.WakeupDisposition, Error) {
  use #(entry, state) <- result.try(load(runs, work, options, id))
  case state.phase {
    g.WaitingFork(a, _) -> {
      use changed <- result.try(
        bounded.call(options.callback_timeout, fn() {
          fork_has_activity(runs, work, state, a)
        })
        |> result.map_error(string.inspect)
        |> result.flatten
        |> result.map_error(CallbackFailed),
      )
      case changed {
        False -> Ok(store.KeepWatching)
        True ->
          recover_work(runs, work, options, entry, state, 3)
          |> result.replace(store.KeepWatching)
      }
    }
    _ -> Ok(store.StopWatching)
  }
}

fn result_event(
  work: live.Work,
  options: Options,
  state: g.State,
  activation: g.Activation,
  ref: g.Reference,
  execution: live.Execution,
) -> g.Event {
  case state.phase, execution {
    g.StoppingJob(_, _, _), live.Returned(Ok(_)) -> g.JobStopRequested(ref)
    g.StoppingJob(_, _, _),
      live.Returned(Error(definition.OperationRejected(operation.BodyFailed(tool.Explain(
        reason,
      )))))
    -> g.JobStopRefused(ref, reason)
    g.StoppingJob(_, _, _), live.Interrupted(reason)
    | g.StoppingJob(_, _, _),
      live.Returned(Error(definition.OperationRejected(operation.BodyFailed(tool.Uncertain(
        reason,
      )))))
    -> g.Unresolved(ref, g.Uncertain(reason))
    g.StoppingJob(_, _, _), result ->
      g.Unresolved(ref, g.Uncertain(string.inspect(result)))
    _, execution ->
      ordinary_result_event(work, options, state, activation, ref, execution)
  }
}

fn ordinary_result_event(
  work: live.Work,
  options: Options,
  state: g.State,
  activation: g.Activation,
  ref: g.Reference,
  execution: live.Execution,
) -> g.Event {
  case execution {
    live.Interrupted(reason) -> g.Unresolved(ref, g.Uncertain(reason))
    live.Returned(Error(definition.OperationRejected(operation.BodyFailed(tool.Explain(
      reason,
    ))))) -> g.FailedBody(ref, g.OperationFailed(reason))
    live.Returned(Error(definition.OperationRejected(operation.BodyFailed(tool.Uncertain(
      reason,
    ))))) -> g.Unresolved(ref, g.Uncertain(reason))
    live.Returned(Error(definition.OperationRejected(operation.OutputEncodingFailed(
      evidence,
      error,
    )))) -> g.Unresolved(ref, g.InvalidResult(evidence, string.inspect(error)))
    live.Returned(Error(error)) ->
      g.FailedBody(ref, g.OperationFailed(string.inspect(error)))
    live.Returned(Ok(output)) ->
      completion_event(work, options, state, activation, output, False)
  }
}

/// Callback failures keep the original output, never repeat its operation.
pub fn completion_event(
  work: live.Work,
  options: Options,
  state: g.State,
  activation: g.Activation,
  output: String,
  reconciliation: Bool,
) -> g.Event {
  let ref = g.reference(state, activation)
  let cancelled = case state.phase {
    g.Stopping(_) | g.StoppingJob(..) | g.Ended(g.Cancelled(_, _)) -> True
    _ -> False
  }
  case cancelled {
    True -> {
      let checked =
        bounded.call(options.callback_timeout, fn() {
          work().check_output(activation, output)
        })
      case checked {
        Ok(Ok(Nil)) -> g.CancelledResult(ref, output)
        error ->
          g.Unresolved(ref, g.InvalidResult(output, string.inspect(error)))
      }
    }
    False -> {
      case
        bounded.call(options.callback_timeout, fn() {
          work().accept(state, activation, output)
        })
      {
        Ok(Ok(decision)) ->
          case reconciliation {
            True ->
              g.Reconciled(activation.id, activation.attempt, output, decision)
            False -> g.Returned(ref, output, decision)
          }
        error ->
          g.Unresolved(ref, g.InvalidResult(output, string.inspect(error)))
      }
    }
  }
}

/// A sweep may reach free ancestors or descendants of its claimed candidate.
/// Inspect those waits without rewriting them: a rewrite would itself make the
/// next ancestor scan eligible again, even though no business work changed.
pub fn discover(
  runs: store.Store,
  work: live.Work,
  options: Options,
  id: String,
  tries: Int,
) -> Result(g.State, Error) {
  use #(entry, state) <- result.try(load(runs, work, options, id))
  let inspect_child =
    driven(entry, state)
    || case state.phase {
      g.WaitingChild(..) | g.ChildBlocked(..) -> True
      _ -> False
    }
  use due <- result.try(case driven(entry, state) {
    True -> Ok(None)
    False -> managed_due(runs, state)
  })
  use expiring <- result.try(approval_due(runs, state))
  let outcome = case due, expiring {
    Some(_), _ | _, Some(_) ->
      recover_abandoned(runs, work, options, entry, state, 1)
    None, None ->
      case state.phase {
        g.WaitingFork(a, _) ->
          discover_fork(runs, work, options, entry, state, a)
        g.Forking(a, _) if inspect_child ->
          discover_fork(runs, work, options, entry, state, a)
        g.WaitingSignal(_) ->
          case driven(entry, state) {
            True -> Ok(state)
            False -> recover_abandoned(runs, work, options, entry, state, 1)
          }
        g.StoppingJob(_, job.RequestQueued, _)
        | g.StoppingJob(_, job.RequestStarted, _) ->
          case driven(entry, state) {
            True -> Ok(state)
            False -> recover_work(runs, work, options, entry, state, 1)
          }
        g.WaitingJob(a) | g.StoppingJob(a, _, _) ->
          discover_job(runs, work, options, entry, state, a)
        g.Joining(a, child)
          | g.WaitingChild(a, child)
          | g.ChildBlocked(a, child, _)
          | g.StoppingChild(a, child, _)
          if inspect_child
        -> {
          use progress <- result.try(
            bounded.call(options.callback_timeout, fn() {
              use _ <- result.try(
                store.get(runs, child) |> result.map_error(string.inspect),
              )
              use driver <- result.try(checked_child(runs, work, a))
              let mode = case state.phase {
                g.StoppingChild(..) -> child_driver.Cancel
                _ -> child_driver.Discover
              }
              use _ <- result.try(driver.reserve(
                child.Parent(state.run, a.id),
                child,
                a.prepared.input,
                mode,
              ))
              driver.read(
                child.Parent(state.run, a.id),
                child,
                child_driver.Observe,
              )
            })
            |> result.map_error(string.inspect)
            |> result.flatten
            |> result.map_error(CallbackFailed),
          )
          case driven(entry, state) {
            True -> Ok(state)
            False ->
              case resting_child(state.phase, progress), entry.holding {
                Some(_), store.Unheld -> Ok(state)
                Some(phase), _ ->
                  commit_recovery(
                    runs,
                    work,
                    options,
                    entry,
                    state,
                    g.State(
                      ..state,
                      phase: phase,
                      incarnation: state.incarnation + 1,
                    ),
                    [],
                    1,
                  )
                None, _ -> recover_work(runs, work, options, entry, state, 1)
              }
          }
        }
        g.Ended(g.Cancelled(a, g.UnresolvedCancellation(_)))
          | g.Ended(g.Expired(a, g.UnresolvedCancellation(_)))
          if {
            a.prepared.kind == operation.Subgraph
            || a.prepared.kind == operation.Agent
          }
        -> settle_child(runs, work, options, entry, state, a, 1, True)
        _ -> recover_work(runs, work, options, entry, state, 1)
      }
  }
  case outcome {
    Error(StoreFailed(backend.Conflict(_))) if tries > 1 ->
      discover(runs, work, options, id, tries - 1)
    other -> other
  }
}

/// A claimed fork follows its existing members. Unchanged unclaimed ancestors
/// stay read-only, so nested discovery can converge instead of waking itself.
fn discover_fork(
  runs: store.Store,
  work: live.Work,
  options: Options,
  entry: store.Entry,
  state: g.State,
  a: g.Activation,
) -> Result(g.State, Error) {
  use changed <- result.try(
    bounded.call(options.callback_timeout, fn() {
      use members <- result.try(
        g.current_fork(state, a.id) |> result.map_error(string.inspect),
      )
      use driver <- result.try(checked_fork(runs, work, a))
      use _ <- result.try(
        list.try_each(scope.unsettled(members), fn(ref) {
          use member <- result.try(
            scope.member(members, ref) |> result.map_error(string.inspect),
          )
          use binding <- result.try(driver.member(ref.member))
          let id = attachment.branch_id(state.run, a.id, ref.member)
          case store.get(runs, id), member.status {
            Error(backend.NotFound), fork.Reserved -> Ok(Nil)
            Error(error), _ -> Error(string.inspect(error))
            Ok(_), _ -> {
              let parent = child.Branch(state.run, a.id, ref.member)
              use _ <- result.try(case scope.snapshot(members).stop {
                None -> Ok(Nil)
                Some(_) ->
                  binding.reserve(
                    parent,
                    id,
                    member.request.input,
                    child_driver.Cancel,
                  )
              })
              binding.reserve(
                parent,
                id,
                member.request.input,
                child_driver.Discover,
              )
            }
          }
        }),
      )
      case driven(entry, state) {
        True -> Ok(False)
        False -> fork_has_activity(runs, work, state, a)
      }
    })
    |> result.map_error(string.inspect)
    |> result.flatten
    |> result.map_error(CallbackFailed),
  )
  case driven(entry, state), changed, entry.holding {
    True, _, _ -> Ok(state)
    False, False, store.Unheld -> Ok(state)
    False, False, _ ->
      commit_recovery(
        runs,
        work,
        options,
        entry,
        state,
        g.State(..state, incarnation: state.incarnation + 1),
        [],
        1,
      )
    False, True, _ -> recover_work(runs, work, options, entry, state, 1)
  }
}

fn discover_job(
  runs: store.Store,
  work: live.Work,
  options: Options,
  entry: store.Entry,
  state: g.State,
  a: g.Activation,
) -> Result(g.State, Error) {
  use due <- result.try(case state.phase, driven(entry, state) {
    g.WaitingJob(_), False -> wait_due(runs, a)
    _, _ -> Ok(None)
  })
  case due {
    Some(_) -> recover_abandoned(runs, work, options, entry, state, 1)
    None ->
      case a.prepared.kind, entry.holding {
        operation.Job(job.Every(_)), store.HeldHere
        | operation.OwnedJob(job.Every(_)), store.HeldHere
        -> {
          use reserved <- result.try(
            store.reserve_job_observation(runs, state.run)
            |> result.map_error(StoreFailed),
          )
          case reserved {
            False -> Ok(state)
            True -> {
              let outcome =
                observe_claimed_job(runs, work, options, entry, state, a)
              store.release_job_observation(runs, state.run)
              outcome
            }
          }
        }
        _, store.HeldHere ->
          commit_recovery(
            runs,
            work,
            options,
            entry,
            state,
            g.State(..state, incarnation: state.incarnation + 1),
            [],
            1,
          )
        _, _ -> Ok(state)
      }
  }
}

/// A pending read and release of its claim share one local reservation. A
/// concurrent parent discovery must neither repeat the read nor release that
/// claim while its observer is still running. Failed reads retain the claim's
/// expiry path; process loss releases the local reservation through monitoring.
fn observe_claimed_job(
  runs: store.Store,
  work: live.Work,
  options: Options,
  entry: store.Entry,
  state: g.State,
  a: g.Activation,
) -> Result(g.State, Error) {
  use observed <- result.try(observe_job_with(
    runs,
    work,
    options,
    job.Reference(
      run_id.from_string(state.run),
      a.id,
      a.attempt,
      a.prepared.operation,
    ),
    1,
    ScheduledObservation,
  ))
  case observed == state {
    True ->
      commit_recovery(
        runs,
        work,
        options,
        entry,
        state,
        g.State(..observed, incarnation: observed.incarnation + 1),
        [],
        1,
      )
    False -> Ok(observed)
  }
}

/// Retained idle states need no new child command. Keep changed uncertainty
/// evidence when acknowledging a claimed wait, without restarting observation.
fn resting_child(phase: g.Phase, progress: child.Progress) -> Option(g.Phase) {
  case phase, progress {
    g.WaitingChild(..), child.Approval(_)
    | g.WaitingChild(..), child.AgentInput(..)
    | g.WaitingChild(..), child.Signal(_)
    | g.WaitingChild(..), child.Job(_)
    | g.WaitingChild(..), child.Fork(_)
    -> Some(phase)
    g.ChildBlocked(a, id, _), child.Uncertain(reason)
    | g.ChildBlocked(a, id, _), child.FinishedUncertain(reason)
    -> Some(g.ChildBlocked(a, id, reason))
    g.ChildBlocked(a, id, _), child.Cancelled(True) ->
      Some(g.ChildBlocked(a, id, "child cancellation retains uncertain effects"))
    _, _ -> None
  }
}

/// A job poll observes only an already admitted receipt. Read-only callbacks
/// may repeat; only one conditional completion can release successor work.
pub fn observe_job(
  runs: store.Store,
  work: live.Work,
  options: Options,
  ref: job.Reference,
  tries: Int,
) -> Result(g.State, Error) {
  observe_job_with(runs, work, options, ref, tries, ManualObservation)
}

type Observation {
  ManualObservation
  ScheduledObservation
}

fn observe_job_with(
  runs: store.Store,
  work: live.Work,
  options: Options,
  ref: job.Reference,
  tries: Int,
  observation: Observation,
) -> Result(g.State, Error) {
  use #(entry, state) <- result.try(load(
    runs,
    work,
    options,
    run.id_to_string(ref.run),
  ))
  case
    list.find(state.receipts, fn(receipt) {
      job_matches(ref, receipt.activation)
    })
  {
    Ok(_) -> Ok(state)
    Error(_) -> {
      // Another discovery can release the claim between discover_job's read
      // and this reload. That old ownership does not authorize a new poll.
      case observation, entry.holding {
        ScheduledObservation, store.Unheld
        | ScheduledObservation, store.HeldElsewhere(..)
        -> Ok(state)
        ScheduledObservation, store.HeldHere | ManualObservation, _ ->
          observe_current_job(runs, work, options, ref, tries, entry, state)
      }
    }
  }
}

fn observe_current_job(
  runs: store.Store,
  work: live.Work,
  options: Options,
  ref: job.Reference,
  tries: Int,
  entry: store.Entry,
  state: g.State,
) -> Result(g.State, Error) {
  case state.phase {
    g.Ended(g.Expired(a, _))
    | g.Ended(g.Cancelled(a, g.JobStopped))
    | g.Ended(g.Cancelled(a, g.AfterFailure(g.OperationFailed(_)))) ->
      case job_matches(ref, a) {
        True -> Ok(state)
        False -> Error(Refused(g.StaleInvocation))
      }
    _ -> {
      use a <- result.try(case state.phase {
        g.StoppingJob(_, job.RequestQueued, _)
        | g.StoppingJob(_, job.RequestStarted, _) ->
          Error(Refused(g.WrongPhase))
        g.WaitingJob(a) | g.StoppingJob(a, _, _) ->
          case job_matches(ref, a) {
            True -> Ok(a)
            False -> Error(Refused(g.StaleInvocation))
          }
        _ -> Error(Refused(g.WrongPhase))
      })
      let stopping = case state.phase {
        g.StoppingJob(..) -> True
        _ -> False
      }
      use _ <- result.try(case stopping {
        True -> Ok(Nil)
        False -> check_ancestry(runs, state)
      })
      use due <- result.try(case stopping {
        True -> Ok(None)
        False -> wait_due(runs, a)
      })
      case due {
        Some(now) ->
          commit_job(
            runs,
            work,
            options,
            ref,
            tries,
            entry,
            state,
            g.ExpireWait(g.reference(state, a), now),
          )
        None ->
          read_job(runs, work, options, ref, tries, entry, state, a, stopping)
      }
    }
  }
}

fn read_job(
  runs: store.Store,
  work: live.Work,
  options: Options,
  ref: job.Reference,
  tries: Int,
  entry: store.Entry,
  state: g.State,
  a: g.Activation,
  stopping: Bool,
) -> Result(g.State, Error) {
  let observed =
    bounded.call(options.callback_timeout, fn() { work().observe_job(state, a) })
    |> result.map_error(string.inspect)
    |> result.try(fn(reply) { reply |> result.map_error(string.inspect) })
    |> result.map_error(CallbackFailed)
  use due <- result.try(case stopping {
    True -> Ok(None)
    False -> wait_due(runs, a)
  })
  case due {
    Some(now) -> {
      // A failed read has no terminal authority, but cannot extend the wait.
      let progress = result.unwrap(observed, job.Pending)
      let progress = case progress {
        job.Completed(output) ->
          case checked_job_output(work, options, a, output) {
            Ok(_) -> progress
            Error(_) -> job.Pending
          }
        _ -> progress
      }
      commit_job(
        runs,
        work,
        options,
        ref,
        tries,
        entry,
        state,
        g.JobExpired(g.reference(state, a), now, progress),
      )
    }
    None -> {
      use progress <- result.try(observed)
      case progress {
        job.Pending -> Ok(state)
        _ -> {
          use event <- result.try(job_event(
            work,
            options,
            state,
            a,
            progress,
            stopping,
          ))
          use due <- result.try(case stopping {
            True -> Ok(None)
            False -> wait_due(runs, a)
          })
          let event = case due {
            None -> event
            Some(now) -> g.JobExpired(g.reference(state, a), now, progress)
          }
          commit_job(runs, work, options, ref, tries, entry, state, event)
        }
      }
    }
  }
}

fn checked_job_output(
  work: live.Work,
  options: Options,
  a: g.Activation,
  output: String,
) -> Result(Nil, Error) {
  bounded.call(options.callback_timeout, fn() { work().check_output(a, output) })
  |> result.map_error(string.inspect)
  |> result.try(fn(reply) { reply |> result.map_error(string.inspect) })
  |> result.map_error(CallbackFailed)
}

fn job_event(
  work: live.Work,
  options: Options,
  state: g.State,
  a: g.Activation,
  progress: job.Progress(String),
  stopping: Bool,
) -> Result(g.Event, Error) {
  case progress, stopping {
    job.Completed(output), True -> {
      use _ <- result.map(checked_job_output(work, options, a, output))
      g.CancelledResult(g.reference(state, a), output)
    }
    job.Cancelled, True -> Ok(g.JobConfirmedStopped(g.reference(state, a)))
    job.Cancelled, False ->
      Ok(g.JobFailed(g.reference(state, a), "external job was cancelled"))
    job.Completed(output), False -> {
      use decision <- result.map(
        bounded.call(options.callback_timeout, fn() {
          work().accept(state, a, output)
        })
        |> result.map_error(string.inspect)
        |> result.try(fn(reply) { reply |> result.map_error(string.inspect) })
        |> result.map_error(CallbackFailed),
      )
      g.JobCompleted(g.reference(state, a), output, decision)
    }
    job.Failed(reason), _ -> Ok(g.JobFailed(g.reference(state, a), reason))
    job.Pending, _ -> Error(Refused(g.WrongPhase))
  }
}

fn commit_job(
  runs: store.Store,
  work: live.Work,
  options: Options,
  ref: job.Reference,
  tries: Int,
  entry: store.Entry,
  state: g.State,
  event: g.Event,
) -> Result(g.State, Error) {
  use #(next, effects) <- result.try(
    g.step(state, event) |> result.map_error(Refused),
  )
  case
    launch(
      runs,
      work,
      options,
      Some(#(entry.revision, state)),
      next,
      effects,
      None,
      False,
    )
  {
    Ok(_) -> Ok(next)
    Error(StoreFailed(backend.Conflict(_))) if tries > 1 ->
      observe_job(runs, work, options, ref, tries - 1)
    Error(error) -> Error(error)
  }
}

fn job_matches(ref: job.Reference, a: g.Activation) -> Bool {
  ref.activation == a.id
  && ref.attempt == a.attempt
  && ref.operation == a.prepared.operation
  && case a.prepared.kind {
    operation.Job(_) | operation.OwnedJob(_) -> True
    _ -> False
  }
}

pub fn recover(
  runs: store.Store,
  work: live.Work,
  options: Options,
  id: String,
  tries: Int,
) -> Result(g.State, Error) {
  use #(entry, state) <- result.try(load(runs, work, options, id))
  case driven(entry, state) {
    True -> recover_driven_child(runs, work, options, state)
    False -> recover_abandoned(runs, work, options, entry, state, tries)
  }
}

// A live parent retains its own lease. Its child may independently lose a
// runner, so the root registration must still drive that child's recovery.
fn recover_driven_child(
  runs: store.Store,
  work: live.Work,
  options: Options,
  state: g.State,
) -> Result(g.State, Error) {
  use due <- result.try(managed_due(runs, state))
  case due {
    Some(_) -> Ok(state)
    None ->
      case state.phase {
        g.Joining(a, id)
        | g.WaitingChild(a, id)
        | g.ChildBlocked(a, id, _)
        | g.StoppingChild(a, id, _) -> {
          use _ <- result.try(
            store.get(runs, id) |> result.map_error(StoreFailed),
          )
          let mode = case state.phase {
            g.StoppingChild(..) -> child_driver.Cancel
            _ -> child_driver.Start
          }
          use _ <- result.map(
            bounded.call(options.callback_timeout, fn() {
              use driver <- result.try(checked_child(runs, work, a))
              driver.reserve(
                child.Parent(state.run, a.id),
                id,
                a.prepared.input,
                mode,
              )
            })
            |> result.map_error(string.inspect)
            |> result.flatten
            |> result.map_error(CallbackFailed),
          )
          state
        }
        _ -> Ok(state)
      }
  }
}

fn recover_abandoned(
  runs: store.Store,
  work: live.Work,
  options: Options,
  entry: store.Entry,
  state: g.State,
  tries: Int,
) -> Result(g.State, Error) {
  use expiring <- result.try(approval_due(runs, state))
  use due <- result.try(managed_due(runs, state))
  case expiring, due {
    // An approval request whose deadline passed expires: the run fails
    // with `graph.ExpiredApproval`.
    Some(#(approval, now)), _ -> {
      use #(next, effects) <- result.try(
        g.step(state, g.ExpireApproval(approval, now))
        |> result.map_error(Refused),
      )
      commit_recovery(runs, work, options, entry, state, next, effects, tries)
    }
    None, Some(#(a, now)) -> {
      use #(next, effects) <- result.try(
        g.step(state, g.ExpireWait(g.reference(state, a), now))
        |> result.map_error(Refused),
      )
      commit_recovery(runs, work, options, entry, state, next, effects, tries)
    }
    None, None ->
      case state.phase {
        g.WaitingSignal(a) | g.WaitingJob(a) -> {
          use due <- result.try(wait_due(runs, a))
          case due {
            None
              if entry.holding == store.HeldHere
              && a.prepared.kind == operation.Signal
            ->
              commit_recovery(
                runs,
                work,
                options,
                entry,
                state,
                g.State(..state, incarnation: state.incarnation + 1),
                [],
                tries,
              )
            None -> Ok(state)
            Some(now) -> {
              use #(next, effects) <- result.try(
                g.step(state, g.ExpireWait(g.reference(state, a), now))
                |> result.map_error(Refused),
              )
              commit_recovery(
                runs,
                work,
                options,
                entry,
                state,
                next,
                effects,
                tries,
              )
            }
          }
        }
        g.WaitingChild(a, child) -> {
          // A retained wait proves its child was created. Never recreate a
          // missing record after earlier child activities may have acted.
          use _ <- result.try(
            store.get(runs, child) |> result.map_error(StoreFailed),
          )
          use _ <- result.try(
            bounded.call(options.callback_timeout, fn() {
              use driver <- result.try(checked_child(runs, work, a))
              driver.reserve(
                child.Parent(state.run, a.id),
                child,
                a.prepared.input,
                child_driver.Start,
              )
            })
            |> result.map_error(string.inspect)
            |> result.flatten
            |> result.map_error(CallbackFailed),
          )
          commit_recovery(
            runs,
            work,
            options,
            entry,
            state,
            g.State(..state, incarnation: state.incarnation + 1),
            [],
            tries,
          )
        }
        g.Ended(g.Cancelled(a, g.UnresolvedCancellation(_)))
          | g.Ended(g.Expired(a, g.UnresolvedCancellation(_)))
          if {
            a.prepared.kind == operation.Subgraph
            || a.prepared.kind == operation.Agent
          }
        -> settle_child(runs, work, options, entry, state, a, tries, False)
        _ -> recover_work(runs, work, options, entry, state, tries)
      }
  }
}

pub fn managed_due(
  runs: store.Store,
  state: g.State,
) -> Result(Option(#(g.Activation, Int)), Error) {
  let current = case state.phase {
    g.PreparingFork(a)
    | g.Forking(a, g.JoiningFork)
    | g.WaitingFork(a, g.JoiningFork) -> Some(a)
    g.Joining(a, _)
    | g.WaitingChild(a, _)
    | g.ChildBlocked(a, _, _)
    | g.Blocked(a, g.InvalidResult(_, _)) ->
      case a.prepared.kind {
        operation.Agent | operation.Subgraph | operation.Fork(..) -> Some(a)
        _ -> None
      }
    _ -> None
  }
  case current {
    None -> Ok(None)
    Some(a) -> {
      use due <- result.try(wait_due(runs, a))
      case due {
        None -> Ok(None)
        Some(now) -> {
          // A retained wait or result proves the child already existed. Its
          // disappearance is data loss, never permission for a new tombstone.
          use _ <- result.try(case state.phase {
            g.WaitingChild(_, id) ->
              store.get(runs, id)
              |> result.replace(Nil)
              |> result.map_error(StoreFailed)
            g.Blocked(_, g.InvalidResult(_, _)) ->
              case a.prepared.kind {
                operation.Fork(..) -> Ok(Nil)
                _ ->
                  store.get(runs, attachment.reserved_id(state.run, a.id))
                  |> result.replace(Nil)
                  |> result.map_error(StoreFailed)
              }
            _ -> Ok(Nil)
          })
          Ok(Some(#(a, now)))
        }
      }
    }
  }
}

/// A time sample is only an input to a revision-checked transition. A missing
/// clock never grants delivery permission or substitutes a local timestamp.
pub fn wait_due(
  runs: store.Store,
  activation: g.Activation,
) -> Result(Option(Int), Error) {
  case activation.deadline {
    None -> Ok(None)
    Some(due) -> {
      use now <- result.map(store.now(runs) |> result.map_error(StoreFailed))
      case now >= due {
        True -> Some(now)
        False -> None
      }
    }
  }
}

pub fn checked_child(
  runs: store.Store,
  work: live.Work,
  activation: g.Activation,
) -> Result(child_driver.Driver, String) {
  use driver <- result.try(
    work().child(activation) |> result.map_error(string.inspect),
  )
  case driver.store(), store.pid(runs) {
    Ok(child_store), Ok(parent_store) if child_store == parent_store ->
      Ok(driver)
    _, _ -> Error("managed child must use its parent's store")
  }
}

fn park(
  runs: store.Store,
  work: live.Work,
  options: Options,
  id: String,
  dependency: String,
) -> store.Ownership {
  store.Park([dependency], fn() {
    wake_parent(runs, work, options, id) |> result.unwrap(store.KeepWatching)
  })
}

/// A notification is only a reason to inspect committed data. It never starts
/// a child or rewrites an unchanged wait, preventing notification loops.
fn wake_parent(
  runs: store.Store,
  work: live.Work,
  options: Options,
  id: String,
) -> Result(store.WakeupDisposition, Error) {
  use #(entry, state) <- result.try(load(runs, work, options, id))
  case state.phase {
    g.WaitingChild(a, child) -> {
      use progress <- result.try(
        bounded.call(options.callback_timeout, fn() {
          use driver <- result.try(checked_child(runs, work, a))
          driver.read(
            child.Parent(state.run, a.id),
            child,
            child_driver.Observe,
          )
        })
        |> result.map_error(string.inspect)
        |> result.flatten
        |> result.map_error(CallbackFailed),
      )
      case progress {
        child.Approval(_)
        | child.AgentInput(..)
        | child.Signal(_)
        | child.Job(_)
        | child.Fork(_) -> Ok(store.KeepWatching)
        _ ->
          recover_work(runs, work, options, entry, state, 3)
          |> result.replace(store.KeepWatching)
      }
    }
    _ -> Ok(store.StopWatching)
  }
}

/// Settlement reads retained evidence. Discovery also follows nested cleanup;
/// neither path recreates missing children or resumes parent business routing.
fn settle_child(
  runs: store.Store,
  work: live.Work,
  options: Options,
  entry: store.Entry,
  state: g.State,
  activation: g.Activation,
  tries: Int,
  discover: Bool,
) -> Result(g.State, Error) {
  let id = attachment.reserved_id(state.run, activation.id)
  use progress <- result.try(
    bounded.call(options.callback_timeout, fn() {
      use driver <- result.try(checked_child(runs, work, activation))
      use _ <- result.try(case discover {
        False -> Ok(Nil)
        True -> {
          // Discovery follows already retained children so a nested cleanup
          // can settle. Missing records never authorize child recreation.
          use _ <- result.try(
            store.get(runs, id) |> result.map_error(string.inspect),
          )
          driver.reserve(
            child.Parent(state.run, activation.id),
            id,
            activation.prepared.input,
            child_driver.Discover,
          )
        }
      })
      driver.read(
        child.Parent(state.run, activation.id),
        id,
        child_driver.Settle,
      )
    })
    |> result.map_error(string.inspect)
    |> result.flatten
    |> result.map_error(CallbackFailed),
  )
  case progress {
    child.Succeeded(_)
    | child.Failed(_)
    | child.InvalidOutput(..)
    | child.Cancelled(False) -> {
      use #(next, effects) <- result.try(
        g.step(
          state,
          g.ChildCancellationSettled(g.reference(state, activation), id),
        )
        |> result.map_error(Refused),
      )
      commit_recovery(runs, work, options, entry, state, next, effects, tries)
    }
    child.Working
    | child.Approval(_)
    | child.AgentInput(..)
    | child.Signal(_)
    | child.Job(_)
    | child.Fork(_)
    | child.Uncertain(_)
    | child.FinishedUncertain(_)
    | child.Cancelled(True) -> Ok(state)
  }
}

fn recover_work(
  runs: store.Store,
  work: live.Work,
  options: Options,
  entry: store.Entry,
  state: g.State,
  tries: Int,
) -> Result(g.State, Error) {
  let recoverable = case state.phase {
    g.ChildBlocked(_, _, _) | g.WaitingChild(_, _) | g.WaitingFork(..) -> True
    _ -> g.needs_runner(state)
  }
  case
    driven(entry, state)
    || { !recoverable && !bootstrap.pending(state.family_budget) }
  {
    True -> Ok(state)
    False -> {
      use #(next, effects) <- result.try(case recoverable {
        True -> g.recover(state) |> result.map_error(Refused)
        False -> Ok(#(state, []))
      })
      commit_recovery(runs, work, options, entry, state, next, effects, tries)
    }
  }
}

fn commit_recovery(
  runs: store.Store,
  work: live.Work,
  options: Options,
  entry: store.Entry,
  before: g.State,
  next: g.State,
  effects: List(g.Effect),
  tries: Int,
) -> Result(g.State, Error) {
  case
    launch(
      runs,
      work,
      options,
      Some(#(entry.revision, before)),
      next,
      effects,
      None,
      False,
    )
  {
    Ok(_) -> Ok(next)
    Error(StoreFailed(backend.Conflict(_))) if tries > 1 ->
      recover(runs, work, options, next.run, tries - 1)
    Error(StoreFailed(backend.LeaseRefused(_))) -> Error(OwnerUnknown)
    Error(error) -> Error(error)
  }
}

pub fn cancel(
  runs: store.Store,
  work: live.Work,
  options: Options,
  id: String,
  tries: Int,
) -> Result(g.State, Error) {
  use #(entry, state) <- result.try(load_raw(runs, id))
  let held = owner(entry, state)
  let caller = process.self()
  let cancel_stored = fn() {
    use #(next, effects) <- result.try(
      g.cancel_abandoned(state) |> result.map_error(Refused),
    )
    case
      launch(
        runs,
        work,
        options,
        Some(#(entry.revision, state)),
        next,
        effects,
        None,
        True,
      )
    {
      Ok(_) -> {
        case held {
          Some(mailbox) ->
            case process.subject_owner(mailbox) {
              Ok(pid) if pid != caller -> process.kill(pid)
              _ -> Nil
            }
          None -> Nil
        }
        Ok(next)
      }
      Error(StoreFailed(backend.Conflict(_))) if tries > 1 ->
        cancel(runs, work, options, id, tries - 1)
      Error(error) -> Error(error)
    }
  }
  case held {
    None -> cancel_stored()
    Some(mailbox) ->
      case send_cancel(mailbox, options.command_timeout) {
        Ok(state) -> Ok(state)
        Error(Busy) -> cancel_stored()
        Error(OwnerUnknown) if tries > 1 ->
          cancel(runs, work, options, id, tries - 1)
        Error(error) -> Error(error)
      }
  }
}

fn send_cancel(
  mailbox: Subject(live.Message),
  within: Int,
) -> Result(g.State, Error) {
  let caller = process.self()
  case process.subject_owner(mailbox) {
    Error(Nil) -> Error(OwnerUnknown)
    Ok(pid) if pid == caller -> Error(Busy)
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      let command = claim.new()
      process.send(mailbox, live.Cancel(command, reply))
      let selector =
        process.new_selector()
        |> process.select_map(reply, Ok)
        |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
      let first = case process.selector_receive(selector, within) {
        Ok(first) -> Ok(first)
        Error(Nil) ->
          case claim.withdraw(command) {
            True -> Error(Busy)
            False -> Ok(process.selector_receive_forever(selector))
          }
      }
      let result = case first {
        Ok(Ok(live.Accepted)) ->
          case process.selector_receive_forever(selector) {
            Ok(live.Applied(state)) -> Ok(state)
            Ok(live.Refused(reason)) -> Error(Refused(reason))
            _ -> Error(OwnerUnknown)
          }
        Error(error) -> Error(error)
        _ -> Error(OwnerUnknown)
      }
      process.demonitor_process(monitor)
      result
    }
  }
}

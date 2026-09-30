//// Serial graph execution over the shared store, supervised host, bounded
//// callbacks and fenced executor. No effect is released by an unconfirmed
//// commit. Every runner pins the store process that owns its lifetime.

import fabric/budget
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/operation
import fabric/internal/ancestry
import fabric/internal/bounded
import fabric/internal/budget/admission as capacity
import fabric/internal/budget/bootstrap
import fabric/internal/budget/model as reservations
import fabric/internal/claim
import fabric/internal/executor
import fabric/internal/graph/child_driver
import fabric/internal/graph/controller as g
import fabric/internal/graph/live
import fabric/internal/graph/record
import fabric/internal/runner_host as host
import fabric/policy
import fabric/store
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Options {
  Options(callback_timeout: Int, operation_timeout: Int, command_timeout: Int)
}

pub type Error {
  StoreFailed(store.StoreError)
  Unreadable(record.DecodeError)
  Incompatible(definition.Error)
  CallbackFailed(String)
  Refused(g.Rejection)
  Busy
  Contended
  OwnerUnknown
}

pub fn load(
  runs: store.Store,
  work: live.Work,
  options: Options,
  id: String,
) -> Result(#(store.Entry, g.State), Error) {
  use #(entry, state) <- result.try(load_raw(runs, id))
  use checked <- result.try(
    bounded.call(options.callback_timeout, fn() { work.validate(state) })
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
  Ok(#(entry, state))
}

pub type AdmissionError {
  PolicyRejected(String)
  BudgetLimited(budget.Denial)
  BudgetUnavailable(String)
}

fn capacity_error(error: capacity.Error) -> AdmissionError {
  case error {
    capacity.Limited(reason) -> BudgetLimited(reason)
    capacity.Closed -> PolicyRejected("parent no longer accepts child work")
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
        operation.Activity | operation.Signal -> Ok(Nil)
      })
      work.admit(state.run, activation)
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
        child.reserved_id(state.run, activation.id),
      )
      |> result.map_error(capacity_error)
    _, _ -> Ok(Nil)
  })
  Ok(admitted)
}

pub fn check_ancestry(runs: store.Store, state: g.State) -> Result(Nil, Error) {
  case ancestry.read(runs, state.run, state.parent, 64) {
    Ok(True) -> Ok(Nil)
    Ok(False) -> Error(CallbackFailed("parent no longer accepts child work"))
    Error(error) -> Error(CallbackFailed(string.inspect(error)))
  }
}

pub fn owner(
  entry: store.Entry,
  state: g.State,
) -> Option(Subject(live.Message)) {
  case entry.live {
    Some(store.GraphLive(incarnation, mailbox))
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

pub fn launch(
  runs: store.Store,
  work: live.Work,
  options: Options,
  expected: Option(Int),
  state: g.State,
  effects: List(g.Effect),
  body: Option(live.Body),
  seize: Bool,
) -> Result(Int, Error) {
  use encoded <- result.try(
    record.encode(state)
    |> result.map_error(fn(error) { CallbackFailed(string.inspect(error)) }),
  )
  case g.needs_runner(state) {
    False -> {
      let ownership = case state.phase {
        g.WaitingChild(_, child) -> park(runs, work, options, state.run, child)
        _ -> store.Detached(False, seize)
      }
      write_initialized(runs, state, expected, encoded, ownership)
      |> result.map(fn(entry) { entry.0 })
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
          |> result.map(fn(entry) { entry.0 })
        Ok(#(pid, mailbox, go)) -> {
          let ownership =
            store.Launch(
              pid,
              store.GraphLive(state.incarnation, mailbox),
              seize,
            )
          case write_initialized(runs, state, expected, encoded, ownership) {
            Ok(#(revision, state)) -> {
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
) -> Result(Int, store.StoreError) {
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
    g.Running(_) | g.Stopping(_) -> True
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
      let _ = persist(runner, runner.state, store.HandOff(process.self()))
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
      | g.Dispatch(_), True
      | g.ObserveChild(_, _), True
      | g.CancelChild(_, _), True
      -> Ok(runner)
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
            Ok(live.Admission(decision, body)) ->
              Ok(#(
                g.Inspected(g.reference(runner.state, activation), Ok(decision)),
                Some(body),
              ))
            Error(PolicyRejected(reason)) ->
              Ok(#(
                g.Inspected(
                  g.reference(runner.state, activation),
                  Error(reason),
                ),
                None,
              ))
            Error(BudgetLimited(reason)) ->
              Ok(#(
                g.BudgetRefused(g.reference(runner.state, activation), reason),
                None,
              ))
            Error(BudgetUnavailable(reason)) ->
              Error(StoreFailed(store.Unavailable(reason)))
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
          executor.Job(g.reference(runner.state, activation), fn() {
            case bounded.call(runner.options.operation_timeout, body) {
              Ok(result) -> live.Returned(result)
              Error(error) -> live.Interrupted(string.inspect(error))
            }
          }),
        ])
        Ok(Runner(..runner, executor: Some(executor), body: None))
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
        g.Running(a) | g.Stopping(a) ->
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
        use _ <- result.try(check_ancestry(runner.runs, runner.state))
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

fn poll_child(runner: Runner) -> Result(Runner, Error) {
  let state = runner.state
  use #(a, id, stopping) <- result.try(case state.phase {
    g.Joining(a, id) -> Ok(#(a, id, False))
    g.StoppingChild(a, id) -> Ok(#(a, id, True))
    _ -> Error(Refused(g.WrongPhase))
  })
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
  let ref = g.reference(state, a)
  case checked, stopping {
    Ok(child.Approval(_)), False
    | Ok(child.AgentInput(..)), False
    | Ok(child.Signal(_)), False
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
          runner.work.accept(state, a, output)
        })
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
    g.Running(a) | g.Stopping(a) ->
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

fn result_event(
  work: live.Work,
  options: Options,
  state: g.State,
  activation: g.Activation,
  ref: g.Reference,
  execution: live.Execution,
) -> g.Event {
  case execution {
    live.Interrupted(reason) -> g.Unresolved(ref, g.Uncertain(reason))
    live.Returned(Error(definition.OperationRejected(operation.BodyFailed(operation.DefiniteFailure(
      reason,
    ))))) -> g.FailedBody(ref, g.OperationFailed(reason))
    live.Returned(Error(definition.OperationRejected(operation.BodyFailed(operation.UncertainEffect(
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
    g.Stopping(_) | g.Ended(g.Cancelled(_, _)) -> True
    _ -> False
  }
  case cancelled {
    True -> {
      let checked =
        bounded.call(options.callback_timeout, fn() {
          work.check_output(activation, output)
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
          work.accept(state, activation, output)
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
  let outcome = case state.phase {
    g.Joining(a, child)
      | g.WaitingChild(a, child)
      | g.ChildBlocked(a, child, _)
      | g.StoppingChild(a, child)
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
      if {
        a.prepared.kind == operation.Subgraph
        || a.prepared.kind == operation.Agent
      }
    -> recover_cancelled_child(runs, work, options, entry, state, a, 1)
    _ -> recover_work(runs, work, options, entry, state, 1)
  }
  case outcome {
    Error(StoreFailed(store.Conflict(_))) if tries > 1 ->
      discover(runs, work, options, id, tries - 1)
    other -> other
  }
}

/// Retained idle states need no new child command. Keep changed uncertainty
/// evidence when acknowledging a claimed wait, without restarting observation.
fn resting_child(phase: g.Phase, progress: child.Progress) -> Option(g.Phase) {
  case phase, progress {
    g.WaitingChild(..), child.Approval(_)
    | g.WaitingChild(..), child.AgentInput(..)
    | g.WaitingChild(..), child.Signal(_)
    -> Some(phase)
    g.ChildBlocked(a, id, _), child.Uncertain(reason)
    | g.ChildBlocked(a, id, _), child.FinishedUncertain(reason)
    -> Some(g.ChildBlocked(a, id, reason))
    g.ChildBlocked(a, id, _), child.Cancelled(True) ->
      Some(g.ChildBlocked(a, id, "child cancellation retains uncertain effects"))
    _, _ -> None
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
  case state.phase {
    g.Joining(a, id)
    | g.WaitingChild(a, id)
    | g.ChildBlocked(a, id, _)
    | g.StoppingChild(a, id) -> {
      use _ <- result.try(store.get(runs, id) |> result.map_error(StoreFailed))
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

fn recover_abandoned(
  runs: store.Store,
  work: live.Work,
  options: Options,
  entry: store.Entry,
  state: g.State,
  tries: Int,
) -> Result(g.State, Error) {
  case state.phase {
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
        g.State(..state, incarnation: state.incarnation + 1),
        [],
        tries,
      )
    }
    g.Ended(g.Cancelled(a, g.UnresolvedCancellation(_)))
      if {
        a.prepared.kind == operation.Subgraph
        || a.prepared.kind == operation.Agent
      }
    -> recover_cancelled_child(runs, work, options, entry, state, a, tries)
    _ -> recover_work(runs, work, options, entry, state, tries)
  }
}

pub fn checked_child(
  runs: store.Store,
  work: live.Work,
  activation: g.Activation,
) -> Result(child_driver.Driver, String) {
  use driver <- result.try(
    work.child(activation) |> result.map_error(string.inspect),
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
  store.Park(dependency, fn() {
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
        child.Approval(_) | child.AgentInput(..) | child.Signal(_) ->
          Ok(store.KeepWatching)
        _ ->
          recover_work(runs, work, options, entry, state, 3)
          |> result.replace(store.KeepWatching)
      }
    }
    _ -> Ok(store.StopWatching)
  }
}

/// Settlement observes retained child evidence only. It never restarts a child
/// or calls the parent's routing callback after cancellation.
fn recover_cancelled_child(
  runs: store.Store,
  work: live.Work,
  options: Options,
  entry: store.Entry,
  state: g.State,
  activation: g.Activation,
  tries: Int,
) -> Result(g.State, Error) {
  let id = child.reserved_id(state.run, activation.id)
  use progress <- result.try(
    bounded.call(options.callback_timeout, fn() {
      use driver <- result.try(checked_child(runs, work, activation))
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
      commit_recovery(runs, work, options, entry, next, effects, tries)
    }
    child.Working
    | child.Approval(_)
    | child.AgentInput(..)
    | child.Signal(_)
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
    g.ChildBlocked(_, _, _) | g.WaitingChild(_, _) -> True
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
      commit_recovery(runs, work, options, entry, next, effects, tries)
    }
  }
}

fn commit_recovery(
  runs: store.Store,
  work: live.Work,
  options: Options,
  entry: store.Entry,
  next: g.State,
  effects: List(g.Effect),
  tries: Int,
) -> Result(g.State, Error) {
  case
    launch(
      runs,
      work,
      options,
      Some(entry.revision),
      next,
      effects,
      None,
      False,
    )
  {
    Ok(_) -> Ok(next)
    Error(StoreFailed(store.Conflict(_))) if tries > 1 ->
      recover(runs, work, options, next.run, tries - 1)
    Error(StoreFailed(store.LeaseRefused(_))) -> Error(OwnerUnknown)
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
        Some(entry.revision),
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
      Error(StoreFailed(store.Conflict(_))) if tries > 1 ->
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

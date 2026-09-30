//// Terminal evidence updates. No deployed agent, runner, effect or result
//// mapper participates. Each record commits independently; repeating the
//// walk repairs interrupted propagation from descendants to parents.

import fabric/internal/controller
import fabric/internal/observe
import fabric/internal/runner
import fabric/run
import fabric/store
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Error {
  NotFinished
  UnknownAction
  NotReconcilable
  Unreadable(runner.ReadError)
  Contended
}

const retries = 3

pub fn reconcile(
  runs: store.Store,
  effect: run.ActionRef,
  content: String,
) -> Result(controller.State, Error) {
  reconcile_attempt(runs, effect, content, retries)
}

fn reconcile_attempt(
  runs: store.Store,
  effect: run.ActionRef,
  content: String,
  tries: Int,
) -> Result(controller.State, Error) {
  let id = run.id_to_string(effect.run)
  use #(entry, state) <- result.try(load(runs, id))
  use Nil <- result.try(finished(state))
  use action <- result.try(
    list.find(state.history, fn(action) { action.id == effect.id })
    |> result.replace_error(UnknownAction),
  )
  use Nil <- result.try(case action.state, action.child {
    run.Uncertain(_), None -> Ok(Nil)
    run.Reconciled(saved), None if saved == content -> Ok(Nil)
    _, _ -> Error(NotReconcilable)
  })
  let history =
    list.map(state.history, fn(action) {
      case action.id == effect.id {
        True -> run.ActionRecord(..action, state: run.Reconciled(content))
        False -> action
      }
    })
  commit(runs, entry, state, controller.State(..state, history:), tries, fn() {
    reconcile_attempt(runs, effect, content, tries - 1)
  })
}

pub fn settle(
  runs: store.Store,
  id: String,
) -> Result(controller.State, Error) {
  settle_at(runs, id, None, 64, retries)
}

fn settle_at(
  runs: store.Store,
  id: String,
  parent: Option(run.Parent),
  left: Int,
  tries: Int,
) -> Result(controller.State, Error) {
  use Nil <- result.try(case left > 0 {
    True -> Ok(Nil)
    False ->
      Error(Unreadable(runner.Corrupt("terminal family exceeds 64 levels")))
  })
  use #(entry, state) <- result.try(load(runs, id))
  use Nil <- result.try(case parent {
    Some(_) if state.parent != parent ->
      Error(
        Unreadable(runner.Corrupt("child does not name the parent delegation")),
      )
    _ -> Ok(Nil)
  })
  use Nil <- result.try(finished(state))
  use history <- result.try(
    list.try_map(state.history, fn(action) {
      case action.state, action.child {
        run.Uncertain(_), Some(child) -> {
          let expected = run.AgentParent(run.issued(id), action.id)
          case
            settle_at(
              runs,
              run.id_to_string(child),
              Some(expected),
              left - 1,
              retries,
            )
          {
            // An active child cannot be made terminal by evidence recovery.
            Error(NotFinished) -> Ok(action)
            Error(problem) -> Error(problem)
            Ok(child) -> {
              let next = case controller.child_result(child) {
                Ok(controller.ChildFinished(outcome, False)) ->
                  run.ChildSettled(outcome)
                // This result came from a saved never-started tombstone, not
                // an absent record. Absence remains an unreadable child above.
                Ok(controller.ChildMissing) -> run.NotStarted
                _ -> action.state
              }
              Ok(run.ActionRecord(..action, state: next))
            }
          }
        }
        _, _ -> Ok(action)
      }
    }),
  )
  commit(runs, entry, state, controller.State(..state, history:), tries, fn() {
    settle_at(runs, id, parent, left, tries - 1)
  })
}

fn finished(state: controller.State) -> Result(Nil, Error) {
  case state.phase {
    controller.Ended(_) | controller.NeverStarted -> Ok(Nil)
    _ -> Error(NotFinished)
  }
}

fn load(runs, id) {
  runner.load(runs, id) |> result.map_error(Unreadable)
}

fn commit(
  runs: store.Store,
  entry: store.Entry,
  before: controller.State,
  after: controller.State,
  tries: Int,
  retry: fn() -> Result(controller.State, Error),
) -> Result(controller.State, Error) {
  case before == after {
    True -> Ok(before)
    False -> {
      use encoded <- result.try(
        store.encode(runs, after)
        |> result.map_error(fn(error) { Unreadable(runner.StoreFailed(error)) }),
      )
      case
        store.commit(
          runs,
          after.run,
          entry.revision,
          encoded,
          store.Detached(False, False),
        )
      {
        Ok(_) -> {
          observe.committed(Some(before), after)
          Ok(after)
        }
        Error(store.Conflict(_)) if tries > 1 -> retry()
        Error(store.Conflict(_)) -> Error(Contended)
        Error(error) -> Error(Unreadable(runner.StoreFailed(error)))
      }
    }
  }
}

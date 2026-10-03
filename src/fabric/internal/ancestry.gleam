//// Checked ownership above either runtime. A parent must still retain the
//// exact child reservation; an open but unrelated run cannot admit work.

import fabric/budget as quota

import fabric/graph/child
import fabric/graph/fork
import fabric/internal/budget/config
import fabric/internal/budget/model as budget
import fabric/internal/controller as agent
import fabric/internal/graph/controller as graph
import fabric/internal/graph/fork as scope
import fabric/internal/graph/record as graph_record
import fabric/internal/record as agent_record
import fabric/internal/store
import fabric/run
import fabric/store/backend
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Error {
  StoreFailed(backend.StoreError)
  UnsupportedVersion(Int)
  Corrupt(String)
}

/// Resolved from saved reciprocal attachments, never from a child's local
/// depth counter. The declaration is read only from the root of the chain.
pub type Family {
  Family(root: String, depth: Int, limits: Option(quota.Limits))
}

pub fn read(
  runs: store.Store,
  descendant: String,
  parent: Option(run.Parent),
  left: Int,
) -> Result(Bool, Error) {
  family(runs, descendant, parent, None, left)
  |> result.map(fn(family) { family != None })
}

/// `None` means a parent no longer admits this descendant. Unreadable or
/// overlong ancestry is an error, never a new independent root.
pub fn family(
  runs: store.Store,
  descendant: String,
  parent: Option(run.Parent),
  limits: Option(budget.Declaration),
  left: Int,
) -> Result(Option(Family), Error) {
  walk(runs, descendant, parent, limits, left, 0)
}

fn walk(
  runs: store.Store,
  descendant: String,
  parent: Option(run.Parent),
  limits: Option(budget.Declaration),
  left: Int,
  depth: Int,
) -> Result(Option(Family), Error) {
  use Nil <- result.try(
    config.validate(parent == None, limits) |> result.map_error(Corrupt),
  )
  case parent {
    None ->
      case limits {
        Some(budget.Declaration(_, False)) ->
          Error(Corrupt("the family budget is not initialized"))
        Some(budget.Declaration(limits, True)) ->
          Ok(Some(Family(descendant, depth, Some(limits))))
        None -> Ok(Some(Family(descendant, depth, None)))
      }
    Some(_) if left <= 0 ->
      Error(Corrupt("the chain of parent runs is too long"))
    Some(link) -> {
      let id = run.id_to_string(link.run)
      use entry <- result.try(
        store.get(runs, id) |> result.map_error(StoreFailed),
      )
      use #(stored_id, above, limits, accepts) <- result.try(case link {
        run.GraphBranch(_, activation, ordinal) -> {
          use state <- result.try(
            graph_record.decode(entry.record)
            |> result.map_error(fn(error) {
              case error {
                graph_record.UnsupportedVersion(v) -> UnsupportedVersion(v)
                graph_record.Corrupt(detail) -> Corrupt(detail)
              }
            }),
          )
          let accepts = case
            state.phase,
            graph.current_fork(state, activation)
          {
            graph.Forking(a, graph.JoiningFork), Ok(members)
            | graph.WaitingFork(a, graph.JoiningFork), Ok(members)
              if a.id == activation
            -> {
              let snapshot = scope.snapshot(members)
              let ref = fork.Reference(snapshot.occurrence, ordinal)
              snapshot.stop == None
              && descendant == child.branch_id(state.run, activation, ordinal)
              && case scope.member(members, ref) {
                Ok(fork.Member(_, fork.Reserved))
                | Ok(fork.Member(_, fork.Admitted(fork.Active)))
                | Ok(fork.Member(_, fork.Admitted(fork.Uncertain(_)))) -> True
                _ -> False
              }
            }
            _, _ -> False
          }
          Ok(#(state.run, state.parent, state.family_budget, accepts))
        }
        run.AgentParent(_, action) -> {
          use state <- result.map(
            agent_record.decode(entry.record)
            |> result.map_error(fn(error) {
              case error {
                agent_record.UnsupportedVersion(v) -> UnsupportedVersion(v)
                agent_record.Corrupt(detail) -> Corrupt(detail)
              }
            }),
          )
          let accepts = case state.phase {
            agent.Acting(..) ->
              list.any(agent.active_children(state), fn(child) {
                child.0 == action && child.2 == descendant
              })
            _ -> False
          }
          #(state.run, state.parent, state.family_budget, accepts)
        }
        run.GraphParent(_, activation) -> {
          use state <- result.map(
            graph_record.decode(entry.record)
            |> result.map_error(fn(error) {
              case error {
                graph_record.UnsupportedVersion(v) -> UnsupportedVersion(v)
                graph_record.Corrupt(detail) -> Corrupt(detail)
              }
            }),
          )
          let accepts = case state.phase {
            graph.Joining(a, child)
            | graph.WaitingChild(a, child)
            | graph.ChildBlocked(a, child, _) ->
              a.id == activation && child == descendant
            _ -> False
          }
          #(state.run, state.parent, state.family_budget, accepts)
        }
      })
      case stored_id == id, accepts {
        False, _ -> Error(Corrupt("parent record belongs to a different run"))
        True, False -> Ok(None)
        True, True -> walk(runs, id, above, limits, left - 1, depth + 1)
      }
    }
  }
}

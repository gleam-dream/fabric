//// Checked ownership above either runtime. A parent must still retain the
//// exact child reservation; an open but unrelated run cannot admit work.

import fabric/budget as quota
import fabric/internal/graph/attachment

import fabric/graph/fork
import fabric/internal/budget/config
import fabric/internal/budget/model as budget
import fabric/internal/controller as agent
import fabric/internal/graph/controller as graph
import fabric/internal/graph/fork as scope
import fabric/internal/graph/record as graph_record
import fabric/internal/observe
import fabric/internal/record as agent_record
import fabric/internal/store
import fabric/run
import fabric/store/backend
import fabric/telemetry as o
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sinal/correlation.{type Correlation}

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
              && descendant
              == attachment.branch_id(state.run, activation, ordinal)
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

/// More parent links than a valid family has: a longer chain is corrupt.
pub const max_links = 64

/// The root of a run, derived from its stored ancestors.
pub type Root {
  /// Named by a root run, or by the first ancestor that stores its root.
  Exact(String)
  /// The topmost ancestor that could be read (the parent when none could),
  /// because of `problem` at `ancestor`.
  Inferred(root: String, ancestor: String, problem: o.RootProblem)
}

/// The root of the run `id` under `parent`, for a child record written
/// before roots were stored: the parent links are followed, at most
/// `max_links` and never to a run already seen, up to a root run or to the
/// first ancestor that stores its root. A missing or unreadable ancestor, a
/// repeat or an overlong chain gives `Inferred`; any other store failure is
/// returned, since an unavailable store says nothing about the family.
pub fn resolve_root(
  runs: store.Store,
  id: String,
  parent: Option(run.Parent),
) -> Result(Root, backend.StoreError) {
  resolve_root_within(runs, id, parent, max_links)
}

/// `resolve_root`, following at most `links` parent links.
pub fn resolve_root_within(
  runs: store.Store,
  id: String,
  parent: Option(run.Parent),
  links: Int,
) -> Result(Root, backend.StoreError) {
  case parent {
    None -> Ok(Exact(id))
    Some(link) -> climb(runs, link, [id], None, links)
  }
}

/// `root` and `root_exact` of the run `id` as its record decoded them,
/// derived from its ancestors when the record stores no root
/// (`resolve_root`). An inferred root is reported with `root_inferred` and
/// stays inexact, so the record stores none.
pub fn settle_root(
  runs: store.Store,
  id: String,
  parent: Option(run.Parent),
  root: #(String, Bool),
  correlation: Correlation,
) -> Result(#(String, Bool), backend.StoreError) {
  case root {
    #(_, True) -> Ok(root)
    #(_, False) ->
      case resolve_root(runs, id, parent) {
        Error(problem) -> Error(problem)
        Ok(Exact(root)) -> Ok(#(root, True))
        Ok(Inferred(root, ancestor, problem)) -> {
          observe.root_inferred(id, root, ancestor, problem, correlation)
          Ok(#(root, False))
        }
      }
  }
}

fn climb(
  runs: store.Store,
  link: run.Parent,
  seen: List(String),
  top: Option(String),
  left: Int,
) -> Result(Root, backend.StoreError) {
  let id = run.id_to_string(link.run)
  let inferred = fn(problem) {
    Ok(Inferred(option.unwrap(top, id), id, problem))
  }
  case list.contains(seen, id), left <= 0 {
    True, _ -> inferred(o.AncestryCycle)
    False, True -> inferred(o.AncestryTooLong)
    False, False ->
      case store.get(runs, id) {
        Error(backend.NotFound) -> inferred(o.AncestorMissing)
        Error(problem) -> Error(problem)
        Ok(entry) ->
          case lineage(link, entry.record) {
            Ok(#(stored, _, _)) if stored != id -> inferred(o.AncestorUnreadable)
            Ok(#(_, _, #(root, True))) -> Ok(Exact(root))
            Ok(#(_, Some(above), #(_, False))) ->
              climb(runs, above, [id, ..seen], Some(id), left - 1)
            // A record without a parent is a root, whose root is exact.
            Ok(#(_, None, #(_, False))) -> Ok(Exact(id))
            Error(Nil) -> inferred(o.AncestorUnreadable)
          }
      }
  }
}

/// The run id, parent and root (with whether it is exact) of an ancestor's
/// record, decoded as the record kind the link names.
fn lineage(
  link: run.Parent,
  encoded: String,
) -> Result(#(String, Option(run.Parent), #(String, Bool)), Nil) {
  case link {
    run.AgentParent(..) ->
      agent_record.decode(encoded)
      |> result.map(fn(state) {
        #(state.run, state.parent, #(state.root, state.root_exact))
      })
      |> result.replace_error(Nil)
    run.GraphParent(..) | run.GraphBranch(..) ->
      graph_record.decode(encoded)
      |> result.map(fn(state) {
        #(state.run, state.parent, #(state.root, state.root_exact))
      })
      |> result.replace_error(Nil)
  }
}

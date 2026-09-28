//// A run and its sub-agent runs, read and recovered together.
////
//// A parent's record names each active child run on its delegation
//// (`ActionRecord.child`), and each child is its own record in the same
//// store. Nothing mirrors a child's state into its parent: the family's
//// status is read from every record, so a child's pending approvals are
//// the parent's pending approvals without a second owner of the decision.

import fabric/internal/controller.{type State}
import fabric/internal/registry
import fabric/internal/runner.{type ReadError, type Setup}
import fabric/policy.{type ActionId}
import fabric/run.{type PendingApproval, type Status}
import fabric/store
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// A run's record and its active child runs, recursively.
pub type Node {
  Node(id: String, entry: store.Entry, state: State, children: List(Child))
}

pub type Child {
  Child(action: ActionId, id: String, node: Result(Node, ReadError))
}

/// Reads `id` and its active descendants. Records are read one by one, so
/// a caller that needs a consistent picture compares two reads
/// (`fingerprint`).
pub fn load(store: store.Store, id: String) -> Result(Node, ReadError) {
  use #(entry, state) <- result.map(runner.load(store, id))
  with_children(store, id, entry, state)
}

/// `state` of `id` with its active descendants read now.
pub fn with_children(
  store: store.Store,
  id: String,
  entry: store.Entry,
  state: State,
) -> Node {
  let children =
    list.map(controller.active_children(state), fn(active) {
      let #(action, _, child) = active
      Child(action, child, load(store, child))
    })
  Node(id, entry, state, children)
}

/// What a family is doing, and whether everything in flight has an owner
/// this store knows.
pub type View {
  View(status: Status, driven: Bool)
}

/// The family's status: finished or working as the run itself is; a run
/// waiting only on its children works while any child works (or has ended
/// and is still delivering its end), and is otherwise suspended on its own
/// and its children's approvals and uncertain effects.
pub fn view(node: Node) -> View {
  case controller.status(node.state) {
    run.Finished(_) as finished -> View(finished, True)
    run.Working ->
      View(run.Working, runner.live_runner(node.entry, node.state) != None)
    run.Suspended(approvals, uncertain) -> {
      let views = list.map(node.children, child_view)
      case list.any(views, fn(view) { view.status == run.Working }) {
        True -> View(run.Working, list.all(views, fn(view) { view.driven }))
        False ->
          View(
            run.Suspended(
              list.append(
                approvals,
                list.flat_map(views, fn(view) {
                  case view.status {
                    run.Suspended(approvals, _) -> approvals
                    _ -> []
                  }
                }),
              ),
              list.append(
                uncertain,
                list.flat_map(views, fn(view) {
                  case view.status {
                    run.Suspended(_, uncertain) -> uncertain
                    _ -> []
                  }
                }),
              ),
            ),
            True,
          )
      }
    }
  }
}

fn child_view(child: Child) -> View {
  case child.node {
    // A child that was never stored, or cannot be read, waits for
    // recovery.
    Error(_) -> View(run.Working, False)
    Ok(node) ->
      case view(node) {
        // Ended but not yet applied to the parent: its runner is
        // delivering it, or the delivery was lost.
        View(run.Finished(_), _) ->
          View(run.Working, runner.live_runner(node.entry, node.state) != None)
        other -> other
      }
  }
}

/// The pending approvals of a run and of its active descendants, the run's
/// own first. They can be answered while other work still runs.
pub fn pending(node: Node) -> List(PendingApproval) {
  list.append(
    own_pending(node.state),
    list.flat_map(node.children, fn(child) {
      case child.node {
        Ok(node) -> pending(node)
        Error(_) -> []
      }
    }),
  )
}

pub fn own_pending(state: State) -> List(PendingApproval) {
  case state.phase {
    controller.Acting(_, actions) ->
      list.filter_map(actions, fn(action) {
        case action.state {
          run.AwaitingApproval(requirement, revision) ->
            Ok(run.PendingApproval(
              run.ApprovalRef(state.run, action.id, requirement, revision),
              action.call.name,
              action.call.arguments_json,
            ))
          _ -> Error(Nil)
        }
      })
    _ -> []
  }
}

/// Every record of the family with its revision and whether this store
/// knows a runner for it: two equal fingerprints read one after the other
/// saw one consistent family.
pub fn fingerprint(node: Node) -> List(#(String, Int, Bool)) {
  [
    #(
      node.id,
      node.entry.revision,
      runner.live_runner(node.entry, node.state) != None,
    ),
    ..list.flat_map(node.children, fn(child) {
      case child.node {
        Ok(node) -> fingerprint(node)
        Error(_) -> [#(child.id, 0, False)]
      }
    })
  ]
}

/// Every run id of the family.
pub fn ids(node: Node) -> List(String) {
  [
    node.id,
    ..list.flat_map(node.children, fn(child) {
      case child.node {
        Ok(node) -> ids(node)
        Error(_) -> [child.id]
      }
    })
  ]
}

/// The setup of `target`, a descendant of `id` (or `id` itself), found by
/// following the child links of each record, current and past.
pub fn locate(
  setup: Setup(context),
  id: String,
  target: String,
) -> Result(Setup(context), ReadError) {
  case id == target {
    True -> Ok(setup)
    False -> {
      use #(_, state) <- result.try(runner.load(setup.store, id))
      let links =
        list.filter_map(actions(state), fn(action) {
          case action.child {
            Some(child) ->
              case child == target || string.starts_with(target, child <> "-") {
                True -> Ok(#(action, child))
                False -> Error(Nil)
              }
            None -> Error(Nil)
          }
        })
      case links {
        [#(action, child), ..] ->
          case runner.child_setup(setup, action.call.name, id, action.id) {
            Ok(child_setup) -> locate(child_setup, child, target)
            Error(Nil) ->
              Error(
                runner.Incompatible([
                  run.ToolNotRegistered(action.id, action.call.name),
                ]),
              )
          }
        [] -> Error(runner.NotFound)
      }
    }
  }
}

fn actions(state: State) -> List(run.ActionRecord) {
  case state.phase {
    controller.Acting(_, actions) | controller.Stopping(actions:, ..) ->
      list.append(state.history, actions)
    controller.AwaitingModel(_)
    | controller.Ended(_)
    | controller.NeverStarted -> state.history
  }
}

/// Whether every ancestor of the run `id` still accepts its work: `False`
/// when `id` has not ended but an ancestor is stopping or has ended.
/// Cancelling an ancestor wins over answering or reconciling a descendant,
/// whose end nobody waits for any more. A run that ended refuses commands
/// itself, with a more precise reason.
pub fn ancestors_open(
  store: store.Store,
  id: String,
) -> Result(Bool, ReadError) {
  use #(_, state) <- result.try(runner.load(store, id))
  case state.phase {
    controller.Ended(_) | controller.NeverStarted -> Ok(True)
    _ -> runner.read_ancestors(store, state.parent, 64, 0)
  }
}

pub type TakeOverError {
  TakeOverUnreadable(ReadError)
  TakeOverContended
}

/// Takes over the run `id` if work is in flight and no runner in this store
/// drives it, then does the same for its children: a child that was never
/// stored is started (or, when an answer approved its start, the approval
/// is asked for again: the context that passed its recheck is gone), a
/// child that ended (and whose end the parent missed) is applied to the
/// parent, an active child is taken over in turn, and a child that cannot
/// be read or continued is an uncertain effect of the parent's delegation.
pub fn take_over(
  setup: Setup(context),
  id: String,
  tries: Int,
) -> Result(Nil, TakeOverError) {
  use #(entry, state) <- result.try(
    runner.load_checked(setup, id) |> result.map_error(TakeOverUnreadable),
  )
  let owned = case
    runner.live_runner(entry, state),
    controller.needs_runner(state)
  {
    Some(_), _ | None, False -> Ok(Nil)
    None, True -> {
      let #(next, effects) = controller.recover(setup.env, state)
      runner.launch(setup, Some(#(entry.revision, state)), next, effects)
      |> result.replace(Nil)
    }
  }
  case owned {
    Ok(Nil) -> {
      reattach(setup, id)
      Ok(Nil)
    }
    Error(store.Conflict(_)) if tries > 1 -> take_over(setup, id, tries - 1)
    Error(store.Conflict(_)) -> Error(TakeOverContended)
    Error(error) -> Error(TakeOverUnreadable(runner.StoreFailed(error)))
  }
}

/// Reattaches the delegated children of `id` (see `take_over`). A run that
/// is stopping cancels its children itself.
fn reattach(setup: Setup(context), id: String) -> Nil {
  case runner.load(setup.store, id) {
    Error(_) -> Nil
    Ok(#(_, state)) ->
      case state.phase {
        controller.Acting(_, actions) ->
          list.each(actions, fn(action) {
            case action.state, action.child {
              run.Delegated, Some(child) ->
                reattach_child(setup, state, action, child)
              _, _ -> Nil
            }
          })
        _ -> Nil
      }
  }
}

fn reattach_child(
  setup: Setup(context),
  parent: State,
  action: run.ActionRecord,
  child: String,
) -> Nil {
  case runner.child_setup(setup, action.call.name, parent.run, action.id) {
    // The compatibility check refuses a parent whose delegation is gone.
    Error(Nil) -> Nil
    Ok(child_setup) ->
      case runner.load(setup.store, child) {
        Error(runner.NotFound) if action.approvals != [] ->
          runner.notify_parent(child_setup, controller.ChildMissing)
        Error(runner.NotFound) ->
          case
            registry.prompt(
              setup.env.registry,
              action.call.name,
              action.call.arguments_json,
            )
          {
            Ok(prompt) -> {
              let #(state, effects) =
                runner.child_state(
                  child_setup,
                  child,
                  prompt,
                  parent,
                  action.id,
                )
              let _ = runner.launch(child_setup, None, state, effects)
              Nil
            }
            Error(detail) ->
              runner.notify_parent(child_setup, controller.ChildLost(detail))
          }
        Error(problem) ->
          runner.notify_parent(
            child_setup,
            controller.ChildLost(runner.describe_read(problem)),
          )
        Ok(#(_, state)) ->
          case controller.child_result(state) {
            Ok(result) -> runner.notify_parent(child_setup, result)
            Error(Nil) ->
              case take_over(child_setup, child, 3) {
                Ok(Nil) | Error(TakeOverContended) -> Nil
                Error(TakeOverUnreadable(problem)) ->
                  runner.notify_parent(
                    child_setup,
                    controller.ChildLost(runner.describe_read(problem)),
                  )
              }
          }
      }
  }
}

//// Storage integrations use this projection to retain complete execution
//// families. It contains no prompts, outputs or deployed code. A backend
//// must also verify reciprocal links, complete membership, age and leases
//// atomically before deleting anything; `settled` alone is not permission.

import fabric/budget as quota

import fabric/graph/child
import fabric/graph/operation
import fabric/internal/budget/model as budget
import fabric/internal/budget/record as budget_record
import fabric/internal/controller as agent
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record as graph_record
import fabric/internal/record as agent_record
import fabric/run
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// Change this version whenever a new record format or state changes the
/// projection, so storage integrations can refresh their retained indexes.
pub const version = 3

/// The run at the other end of a link and an opaque attachment key. A child's
/// parent key must equal the key its parent retained for that child. The key
/// is JSON text, so even provider action IDs containing NUL are safe to index.
pub type Link {
  Link(run: run.RunId, key: String)
}

pub type Metadata {
  Metadata(
    run: run.RunId,
    parent: Option(Link),
    children: List(Link),
    settled: Bool,
  )
}

/// Reads supported execution and budget records with their actual decoder.
/// Unknown, corrupt and incompatible formats are not eligible for retention
/// decisions. No deployed definition is required and nothing executes.
pub fn inspect(encoded: String) -> Result(Metadata, Nil) {
  case agent_record.decode(encoded) {
    Ok(state) -> Ok(agent_metadata(state))
    Error(_) ->
      case graph_record.decode(encoded) {
        Ok(state) -> Ok(graph_metadata(state))
        Error(_) ->
          budget_record.decode(encoded)
          |> result.map(fn(record) {
            Metadata(
              run.issued(budget_record.id(record.root)),
              Some(Link(
                run.issued(record.root),
                budget_key(budget.limits(record.state)),
              )),
              [],
              True,
            )
          })
          |> result.replace_error(Nil)
      }
  }
}

fn budget_key(limits: quota.Limits) -> String {
  json.array(
    [
      json.string("budget"),
      json.int(limits.work),
      json.int(limits.children),
      json.int(limits.depth),
    ],
    fn(value) { value },
  )
  |> json.to_string
}

fn budget_link(root: String, limits: Option(budget.Declaration)) -> List(Link) {
  case limits {
    None -> []
    Some(limits) -> [
      Link(run.issued(budget_record.id(root)), budget_key(limits.limits)),
    ]
  }
}

fn key(parent: run.Parent) -> String {
  case parent {
    run.AgentParent(_, action) ->
      json.array(
        [
          json.string("agent"),
          json.int(action.turn),
          json.string(action.call_id),
        ],
        fn(value) { value },
      )
    run.GraphParent(_, activation) ->
      json.array(
        [
          json.string("graph"),
          json.int(activation),
        ],
        fn(value) { value },
      )
  }
  |> json.to_string
}

fn parent_link(parent: run.Parent) -> Link {
  Link(parent.run, key(parent))
}

fn agent_metadata(state: agent.State) -> Metadata {
  let current = case state.phase {
    agent.Acting(_, actions) | agent.Stopping(actions:, ..) -> actions
    agent.AwaitingModel(_) | agent.Ended(_) | agent.NeverStarted -> []
  }
  let actions = list.append(state.history, current)
  let children =
    list.filter_map(actions, fn(action) {
      case action.child {
        None -> Error(Nil)
        Some(child) ->
          Ok(Link(child, key(run.AgentParent(run.issued(state.run), action.id))))
      }
    })
  let ended = case state.phase {
    agent.Ended(_) | agent.NeverStarted -> True
    agent.AwaitingModel(_) | agent.Acting(..) | agent.Stopping(..) -> False
  }
  let definite =
    list.all(actions, fn(action) {
      case action.state {
        run.Queued
        | run.Running
        | run.Delegated
        | run.AwaitingApproval(..)
        | run.Uncertain(_) -> False
        run.Succeeded(_)
        | run.ToolFailed(_)
        | run.Denied(_)
        | run.Rejected(_)
        | run.InvalidArguments(_)
        | run.UnknownTool
        | run.Reconciled(_)
        | run.ChildSettled(_)
        | run.NotStarted
        | run.Faulted(_)
        | run.LimitReached(_) -> True
      }
    })
  Metadata(
    run.issued(state.run),
    option.map(state.parent, parent_link),
    list.append(children, budget_link(state.run, state.family_budget)),
    ended && definite,
  )
}

fn graph_child(state: graph.State, activation: graph.Activation) -> List(Link) {
  case activation.prepared.kind {
    operation.Subgraph | operation.Agent -> [
      Link(
        run.issued(child.reserved_id(state.run, activation.id)),
        key(run.GraphParent(run.issued(state.run), activation.id)),
      ),
    ]
    operation.Activity | operation.Signal -> []
  }
}

fn graph_metadata(state: graph.State) -> Metadata {
  let current = case state.phase {
    graph.Joining(a, _)
    | graph.WaitingChild(a, _)
    | graph.ChildBlocked(a, _, _)
    | graph.StoppingChild(a, _)
    | graph.Blocked(a, _)
    | graph.Ended(graph.Failed(a, graph.OperationFailed(_)))
    | graph.Ended(graph.Cancelled(a, graph.AfterChild(_)))
    | graph.Ended(graph.Cancelled(a, graph.UnresolvedCancellation(_))) ->
      graph_child(state, a)
    graph.Ready(_)
    | graph.Queued(_)
    | graph.Running(_)
    | graph.AwaitingApproval(..)
    | graph.WaitingSignal(_)
    | graph.Stopping(_)
    | graph.Ended(graph.Completed(_))
    | graph.Ended(graph.Exhausted(_))
    | graph.Ended(graph.Failed(_, graph.Denied(_)))
    | graph.Ended(graph.Failed(_, graph.PolicyFailed(_)))
    | graph.Ended(graph.Failed(_, graph.FamilyBudget(_)))
    | graph.Ended(graph.Cancelled(_, graph.BeforeStart))
    | graph.Ended(graph.Cancelled(_, graph.AfterResult))
    | graph.Ended(graph.Cancelled(_, graph.AfterFailure(_))) -> []
  }
  let children =
    list.flat_map(state.receipts, fn(receipt) {
      graph_child(state, receipt.activation)
    })
    |> list.append(current)
  let settled = case state.phase {
    graph.Ended(graph.Cancelled(_, graph.UnresolvedCancellation(_))) -> False
    graph.Ended(graph.Completed(_))
    | graph.Ended(graph.Failed(..))
    | graph.Ended(graph.Exhausted(_))
    | graph.Ended(graph.Cancelled(_, graph.BeforeStart))
    | graph.Ended(graph.Cancelled(_, graph.AfterResult))
    | graph.Ended(graph.Cancelled(_, graph.AfterFailure(_)))
    | graph.Ended(graph.Cancelled(_, graph.AfterChild(_))) -> True
    graph.Ready(_)
    | graph.Queued(_)
    | graph.Running(_)
    | graph.AwaitingApproval(..)
    | graph.WaitingSignal(_)
    | graph.Joining(..)
    | graph.WaitingChild(..)
    | graph.ChildBlocked(..)
    | graph.StoppingChild(..)
    | graph.Blocked(..)
    | graph.Stopping(_) -> False
  }
  Metadata(
    run.issued(state.run),
    option.map(state.parent, parent_link),
    list.append(children, budget_link(state.run, state.family_budget)),
    settled,
  )
}

/// Canonical projection for a storage index. An unknown record is represented
/// by the version alone, and can never pass a complete-family check. The
/// storage key must match the record's ID. Refresh when the projection version
/// or source revision differs; retain original record bytes separately.
pub fn encode(storage_key: String, encoded: String) -> String {
  let checked =
    inspect(encoded)
    |> result.try(fn(metadata) {
      case run.id_to_string(metadata.run) == storage_key {
        True -> Ok(metadata)
        False -> Error(Nil)
      }
    })
  let fields = case checked {
    Ok(metadata) -> [
      #(
        "parent",
        json.nullable(metadata.parent, fn(link) {
          json.string(run.id_to_string(link.run))
        }),
      ),
      #(
        "attachment",
        json.nullable(metadata.parent, fn(link) { json.string(link.key) }),
      ),
      #(
        "children",
        json.array(metadata.children, fn(link) {
          json.object([
            #("run", json.string(run.id_to_string(link.run))),
            #("key", json.string(link.key)),
          ])
        }),
      ),
      #("settled", json.bool(metadata.settled)),
    ]
    _ -> []
  }
  json.object([#("version", json.int(version)), ..fields]) |> json.to_string
}

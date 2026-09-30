//// Pure diagnostic metadata for storage aggregation. This projection contains
//// no prompts, outputs or deployed code and never authorizes execution.

import fabric/graph/job
import fabric/internal/budget/record as budget_record
import fabric/internal/controller as agent
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record as graph_record
import fabric/internal/record as agent_record
import fabric/run
import gleam/json
import gleam/list
import gleam/result

/// Advance when supported formats or classification rules change. A backend
/// must also match the projection's source revision to the stored revision.
pub const version = 1

pub type Execution {
  /// Work needs a runner; the backend's live lease distinguishes working from
  /// unattended. Classification alone cannot know whether a runner exists.
  Active
  Waiting
  Finished
}

pub type Metadata {
  Run(id: run.RunId, execution: Execution, approval: Bool, reconciliation: Bool)
  Budget(id: run.RunId)
}

/// Reads supported agent, graph and budget records through their real decoders.
/// Flags describe this record only; child requests are not copied to ancestors.
/// Ended agents can retain uncertain effects requiring external reconciliation.
pub fn inspect(encoded: String) -> Result(Metadata, Nil) {
  case agent_record.decode(encoded) {
    Ok(state) -> Ok(agent_metadata(state))
    Error(_) ->
      case graph_record.decode(encoded) {
        Ok(state) -> Ok(graph_metadata(state))
        Error(_) ->
          budget_record.decode(encoded)
          |> result.map(fn(record) {
            Budget(run.issued(budget_record.id(record.root)))
          })
          |> result.replace_error(Nil)
      }
  }
}

fn agent_metadata(state: agent.State) -> Metadata {
  let execution = case state.phase {
    agent.Ended(_) | agent.NeverStarted -> Finished
    agent.AwaitingModel(_) | agent.Acting(..) | agent.Stopping(..) ->
      case agent.needs_runner(state) {
        True -> Active
        False -> Waiting
      }
  }
  let actions = agent.snapshot(state).actions
  Run(
    run.issued(state.run),
    execution,
    list.any(actions, fn(action) {
      case action.state {
        run.AwaitingApproval(..) -> True
        _ -> False
      }
    }),
    list.any(actions, fn(action) {
      case action.state {
        run.Uncertain(_) -> True
        _ -> False
      }
    }),
  )
}

fn graph_metadata(state: graph.State) -> Metadata {
  let execution = case state.phase {
    graph.Ended(_) -> Finished
    graph.Ready(_)
    | graph.Queued(_)
    | graph.Running(_)
    | graph.AwaitingApproval(..)
    | graph.WaitingSignal(_)
    | graph.ArmingWait(_)
    | graph.WaitingJob(_)
    | graph.StoppingJob(..)
    | graph.Joining(..)
    | graph.WaitingChild(..)
    | graph.ChildBlocked(..)
    | graph.StoppingChild(..)
    | graph.PreparingFork(_)
    | graph.Forking(..)
    | graph.WaitingFork(..)
    | graph.Blocked(..)
    | graph.Stopping(_) ->
      case graph.needs_runner(state) {
        True -> Active
        False -> Waiting
      }
  }
  let #(approval, reconciliation) = case state.phase {
    graph.AwaitingApproval(..) -> #(True, False)
    graph.Blocked(..)
    | graph.StoppingJob(_, job.RequestUncertain(_), _)
    | graph.Ended(graph.Cancelled(_, graph.UnresolvedCancellation(_)))
    | graph.Ended(graph.Expired(_, graph.UnresolvedCancellation(_))) -> #(
      False,
      True,
    )
    graph.Ready(_)
    | graph.Queued(_)
    | graph.Running(_)
    | graph.WaitingSignal(_)
    | graph.ArmingWait(_)
    | graph.WaitingJob(_)
    | graph.StoppingJob(..)
    | graph.Joining(..)
    | graph.WaitingChild(..)
    | graph.ChildBlocked(..)
    | graph.StoppingChild(..)
    | graph.PreparingFork(_)
    | graph.Forking(..)
    | graph.WaitingFork(..)
    | graph.Stopping(_)
    | graph.Ended(_) -> #(False, False)
  }
  Run(run.issued(state.run), execution, approval, reconciliation)
}

/// Unknown or mismatched source records encode the version only. Backends
/// retain these as explicit unknowns; refreshing cannot invent a healthy state.
pub fn encode(storage_key: String, encoded: String) -> String {
  let checked =
    inspect(encoded)
    |> result.try(fn(metadata) {
      case run.id_to_string(metadata.id) == storage_key {
        True -> Ok(metadata)
        False -> Error(Nil)
      }
    })
  let fields = case checked {
    Ok(Run(_, execution, approval, reconciliation)) -> [
      #("kind", json.string("run")),
      #(
        "execution",
        json.string(case execution {
          Active -> "active"
          Waiting -> "waiting"
          Finished -> "finished"
        }),
      ),
      #("approval", json.bool(approval)),
      #("reconciliation", json.bool(reconciliation)),
    ]
    Ok(Budget(_)) -> [
      #("kind", json.string("budget")),
    ]
    _ -> []
  }
  json.object([#("version", json.int(version)), ..fields]) |> json.to_string
}

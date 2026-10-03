//// Emits Fabric's graph events for one committed transition, derived from
//// the state before and after the commit (see `fabric/telemetry`). The
//// graph runtime calls it after every commit it confirmed, in the process
//// that made the commit.

import fabric/graph/operation
import fabric/internal/graph/controller as g
import fabric/policy
import fabric/run
import fabric/telemetry as o
import gleam/list
import gleam/option.{type Option, None, Some}
import sinal

pub fn committed(before: Option(g.State), after: g.State) -> Nil {
  started(before, after)
  approvals(before, after)
  admitted(before, after)
  settled(before, after)
  cancelled(before, after)
  finished(before, after)
}

fn started(before: Option(g.State), after: g.State) -> Nil {
  case before {
    Some(_) -> Nil
    None ->
      sinal.emit(
        o.graph_started(),
        Nil,
        o.GraphRunStarted(
          after.run,
          after.definition.identity.name,
          after.definition.identity.version,
          option.map(after.parent, parent_run),
          after.root,
          after.correlation,
        ),
      )
  }
}

fn parent_run(parent: run.Parent) -> String {
  case parent {
    run.AgentParent(id, _)
    | run.GraphParent(id, _)
    | run.GraphBranch(id, _, _) -> run.id_to_string(id)
  }
}

fn activation(state: g.State, a: g.Activation) -> o.GraphActivation {
  o.GraphActivation(
    state.run,
    a.id,
    a.attempt,
    a.prepared.node,
    a.prepared.operation.name,
    a.prepared.operation.version,
  )
}

/// The activation whose operation the phase has admitted.
fn admission(phase: g.Phase) -> Option(g.Activation) {
  case phase {
    g.Queued(a)
    | g.Running(a)
    | g.ArmingWait(a)
    | g.WaitingSignal(a)
    | g.WaitingJob(a)
    | g.Joining(a, _)
    | g.WaitingChild(a, _)
    | g.PreparingFork(a) -> Some(a)
    _ -> None
  }
}

fn admitted(before: Option(g.State), after: g.State) -> Nil {
  let earlier = case before {
    Some(state) -> admission(state.phase)
    None -> None
  }
  case admission(after.phase), earlier {
    Some(a), Some(b) if a.id == b.id && a.attempt == b.attempt -> Nil
    Some(a), _ ->
      sinal.emit(
        o.activation_started(),
        Nil,
        o.ActivationStarted(
          activation(after, a),
          kind(a.prepared.kind),
          a.prepared.deadline,
          after.root,
          after.correlation,
        ),
      )
    None, _ -> Nil
  }
}

pub fn kind(kind: operation.Kind) -> policy.OperationKind {
  case kind {
    operation.Activity -> policy.Activity
    operation.Signal -> policy.Signal
    operation.Job(_) -> policy.Job
    operation.OwnedJob(_) -> policy.OwnedJob
    operation.Subgraph -> policy.Subgraph
    operation.Agent -> policy.Agent
    operation.Fork(..) -> policy.Fork
  }
}

fn waiting(phase: g.Phase) -> Option(#(g.Activation, g.Approval)) {
  case phase {
    g.AwaitingApproval(a, approval) -> Some(#(a, approval))
    _ -> None
  }
}

fn approvals(before: Option(g.State), after: g.State) -> Nil {
  let earlier = case before {
    Some(state) -> waiting(state.phase)
    None -> None
  }
  let now = waiting(after.phase)
  case now, earlier {
    Some(#(_, a)), Some(#(_, b)) if a.revision == b.revision -> Nil
    Some(#(a, approval)), _ ->
      sinal.emit(
        o.graph_approval_requested(),
        Nil,
        o.GraphApprovalRequested(
          activation(after, a),
          approval.requirement.name,
          approval.requirement.version,
          approval.revision,
          approval.expires,
          after.root,
          after.correlation,
        ),
      )
    None, _ -> Nil
  }
  case earlier, now {
    Some(#(_, a)), Some(#(_, b)) if a.revision == b.revision -> Nil
    Some(#(a, approval)), _ ->
      case answer(after, a, approval.revision) {
        Some(answered) ->
          sinal.emit(
            o.graph_approval_answered(),
            Nil,
            o.GraphApprovalAnswered(
              activation(after, a),
              approval.revision,
              answered,
              after.root,
              after.correlation,
            ),
          )
        None -> Nil
      }
    None, _ -> Nil
  }
}

/// The answer `after` records to the request `revision` of `a`.
fn answer(
  after: g.State,
  a: g.Activation,
  revision: Int,
) -> Option(o.Answered) {
  case g.activation(after, a.id) {
    Error(Nil) -> None
    Ok(found) ->
      case
        list.find(found.approvals, fn(approval) {
          approval.revision == revision
        })
      {
        Ok(run.Approval(answer: run.Approve, ..)) -> Some(o.Approved)
        Ok(run.Approval(answer: run.Reject(_), ..)) -> Some(o.Rejected)
        Ok(run.Approval(answer: run.Expired, ..)) -> Some(o.Expired)
        Error(Nil) -> None
      }
  }
}

fn settled(before: Option(g.State), after: g.State) -> Nil {
  let known = case before {
    Some(state) -> list.length(state.receipts)
    None -> 0
  }
  list.drop(after.receipts, known)
  |> list.each(fn(receipt) {
    sinal.emit(
      o.activation_settled(),
      Nil,
      o.ActivationSettled(
        activation(after, receipt.activation),
        case receipt.route {
          g.Next(_) -> o.NextNode
          g.Finished -> o.Answer
          g.StoppedRoute -> o.Kept
        },
        after.root,
        after.correlation,
      ),
    )
  })
}

/// Whether the phase records a caller's cancellation.
fn cancelling(phase: g.Phase) -> Bool {
  case phase {
    g.Stopping(_)
    | g.StoppingJob(_, _, operation.CancellationRequested)
    | g.StoppingChild(_, _, operation.CancellationRequested)
    | g.Forking(_, g.ClosingFork(operation.CancellationRequested))
    | g.WaitingFork(_, g.ClosingFork(operation.CancellationRequested))
    | g.Ended(g.Cancelled(..)) -> True
    _ -> False
  }
}

fn cancelled(before: Option(g.State), after: g.State) -> Nil {
  let was = case before {
    Some(state) -> cancelling(state.phase)
    None -> False
  }
  case cancelling(after.phase), was {
    True, False ->
      sinal.emit(
        o.graph_cancelled(),
        Nil,
        o.GraphRunCancelled(after.run, after.root, after.correlation),
      )
    _, _ -> Nil
  }
}

fn finished(before: Option(g.State), after: g.State) -> Nil {
  let was = case before {
    Some(g.State(phase: g.Ended(_), ..)) -> True
    _ -> False
  }
  case after.phase, was {
    g.Ended(outcome), False ->
      sinal.emit(
        o.graph_finished(),
        Nil,
        o.GraphRunFinished(
          after.run,
          case outcome {
            g.Completed(_) -> o.GraphCompleted
            g.Failed(..) -> o.GraphFailed
            g.Exhausted(_) -> o.GraphExhausted
            g.Cancelled(..) -> o.GraphCancelled
            g.Expired(..) -> o.GraphExpired
          },
          after.root,
          after.correlation,
        ),
      )
    _, _ -> Nil
  }
}

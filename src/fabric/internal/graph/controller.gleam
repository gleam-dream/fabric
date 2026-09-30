//// Pure serial graph control. Returned effects are descriptions: the owning
//// runner must commit the complete next state before performing any of them.
//// Native codecs and allowed destinations belong to the bound definition;
//// this module consumes its validated encoded input and completion decisions.

import fabric/graph/child
import fabric/graph/operation.{
  type Recovery, ReplayInterrupted, RequireReconciliation,
}
import fabric/policy
import fabric/run
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string

pub type Prepared {
  Prepared(
    node: String,
    operation: run.Identity,
    input: String,
    recovery: Recovery,
    kind: operation.Kind,
  )
}

pub type Activation {
  Activation(id: Int, attempt: Int, prepared: Prepared)
}

pub type Reference {
  Reference(incarnation: Int, activation: Int, attempt: Int)
}

pub type Approval {
  Approval(
    activation: Int,
    attempt: Int,
    revision: Int,
    requirement: run.Requirement,
  )
}

pub type Definition {
  Definition(identity: run.Identity, signature: String, max_activations: Int)
}

pub type Decision {
  Continue(state: String, next: Prepared)
  Complete(state: String, answer: String)
}

pub type Route {
  Next(node: String)
  Finished
  Canceled
}

pub type Receipt {
  Receipt(activation: Activation, output: String, state: String, route: Route)
}

pub type Problem {
  Uncertain(evidence: String)
  InvalidResult(output: String, reason: String)
}

pub type Fault {
  Denied(reason: String)
  PolicyFailed(reason: String)
  OperationFailed(reason: String)
}

pub type Outcome {
  Completed(answer: String)
  Failed(Activation, Fault)
  Exhausted(next: Prepared)
  Cancelled(Activation, Cancellation)
}

pub type Cancellation {
  BeforeStart
  AfterResult
  AfterFailure(Fault)
  AfterChild(child: String)
  UnresolvedCancellation(Problem)
}

pub type Phase {
  Ready(Activation)
  Queued(Activation)
  Running(Activation)
  AwaitingApproval(Activation, Approval)
  WaitingSignal(Activation)
  Joining(Activation, child: String)
  WaitingChild(Activation, child: String)
  ChildBlocked(Activation, child: String, reason: String)
  StoppingChild(Activation, child: String)
  Blocked(Activation, Problem)
  Stopping(Activation)
  Ended(Outcome)
}

pub type State {
  State(
    run: String,
    definition: Definition,
    incarnation: Int,
    allocated: Int,
    approvals_issued: Int,
    value: String,
    receipts: List(Receipt),
    phase: Phase,
    initial: String,
    parent: Option(child.Parent),
  )
}

pub type Event {
  Inspected(Reference, Result(policy.Decision, String))
  BodyStarted(Reference)
  Returned(Reference, output: String, decision: Decision)
  /// A validated output after cancellation never calls the routing callback.
  CancelledResult(Reference, output: String)
  FailedBody(Reference, Fault)
  Unresolved(Reference, Problem)
  Approved(Approval, Result(policy.Decision, String))
  Rejected(Approval, reason: String)
  Reconciled(activation: Int, attempt: Int, output: String, decision: Decision)
  Signaled(activation: Int, attempt: Int, output: String, decision: Decision)
  ChildReturned(Reference, child: String, output: String, decision: Decision)
  ChildFailed(Reference, child: String, reason: String)
  ChildUnavailable(Reference, child: String, reason: String)
  ChildMappingFailed(Reference, child: String, output: String, reason: String)
  ChildStopped(Reference, child: String, uncertain: Bool)
  ChildWaiting(Reference, child: String)
  ChildCancellationSettled(Reference, child: String)
  Cancel
  Stopped
}

pub type Effect {
  Inspect(Activation)
  Dispatch(Activation)
  Stop
  ObserveChild(Activation, String)
  CancelChild(Activation, String)
}

pub type Rejection {
  InvalidDefinition(String)
  InvalidPrepared(String)
  WrongPhase
  StaleInvocation
  StaleApproval
  AlreadyEnded
}

pub fn start(
  run: String,
  definition: Definition,
  value: String,
  entry: Prepared,
) -> Result(#(State, List(Effect)), Rejection) {
  use _ <- result.try(check_definition(definition))
  use _ <- result.try(check_prepared(entry))
  use _ <- result.try(case run.parse_id(run) {
    Ok(_) -> Ok(Nil)
    Error(Nil) -> Error(InvalidDefinition("invalid run identity"))
  })
  let activation = Activation(1, 1, entry)
  Ok(
    #(
      State(run, definition, 1, 1, 0, value, [], Ready(activation), value, None),
      [
        Inspect(activation),
      ],
    ),
  )
}

pub fn reference(state: State, activation: Activation) -> Reference {
  Reference(state.incarnation, activation.id, activation.attempt)
}

pub fn step(
  state: State,
  event: Event,
) -> Result(#(State, List(Effect)), Rejection) {
  case event, state.phase {
    ChildWaiting(ref, id), Joining(a, current) if id == current -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(#(State(..state, phase: WaitingChild(a, id)), []))
    }
    ChildCancellationSettled(ref, id),
      Ended(Cancelled(a, UnresolvedCancellation(_)))
      if a.prepared.kind == operation.Subgraph
    -> {
      use _ <- result.try(matches(state, a, ref))
      use _ <- result.try(case id == child.reserved_id(state.run, a.id) {
        True -> Ok(Nil)
        False -> Error(StaleInvocation)
      })
      Ok(ended(state, Cancelled(a, AfterChild(id))))
    }
    ChildUnavailable(ref, id, reason), Joining(a, current) if id == current -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(#(State(..state, phase: ChildBlocked(a, id, reason)), []))
    }
    ChildMappingFailed(ref, id, output, reason), Joining(a, current)
      if id == current
    -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(
        #(State(..state, phase: Blocked(a, InvalidResult(output, reason))), []),
      )
    }
    ChildReturned(ref, id, output, decision), Joining(a, current)
      if id == current
    -> {
      use _ <- result.try(matches(state, a, ref))
      complete(state, a, output, decision)
    }
    ChildFailed(ref, id, reason), Joining(a, current) if id == current -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(ended(state, Failed(a, OperationFailed(reason))))
    }
    ChildStopped(ref, id, uncertain), StoppingChild(a, current)
      if id == current
    -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(ended(
        state,
        Cancelled(a, case uncertain {
          True ->
            UnresolvedCancellation(Uncertain(
              "child cancellation retains uncertain effects",
            ))
          False -> AfterChild(id)
        }),
      ))
    }
    Signaled(id, attempt, output, decision), WaitingSignal(activation) -> {
      use _ <- result.try(matches_activation(activation, id, attempt))
      complete(state, activation, output, decision)
    }
    CancelledResult(ref, output), Stopping(activation)
    | CancelledResult(ref, output),
      Ended(Cancelled(activation, UnresolvedCancellation(_)))
      if activation.prepared.kind == operation.Activity
    -> {
      use _ <- result.try(matches(state, activation, ref))
      Ok(cancelled_result(state, activation, output))
    }
    Inspected(ref, decision), Ready(activation) -> {
      use _ <- result.try(matches(state, activation, ref))
      inspect(state, activation, decision)
    }
    BodyStarted(ref), Queued(activation) -> {
      use _ <- result.try(matches(state, activation, ref))
      Ok(#(State(..state, phase: Running(activation)), []))
    }
    Returned(ref, output, decision), Running(activation) -> {
      use _ <- result.try(matches(state, activation, ref))
      complete(state, activation, output, decision)
    }
    Returned(ref, output, _), Stopping(activation) -> {
      use _ <- result.try(matches(state, activation, ref))
      Ok(cancelled_result(state, activation, output))
    }
    FailedBody(ref, fault), Running(activation) -> {
      use _ <- result.try(matches(state, activation, ref))
      Ok(ended(state, Failed(activation, fault)))
    }
    FailedBody(ref, fault), Stopping(activation) -> {
      use _ <- result.try(matches(state, activation, ref))
      Ok(ended(state, Cancelled(activation, AfterFailure(fault))))
    }
    Unresolved(ref, problem), Running(activation) -> {
      use _ <- result.try(matches(state, activation, ref))
      Ok(#(State(..state, phase: Blocked(activation, problem)), []))
    }
    Unresolved(ref, problem), Stopping(activation) -> {
      use _ <- result.try(matches(state, activation, ref))
      Ok(ended(state, Cancelled(activation, UnresolvedCancellation(problem))))
    }
    Approved(answer, decision), AwaitingApproval(activation, current) -> {
      use _ <- result.try(approval_matches(answer, current))
      case decision {
        Ok(policy.Allow) -> Ok(queue(state, activation))
        Ok(policy.RequireApproval(requirement))
          if requirement == current.requirement
        -> Ok(queue(state, activation))
        decision -> inspect(state, activation, decision)
      }
    }
    Rejected(answer, reason), AwaitingApproval(activation, current) -> {
      use _ <- result.try(approval_matches(answer, current))
      Ok(ended(state, Failed(activation, Denied(reason))))
    }
    Reconciled(id, attempt, output, decision), Blocked(activation, _) -> {
      use _ <- result.try(matches_activation(activation, id, attempt))
      complete(state, activation, output, decision)
    }
    Reconciled(id, attempt, output, _),
      Ended(Cancelled(activation, UnresolvedCancellation(_)))
    -> {
      use _ <- result.try(matches_activation(activation, id, attempt))
      Ok(cancelled_result(state, activation, output))
    }
    Cancel, Ended(_) -> Error(AlreadyEnded)
    Cancel, Joining(a, id)
    | Cancel, WaitingChild(a, id)
    | Cancel, ChildBlocked(a, id, _)
    -> Ok(#(State(..state, phase: StoppingChild(a, id)), [CancelChild(a, id)]))
    Cancel, StoppingChild(a, id) -> Ok(#(state, [CancelChild(a, id)]))
    Cancel, Ready(activation)
    | Cancel, Queued(activation)
    | Cancel, AwaitingApproval(activation, _)
    | Cancel, WaitingSignal(activation)
    -> Ok(ended(state, Cancelled(activation, BeforeStart)))
    Cancel, Running(activation) ->
      Ok(#(State(..state, phase: Stopping(activation)), [Stop]))
    Cancel, Stopping(_) -> Ok(#(state, []))
    Cancel, Blocked(activation, problem) ->
      Ok(ended(state, Cancelled(activation, UnresolvedCancellation(problem))))
    Stopped, Stopping(activation) ->
      Ok(ended(
        state,
        Cancelled(
          activation,
          UnresolvedCancellation(Uncertain(
            "cancelled after body start without a committed result",
          )),
        ),
      ))
    _, _ -> Error(WrongPhase)
  }
}

fn inspect(
  state: State,
  activation: Activation,
  decision: Result(policy.Decision, String),
) -> Result(#(State, List(Effect)), Rejection) {
  case decision {
    Error(reason) -> Ok(ended(state, Failed(activation, PolicyFailed(reason))))
    Ok(policy.Deny(reason)) ->
      Ok(ended(state, Failed(activation, Denied(reason))))
    Ok(policy.Allow) -> Ok(queue(state, activation))
    Ok(policy.RequireApproval(requirement)) ->
      case string.trim(requirement.name) == "" || requirement.version < 1 {
        True ->
          Ok(ended(
            state,
            Failed(activation, PolicyFailed("invalid approval requirement")),
          ))
        False -> {
          let revision = state.approvals_issued + 1
          let approval =
            Approval(activation.id, activation.attempt, revision, requirement)
          Ok(
            #(
              State(
                ..state,
                approvals_issued: revision,
                phase: AwaitingApproval(activation, approval),
              ),
              [],
            ),
          )
        }
      }
  }
}

fn queue(state: State, activation: Activation) -> #(State, List(Effect)) {
  case activation.prepared.kind {
    operation.Activity -> #(State(..state, phase: Queued(activation)), [
      Dispatch(activation),
    ])
    operation.Signal -> #(State(..state, phase: WaitingSignal(activation)), [])
    operation.Subgraph -> {
      let id = child.reserved_id(state.run, activation.id)
      #(State(..state, phase: Joining(activation, id)), [
        ObserveChild(activation, id),
      ])
    }
  }
}

fn ended(state: State, outcome: Outcome) -> #(State, List(Effect)) {
  #(State(..state, phase: Ended(outcome)), [])
}

fn complete(
  state: State,
  activation: Activation,
  output: String,
  decision: Decision,
) -> Result(#(State, List(Effect)), Rejection) {
  case decision {
    Complete(value, answer) ->
      Ok(ended(
        State(
          ..state,
          value:,
          receipts: list.append(state.receipts, [
            Receipt(activation, output, value, Finished),
          ]),
        ),
        Completed(answer),
      ))
    Continue(value, next) -> {
      use _ <- result.try(check_prepared(next))
      let state =
        State(
          ..state,
          value:,
          receipts: list.append(state.receipts, [
            Receipt(activation, output, value, Next(next.node)),
          ]),
        )
      case state.allocated >= state.definition.max_activations {
        True -> Ok(ended(state, Exhausted(next)))
        False -> {
          let next = Activation(state.allocated + 1, 1, next)
          Ok(
            #(State(..state, allocated: next.id, phase: Ready(next)), [
              Inspect(next),
            ]),
          )
        }
      }
    }
  }
}

fn cancelled_result(
  state: State,
  activation: Activation,
  output: String,
) -> #(State, List(Effect)) {
  ended(
    State(
      ..state,
      receipts: list.append(state.receipts, [
        Receipt(activation, output, state.value, Canceled),
      ]),
    ),
    Cancelled(activation, AfterResult),
  )
}

/// Recovery itself must be committed before returned inspection effects run.
pub fn recover(state: State) -> Result(#(State, List(Effect)), Rejection) {
  let recovered = State(..state, incarnation: state.incarnation + 1)
  case state.phase {
    Ended(_) -> Error(AlreadyEnded)
    Joining(a, id) | WaitingChild(a, id) | ChildBlocked(a, id, _) ->
      Ok(#(State(..recovered, phase: Joining(a, id)), [ObserveChild(a, id)]))
    StoppingChild(a, id) -> Ok(#(recovered, [CancelChild(a, id)]))
    Ready(activation) | Queued(activation) ->
      Ok(#(State(..recovered, phase: Ready(activation)), [Inspect(activation)]))
    Running(activation) ->
      case activation.prepared.recovery {
        ReplayInterrupted(max) if activation.attempt < max -> {
          let next = Activation(..activation, attempt: activation.attempt + 1)
          Ok(#(State(..recovered, phase: Ready(next)), [Inspect(next)]))
        }
        RequireReconciliation | ReplayInterrupted(_) ->
          Ok(
            #(
              State(
                ..recovered,
                phase: Blocked(
                  activation,
                  Uncertain(
                    "runner lost after body start without a committed result",
                  ),
                ),
              ),
              [],
            ),
          )
      }
    AwaitingApproval(_, _) | WaitingSignal(_) | Blocked(_, _) ->
      Ok(#(recovered, []))
    Stopping(activation) ->
      Ok(ended(
        recovered,
        Cancelled(
          activation,
          UnresolvedCancellation(Uncertain(
            "runner lost while cancelling a started body",
          )),
        ),
      ))
  }
}

fn matches(
  state: State,
  activation: Activation,
  ref: Reference,
) -> Result(Nil, Rejection) {
  case ref == reference(state, activation) {
    True -> Ok(Nil)
    False -> Error(StaleInvocation)
  }
}

fn matches_activation(
  activation: Activation,
  id: Int,
  attempt: Int,
) -> Result(Nil, Rejection) {
  case activation.id == id && activation.attempt == attempt {
    True -> Ok(Nil)
    False -> Error(StaleInvocation)
  }
}

fn approval_matches(
  answer: Approval,
  current: Approval,
) -> Result(Nil, Rejection) {
  case answer == current {
    True -> Ok(Nil)
    False -> Error(StaleApproval)
  }
}

pub fn check_definition(definition: Definition) -> Result(Nil, Rejection) {
  case
    string.trim(definition.identity.name) == ""
    || definition.identity.version < 1
    || string.trim(definition.signature) == ""
    || definition.max_activations < 1
  {
    True ->
      Error(InvalidDefinition(
        "name, version, signature and positive activation limit required",
      ))
    False -> Ok(Nil)
  }
}

pub fn check_prepared(prepared: Prepared) -> Result(Nil, Rejection) {
  let attempts = case prepared.recovery {
    RequireReconciliation -> 1
    ReplayInterrupted(max) -> max
  }
  case
    string.trim(prepared.node) == ""
    || string.trim(prepared.operation.name) == ""
    || prepared.operation.version < 1
    || attempts < 1
    || prepared.kind != operation.Activity
    && prepared.recovery != RequireReconciliation
  {
    True ->
      Error(InvalidPrepared(
        "node, operation version and positive attempt bound required",
      ))
    False -> Ok(Nil)
  }
}

pub fn needs_runner(state: State) -> Bool {
  case state.phase {
    Ready(_)
    | Queued(_)
    | Running(_)
    | Stopping(_)
    | Joining(_, _)
    | StoppingChild(_, _) -> True
    AwaitingApproval(_, _)
    | WaitingSignal(_)
    | WaitingChild(_, _)
    | Blocked(_, _)
    | ChildBlocked(_, _, _)
    | Ended(_) -> False
  }
}

/// Cancellation when nobody can settle the old executor's reports.
pub fn cancel_abandoned(
  state: State,
) -> Result(#(State, List(Effect)), Rejection) {
  use #(state, effects) <- result.try(step(state, Cancel))
  case state.phase {
    Stopping(_) -> step(state, Stopped)
    _ -> Ok(#(state, effects))
  }
}

//// Pure serial graph control. Returned effects are descriptions: the owning
//// runner must commit the complete next state before performing any of them.
//// Native codecs and allowed destinations belong to the bound definition;
//// this module consumes its validated encoded input and completion decisions.

import fabric/budget as quota
import fabric/graph/child
import fabric/graph/job
import fabric/graph/operation.{
  type Recovery, ReplayInterrupted, RequireReconciliation,
}
import fabric/internal/budget/model as budget
import fabric/policy
import fabric/run
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Prepared {
  Prepared(
    node: String,
    operation: run.Identity,
    input: String,
    recovery: Recovery,
    kind: operation.Kind,
    deadline: Option(Int),
  )
}

pub type Activation {
  Activation(id: Int, attempt: Int, prepared: Prepared, deadline: Option(Int))
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
  FamilyBudget(quota.Denial)
  DeadlineExpired(due: Int)
}

pub type Outcome {
  Completed(answer: String)
  Failed(Activation, Fault)
  Exhausted(next: Prepared)
  Cancelled(Activation, Cancellation)
}

pub type Cancellation {
  BeforeStart
  JobDetached
  JobStopped
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
  ArmingSignal(Activation)
  WaitingJob(Activation)
  StoppingJob(Activation, job.CancellationProgress)
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
    parent: Option(run.Parent),
    family_budget: Option(budget.Declaration),
  )
}

pub type Event {
  Inspected(Reference, Result(policy.Decision, String))
  BudgetRefused(Reference, quota.Denial)
  BodyStarted(Reference)
  Returned(Reference, output: String, decision: Decision)
  /// A validated output after cancellation never calls the routing callback.
  CancelledResult(Reference, output: String)
  FailedBody(Reference, Fault)
  Unresolved(Reference, Problem)
  Approved(Approval, Result(policy.Decision, String))
  Rejected(Approval, reason: String)
  Reconciled(activation: Int, attempt: Int, output: String, decision: Decision)
  JobCompleted(Reference, output: String, decision: Decision)
  JobFailed(Reference, reason: String)
  JobStopRequested(Reference)
  JobStopRefused(Reference, reason: String)
  JobConfirmedStopped(Reference)
  Signaled(activation: Int, attempt: Int, output: String, decision: Decision)
  SignalArmed(Reference, now: Int)
  ExpireSignal(Reference, now: Int)
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
  RequestJobStop(Activation)
  ArmSignal(Activation)
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
  let activation = Activation(1, 1, entry, None)
  Ok(
    #(
      State(
        run,
        definition,
        1,
        1,
        0,
        value,
        [],
        Ready(activation),
        value,
        None,
        None,
      ),
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
    SignalArmed(ref, now), ArmingSignal(a) -> {
      use _ <- result.try(matches(state, a, ref))
      use within <- result.try(case a.prepared.deadline, now >= 0 {
        Some(within), True -> Ok(within)
        _, _ -> Error(InvalidPrepared("signal deadline has no valid clock"))
      })
      let armed = Activation(..a, deadline: Some(now + within))
      Ok(#(State(..state, phase: WaitingSignal(armed)), []))
    }
    ExpireSignal(ref, now), WaitingSignal(a) -> {
      use _ <- result.try(matches(state, a, ref))
      case a.deadline {
        Some(due) if now >= due ->
          Ok(ended(state, Failed(a, DeadlineExpired(due))))
        _ -> Error(WrongPhase)
      }
    }
    BodyStarted(ref), StoppingJob(a, job.RequestQueued) -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(#(State(..state, phase: StoppingJob(a, job.RequestStarted)), []))
    }
    JobStopRequested(ref), StoppingJob(a, job.RequestStarted) -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(#(State(..state, phase: StoppingJob(a, job.RequestAccepted)), []))
    }
    JobStopRefused(ref, reason), StoppingJob(a, job.RequestStarted) -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(
        #(State(..state, phase: StoppingJob(a, job.RequestRefused(reason))), []),
      )
    }
    Unresolved(ref, problem), StoppingJob(a, job.RequestStarted) -> {
      use _ <- result.try(matches(state, a, ref))
      let evidence = case problem {
        Uncertain(reason) -> reason
        InvalidResult(output, reason) -> reason <> ": " <> output
      }
      Ok(
        #(
          State(..state, phase: StoppingJob(a, job.RequestUncertain(evidence))),
          [],
        ),
      )
    }
    JobConfirmedStopped(ref), StoppingJob(a, progress) -> {
      use _ <- result.try(matches(state, a, ref))
      use _ <- result.try(stoppable(progress))
      Ok(ended(state, Cancelled(a, JobStopped)))
    }
    CancelledResult(ref, output), StoppingJob(a, progress) -> {
      use _ <- result.try(matches(state, a, ref))
      use _ <- result.try(stoppable(progress))
      Ok(cancelled_result(state, a, output))
    }
    JobFailed(ref, reason), StoppingJob(a, progress) -> {
      use _ <- result.try(matches(state, a, ref))
      use _ <- result.try(stoppable(progress))
      Ok(ended(state, Cancelled(a, AfterFailure(OperationFailed(reason)))))
    }
    ChildWaiting(ref, id), Joining(a, current) if id == current -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(#(State(..state, phase: WaitingChild(a, id)), []))
    }
    ChildCancellationSettled(ref, id),
      Ended(Cancelled(a, UnresolvedCancellation(_)))
      if {
        a.prepared.kind == operation.Subgraph
        || a.prepared.kind == operation.Agent
      }
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
    JobCompleted(ref, output, decision), WaitingJob(activation) -> {
      use _ <- result.try(matches(state, activation, ref))
      complete(state, activation, output, decision)
    }
    JobFailed(ref, reason), WaitingJob(activation) -> {
      use _ <- result.try(matches(state, activation, ref))
      Ok(ended(state, Failed(activation, OperationFailed(reason))))
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
    BudgetRefused(ref, reason), Ready(activation)
    | BudgetRefused(ref, reason), AwaitingApproval(activation, _)
    -> {
      use _ <- result.try(matches(state, activation, ref))
      Ok(ended(state, Failed(activation, FamilyBudget(reason))))
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
    Cancel, WaitingJob(a) ->
      case a.prepared.kind {
        operation.OwnedJob(_) ->
          Ok(
            #(State(..state, phase: StoppingJob(a, job.RequestQueued)), [
              RequestJobStop(a),
            ]),
          )
        _ -> Ok(ended(state, Cancelled(a, JobDetached)))
      }
    Cancel, StoppingJob(_, _) -> Ok(#(state, []))
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
    | Cancel, ArmingSignal(activation)
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
    operation.Signal ->
      case activation.prepared.deadline {
        None -> #(State(..state, phase: WaitingSignal(activation)), [])
        Some(_) -> #(State(..state, phase: ArmingSignal(activation)), [
          ArmSignal(activation),
        ])
      }
    operation.Job(_) | operation.OwnedJob(_) -> #(
      State(..state, phase: WaitingJob(activation)),
      [],
    )
    operation.Subgraph | operation.Agent -> {
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
          let next = Activation(state.allocated + 1, 1, next, None)
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
    ArmingSignal(a) -> Ok(#(recovered, [ArmSignal(a)]))
    StoppingJob(a, job.RequestQueued) -> Ok(#(recovered, [RequestJobStop(a)]))
    StoppingJob(a, job.RequestStarted) ->
      Ok(
        #(
          State(
            ..recovered,
            phase: StoppingJob(
              a,
              job.RequestUncertain("runner lost after stop request started"),
            ),
          ),
          [],
        ),
      )
    StoppingJob(_, _) -> Ok(#(recovered, []))
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
    AwaitingApproval(_, _) | WaitingSignal(_) | WaitingJob(_) | Blocked(_, _) ->
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
  use _ <- result.try(case prepared.deadline, prepared.kind {
    None, _ -> Ok(Nil)
    Some(ms), operation.Signal if ms > 0 && ms <= 4_294_967_295 -> Ok(Nil)
    _, _ -> Error(InvalidPrepared("invalid signal deadline"))
  })
  use _ <- result.try(case prepared.kind {
    operation.Job(polling) | operation.OwnedJob(polling) ->
      case job.valid_polling(polling) {
        True -> Ok(Nil)
        False -> Error(InvalidPrepared("invalid job polling interval"))
      }
    _ -> Ok(Nil)
  })
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
    StoppingJob(_, job.RequestQueued) | StoppingJob(_, job.RequestStarted) ->
      True
    StoppingJob(_, _) -> False
    Ready(_)
    | ArmingSignal(_)
    | Queued(_)
    | Running(_)
    | Stopping(_)
    | Joining(_, _)
    | StoppingChild(_, _) -> True
    AwaitingApproval(_, _)
    | WaitingSignal(_)
    | WaitingJob(_)
    | WaitingChild(_, _)
    | Blocked(_, _)
    | ChildBlocked(_, _, _)
    | Ended(_) -> False
  }
}

fn stoppable(progress: job.CancellationProgress) -> Result(Nil, Rejection) {
  case progress {
    job.RequestQueued | job.RequestStarted -> Error(WrongPhase)
    job.RequestAccepted | job.RequestRefused(_) | job.RequestUncertain(_) ->
      Ok(Nil)
  }
}

/// Cancellation when nobody can settle the old executor's reports.
pub fn cancel_abandoned(
  state: State,
) -> Result(#(State, List(Effect)), Rejection) {
  use #(state, effects) <- result.try(step(state, Cancel))
  case state.phase {
    Stopping(_) -> step(state, Stopped)
    StoppingJob(a, job.RequestStarted) ->
      step(
        state,
        Unresolved(
          reference(state, a),
          Uncertain("owner lost after stop request started"),
        ),
      )
    StoppingJob(a, job.RequestQueued) -> Ok(#(state, [RequestJobStop(a)]))
    _ -> Ok(#(state, effects))
  }
}

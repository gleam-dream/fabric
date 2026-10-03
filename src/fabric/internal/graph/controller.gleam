//// Pure serial graph control. Returned effects are descriptions: the owning
//// runner must commit the complete next state before performing any of them.
//// Native codecs and allowed destinations belong to the bound definition;
//// this module consumes its validated encoded input and completion decisions.

import fabric/budget as quota
import fabric/graph/fork
import fabric/graph/job
import fabric/graph/operation.{
  type Recovery, ReplayInterrupted, RequireReconciliation,
}
import fabric/internal/budget/model as budget
import fabric/internal/graph/attachment
import fabric/internal/graph/fork as scope
import fabric/internal/run_id
import fabric/policy
import fabric/reviewer.{type Reviewer}
import fabric/run
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sinal/correlation.{type Correlation}

pub type Prepared {
  Prepared(
    node: String,
    operation: run.DefinitionId,
    input: String,
    recovery: Recovery,
    kind: operation.Kind,
    deadline: Option(Int),
  )
}

/// `approvals` are the answered approval requests of this attempt, oldest
/// first: who approved or rejected it, or that it expired.
pub type Activation {
  Activation(
    id: Int,
    attempt: Int,
    prepared: Prepared,
    deadline: Option(Int),
    approvals: List(run.Approval),
  )
}

pub type Reference {
  Reference(incarnation: Int, activation: Int, attempt: Int)
}

/// A waiting approval request. `expires` is its deadline in UTC Unix
/// milliseconds by the store's clock; `None` never expires (also every
/// request stored before deadlines existed).
pub type Approval {
  Approval(
    activation: Int,
    attempt: Int,
    revision: Int,
    requirement: run.Requirement,
    expires: Option(Int),
  )
}

pub type Definition {
  Definition(
    identity: run.DefinitionId,
    signature: String,
    max_activations: Int,
  )
}

pub type Decision {
  Continue(state: String, next: Prepared)
  Complete(state: String, answer: String)
}

pub type Route {
  Next(node: String)
  Finished
  StoppedRoute
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
  /// The approval request expired unanswered at `due`.
  ApprovalExpired(due: Int)
}

pub type Outcome {
  Completed(answer: String)
  Failed(Activation, Fault)
  Exhausted(next: Prepared)
  Cancelled(Activation, Cancellation)
  Expired(Activation, Cancellation)
}

pub type Cancellation {
  BeforeStart
  JobDetached
  JobStopped
  AfterResult
  AfterFailure(Fault)
  AfterChild(child: String)
  AfterFork
  UnresolvedCancellation(Problem)
}

pub type ForkMode {
  JoiningFork
  ClosingFork(operation.StopReason)
}

pub type Phase {
  Ready(Activation)
  Queued(Activation)
  Running(Activation)
  AwaitingApproval(Activation, Approval)
  WaitingSignal(Activation)
  ArmingWait(Activation)
  WaitingJob(Activation)
  StoppingJob(Activation, job.CancellationProgress, operation.StopReason)
  Joining(Activation, child: String)
  WaitingChild(Activation, child: String)
  ChildBlocked(Activation, child: String, reason: String)
  StoppingChild(Activation, child: String, cause: operation.StopReason)
  PreparingFork(Activation)
  Forking(Activation, ForkMode)
  WaitingFork(Activation, ForkMode)
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
    forks: List(fork.Snapshot),
    /// Carried in every event and operation invocation of the run, and
    /// inherited by its child runs.
    correlation: Correlation,
    /// The id of the family's root run: the run itself for a root.
    root: String,
  )
}

/// `expires` is the deadline an approval request issued by the event gets
/// (the runner computes it from the store's clock); `None` never expires.
pub type Event {
  Inspected(Reference, Result(policy.Decision, String), expires: Option(Int))
  BudgetRefused(Reference, quota.Denial)
  BodyStarted(Reference)
  Returned(Reference, output: String, decision: Decision)
  /// A validated output after cancellation never calls the routing callback.
  CancelledResult(Reference, output: String)
  FailedBody(Reference, Fault)
  Unresolved(Reference, Problem)
  Approved(
    Approval,
    Result(policy.Decision, String),
    reviewer: Reviewer,
    expires: Option(Int),
  )
  Rejected(Approval, reason: String, reviewer: Reviewer)
  /// The approval request's deadline passed at `now` (store clock).
  ExpireApproval(Approval, now: Int)
  Reconciled(activation: Int, attempt: Int, output: String, decision: Decision)
  JobCompleted(Reference, output: String, decision: Decision)
  JobFailed(Reference, reason: String)
  JobStopRequested(Reference)
  JobStopRefused(Reference, reason: String)
  JobConfirmedStopped(Reference)
  Signaled(activation: Int, attempt: Int, output: String, decision: Decision)
  WaitArmed(Reference, now: Int)
  ExpireWait(Reference, now: Int)
  JobExpired(Reference, now: Int, progress: job.Progress(String))
  ChildReturned(Reference, child: String, output: String, decision: Decision)
  ChildFailed(Reference, child: String, reason: String)
  ChildUnavailable(Reference, child: String, reason: String)
  ChildMappingFailed(Reference, child: String, output: String, reason: String)
  ChildStopped(Reference, child: String, uncertain: Bool)
  ChildWaiting(Reference, child: String)
  ChildCancellationSettled(Reference, child: String)
  ForkPrepared(Reference, Result(List(fork.Request), String))
  ForkAdmitted(Reference, fork.Reference)
  ForkRejected(Reference, fork.Reference, reason: String)
  ForkObserved(Reference, fork.Reference, fork.Progress)
  ForkWaiting(Reference)
  ForkReturned(Reference, output: String, decision: Decision)
  ForkMappingFailed(Reference, output: String, reason: String)
  ForkStopped(Reference)
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
  ArmWait(Activation)
  PrepareFork(Activation)
  ObserveFork(Activation)
}

pub type Rejection {
  InvalidDefinition(String)
  InvalidPrepared(String)
  WrongPhase
  StaleInvocation
  StaleApproval
  AlreadyEnded
}

/// A root run's first state, with the correlation derived from its id.
pub fn start(
  run: String,
  definition: Definition,
  value: String,
  entry: Prepared,
) -> Result(#(State, List(Effect)), Rejection) {
  start_correlated(
    run,
    definition,
    value,
    entry,
    correlation.from_key(run),
    run,
  )
}

/// `start` with the run's correlation and its family's root.
pub fn start_correlated(
  run: String,
  definition: Definition,
  value: String,
  entry: Prepared,
  correlation: Correlation,
  root: String,
) -> Result(#(State, List(Effect)), Rejection) {
  use _ <- result.try(check_definition(definition))
  use _ <- result.try(check_prepared(entry))
  use _ <- result.try(case run.parse_id(run) {
    Ok(_) -> Ok(Nil)
    Error(Nil) -> Error(InvalidDefinition("invalid run identity"))
  })
  let activation = Activation(1, 1, entry, None, [])
  Ok(
    #(
      State(
        run:,
        definition:,
        incarnation: 1,
        allocated: 1,
        approvals_issued: 0,
        value:,
        receipts: [],
        phase: Ready(activation),
        initial: value,
        parent: None,
        family_budget: None,
        forks: [],
        correlation:,
        root:,
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
    ForkPrepared(ref, prepared), PreparingFork(a) -> {
      use _ <- result.try(matches(state, a, ref))
      let made = {
        use members <- result.try(prepared)
        use #(maximum, concurrency) <- result.try(case a.prepared.kind {
          operation.Fork(maximum, concurrency, _) -> Ok(#(maximum, concurrency))
          _ -> Error("activation is not a fork")
        })
        scope.new(
          fork.Occurrence(run_id.from_string(state.run), a.id),
          members,
          maximum,
          concurrency,
        )
        |> result.map_error(string.inspect)
      }
      case made {
        Error(reason) -> Ok(ended(state, Failed(a, OperationFailed(reason))))
        Ok(fork) ->
          Ok(
            #(
              State(
                ..state,
                forks: list.append(state.forks, [scope.snapshot(fork)]),
                phase: Forking(a, JoiningFork),
              ),
              [ObserveFork(a)],
            ),
          )
      }
    }
    ForkAdmitted(ref, member), Forking(a, JoiningFork) -> {
      use _ <- result.try(matches(state, a, ref))
      use fork <- result.try(current_fork(state, a.id))
      use fork <- result.try(
        scope.admit(fork, member) |> result.map_error(fn(_) { WrongPhase }),
      )
      Ok(#(save_fork(state, fork), []))
    }
    ForkRejected(ref, member, reason), Forking(a, JoiningFork) -> {
      use _ <- result.try(matches(state, a, ref))
      use fork <- result.try(current_fork(state, a.id))
      use fork <- result.try(
        scope.reject(fork, member, reason)
        |> result.map_error(fn(_) { WrongPhase }),
      )
      Ok(#(save_fork(state, fork), []))
    }
    ForkObserved(ref, member, progress), Forking(a, _) -> {
      use _ <- result.try(matches(state, a, ref))
      use fork <- result.try(current_fork(state, a.id))
      use fork <- result.try(
        scope.observe(fork, member, progress)
        |> result.map_error(fn(_) { WrongPhase }),
      )
      Ok(#(save_fork(state, fork), []))
    }
    ForkWaiting(ref), Forking(a, mode) -> {
      use _ <- result.try(matches(state, a, ref))
      use fork <- result.try(current_fork(state, a.id))
      use _ <- result.try(case scope.can_wait(fork) {
        False -> Error(WrongPhase)
        True -> Ok(Nil)
      })
      Ok(#(State(..state, phase: WaitingFork(a, mode)), []))
    }
    ForkReturned(ref, output, decision), Forking(a, JoiningFork) -> {
      use _ <- result.try(matches(state, a, ref))
      use fork <- result.try(current_fork(state, a.id))
      use _ <- result.try(case scope.join(fork) {
        scope.Ready(Ok(_)) | scope.Ready(Error(fork.MemberFailed(_))) -> Ok(Nil)
        _ -> Error(WrongPhase)
      })
      complete(state, a, output, decision)
    }
    ForkMappingFailed(ref, output, reason), Forking(a, JoiningFork) -> {
      use _ <- result.try(matches(state, a, ref))
      use fork <- result.try(current_fork(state, a.id))
      use _ <- result.try(case scope.join(fork) {
        scope.Ready(Ok(_)) | scope.Ready(Error(fork.MemberFailed(_))) -> Ok(Nil)
        _ -> Error(WrongPhase)
      })
      Ok(
        #(State(..state, phase: Blocked(a, InvalidResult(output, reason))), []),
      )
    }
    ForkStopped(ref), Forking(a, ClosingFork(cause)) -> {
      use _ <- result.try(matches(state, a, ref))
      use fork <- result.try(current_fork(state, a.id))
      case scope.join(fork) {
        scope.Ready(_) -> Ok(stopped_operation(state, a, cause, AfterFork))
        _ -> Error(WrongPhase)
      }
    }
    Cancel, PreparingFork(a) -> Ok(ended(state, Cancelled(a, BeforeStart)))
    Cancel, Forking(a, mode) | Cancel, WaitingFork(a, mode) -> {
      use fork <- result.try(current_fork(state, a.id))
      let state = save_fork(state, scope.cancel(fork))
      let cause = case mode {
        JoiningFork -> operation.CancellationRequested
        ClosingFork(cause) -> cause
      }
      Ok(
        #(State(..state, phase: Forking(a, ClosingFork(cause))), [
          ObserveFork(a),
        ]),
      )
    }
    WaitArmed(ref, now), ArmingWait(a) -> {
      use _ <- result.try(matches(state, a, ref))
      use within <- result.try(case a.prepared.deadline, now >= 0 {
        Some(within), True -> Ok(within)
        _, _ -> Error(InvalidPrepared("wait deadline has no valid clock"))
      })
      let armed = Activation(..a, deadline: Some(now + within))
      Ok(waiting(state, armed))
    }
    ExpireWait(ref, now), WaitingSignal(a) -> {
      use _ <- result.try(matches(state, a, ref))
      case a.deadline {
        Some(due) if now >= due ->
          Ok(ended(state, Failed(a, DeadlineExpired(due))))
        _ -> Error(WrongPhase)
      }
    }
    ExpireWait(ref, now), WaitingJob(a) -> {
      use _ <- result.try(matches(state, a, ref))
      expire_job(state, a, now, job.Pending)
    }
    ExpireWait(ref, now), PreparingFork(a)
    | ExpireWait(ref, now), Forking(a, JoiningFork)
    | ExpireWait(ref, now), WaitingFork(a, JoiningFork)
    -> {
      use _ <- result.try(matches(state, a, ref))
      expire_fork(state, a, now)
    }
    ExpireWait(ref, now), Joining(a, id)
    | ExpireWait(ref, now), WaitingChild(a, id)
    | ExpireWait(ref, now), ChildBlocked(a, id, _)
    -> {
      use _ <- result.try(matches(state, a, ref))
      expire_child(state, a, id, now)
    }
    ExpireWait(ref, now), Blocked(a, InvalidResult(_, _)) -> {
      use _ <- result.try(matches(state, a, ref))
      case a.prepared.kind {
        operation.Fork(..) -> expire_fork(state, a, now)
        _ ->
          expire_child(state, a, attachment.reserved_id(state.run, a.id), now)
      }
    }
    JobExpired(ref, now, progress), WaitingJob(a) -> {
      use _ <- result.try(matches(state, a, ref))
      expire_job(state, a, now, progress)
    }
    BodyStarted(ref), StoppingJob(a, job.RequestQueued, cause) -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(
        #(State(..state, phase: StoppingJob(a, job.RequestStarted, cause)), []),
      )
    }
    JobStopRequested(ref), StoppingJob(a, job.RequestStarted, cause) -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(
        #(State(..state, phase: StoppingJob(a, job.RequestAccepted, cause)), []),
      )
    }
    JobStopRefused(ref, reason), StoppingJob(a, job.RequestStarted, cause) -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(
        #(
          State(
            ..state,
            phase: StoppingJob(a, job.RequestRefused(reason), cause),
          ),
          [],
        ),
      )
    }
    Unresolved(ref, problem), StoppingJob(a, job.RequestStarted, cause) -> {
      use _ <- result.try(matches(state, a, ref))
      let evidence = case problem {
        Uncertain(reason) -> reason
        InvalidResult(output, reason) -> reason <> ": " <> output
      }
      Ok(
        #(
          State(
            ..state,
            phase: StoppingJob(a, job.RequestUncertain(evidence), cause),
          ),
          [],
        ),
      )
    }
    JobConfirmedStopped(ref), StoppingJob(a, progress, cause) -> {
      use _ <- result.try(matches(state, a, ref))
      use _ <- result.try(stoppable(progress))
      Ok(stopped_operation(state, a, cause, JobStopped))
    }
    CancelledResult(ref, output), StoppingJob(a, progress, cause) -> {
      use _ <- result.try(matches(state, a, ref))
      use _ <- result.try(stoppable(progress))
      Ok(stopped_result(state, a, output, cause))
    }
    JobFailed(ref, reason), StoppingJob(a, progress, cause) -> {
      use _ <- result.try(matches(state, a, ref))
      use _ <- result.try(stoppable(progress))
      Ok(stopped_operation(
        state,
        a,
        cause,
        AfterFailure(OperationFailed(reason)),
      ))
    }
    ChildWaiting(ref, id), Joining(a, current) if id == current -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(#(State(..state, phase: WaitingChild(a, id)), []))
    }
    ChildCancellationSettled(ref, id),
      Ended(Cancelled(a, UnresolvedCancellation(_)))
    | ChildCancellationSettled(ref, id),
      Ended(Expired(a, UnresolvedCancellation(_)))
      if {
        a.prepared.kind == operation.Subgraph
        || a.prepared.kind == operation.Agent
      }
    -> {
      use _ <- result.try(matches(state, a, ref))
      use _ <- result.try(case id == attachment.reserved_id(state.run, a.id) {
        True -> Ok(Nil)
        False -> Error(StaleInvocation)
      })
      Ok(stopped_operation(state, a, stop_reason(state), AfterChild(id)))
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
    ChildStopped(ref, id, uncertain), StoppingChild(a, current, cause)
      if id == current
    -> {
      use _ <- result.try(matches(state, a, ref))
      Ok(
        stopped_operation(state, a, cause, case uncertain {
          True ->
            UnresolvedCancellation(Uncertain(
              "child cancellation retains uncertain effects",
            ))
          False -> AfterChild(id)
        }),
      )
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
    Inspected(ref, decision, expires), Ready(activation) -> {
      use _ <- result.try(matches(state, activation, ref))
      inspect(state, activation, decision, expires)
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
    Approved(answer, decision, reviewer, expires),
      AwaitingApproval(activation, current)
    -> {
      use _ <- result.try(approval_matches(answer, current))
      let activation =
        answered(activation, current, run.Approve, Some(reviewer))
      case decision {
        Ok(policy.Allow) -> Ok(queue(state, activation))
        Ok(policy.RequireApproval(requirement))
          if requirement == current.requirement
        -> Ok(queue(state, activation))
        decision -> inspect(state, activation, decision, expires)
      }
    }
    Rejected(answer, reason, reviewer), AwaitingApproval(activation, current) -> {
      use _ <- result.try(approval_matches(answer, current))
      let activation =
        answered(activation, current, run.Reject(reason), Some(reviewer))
      Ok(ended(state, Failed(activation, Denied(reason))))
    }
    ExpireApproval(answer, now), AwaitingApproval(activation, current) -> {
      use _ <- result.try(approval_matches(answer, current))
      case current.expires {
        Some(due) if now >= due -> {
          let activation = answered(activation, current, run.Expired, None)
          Ok(ended(state, Failed(activation, ApprovalExpired(due))))
        }
        _ -> Error(WrongPhase)
      }
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
    Cancel, WaitingJob(a) | Cancel, ArmingWait(a) ->
      case a.prepared.kind {
        operation.OwnedJob(_) ->
          Ok(
            #(
              State(
                ..state,
                phase: StoppingJob(
                  a,
                  job.RequestQueued,
                  operation.CancellationRequested,
                ),
              ),
              [
                RequestJobStop(a),
              ],
            ),
          )
        operation.Job(_) -> Ok(ended(state, Cancelled(a, JobDetached)))
        _ -> Ok(ended(state, Cancelled(a, BeforeStart)))
      }
    Cancel, StoppingJob(_, _, _) -> Ok(#(state, []))
    Cancel, Ended(_) -> Error(AlreadyEnded)
    Cancel, Joining(a, id)
    | Cancel, WaitingChild(a, id)
    | Cancel, ChildBlocked(a, id, _)
    ->
      Ok(
        #(
          State(
            ..state,
            phase: StoppingChild(a, id, operation.CancellationRequested),
          ),
          [CancelChild(a, id)],
        ),
      )
    Cancel, StoppingChild(a, id, _) -> Ok(#(state, [CancelChild(a, id)]))
    Cancel, Ready(activation)
    | Cancel, Queued(activation)
    | Cancel, AwaitingApproval(activation, _)
    | Cancel, WaitingSignal(activation)
    -> Ok(ended(state, Cancelled(activation, BeforeStart)))
    Cancel, Running(activation) ->
      Ok(#(State(..state, phase: Stopping(activation)), [Stop]))
    Cancel, Stopping(_) -> Ok(#(state, []))
    Cancel, Blocked(activation, problem) ->
      case activation.prepared.kind {
        operation.Fork(..) -> {
          use fork <- result.try(current_fork(state, activation.id))
          let state = save_fork(state, scope.cancel(fork))
          Ok(
            #(
              State(
                ..state,
                phase: Forking(
                  activation,
                  ClosingFork(operation.CancellationRequested),
                ),
              ),
              [ObserveFork(activation)],
            ),
          )
        }
        _ ->
          Ok(ended(
            state,
            Cancelled(activation, UnresolvedCancellation(problem)),
          ))
      }
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

/// `activation` with the answer to `approval` recorded.
fn answered(
  activation: Activation,
  approval: Approval,
  answer: run.Answer,
  reviewer: Option(Reviewer),
) -> Activation {
  Activation(
    ..activation,
    approvals: list.append(activation.approvals, [
      run.Approval(approval.requirement, approval.revision, answer, reviewer),
    ]),
  )
}

fn inspect(
  state: State,
  activation: Activation,
  decision: Result(policy.Decision, String),
  expires: Option(Int),
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
            Approval(
              activation.id,
              activation.attempt,
              revision,
              requirement,
              expires,
            )
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
    operation.Signal
    | operation.Job(_)
    | operation.OwnedJob(_)
    | operation.Subgraph
    | operation.Agent
    | operation.Fork(..) ->
      case activation.prepared.deadline {
        None -> waiting(state, activation)
        Some(_) -> #(State(..state, phase: ArmingWait(activation)), [
          ArmWait(activation),
        ])
      }
  }
}

fn waiting(state: State, a: Activation) -> #(State, List(Effect)) {
  case a.prepared.kind {
    operation.Fork(..) -> #(State(..state, phase: PreparingFork(a)), [
      PrepareFork(a),
    ])
    operation.Subgraph | operation.Agent -> {
      let id = attachment.reserved_id(state.run, a.id)
      #(State(..state, phase: Joining(a, id)), [ObserveChild(a, id)])
    }
    _ -> #(
      State(..state, phase: case a.prepared.kind {
        operation.Signal -> WaitingSignal(a)
        _ -> WaitingJob(a)
      }),
      [],
    )
  }
}

fn stopped_operation(
  state: State,
  a: Activation,
  cause: operation.StopReason,
  disposition: Cancellation,
) -> #(State, List(Effect)) {
  ended(state, case cause {
    operation.CancellationRequested -> Cancelled(a, disposition)
    operation.DeadlineReached(_) -> Expired(a, disposition)
  })
}

fn stopped_result(
  state: State,
  a: Activation,
  output: String,
  cause: operation.StopReason,
) -> #(State, List(Effect)) {
  stopped_operation(
    State(
      ..state,
      receipts: list.append(state.receipts, [
        Receipt(a, output, state.value, StoppedRoute),
      ]),
    ),
    a,
    cause,
    AfterResult,
  )
}

fn expire_job(
  state: State,
  a: Activation,
  now: Int,
  progress: job.Progress(String),
) -> Result(#(State, List(Effect)), Rejection) {
  use due <- result.try(case a.deadline {
    Some(due) if now >= due -> Ok(due)
    _ -> Error(WrongPhase)
  })
  let cause = operation.DeadlineReached(due)
  Ok(case progress {
    job.Completed(output) -> stopped_result(state, a, output, cause)
    job.Failed(reason) ->
      stopped_operation(state, a, cause, AfterFailure(OperationFailed(reason)))
    job.Cancelled -> stopped_operation(state, a, cause, JobStopped)
    job.Pending ->
      case a.prepared.kind {
        operation.OwnedJob(_) -> #(
          State(..state, phase: StoppingJob(a, job.RequestQueued, cause)),
          [RequestJobStop(a)],
        )
        _ -> stopped_operation(state, a, cause, JobDetached)
      }
  })
}

fn expire_child(
  state: State,
  a: Activation,
  id: String,
  now: Int,
) -> Result(#(State, List(Effect)), Rejection) {
  case a.deadline, a.prepared.kind {
    Some(due), operation.Subgraph | Some(due), operation.Agent if now >= due ->
      Ok(
        #(
          State(
            ..state,
            phase: StoppingChild(a, id, operation.DeadlineReached(due)),
          ),
          [CancelChild(a, id)],
        ),
      )
    _, _ -> Error(WrongPhase)
  }
}

fn expire_fork(
  state: State,
  a: Activation,
  now: Int,
) -> Result(#(State, List(Effect)), Rejection) {
  use due <- result.try(case a.deadline {
    Some(due) if now >= due -> Ok(due)
    _ -> Error(WrongPhase)
  })
  let cause = operation.DeadlineReached(due)
  case state.phase {
    PreparingFork(_) -> Ok(stopped_operation(state, a, cause, BeforeStart))
    _ -> {
      use fork <- result.try(current_fork(state, a.id))
      use fork <- result.try(
        scope.expire(fork, due) |> result.map_error(fn(_) { WrongPhase }),
      )
      let state = save_fork(state, fork)
      Ok(
        #(State(..state, phase: Forking(a, ClosingFork(cause))), [
          ObserveFork(a),
        ]),
      )
    }
  }
}

fn stop_reason(state: State) -> operation.StopReason {
  case state.phase {
    Ended(Expired(a, _)) -> {
      let assert Some(due) = a.deadline
      operation.DeadlineReached(due)
    }
    _ -> operation.CancellationRequested
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
          let next = Activation(state.allocated + 1, 1, next, None, [])
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
        Receipt(activation, output, state.value, StoppedRoute),
      ]),
    ),
    Cancelled(activation, AfterResult),
  )
}

/// Recovery itself must be committed before returned inspection effects run.
pub fn recover(state: State) -> Result(#(State, List(Effect)), Rejection) {
  let recovered = State(..state, incarnation: state.incarnation + 1)
  case state.phase {
    PreparingFork(a) -> Ok(#(recovered, [PrepareFork(a)]))
    Forking(a, mode) | WaitingFork(a, mode) ->
      Ok(#(State(..recovered, phase: Forking(a, mode)), [ObserveFork(a)]))
    ArmingWait(a) -> Ok(#(recovered, [ArmWait(a)]))
    StoppingJob(a, job.RequestQueued, _) ->
      Ok(#(recovered, [RequestJobStop(a)]))
    StoppingJob(a, job.RequestStarted, cause) ->
      Ok(
        #(
          State(
            ..recovered,
            phase: StoppingJob(
              a,
              job.RequestUncertain("runner lost after stop request started"),
              cause,
            ),
          ),
          [],
        ),
      )
    StoppingJob(_, _, _) -> Ok(#(recovered, []))
    Ended(_) -> Error(AlreadyEnded)
    Joining(a, id) | WaitingChild(a, id) | ChildBlocked(a, id, _) ->
      Ok(#(State(..recovered, phase: Joining(a, id)), [ObserveChild(a, id)]))
    StoppingChild(a, id, _) -> Ok(#(recovered, [CancelChild(a, id)]))
    Ready(activation) | Queued(activation) ->
      Ok(#(State(..recovered, phase: Ready(activation)), [Inspect(activation)]))
    Running(activation) ->
      case activation.prepared.recovery {
        ReplayInterrupted(max) if activation.attempt < max -> {
          let next =
            Activation(
              ..activation,
              attempt: activation.attempt + 1,
              approvals: [],
            )
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

pub fn current_fork(
  state: State,
  activation: Int,
) -> Result(scope.Scope, Rejection) {
  use saved <- result.try(
    list.find(state.forks, fn(fork) { fork.occurrence.activation == activation })
    |> result.map_error(fn(_) { WrongPhase }),
  )
  scope.restore(saved)
  |> result.map_error(fn(error) { InvalidPrepared(string.inspect(error)) })
}

pub fn activation(state: State, ordinal: Int) -> Result(Activation, Nil) {
  case
    list.find(state.receipts, fn(receipt) { receipt.activation.id == ordinal })
  {
    Ok(receipt) -> Ok(receipt.activation)
    Error(_) -> {
      let pending = case state.phase {
        Ready(a)
        | Queued(a)
        | Running(a)
        | AwaitingApproval(a, _)
        | WaitingSignal(a)
        | ArmingWait(a)
        | WaitingJob(a)
        | StoppingJob(a, _, _)
        | Joining(a, _)
        | WaitingChild(a, _)
        | ChildBlocked(a, _, _)
        | StoppingChild(a, _, _)
        | PreparingFork(a)
        | Forking(a, _)
        | WaitingFork(a, _)
        | Blocked(a, _)
        | Stopping(a)
        | Ended(Failed(a, _))
        | Ended(Cancelled(a, _))
        | Ended(Expired(a, _)) -> Some(a)
        Ended(Completed(_)) | Ended(Exhausted(_)) -> None
      }
      case pending {
        Some(a) if a.id == ordinal -> Ok(a)
        _ -> Error(Nil)
      }
    }
  }
}

fn save_fork(state: State, updated: scope.Scope) -> State {
  let occurrence = scope.snapshot(updated).occurrence
  State(
    ..state,
    forks: list.map(state.forks, fn(saved) {
      case saved.occurrence == occurrence {
        True -> scope.snapshot(updated)
        False -> saved
      }
    }),
  )
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
  // The deadline is the stored one; a reference names the request alone.
  case Approval(..answer, expires: current.expires) == current {
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
    Some(ms), operation.Signal
    | Some(ms), operation.Job(_)
    | Some(ms), operation.OwnedJob(_)
    | Some(ms), operation.Subgraph
    | Some(ms), operation.Agent
    | Some(ms), operation.Fork(..)
      if ms > 0 && ms <= 4_294_967_295
    -> Ok(Nil)
    _, _ -> Error(InvalidPrepared("invalid wait deadline"))
  })
  use _ <- result.try(case prepared.kind {
    operation.Fork(maximum, concurrency, signature) ->
      case maximum > 0 && concurrency > 0 && string.trim(signature) != "" {
        True -> Ok(Nil)
        False ->
          Error(InvalidPrepared("invalid fork membership bounds or signature"))
      }
    operation.Job(polling) | operation.OwnedJob(polling) ->
      case
        case polling {
          job.Manual -> True
          job.Every(ms) -> ms > 0 && ms <= 4_294_967_295
        }
      {
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
    PreparingFork(_) | Forking(_, _) -> True
    WaitingFork(_, _) -> False
    StoppingJob(_, job.RequestQueued, _)
    | StoppingJob(_, job.RequestStarted, _) -> True
    StoppingJob(_, _, _) -> False
    Ready(_)
    | ArmingWait(_)
    | Queued(_)
    | Running(_)
    | Stopping(_)
    | Joining(_, _)
    | StoppingChild(_, _, _) -> True
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
    StoppingJob(a, job.RequestStarted, _) ->
      step(
        state,
        Unresolved(
          reference(state, a),
          Uncertain("owner lost after stop request started"),
        ),
      )
    StoppingJob(a, job.RequestQueued, _) -> Ok(#(state, [RequestJobStop(a)]))
    _ -> Ok(#(state, effects))
  }
}

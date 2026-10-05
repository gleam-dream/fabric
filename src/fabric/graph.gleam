//// Durable agentic graphs. Author a definition with native codecs, bind it
//// to a store, a context and the same `policy.Policy` agents use, and start
//// runs in the same supervised store as ordinary Fabric agents.
////
//// ```gleam
//// let assert Ok(runtime) =
////   graph.new(publishing, runs, context: fn(_run) { Ctx(user:) }, policy:)
////   |> graph.with_approvers(editors)
////   |> graph.with_operation_timeout(run.After(duration.minutes(5)))
////   |> graph.build
//// let assert Ok(handle) =
////   graph.start(runtime, id: run.new_id(), initial: draft, correlation: None)
//// case graph.await(handle, within: duration.seconds(5)) {
////   Ok(graph.AwaitingApproval(pending)) -> {
////     let assert Ok(proof) =
////       approvers.check(editors, token, pending.requirement)
////     graph.approve(handle, pending, proof:, context: Ctx(user:))
////   }
////   ...
//// }
//// ```
////
//// `await` and every command (`approve`, `reject`, `deliver`, `reconcile`,
//// `poll_job`, `cancel`, `recover`) return the run's `Status`, as the
//// agent runtime's do; `snapshot` reads the whole record (the state value,
//// receipts, deadline). `status_kind` classifies a status by what the
//// caller does next.
////
//// A run handle starts no process by itself. Waiting approvals, unresolved
//// effects and completed runs live as stored data. `recover` reconnects work
//// whose owner is gone; recorded routing decisions are never recomputed.
////
//// The vocabulary is the agent runtime's: one `policy.Action` and
//// `policy.Policy`, one `tool.Failure` for operation bodies, `ApprovalRef`
//// answered with an `approvers.Proof` and the current context, the
//// context built from the run id (`fn(RunId) -> context`), and one `Error`
//// classified by `error_kind` (`fabric.ErrorKind`).
////
//// Every wait is bounded by default:
////
//// | Bound | Default | Setter |
//// | --- | --- | --- |
//// | one pure callback (context, selection, acceptance) | 1 s | `with_callback_timeout` |
//// | one activity body | 60 s | `with_operation_timeout` |
//// | command waiting for the live runner | 1 s | `with_command_timeout` |
//// | approval request | 7 days | `with_approval_expiry` |
//// | signal, job, child and fork waits | 7 days | `operation.with_deadline` |
//// | activations per run | 100 | `definition.with_max_activations` |
//// | family budget | none (opt-in) | `with_family_budget` |
////
//// Deadlines are set and judged by the store's clock (`store.now`).
////
//// A bound may come from configuration, so a setter only stores it; `build`
//// checks every bound and reports every problem at once
//// (`InvalidLimit(limit:, value:, minimum:, maximum:)`, as `agent.build`
//// does). Only `build` makes the `Runtime` that `start`, `open` and the
//// composition functions take.

import fabric
import fabric/approvers.{type Approvers, type Proof, type ProofError}
import fabric/budget
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/fork
import fabric/graph/job
import fabric/graph/operation
import fabric/graph/signal
import fabric/internal/answerer
import fabric/internal/bounded
import fabric/internal/budget/model as reservations
import fabric/internal/graph/agent_child
import fabric/internal/graph/attachment
import fabric/internal/graph/child_driver
import fabric/internal/graph/compiled
import fabric/internal/graph/controller as control
import fabric/internal/graph/fork as scope
import fabric/internal/graph/fork_driver
import fabric/internal/graph/handle as graph_handle
import fabric/internal/graph/live
import fabric/internal/graph/managed
import fabric/internal/graph/observe
import fabric/internal/graph/record
import fabric/internal/graph/runner
import fabric/internal/graph/runtime as graph_runtime
import fabric/internal/graph/signal as signal_contract
import fabric/internal/limit as bounds
import fabric/internal/run_id
import fabric/internal/store as store_core
import fabric/policy.{type Policy}
import fabric/reviewer.{type Reviewer}
import fabric/run
import fabric/store
import fabric/store/backend
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import json/blueprint/codec
import sinal/correlation.{type Correlation}

/// A graph definition bound to its store, context and policy, with its
/// bounds; `build` checks it. Make one with `new` and the `with_*` setters.
pub opaque type Spec(context, state, answer) {
  Spec(
    runtime: graph_runtime.Runtime(context, state, answer),
    callback_timeout: Duration,
    operation_timeout: run.Timeout,
    command_timeout: Duration,
    approval_expiry: run.Timeout,
    family_budget: Option(budget.Limits),
  )
}

/// A checked runtime: what `start`, `open`, `as_subgraph`, `both` and `map`
/// take. Only `build` makes one.
pub type Runtime(context, state, answer) =
  graph_runtime.Runtime(context, state, answer)

/// Why `build` refused a spec. This union may grow: match the variants you
/// handle and keep a catch-all, or use `describe_config_error`.
pub type ConfigError {
  /// A bound is outside `minimum..maximum` (both included), as for
  /// `agent.InvalidLimit`. Durations are in milliseconds.
  InvalidLimit(limit: Limit, value: Int, minimum: Int, maximum: Int)
}

/// A bound `build` checks, named after its setter. This union may grow.
pub type Limit {
  /// At most 2^32 - 1 ms, the longest timer the runtime can set, like the
  /// operation and command timeouts.
  CallbackTimeout
  OperationTimeout
  CommandTimeout
  /// At most 2^53 - 1 ms, as for agents: the deadline is stored, not timed.
  ApprovalExpiry
  /// `budget.limits(work:)`.
  FamilyWork
  /// `budget.with_children`.
  FamilyChildren
  /// `budget.with_depth`, at most 63.
  FamilyDepth
}

/// A handle on one graph run, for the runtime it was started or opened
/// with. It holds no process.
pub type Handle(context, state, answer) =
  graph_handle.Handle(Runtime(context, state, answer))

/// A waiting approval request. References are plain data: an application
/// may serialize one and rebuild it later; `approve` and `reject` check it
/// against the stored record.
pub type ApprovalRef {
  ApprovalRef(
    run: run.RunId,
    activation: Int,
    attempt: Int,
    revision: Int,
    requirement: run.Requirement,
  )
}

pub type Reconciliation {
  Reconciliation(run: run.RunId, activation: Int, attempt: Int)
}

/// Durable correlation data, not an authorization token. Applications must
/// authorize callers before using the delivery APIs.
pub type SignalReference {
  SignalReference(
    run: run.RunId,
    activation: Int,
    attempt: Int,
    contract: run.DefinitionId,
  )
}

pub type Problem {
  EffectUncertain(evidence: String)
  InvalidResult(output: String, reason: String)
}

/// Why a run failed. This union may grow: keep a catch-all.
pub type Failure {
  /// A wait passed its deadline (`operation.with_deadline`).
  DeadlineExpired(due: Int)
  /// The approval request expired unanswered at `due`
  /// (`with_approval_expiry`).
  ExpiredApproval(due: Int)
  /// The policy denied the operation, or a reviewer rejected it.
  Denied(String)
  PolicyFailed(String)
  /// The body failed definitely (`tool.Explain`), or a managed child
  /// failed.
  OperationFailed(String)
  FamilyBudget(budget.Denial)
}

pub type Cancellation {
  BeforeStart
  JobDetached(job.Reference)
  JobStopped(job.Reference)
  AfterResult
  AfterFailure(Failure)
  ChildSettled(child.Reference)
  ForkSettled(activation: Int)
  /// Reconcile the child's operation, then recover its canceled or expired parent.
  ChildUnresolved(child.Reference, problem: Problem)
  Unresolved(reference: Reconciliation, problem: Problem)
}

/// A run's status. This union may grow: branch on `status_kind`, and match
/// the variants you handle with a catch-all.
pub type Status(answer) {
  Working
  /// Work exists but this store knows no owner and no live foreign lease.
  Unattended
  AwaitingApproval(ApprovalRef)
  AwaitingSignal(SignalReference)
  AwaitingJob(job.Reference)
  CancellingJob(job.Reference, job.CancellationProgress, operation.StopReason)
  Child(child.Reference, child.Progress)
  Fork(fork.Snapshot, stop: option.Option(operation.StopReason))
  /// The stop cause is committed; the owned child has not settled yet.
  CancellingChild(child.Reference, operation.StopReason)
  Blocked(Reconciliation, problem: Problem)
  Completed(answer)
  Failed(Failure)
  Exhausted
  Cancelled(Cancellation)
  Expired(due: Int, disposition: Cancellation)
}

/// A stable classification of `Status`, by what the caller does next.
pub type StatusKind {
  /// Work is in flight, or the run waits on something that settles
  /// without the caller: an operation, a job, a child, a fork, a stop in
  /// progress (`Working`, `AwaitingJob`, `CancellingJob`, `Child`, `Fork`,
  /// `CancellingChild`). `await` it. A job without a schedule is observed
  /// with `poll_job`, and a child or fork may itself wait for input (open
  /// it with `child` or `branch`).
  Active
  /// Work is in flight and nothing drives it (`Unattended`): `recover` it
  /// once its previous owner is known to be gone.
  NeedsRecovery
  /// The run waits for the application: an answer (`AwaitingApproval`), a
  /// signal (`AwaitingSignal`) or a reconciliation (`Blocked`).
  NeedsInput
  /// The run has ended (`Completed`, `Failed`, `Exhausted`, `Cancelled`,
  /// `Expired`). A cancelled run may still name an effect to reconcile.
  Ended
}

pub fn status_kind(status: Status(answer)) -> StatusKind {
  case status {
    Working
    | AwaitingJob(_)
    | CancellingJob(..)
    | Child(..)
    | Fork(..)
    | CancellingChild(..) -> Active
    Unattended -> NeedsRecovery
    AwaitingApproval(_) | AwaitingSignal(_) | Blocked(..) -> NeedsInput
    Completed(_) | Failed(_) | Exhausted | Cancelled(_) | Expired(..) -> Ended
  }
}

/// One line for logs; it names the answer only by its presence.
pub fn describe_status(status: Status(answer)) -> String {
  case status {
    Working -> "working"
    Unattended -> "work in flight with no runner"
    AwaitingApproval(reference) ->
      "awaiting approval of activation "
      <> int.to_string(reference.activation)
      <> " ("
      <> reference.requirement.name
      <> ")"
    AwaitingSignal(reference) ->
      "awaiting the signal " <> reference.contract.name
    AwaitingJob(reference) ->
      "awaiting the job of activation " <> int.to_string(reference.activation)
    CancellingJob(reference, _, _) ->
      "cancelling the job of activation " <> int.to_string(reference.activation)
    Child(reference, _) ->
      "waiting for the child run " <> run.id_to_string(reference.child)
    Fork(_, _) -> "waiting for a fork"
    CancellingChild(reference, _) ->
      "cancelling the child run " <> run.id_to_string(reference.child)
    Blocked(reference, _) ->
      "blocked on activation "
      <> int.to_string(reference.activation)
      <> ", which needs reconciling"
    Completed(_) -> "completed"
    Failed(failure) -> "failed: " <> describe_failure(failure)
    Exhausted -> "out of activations"
    Cancelled(_) -> "cancelled"
    Expired(due, _) -> "expired at " <> int.to_string(due)
  }
}

/// Where an activation's accepted result led.
pub type Route {
  Next(node: String)
  Finished
  /// The run was stopping (cancelled, or past a deadline) when the result
  /// arrived: it was kept, and routed nowhere.
  Stopped
}

/// A committed result. Read it by label: Fabric may add fields.
/// `approvals` are the activation's answered approval requests, oldest
/// first, with their reviewers.
pub type Receipt {
  Receipt(
    activation: Int,
    attempt: Int,
    node: String,
    operation: run.DefinitionId,
    input_json: String,
    output_json: String,
    state_json: String,
    route: Route,
    approvals: List(run.Approval),
  )
}

/// A run as stored. Read it by label: Fabric may add fields.
///
/// `current` is the action of the current (or last) activation, as the
/// policy saw it, and `approvals` its answered approval requests (who
/// approved or rejected it). `deadline` is the current wait's, approval
/// request's or job cleanup's due time, or an expired outcome's, in UTC
/// Unix milliseconds by the store's clock.
pub type Snapshot(state, answer) {
  Snapshot(
    revision: Int,
    value: state,
    status: Status(answer),
    current: option.Option(policy.Action),
    approvals: List(run.Approval),
    receipts: List(Receipt),
    deadline: option.Option(Int),
    forks: List(fork.Snapshot),
  )
}

/// How a managed child does not belong to the parent that opens it.
pub type ChildProblem {
  /// The child's runtime uses another store than its parent's.
  DifferentStore
  /// The child was started by another parent activation.
  OtherParent
}

/// Why a call to `fabric/graph` failed: one type for every function of this
/// module. Branch on `error_kind` and log with `describe_error`; this union
/// may grow, so match a variant only where it decides something (keep a
/// catch-all).
pub type Error {
  /// A run with this id is already stored: this start stored nothing.
  /// `same_input` says whether the stored run is a root of the same graph
  /// with the same initial state and correlation; a retry can then `open`
  /// it. When the id is taken but the stored run cannot be read, the start
  /// returns the read's error instead (`StoreUnavailable`, `CorruptRecord`
  /// or `UnsupportedVersion`).
  AlreadyStarted(id: run.RunId, same_input: Bool)
  /// The runtime declares a family budget (`with_family_budget`) and the
  /// store writes agent records older than version 7. Nothing was stored.
  FamilyBudgetUnsupported
  RunNotFound
  /// The store failed. A write it reported unavailable has an unknown
  /// outcome: the backend may still perform it later.
  StoreUnavailable(reason: String)
  /// The record was written by a Fabric version this one cannot read.
  UnsupportedVersion(found: Int)
  CorruptRecord(detail: String)
  /// The stored run cannot continue under this definition: another graph,
  /// changed structure, or a value its codecs refuse.
  IncompatibleDefinition(definition.Error)
  /// A deployed callback (context, selection, acceptance, a child or job
  /// binding) crashed or ran past the callback timeout. `evidence` is for
  /// logs.
  CallbackFailed(evidence: String)
  /// `deliver`'s value does not encode with its signal's codec.
  SignalEncodingFailed(codec.EncodeError)
  /// A delivered signal value or a reconciled result is refused by the
  /// definition: its codec does not decode it, or the node's acceptance
  /// refuses it. Nothing changed.
  ValueRefused(definition.Error)
  /// The run has ended, or an ancestor of it is stopping or has ended: it
  /// accepts no command but terminal reconciliation.
  RunEnded
  /// The reference names another run, or no wait or activation of this one.
  WrongReference
  /// The reference names a wait, approval request or attempt of this run
  /// that is not current: one the run moved past (also a request a new one
  /// superseded), or one not yet published.
  StaleReference
  /// This approval request was already answered.
  AlreadyAnswered
  /// The approval request's deadline passed before this answer
  /// (`with_approval_expiry`): it expired instead, and the run failed with
  /// `ExpiredApproval`.
  ApprovalExpired
  /// The current policy now requires another approval for the operation;
  /// the answer was not applied. Answer the new request, with a proof
  /// checked for its requirement.
  RequirementChanged(ApprovalRef)
  /// The answer's proof is not one the runtime's approvers accept for the
  /// request (see `fabric/approvers`). Nothing was changed.
  ProofRefused(ProofError)
  /// A different value was already accepted for this signal.
  SignalConflict
  /// The run has no uncertain effect to reconcile.
  NotReconcilable
  /// The uncertain effect is a managed child's: reconcile the child, then
  /// `recover` its parent.
  ReconcileChildFirst
  ChildMismatch(ChildProblem)
  /// Work is in flight and no runner known to this store drives it (its
  /// runner was lost, or another node's holds it). Nothing was changed.
  RunUnattended
  /// The run's runner did not take the command within the command timeout
  /// (`with_command_timeout`). Nothing was changed.
  RunnerBusy
  /// The command lost every retry against concurrent commits.
  Contended
}

/// The stable classification of `Error`, shared with `fabric.error_kind`.
pub fn error_kind(error: Error) -> fabric.ErrorKind {
  case error {
    RunNotFound | WrongReference -> fabric.NotFound
    AlreadyStarted(..)
    | RunEnded
    | StaleReference
    | AlreadyAnswered
    | ApprovalExpired
    | RequirementChanged(_)
    | ProofRefused(_)
    | SignalConflict
    | SignalEncodingFailed(_)
    | ValueRefused(_)
    | NotReconcilable
    | ReconcileChildFirst
    | ChildMismatch(_) -> fabric.Refused
    RunnerBusy | Contended -> fabric.Retry
    StoreUnavailable(_) | RunUnattended | CallbackFailed(_) ->
      fabric.Unavailable
    UnsupportedVersion(_)
    | CorruptRecord(_)
    | IncompatibleDefinition(_)
    | FamilyBudgetUnsupported -> fabric.Incompatible
  }
}

/// One line for logs.
pub fn describe_error(error: Error) -> String {
  case error {
    AlreadyStarted(id, same_input) ->
      "the graph run "
      <> run.id_to_string(id)
      <> " is already started"
      <> case same_input {
        True -> " with the same input"
        False -> " with other input"
      }
    FamilyBudgetUnsupported ->
      "a family budget needs a store that writes agent records of version 7 or later"
    RunNotFound -> "the run does not exist"
    StoreUnavailable(reason) -> "the store is unavailable: " <> reason
    UnsupportedVersion(found) ->
      "the record has version "
      <> int.to_string(found)
      <> ", which this Fabric cannot read"
    CorruptRecord(detail) -> "the record is corrupt: " <> detail
    IncompatibleDefinition(_) ->
      "the run cannot continue under this graph definition"
    CallbackFailed(evidence) -> "a deployed callback failed: " <> evidence
    SignalEncodingFailed(_) -> "the signal value does not encode"
    ValueRefused(_) -> "the definition refuses the value"
    RunEnded -> "the run, or an ancestor of it, has ended"
    WrongReference -> "the reference names no wait of this run"
    StaleReference -> "the reference names a wait that is not current"
    AlreadyAnswered -> "the approval request was already answered"
    ApprovalExpired -> "the approval request expired before this answer"
    RequirementChanged(_) -> "the policy now requires another approval"
    ProofRefused(error) ->
      "the answer's proof is refused: " <> approvers.describe_proof_error(error)
    SignalConflict -> "another value was accepted for this signal"
    NotReconcilable -> "the run has no uncertain effect to reconcile"
    ReconcileChildFirst ->
      "the uncertain effect is a child's: reconcile the child, then recover the parent"
    ChildMismatch(DifferentStore) ->
      "the child runtime does not use the parent's store"
    ChildMismatch(OtherParent) ->
      "the child belongs to another parent activation"
    RunUnattended -> "work is in flight and no runner drives the run"
    RunnerBusy -> "the run's runner did not take the command in time"
    Contended -> "the command lost every retry against concurrent commits"
  }
}

/// Binds `definition` to `store`, with the default bounds (see the module
/// documentation); `build` checks it. `context` builds the live context of
/// the run it is given, for each admission, recovery and job observation;
/// the admitted body receives that same context (an approved one, the
/// context its answer was checked with). `policy` gates every operation, as
/// for agents: it sees `policy.Activation(..)` as the action's step and
/// `policy.RunOperation(..)` as its target. Callbacks and operations are
/// bounded separately; pure selection and acceptance must contain no
/// effects.
pub fn new(
  definition: definition.Definition(context, state, answer),
  store: store.Store,
  context context: fn(run.RunId) -> context,
  policy policy: Policy(context),
) -> Spec(context, state, answer) {
  // Keep child runtimes in one deployed callback. The ordinary callbacks
  // capture the parent's codecs and routes, without copying descendant trees.
  let compiled.Detached(definition, child, fork) =
    compiled.detach_children(definition)
  let work_with = fn(context: fn(run.RunId) -> context) {
    fn() {
      live.Work(
        admit: fn(state, activation) {
          let invocation = invocation(state, activation)
          let prepared = activation.prepared
          let context = context(invocation.run)
          use decision <- result.try(policy(
            context,
            action(state, activation.id, activation.attempt, prepared),
          ))
          Ok(
            live.Admission(decision, fn() {
              compiled.invoke(definition, context, invocation, prepared)
            }),
          )
        },
        accept: fn(state, activation, output) {
          use _ <- result.try(compiled.check_join(
            definition,
            state,
            activation,
            output,
          ))
          compiled.accept(definition, state.value, activation.prepared, output)
        },
        check_output: fn(activation, output) {
          compiled.check_output(definition, activation.prepared, output)
        },
        observe_job: fn(state, activation) {
          compiled.observe_job(
            definition,
            context(run_id.from_string(state.run)),
            activation.prepared,
          )
        },
        cancel_job: fn(state, activation) {
          let invocation = invocation(state, activation)
          let context = context(invocation.run)
          fn() {
            compiled.cancel_job(
              definition,
              context,
              invocation,
              activation.prepared,
            )
            |> result.replace("null")
          }
        },
        validate: fn(state) { compiled.validate(definition, state) },
        child: fn(activation) { child(activation.prepared) },
        fork: fn(activation) { fork(activation.prepared) },
      )
    }
  }
  // `build` replaces these options with the checked bounds of the spec.
  let runtime =
    graph_runtime.new(
      definition,
      store,
      fn(given) {
        work_with(case given {
          None -> context
          Some(given) -> fn(_) { given }
        })
      },
      runner.Options(
        callback_timeout: 1,
        operation_timeout: None,
        command_timeout: 1,
        approval_expiry: None,
      ),
    )
  Spec(
    runtime:,
    callback_timeout: duration.seconds(1),
    operation_timeout: run.After(duration.seconds(60)),
    command_timeout: duration.seconds(1),
    approval_expiry: run.After(duration.hours(24 * 7)),
    family_budget: None,
  )
}

fn invocation(
  state: control.State,
  activation: control.Activation,
) -> operation.Invocation {
  operation.Invocation(
    run_id.from_string(state.run),
    activation.id,
    activation.attempt,
    state.correlation,
  )
}

/// The policy's view of an attempt of an activation of `state`.
fn action(
  state: control.State,
  activation: Int,
  attempt: Int,
  prepared: control.Prepared,
) -> policy.Action {
  policy.Action(
    run: run_id.from_string(state.run),
    step: policy.Activation(activation, attempt),
    name: prepared.operation.name,
    arguments_json: prepared.input,
    target: policy.RunOperation(
      prepared.node,
      prepared.operation,
      observe.kind(prepared.kind),
    ),
  )
}

/// Bounds one call of the definition's pure callbacks (context, selection,
/// acceptance, validation); default 1 s, from 1 ms to 2^32 - 1 ms.
pub fn with_callback_timeout(
  spec: Spec(context, state, answer),
  timeout: Duration,
) -> Spec(context, state, answer) {
  Spec(..spec, callback_timeout: timeout)
}

/// Bounds one admitted activity body; default 60 s, from 1 ms to 2^32 - 1
/// ms. A body still running then is stopped and its effect is uncertain
/// (`Blocked`). `run.Infinity` lets a body run as long as it needs.
pub fn with_operation_timeout(
  spec: Spec(context, state, answer),
  timeout: run.Timeout,
) -> Spec(context, state, answer) {
  Spec(..spec, operation_timeout: timeout)
}

/// How long a command (`cancel`) waits for the run's live runner to take
/// it; default 1 s, from 1 ms to 2^32 - 1 ms.
pub fn with_command_timeout(
  spec: Spec(context, state, answer),
  timeout: Duration,
) -> Spec(context, state, answer) {
  Spec(..spec, command_timeout: timeout)
}

/// How long an approval request this runtime issues waits for an answer;
/// default 7 days, at least 1 ms. Its deadline is stored with the request
/// (by the store's clock) and shown as `Snapshot.deadline`. After it the
/// request expires: the run fails with `ExpiredApproval`, and a late
/// `approve` or `reject` is refused with `ApprovalExpired`. Whoever touches
/// the run next expires it: an answer, `await`, `recover`, or on a leased
/// store the sweeper. `run.Infinity` never expires; requests stored without
/// a deadline never expire.
pub fn with_approval_expiry(
  spec: Spec(context, state, answer),
  expiry: run.Timeout,
) -> Spec(context, state, answer) {
  Spec(..spec, approval_expiry: expiry)
}

/// Who may answer this runtime's approval requests: `approve` and
/// `reject` take a proof from `approvers.check` with these approvers,
/// checked for the request's requirement (see `fabric/approvers`), and
/// refuse any other. A runtime without approvers refuses every answer
/// (`approvers.NoApprovers`). A child runtime (`as_subgraph`, `both`,
/// `map`) answers with its own approvers, given to its own spec.
pub fn with_approvers(
  spec: Spec(context, state, answer),
  approvers: Approvers(credential),
) -> Spec(context, state, answer) {
  Spec(
    ..spec,
    runtime: graph_runtime.with_approvers(
      spec.runtime,
      answerer.from(approvers),
    ),
  )
}

/// One budget shared by every root run this runtime starts and all its
/// managed descendants, graphs and agents alike (see `fabric/budget`),
/// stored with the root. A new attempt spends new work capacity;
/// acknowledging an existing reservation never spends twice. The store
/// must write agent records of version 7 or later (`start` is then
/// `FamilyBudgetUnsupported`). `build` checks the limits: none negative,
/// a depth of at most 63.
pub fn with_family_budget(
  spec: Spec(context, state, answer),
  limits: budget.Limits,
) -> Spec(context, state, answer) {
  Spec(..spec, family_budget: Some(limits))
}

/// Checks `spec` and reports every problem at once. Building starts
/// nothing.
///
/// ```gleam
/// case graph.new(publishing, runs, context:, policy:) |> graph.build {
///   Ok(runtime) -> runtime
///   Error(errors) -> panic as graph.describe_config_errors(errors)
/// }
/// ```
pub fn build(
  spec: Spec(context, state, answer),
) -> Result(Runtime(context, state, answer), List(ConfigError)) {
  let ms = duration.to_milliseconds
  let timeout = fn(timeout) {
    case timeout {
      run.After(within) -> Some(ms(within))
      run.Infinity -> None
    }
  }
  let problems =
    bounds.check(
      [
        bounds.Bound(
          CallbackTimeout,
          Some(ms(spec.callback_timeout)),
          1,
          bounds.longest_timer,
        ),
        bounds.Bound(
          OperationTimeout,
          timeout(spec.operation_timeout),
          1,
          bounds.longest_timer,
        ),
        bounds.Bound(
          CommandTimeout,
          Some(ms(spec.command_timeout)),
          1,
          bounds.longest_timer,
        ),
        bounds.Bound(
          ApprovalExpiry,
          timeout(spec.approval_expiry),
          1,
          bounds.largest,
        ),
        ..bounds.family(
          spec.family_budget,
          work: FamilyWork,
          children: FamilyChildren,
          depth: FamilyDepth,
        )
      ],
      InvalidLimit,
    )
  case problems {
    [_, ..] -> Error(problems)
    [] -> {
      let runtime =
        graph_runtime.with_options(
          spec.runtime,
          runner.Options(
            callback_timeout: ms(spec.callback_timeout),
            operation_timeout: timeout(spec.operation_timeout),
            command_timeout: ms(spec.command_timeout),
            approval_expiry: timeout(spec.approval_expiry),
          ),
        )
      Ok(case spec.family_budget {
        Some(limits) -> graph_runtime.with_family_budget(runtime, limits)
        None -> runtime
      })
    }
  }
}

/// One line naming the problem and the setter that changes it.
pub fn describe_config_error(error: ConfigError) -> String {
  case error {
    InvalidLimit(limit, value, minimum, maximum) ->
      bounds.describe(setter(limit), value, minimum, maximum)
  }
}

/// One line for every problem `build` reported, in its order, joined with
/// `"; "`.
pub fn describe_config_errors(errors: List(ConfigError)) -> String {
  errors
  |> list.map(describe_config_error)
  |> string.join("; ")
}

fn setter(limit: Limit) -> String {
  case limit {
    CallbackTimeout -> "graph.with_callback_timeout (ms)"
    OperationTimeout -> "graph.with_operation_timeout (ms)"
    CommandTimeout -> "graph.with_command_timeout (ms)"
    ApprovalExpiry -> "graph.with_approval_expiry (ms)"
    FamilyWork -> "budget.limits(work:)"
    FamilyChildren -> "budget.with_children"
    FamilyDepth -> "budget.with_depth"
  }
}

/// Opens the stored run `id` under `runtime`: it reads the record and
/// checks that the run can continue under the runtime's definition
/// (`IncompatibleDefinition` otherwise). It never takes the run over and
/// starts nothing; `recover` does.
pub fn open(
  runtime: Runtime(context, state, answer),
  id: run.RunId,
) -> Result(Handle(context, state, answer), Error) {
  use _ <- result.try(
    runner.load(
      graph_runtime.store(runtime),
      graph_runtime.work(runtime),
      graph_runtime.options(runtime),
      run.id_to_string(id),
    )
    |> result.map_error(from_runner),
  )
  Ok(handle(runtime, id))
}

fn handle(
  runtime: Runtime(context, state, answer),
  id: run.RunId,
) -> Handle(context, state, answer) {
  graph_handle.new(runtime, id, graph_runtime.store(runtime))
}

pub fn id(handle: Handle(context, state, answer)) -> run.RunId {
  graph_handle.id(handle)
}

/// The driver of a managed child run of `runtime`.
fn subgraph_driver(
  runtime: Runtime(context, state, answer),
) -> child_driver.Driver {
  let runs = graph_runtime.store(runtime)
  child_driver.Driver(
    store: fn() { store_core.pid(runs) },
    reserve: fn(parent, id, input, reservation) {
      reserved_child(runtime, parent, id, input, reservation, 3)
      |> result.map_error(describe_error)
    },
    read: fn(parent, id, _) {
      child_progress(runs, parent, id, 64) |> result.map_error(describe_error)
    },
  )
}

/// Bind a graph's native initial state and answer as one managed operation.
/// Parent and child runtimes must use the same supervised store. The parent
/// owns cancellation; child policy still gates every child operation. The
/// child inherits its parent's correlation and family root.
pub fn as_subgraph(
  runtime: Runtime(child_context, child_state, child_answer),
) -> operation.Operation(parent_context, child_state, child_answer) {
  managed.subgraph(
    compiled.identity(graph_runtime.definition(runtime)).identity,
    compiled.state_codec(graph_runtime.definition(runtime)),
    compiled.answer_codec(graph_runtime.definition(runtime)),
    subgraph_driver(runtime),
  )
}

/// Compose two managed graphs with independent native inputs and answers.
/// A settled member failure is available to the parent as a typed alternative.
pub fn both(
  identity: run.DefinitionId,
  left: Runtime(left_context, left_state, left_answer),
  right: Runtime(right_context, right_state, right_answer),
) -> operation.Operation(
  parent_context,
  #(left_state, right_state),
  Result(#(left_answer, right_answer), fork.Failure),
) {
  let left_input = compiled.state_codec(graph_runtime.definition(left))
  let right_input = compiled.state_codec(graph_runtime.definition(right))
  let input = codec.pair(left_input, right_input)
  let left_output = compiled.answer_codec(graph_runtime.definition(left))
  let right_output = compiled.answer_codec(graph_runtime.definition(right))
  let output = fork.result_codec(codec.pair(left_output, right_output))
  let left_driver = subgraph_driver(left)
  let right_driver = subgraph_driver(right)
  let left_definition = compiled.identity(graph_runtime.definition(left))
  let right_definition = compiled.identity(graph_runtime.definition(right))
  let left_store = graph_runtime.store(left)
  let right_store = graph_runtime.store(right)
  let driver =
    fork_driver.Driver(
      stores: fn() { [store_core.pid(left_store), store_core.pid(right_store)] },
      prepare: fn(encoded) {
        use values <- result.try(
          codec.decode_json(input, encoded)
          |> result.map_error(codec.describe_decode_error),
        )
        use left <- result.try(
          codec.encode_json(left_input, values.0)
          |> result.map_error(codec.describe_encode_error),
        )
        use right <- result.map(
          codec.encode_json(right_input, values.1)
          |> result.map_error(codec.describe_encode_error),
        )
        [
          fork.Request(left_definition.identity, left),
          fork.Request(right_definition.identity, right),
        ]
      },
      member: fn(ordinal) {
        case ordinal {
          1 -> Ok(left_driver)
          2 -> Ok(right_driver)
          _ -> Error("unknown pair member")
        }
      },
      check: fn(ordinal, request) {
        case ordinal, request.definition {
          1, identity if identity == left_definition.identity ->
            codec.decode_json(left_input, request.input)
            |> result.replace(Nil)
            |> result.map_error(codec.describe_decode_error)
          2, identity if identity == right_definition.identity ->
            codec.decode_json(right_input, request.input)
            |> result.replace(Nil)
            |> result.map_error(codec.describe_decode_error)
          _, _ -> Error("fork member definition changed")
        }
      },
      output: fn(outcome) {
        use answer <- result.try(case outcome {
          Error(failure) -> Ok(Error(failure))
          Ok([left, right]) -> {
            use left <- result.try(
              codec.decode_json(left_output, left)
              |> result.map_error(codec.describe_decode_error),
            )
            use right <- result.map(
              codec.decode_json(right_output, right)
              |> result.map_error(codec.describe_decode_error),
            )
            Ok(#(left, right))
          }
          Ok(_) -> Error("pair result must contain exactly two members")
        })
        codec.encode_json(output, answer)
        |> result.map_error(codec.describe_encode_error)
      },
    )
  let signature = fork_signature([left_definition, right_definition])
  managed.parallel(identity, input, output, 2, 2, signature, driver)
}

/// Run a bounded list of managed children and join native answers in input order.
/// Empty input succeeds; oversized input is refused before any child reservation.
/// Waiting and uncertain members keep their concurrency slots.
/// `definition.build` refuses bounds below 1
/// (`operation.InvalidLimit(MaxMembers, ..)`, `Concurrency`).
pub fn map(
  identity: run.DefinitionId,
  child: Runtime(child_context, child_state, child_answer),
  max_members maximum: Int,
  concurrency concurrency: Int,
) -> operation.Operation(
  parent_context,
  List(child_state),
  Result(List(child_answer), fork.Failure),
) {
  let child_input = compiled.state_codec(graph_runtime.definition(child))
  let child_output = compiled.answer_codec(graph_runtime.definition(child))
  let input = codec.list(child_input)
  let output = fork.result_codec(codec.list(child_output))
  let binding = subgraph_driver(child)
  let child_definition = compiled.identity(graph_runtime.definition(child))
  let runs = graph_runtime.store(child)
  let driver =
    fork_driver.Driver(
      stores: fn() { [store_core.pid(runs)] },
      prepare: fn(encoded) {
        use values <- result.try(
          codec.decode_json(input, encoded)
          |> result.map_error(codec.describe_decode_error),
        )
        list.try_map(values, fn(value) {
          use input <- result.map(
            codec.encode_json(child_input, value)
            |> result.map_error(codec.describe_encode_error),
          )
          fork.Request(child_definition.identity, input)
        })
      },
      member: fn(ordinal) {
        case ordinal > 0 && ordinal <= maximum {
          True -> Ok(binding)
          False -> Error("unknown map member")
        }
      },
      check: fn(ordinal, request) {
        case
          ordinal > 0
          && ordinal <= maximum
          && request.definition == child_definition.identity
        {
          True ->
            codec.decode_json(child_input, request.input)
            |> result.replace(Nil)
            |> result.map_error(codec.describe_decode_error)
          False -> Error("map member definition changed")
        }
      },
      output: fn(outcome) {
        use answer <- result.try(case outcome {
          Error(failure) -> Ok(Error(failure))
          Ok(outputs) ->
            list.try_map(outputs, fn(output) {
              codec.decode_json(child_output, output)
              |> result.map_error(codec.describe_decode_error)
            })
            |> result.map(Ok)
        })
        codec.encode_json(output, answer)
        |> result.map_error(codec.describe_encode_error)
      },
    )
  managed.parallel(
    identity,
    input,
    output,
    maximum,
    concurrency,
    fork_signature([child_definition]),
    driver,
  )
}

fn fork_signature(definitions: List(control.Definition)) -> String {
  json.array(definitions, fn(definition) {
    json.array(
      [
        json.string(definition.identity.name),
        json.int(definition.identity.version),
        json.string(definition.signature),
        json.int(definition.max_activations),
      ],
      fn(value) { value },
    )
  })
  |> json.to_string
}

/// Open one admitted fork member with its native runtime. Ordinals start at one.
pub fn branch(
  parent: Handle(context, state, answer),
  activation: Int,
  member: Int,
  runtime: Runtime(child_context, child_state, child_answer),
) -> Result(Handle(child_context, child_state, child_answer), Error) {
  let link =
    child.Branch(run.id_to_string(graph_handle.id(parent)), activation, member)
  attached_child(
    parent,
    runtime,
    link,
    attachment.branch_id(link.run, activation, member),
  )
}

/// Open a specific child visit, including a completed one, with its native
/// runtime. The child's reciprocal attachment is checked before returning.
pub fn child(
  parent: Handle(context, state, answer),
  activation: Int,
  runtime: Runtime(child_context, child_state, child_answer),
) -> Result(Handle(child_context, child_state, child_answer), Error) {
  let link = child.Parent(run.id_to_string(graph_handle.id(parent)), activation)
  attached_child(
    parent,
    runtime,
    link,
    attachment.reserved_id(link.run, activation),
  )
}

fn attached_child(
  parent: Handle(context, state, answer),
  runtime: Runtime(child_context, child_state, child_answer),
  link: child.Parent,
  id: String,
) -> Result(Handle(child_context, child_state, child_answer), Error) {
  use _ <- result.try(
    case
      store_core.pid(graph_runtime.store(graph_handle.runtime(parent))),
      store_core.pid(graph_runtime.store(runtime))
    {
      Ok(parent_store), Ok(child_store) if parent_store == child_store -> Ok(Nil)
      _, _ -> Error(ChildMismatch(DifferentStore))
    },
  )
  use #(_, state) <- result.try(
    runner.load(
      graph_runtime.store(runtime),
      graph_runtime.work(runtime),
      graph_runtime.options(runtime),
      id,
    )
    |> result.map_error(from_runner),
  )
  use _ <- result.try(check_attachment(state, link))
  Ok(handle(runtime, run_id.from_string(id)))
}

fn check_attachment(
  state: control.State,
  parent: child.Parent,
) -> Result(Nil, Error) {
  case state.parent == Some(attachment.parent(parent)) {
    True -> Ok(Nil)
    False -> Error(ChildMismatch(OtherParent))
  }
}

fn reserved_child(
  runtime: Runtime(context, state, answer),
  parent: child.Parent,
  id: String,
  input: String,
  reservation: child_driver.Reservation,
  tries: Int,
) -> Result(Nil, Error) {
  case runner.load_raw(graph_runtime.store(runtime), id) {
    Ok(#(_, state)) -> {
      use _ <- result.try(check_attachment(state, parent))
      use _ <- result.try(case state.initial == input {
        True -> Ok(Nil)
        False ->
          Error(CorruptRecord("child input differs from its reservation"))
      })
      case reservation, state.phase {
        child_driver.Cancel, control.Ended(_) -> Ok(Nil)
        child_driver.Cancel, control.Forking(_, control.ClosingFork(_))
        | child_driver.Cancel, control.WaitingFork(_, control.ClosingFork(_))
        ->
          // Intent already committed: follow cleanup without restarting waits.
          runner.discover(
            graph_runtime.store(runtime),
            graph_runtime.work(runtime),
            graph_runtime.options(runtime),
            id,
            3,
          )
          |> result.replace(Nil)
          |> result.map_error(from_runner)
        child_driver.Cancel, _ ->
          runner.cancel(
            graph_runtime.store(runtime),
            graph_runtime.work(runtime),
            graph_runtime.options(runtime),
            id,
            3,
          )
          |> result.replace(Nil)
          |> result.map_error(from_runner)
        child_driver.Discover, _ | child_driver.Start, _ ->
          // An acknowledged child may be idle inside a nested fork. Inspect
          // it without resetting unchanged waits on every parent observation.
          runner.discover(
            graph_runtime.store(runtime),
            graph_runtime.work(runtime),
            graph_runtime.options(runtime),
            id,
            3,
          )
          |> result.replace(Nil)
          |> result.map_error(from_runner)
      }
    }
    Error(runner.StoreFailed(backend.NotFound))
      if reservation == child_driver.Discover
    -> Error(RunNotFound)
    Error(runner.StoreFailed(backend.NotFound)) -> {
      use initial <- result.try(
        compiled.decode_state(graph_runtime.definition(runtime), input)
        |> result.map_error(IncompatibleDefinition),
      )
      use #(value, entry) <- result.try(
        compiled.prepare(graph_runtime.definition(runtime), initial)
        |> result.map_error(IncompatibleDefinition),
      )
      let #(correlation, root, root_exact) =
        runner.lineage(graph_runtime.store(runtime), parent.run)
      use #(state, effects) <- result.try(
        control.start_correlated(
          id,
          compiled.identity(graph_runtime.definition(runtime)),
          value,
          entry,
          correlation,
          root,
        )
        |> result.map_error(rejected),
      )
      let state =
        control.State(
          ..state,
          parent: Some(attachment.parent(parent)),
          root_exact:,
        )
      use #(state, effects) <- result.try(
        case reservation == child_driver.Cancel {
          True -> control.cancel_abandoned(state) |> result.map_error(rejected)
          False -> {
            use _ <- result.map(
              runner.check_ancestry(graph_runtime.store(runtime), state)
              |> result.map_error(from_runner),
            )
            #(state, effects)
          }
        },
      )
      case
        runner.launch(
          graph_runtime.store(runtime),
          graph_runtime.work(runtime),
          graph_runtime.options(runtime),
          None,
          state,
          effects,
          None,
          False,
        )
      {
        Ok(_) -> Ok(Nil)
        Error(runner.StoreFailed(backend.AlreadyExists)) if tries > 1 ->
          reserved_child(runtime, parent, id, input, reservation, tries - 1)
        Error(error) -> Error(from_runner(error))
      }
    }
    Error(error) -> Error(from_runner(error))
  }
}

fn child_progress(
  runs: store.Store,
  parent: child.Parent,
  id: String,
  left: Int,
) -> Result(child.Progress, Error) {
  use _ <- result.try(case left > 0 {
    True -> Ok(Nil)
    False -> Error(CorruptRecord("child nesting limit reached"))
  })
  case runner.load_raw(runs, id) {
    Error(runner.StoreFailed(backend.NotFound)) -> Ok(child.Working)
    Error(error) -> Error(from_runner(error))
    Ok(#(_, state)) -> {
      use _ <- result.try(check_attachment(state, parent))
      use nested <- result.try(case state.phase {
        control.WaitingFork(a, _) -> nested_fork_progress(runs, state, a, left)
        control.Joining(a, child) | control.WaitingChild(a, child) ->
          case a.prepared.kind {
            operation.Agent ->
              agent_child.progress(runs, child.Parent(state.run, a.id), child)
              |> result.map_error(CallbackFailed)
            _ ->
              child_progress(
                runs,
                child.Parent(state.run, a.id),
                child,
                left - 1,
              )
          }
        _ -> Ok(child.Working)
      })
      Ok(case state.phase {
        control.AwaitingApproval(_, approval) ->
          child.Approval(approval.requirement)
        control.WaitingSignal(a) -> child.Signal(a.prepared.operation)
        control.WaitingJob(a) -> child.Job(a.prepared.operation)
        control.StoppingJob(_, job.RequestQueued, _)
        | control.StoppingJob(_, job.RequestStarted, _) -> child.Working
        control.StoppingJob(_, _, _) -> child.Cancelled(True)
        control.Blocked(_, problem) ->
          child.Uncertain(describe_problem(problem))
        control.ChildBlocked(_, _, reason) -> child.Uncertain(reason)
        control.Ended(control.Completed(output)) -> child.Succeeded(output)
        control.Ended(control.Failed(_, fault)) ->
          child.Failed(describe_failure(failure(fault)))
        control.Ended(control.Expired(_, control.UnresolvedCancellation(_))) ->
          child.Cancelled(True)
        control.Ended(control.Expired(_, _)) ->
          child.Failed("child deadline expired")
        control.Ended(control.Exhausted(_)) ->
          child.Failed("child activation limit reached")
        control.Ended(control.Cancelled(_, control.UnresolvedCancellation(_))) ->
          child.Cancelled(True)
        control.Ended(control.Cancelled(_, _)) -> child.Cancelled(False)
        _ ->
          case nested {
            child.Approval(_)
            | child.AgentInput(..)
            | child.Signal(_)
            | child.Job(_)
            | child.Fork(_)
            | child.Uncertain(_) -> nested
            child.FinishedUncertain(reason) -> child.Uncertain(reason)
            _ -> child.Working
          }
      })
    }
  }
}

fn describe_problem(problem: control.Problem) -> String {
  case problem {
    control.Uncertain(evidence) -> evidence
    control.InvalidResult(output, reason) -> reason <> ": " <> output
  }
}

/// One line for a run's failure, as a child's failure reads to its parent.
pub fn describe_failure(failure: Failure) -> String {
  case failure {
    DeadlineExpired(due) ->
      "the wait passed its deadline " <> int.to_string(due)
    ExpiredApproval(due) ->
      "the approval request expired unanswered at " <> int.to_string(due)
    Denied(reason) -> "denied: " <> reason
    PolicyFailed(reason) -> "the policy failed: " <> reason
    OperationFailed(reason) -> "the operation failed: " <> reason
    FamilyBudget(denial) ->
      "the family budget refused work: " <> describe_denial(denial)
  }
}

fn describe_denial(denial: budget.Denial) -> String {
  case denial {
    budget.WorkLimit(limit) -> "work limit " <> int.to_string(limit)
    budget.ChildLimit(limit) -> "child limit " <> int.to_string(limit)
    budget.DepthLimit(maximum, requested) ->
      "depth "
      <> int.to_string(requested)
      <> " over the limit "
      <> int.to_string(maximum)
  }
}

fn nested_fork_progress(
  runs: store.Store,
  state: control.State,
  a: control.Activation,
  left: Int,
) -> Result(child.Progress, Error) {
  use members <- result.try(
    control.current_fork(state, a.id) |> result.map_error(rejected),
  )
  use active <- result.try(
    list.try_map(scope.unsettled(members), fn(ref) {
      use member <- result.try(
        scope.member(members, ref)
        |> result.replace_error(CorruptRecord("fork member missing")),
      )
      let id = attachment.branch_id(state.run, a.id, ref.member)
      // A parked scope has acknowledged children; absence is not fresh work.
      use _ <- result.try(
        store_core.get(runs, id) |> result.map_error(store_failed),
      )
      use progress <- result.map(child_progress(
        runs,
        child.Branch(state.run, a.id, ref.member),
        id,
        left - 1,
      ))
      progress == child.Working
      || member.status != fork.Admitted(fork_driver.progress(progress))
    }),
  )
  case list.any(active, fn(value) { value }) {
    True -> Ok(child.Working)
    False -> Ok(child.Fork(scope.snapshot(members)))
  }
}

/// Starts a root run of `runtime` under `id`: stores its first record (a
/// successful return means it was confirmed) and hands its first
/// activation to a runner. Execution proceeds independently; a store
/// draining during start retains unattended work for recovery. `id` is the
/// caller's (`run.new_id()`, or `run.id_from_parts` of the work that starts
/// it), so that starting again finds the run (`AlreadyStarted`). A runtime
/// with a family budget (`with_family_budget`) declares it for this root.
///
/// `correlation` is carried in every event of the run, its child runs
/// included, and in every operation's `Invocation`; it is stored with the
/// run. `None` derives it from the id.
pub fn start(
  runtime: Runtime(context, state, answer),
  id id: run.RunId,
  initial initial: state,
  correlation correlation: Option(Correlation),
) -> Result(Handle(context, state, answer), Error) {
  use declaration <- result.try(case graph_runtime.family_budget(runtime) {
    None -> Ok(None)
    Some(limits) ->
      case store_core.supports_family_budget(graph_runtime.store(runtime)) {
        True -> Ok(Some(reservations.Declaration(limits, False)))
        False -> Error(FamilyBudgetUnsupported)
      }
  })
  let text = run.id_to_string(id)
  let correlation =
    option.lazy_unwrap(correlation, fn() { correlation.from_key(text) })
  use prepared <- result.try(
    bounded.call(graph_runtime.options(runtime).callback_timeout, fn() {
      compiled.prepare(graph_runtime.definition(runtime), initial)
    })
    |> result.map_error(callback_failed),
  )
  use #(value, prepared) <- result.try(
    prepared |> result.map_error(IncompatibleDefinition),
  )
  use #(state, effects) <- result.try(
    control.start_correlated(
      text,
      compiled.identity(graph_runtime.definition(runtime)),
      value,
      prepared,
      correlation,
      text,
    )
    |> result.map_error(rejected),
  )
  let state = control.State(..state, family_budget: declaration)
  case
    runner.launch(
      graph_runtime.store(runtime),
      graph_runtime.work(runtime),
      graph_runtime.options(runtime),
      None,
      state,
      effects,
      None,
      False,
    )
  {
    Ok(_) -> Ok(handle(runtime, id))
    Error(runner.StoreFailed(backend.AlreadyExists)) ->
      same_started_input(runtime, state)
      |> result.map_error(from_runner)
      |> result.try(fn(same) { Error(AlreadyStarted(id, same)) })
    Error(error) -> Error(from_runner(error))
  }
}

/// Whether the stored run `fresh.run` is a root of the same graph started
/// with the same initial state and correlation as `fresh`; the read's error
/// when the stored run cannot be read.
fn same_started_input(
  runtime: Runtime(context, state, answer),
  fresh: control.State,
) -> Result(Bool, runner.Error) {
  use #(_, stored) <- result.map(runner.load_raw(
    graph_runtime.store(runtime),
    fresh.run,
  ))
  stored.parent == None
  && stored.definition == fresh.definition
  && stored.initial == fresh.initial
  && stored.correlation == fresh.correlation
}

/// Whether this root was started with `initial`, under this definition.
/// Compares the canonical stored input, not the current state or the
/// correlation of a later request. Useful for idempotent request handlers.
/// The codec runs under the runtime's callback timeout.
pub fn matches_initial(
  handle: Handle(context, state, answer),
  initial: state,
) -> Result(Bool, Error) {
  let runtime = graph_handle.runtime(handle)
  use prepared <- result.try(
    bounded.call(graph_runtime.options(runtime).callback_timeout, fn() {
      compiled.prepare(graph_runtime.definition(runtime), initial)
    })
    |> result.map_error(callback_failed),
  )
  use #(value, _) <- result.try(
    prepared |> result.map_error(IncompatibleDefinition),
  )
  use #(_, stored) <- result.try(
    runner.load_raw(
      graph_runtime.store(runtime),
      run.id_to_string(graph_handle.id(handle)),
    )
    |> result.map_error(from_runner),
  )
  Ok(
    stored.parent == None
    && stored.definition == compiled.identity(graph_runtime.definition(runtime))
    && stored.initial == value,
  )
}

/// The run as stored, read through its current definition.
pub fn snapshot(
  handle: Handle(context, state, answer),
) -> Result(Snapshot(state, answer), Error) {
  let runtime = graph_handle.runtime(handle)
  use #(entry, state) <- result.try(
    runner.load(
      graph_runtime.store(runtime),
      graph_runtime.work(runtime),
      graph_runtime.options(runtime),
      run.id_to_string(graph_handle.id(handle)),
    )
    |> result.map_error(from_runner),
  )
  use view <- result.try(
    bounded.call(graph_runtime.options(runtime).callback_timeout, fn() {
      view(runtime, entry, state)
    })
    |> result.map_error(callback_failed),
  )
  view
}

/// The run's status, read through its current definition.
fn status(
  handle: Handle(context, state, answer),
) -> Result(Status(answer), Error) {
  snapshot(handle) |> result.map(fn(snapshot) { snapshot.status })
}

/// Waits up to `within` for completion, approval, reconciliation or
/// unattended work, and returns the run's status. At the deadline a
/// still-working status is returned; a `within` of zero (or less) reads the
/// status now. It never recovers a run, but an approval request whose
/// deadline passed is expired first, and the status shows the failed run.
/// `snapshot` reads the whole record (the state value, receipts, deadline).
pub fn await(
  handle: Handle(context, state, answer),
  within within: Duration,
) -> Result(Status(answer), Error) {
  case await_with(handle, within:, or: process.new_selector()) {
    Ok(Reached(status)) -> Ok(status)
    Ok(Interrupted(never)) -> never
    Error(error) -> Error(error)
  }
}

/// The status reached, or a caller-owned message that interrupted the wait.
pub type Awaited(answer, message) {
  Reached(Status(answer))
  Interrupted(message)
}

/// `await`, selecting on a caller's cancellation or shutdown at the same
/// time. Interruption leaves the run unchanged; the caller may `cancel` it.
pub fn await_with(
  handle: Handle(context, state, answer),
  within within: Duration,
  or interrupt: process.Selector(message),
) -> Result(Awaited(answer, message), Error) {
  let within = int.max(0, duration.to_milliseconds(within))
  let watcher = process.new_subject()
  let id = run.id_to_string(graph_handle.id(handle))
  use _ <- result.try(
    store_core.watch(
      graph_runtime.store(graph_handle.runtime(handle)),
      id,
      watcher,
    )
    |> result.map_error(store_failed),
  )
  let outcome = attend(handle, watcher, interrupt, now() + within)
  store_core.unwatch(
    graph_runtime.store(graph_handle.runtime(handle)),
    id,
    watcher,
  )
  outcome
}

fn attend(
  handle: Handle(context, state, answer),
  watcher: process.Subject(Nil),
  interrupt: process.Selector(message),
  deadline: Int,
) -> Result(Awaited(answer, message), Error) {
  use snapshot <- result.try(snapshot(handle))
  let left = deadline - now()
  case snapshot.status, left > 0 {
    AwaitingApproval(reference), _ ->
      case expire_if_due(handle, reference) {
        Ok(True) -> attend(handle, watcher, interrupt, deadline)
        Ok(False) -> Ok(Reached(snapshot.status))
        Error(error) -> Error(error)
      }
    Working, True
    | CancellingJob(_, job.RequestQueued, _), True
    | CancellingJob(_, job.RequestStarted, _), True
    | CancellingChild(_, _), True
    | Child(_, child.Working), True
    | Child(_, child.Succeeded(_)), True
    | Child(_, child.InvalidOutput(..)), True
    | Child(_, child.Failed(_)), True
    | Child(_, child.Cancelled(_)), True
    -> {
      let selected =
        interrupt
        |> process.map_selector(Interrupted)
        |> process.select_map(watcher, fn(_) { Reached(snapshot.status) })
      case process.selector_receive(selected, int.min(left, 100)) {
        Ok(Interrupted(message)) -> Ok(Interrupted(message))
        _ -> attend(handle, watcher, interrupt, deadline)
      }
    }
    _, _ -> Ok(Reached(snapshot.status))
  }
}

/// Expires the approval request `reference` names if its deadline passed;
/// `True` when the record changed (expired here or by another).
fn expire_if_due(
  handle: Handle(context, state, answer),
  reference: ApprovalRef,
) -> Result(Bool, Error) {
  let runtime = graph_handle.runtime(handle)
  use #(entry, state) <- result.try(
    runner.load_raw(
      graph_runtime.store(runtime),
      run.id_to_string(graph_handle.id(handle)),
    )
    |> result.map_error(from_runner),
  )
  use due <- result.try(
    runner.approval_due(graph_runtime.store(runtime), state)
    |> result.map_error(from_runner),
  )
  case due {
    None -> Ok(False)
    Some(#(approval, at)) ->
      case approval.revision == reference.revision {
        False -> Ok(True)
        True ->
          case commit_expiry(runtime, entry, state, approval, at) {
            Ok(_) | Error(Contended) | Error(StaleReference) -> Ok(True)
            Error(error) -> Error(error)
          }
      }
  }
}

fn commit_expiry(
  runtime: Runtime(context, state, answer),
  entry: store_core.Entry,
  state: control.State,
  approval: control.Approval,
  now: Int,
) -> Result(Nil, Error) {
  use #(next, effects) <- result.try(
    control.step(state, control.ExpireApproval(approval, now))
    |> result.map_error(rejected),
  )
  runner.launch(
    graph_runtime.store(runtime),
    graph_runtime.work(runtime),
    graph_runtime.options(runtime),
    Some(#(entry.revision, state)),
    next,
    effects,
    None,
    False,
  )
  |> result.replace(Nil)
  |> result.map_error(from_runner)
}

@external(erlang, "fabric_ffi", "now_ms")
fn now() -> Int

/// A leased store leaves a live foreign owner alone. On an unleased store,
/// callers must know the previous owner is gone before recovering through
/// another store process. Started effects obey their declared replay contract.
/// Idle child waits restore their local wakeup registration and reconnect the
/// child; a missed notification is repaired from its retained outcome.
/// For a canceled subgraph, recovery only records a now-settled child outcome;
/// it never restarts the child or resumes the parent's routes. A wait or an
/// approval request whose deadline passed expires.
pub fn recover(
  handle: Handle(context, state, answer),
) -> Result(Status(answer), Error) {
  let runtime = graph_handle.runtime(handle)
  use _ <- result.try(
    runner.recover(
      graph_runtime.store(runtime),
      graph_runtime.work(runtime),
      graph_runtime.options(runtime),
      run.id_to_string(graph_handle.id(handle)),
      3,
    )
    |> result.map_error(from_runner),
  )
  status(handle)
}

/// Inspect an admitted job wait once. Pending progress leaves its record
/// unchanged; a checked outcome commits its route before successor work starts.
/// Repeating an accepted reference reuses the saved result without another read.
/// After owned cancellation, terminal evidence settles the canceled run without
/// invoking its route. An accepted, refused or uncertain stop may be observed.
pub fn poll_job(
  handle: Handle(context, state, answer),
  reference: job.Reference,
) -> Result(Status(answer), Error) {
  use _ <- result.try(case reference.run == graph_handle.id(handle) {
    True -> Ok(Nil)
    False -> Error(WrongReference)
  })
  let runtime = graph_handle.runtime(handle)
  use _ <- result.try(
    runner.observe_job(
      graph_runtime.store(runtime),
      graph_runtime.work(runtime),
      graph_runtime.options(runtime),
      reference,
      3,
    )
    |> result.map_error(from_runner),
  )
  status(handle)
}

/// Cancels the run, and its managed children through the store, and
/// returns its status right after the cancellation was committed.
/// Cancellation does not require the currently deployed definition to fit the
/// record. A lost or unresponsive owner is fenced by a committed cancellation;
/// effects whose results were not saved remain explicitly unresolved.
/// For an admitted owned job this records intent, not proof that remote work
/// stopped. Its request runs only with compatible code and a committed fence;
/// manual or scheduled observation must confirm the terminal outcome. A run
/// that has ended is `RunEnded`.
pub fn cancel(
  handle: Handle(context, state, answer),
) -> Result(Status(answer), Error) {
  let runtime = graph_handle.runtime(handle)
  use _ <- result.try(
    runner.cancel(
      graph_runtime.store(runtime),
      graph_runtime.work(runtime),
      graph_runtime.options(runtime),
      run.id_to_string(graph_handle.id(handle)),
      3,
    )
    |> result.map_error(from_runner),
  )
  status(handle)
}

/// Cancels the stored run `id` with no definition: for a run that cannot
/// be opened because its definition changed (`IncompatibleDefinition`). A
/// run waiting on an approval, a signal, a job it observes, or a child is
/// cancelled in one commit, and its managed children through the store. An
/// owned job's stop request runs only under a compatible definition: its
/// intent is recorded, and the run stays unattended until it is recovered
/// with one. A run that has ended is `RunEnded`.
pub fn cancel_stored(store: store.Store, id: run.RunId) -> Result(Nil, Error) {
  runner.cancel(
    store,
    refusing_work(),
    runner.Options(
      callback_timeout: 1000,
      operation_timeout: Some(60_000),
      command_timeout: 1000,
      approval_expiry: None,
    ),
    run.id_to_string(id),
    3,
  )
  |> result.replace(Nil)
  |> result.map_error(from_runner)
}

/// Work with no definition behind it: every deployed callback refuses.
fn refusing_work() -> live.Work {
  fn() {
    live.Work(
      admit: fn(_, _) { Error("no definition is deployed for this run") },
      accept: fn(_, _, _) { Error(definition.DefinitionChanged) },
      check_output: fn(_, _) { Error(definition.DefinitionChanged) },
      observe_job: fn(_, _) { Error(definition.DefinitionChanged) },
      cancel_job: fn(_, _) { fn() { Error(definition.DefinitionChanged) } },
      validate: fn(_) { Error(definition.DefinitionChanged) },
      child: fn(_) { Error(definition.DefinitionChanged) },
      fork: fn(_) { Error(definition.DefinitionChanged) },
    )
  }
}

/// Approves the run's waiting approval request. `context` is the
/// application's current context: the policy is checked again with it, and
/// a current denial or policy failure wins over the approval; a policy that
/// now requires another approval refuses it with `RequirementChanged`. The
/// approved operation runs with exactly this context; it does not become
/// the run's context. An answer after the request's deadline
/// (`with_approval_expiry`) is refused with `ApprovalExpired`: the request
/// expires instead, and the run fails.
///
/// `proof` says who answers: `approvers.check` made it for the request's
/// requirement (`reference.requirement`) with the runtime's approvers
/// (`with_approvers`). Any other proof, or one older than the proof
/// lifetime, is refused with `ProofRefused` before the run is read. The
/// reviewer it names and the approvers' name are recorded with the answer
/// (`Snapshot.approvals`, `Receipt.approvals`).
pub fn approve(
  handle: Handle(context, state, answer),
  reference: ApprovalRef,
  proof proof: Proof,
  context context: context,
) -> Result(Status(answer), Error) {
  use #(reviewer, verifier) <- result.try(answerer_of(handle, proof, reference))
  answer_approval(handle, reference, Approving(reviewer, verifier, context), 3)
  |> result.map(fn(snapshot) { snapshot.status })
}

/// Rejects the run's waiting approval request: the operation does not run
/// and the run fails with `Denied(reason)`. A rejection is not checked
/// again, so it takes no context. It is refused like an approval (see
/// `approve`), except `RequirementChanged`. `proof` is checked and
/// recorded as for `approve`.
pub fn reject(
  handle: Handle(context, state, answer),
  reference: ApprovalRef,
  proof proof: Proof,
  reason reason: String,
) -> Result(Status(answer), Error) {
  use #(reviewer, verifier) <- result.try(answerer_of(handle, proof, reference))
  answer_approval(handle, reference, Rejecting(reviewer, verifier, reason), 3)
  |> result.map(fn(snapshot) { snapshot.status })
}

/// The reviewer and verifier of an answer to `reference` with `proof`.
fn answerer_of(
  handle: Handle(context, state, answer),
  proof: Proof,
  reference: ApprovalRef,
) -> Result(#(Reviewer, String), Error) {
  graph_runtime.approvers(graph_handle.runtime(handle))
  |> answerer.check(proof, reference.requirement)
  |> result.map_error(ProofRefused)
}

type Answering(context) {
  Approving(reviewer: Reviewer, verifier: String, context: context)
  Rejecting(reviewer: Reviewer, verifier: String, reason: String)
}

/// Supply a native value for the exact committed wait. An identical encoded
/// value for an already consumed reference is acknowledged without routing
/// again. A conflicting value is `SignalConflict`; a wait the run moved past
/// is `StaleReference`. A due wait instead commits and returns
/// `Failed(DeadlineExpired(due))`; that status acknowledges expiration,
/// not acceptance of the supplied value.
pub fn deliver(
  handle: Handle(context, state, answer),
  reference: SignalReference,
  contract: signal.Signal(value),
  value: value,
) -> Result(Status(answer), Error) {
  use _ <- result.try(case signal.identity(contract) == reference.contract {
    True -> Ok(Nil)
    False -> Error(WrongReference)
  })
  use encoded <- result.try(
    bounded.call(
      graph_runtime.options(graph_handle.runtime(handle)).callback_timeout,
      fn() { signal_contract.encode(contract, value) },
    )
    |> result.map_error(callback_failed),
  )
  use encoded <- result.try(encoded |> result.map_error(SignalEncodingFailed))
  deliver_json(handle, reference, encoded)
}

/// Transport boundary for callers that already hold encoded data. The saved
/// signal's deployed codec validates the value before it can be consumed.
/// Duplicate acknowledgement compares exact encoded bytes, including JSON
/// whitespace; transports should retain the original payload on retries.
pub fn deliver_json(
  handle: Handle(context, state, answer),
  reference: SignalReference,
  output_json: String,
) -> Result(Status(answer), Error) {
  deliver_with(handle, reference, output_json, 3)
  |> result.map(fn(snapshot) { snapshot.status })
}

fn signal_matches(
  reference: SignalReference,
  activation: control.Activation,
) -> Bool {
  reference.activation == activation.id
  && reference.attempt == activation.attempt
  && reference.contract == activation.prepared.operation
  && activation.prepared.kind == operation.Signal
}

/// `RunEnded` for an ended run, `StaleReference` for one that moved past
/// the wait `activation` names, `WrongReference` for one with no such
/// activation.
fn not_current(state: control.State, activation: Int) -> Error {
  case state.phase, control.activation(state, activation) {
    control.Ended(_), _ -> RunEnded
    _, Ok(_) -> StaleReference
    _, Error(Nil) ->
      case activation > 0 && activation <= state.allocated {
        True -> StaleReference
        False -> WrongReference
      }
  }
}

fn deliver_with(
  handle: Handle(context, state, answer),
  reference: SignalReference,
  output: String,
  tries: Int,
) -> Result(Snapshot(state, answer), Error) {
  use _ <- result.try(case reference.run == graph_handle.id(handle) {
    True -> Ok(Nil)
    False -> Error(WrongReference)
  })
  let runtime = graph_handle.runtime(handle)
  use #(entry, state) <- result.try(
    runner.load(
      graph_runtime.store(runtime),
      graph_runtime.work(runtime),
      graph_runtime.options(runtime),
      run.id_to_string(graph_handle.id(handle)),
    )
    |> result.map_error(from_runner),
  )
  case
    list.find(state.receipts, fn(receipt) {
      receipt.activation.id == reference.activation
    })
  {
    Ok(receipt) ->
      case
        signal_matches(reference, receipt.activation)
        && receipt.output == output
        && receipt.route != control.StoppedRoute
      {
        True -> snapshot(handle)
        False -> Error(SignalConflict)
      }
    Error(Nil) -> {
      use activation <- result.try(case state.phase {
        control.WaitingSignal(a) ->
          case signal_matches(reference, a) {
            True -> Ok(a)
            False -> Error(not_current(state, reference.activation))
          }
        _ -> Error(not_current(state, reference.activation))
      })
      use _ <- result.try(
        runner.check_ancestry(graph_runtime.store(runtime), state)
        |> result.map_error(from_runner),
      )
      use due <- result.try(
        runner.wait_due(graph_runtime.store(runtime), activation)
        |> result.map_error(from_runner),
      )
      use event <- result.try(case due {
        Some(now) ->
          Ok(control.ExpireWait(control.reference(state, activation), now))
        None -> signal_event(runtime, state, activation, output)
      })
      use #(next, effects) <- result.try(
        control.step(state, event) |> result.map_error(rejected),
      )
      case
        runner.launch(
          graph_runtime.store(runtime),
          graph_runtime.work(runtime),
          graph_runtime.options(runtime),
          Some(#(entry.revision, state)),
          next,
          effects,
          None,
          False,
        )
      {
        Ok(_) -> snapshot(handle)
        Error(runner.StoreFailed(backend.Conflict(_))) if tries > 1 ->
          deliver_with(handle, reference, output, tries - 1)
        Error(error) -> Error(from_runner(error))
      }
    }
  }
}

fn signal_event(
  runtime: Runtime(context, state, answer),
  state: control.State,
  activation: control.Activation,
  output: String,
) -> Result(control.Event, Error) {
  use accepted <- result.try(
    bounded.call(graph_runtime.options(runtime).callback_timeout, fn() {
      graph_runtime.work(runtime)().accept(state, activation, output)
    })
    |> result.map_error(callback_failed),
  )
  use decision <- result.try(accepted |> result.map_error(ValueRefused))
  use due <- result.map(
    runner.wait_due(graph_runtime.store(runtime), activation)
    |> result.map_error(from_runner),
  )
  case due {
    Some(now) -> control.ExpireWait(control.reference(state, activation), now)
    None ->
      control.Signaled(activation.id, activation.attempt, output, decision)
  }
}

/// Why `reference` cannot be answered in `state`.
fn unanswerable(state: control.State, reference: ApprovalRef) -> Error {
  let answered = case control.activation(state, reference.activation) {
    Ok(a) ->
      list.find(a.approvals, fn(approval) {
        approval.revision == reference.revision
      })
    Error(Nil) -> Error(Nil)
  }
  case state.phase, answered {
    // A request superseded by a new one is stale even though it was
    // answered.
    control.AwaitingApproval(a, _), _ if a.id == reference.activation ->
      StaleReference
    _, Ok(run.Approval(answer: run.Expired, ..)) -> ApprovalExpired
    _, Ok(_) -> AlreadyAnswered
    _, Error(Nil) -> not_current(state, reference.activation)
  }
}

fn answer_approval(
  handle: Handle(context, state, answer),
  approval: ApprovalRef,
  answering: Answering(context),
  tries: Int,
) -> Result(Snapshot(state, answer), Error) {
  let runtime = graph_handle.runtime(handle)
  let runs = graph_runtime.store(runtime)
  let id = run.id_to_string(graph_handle.id(handle))
  use _ <- result.try(case approval.run == graph_handle.id(handle) {
    True -> Ok(Nil)
    False -> Error(WrongReference)
  })
  use #(entry, state) <- result.try(
    runner.load(
      runs,
      graph_runtime.work(runtime),
      graph_runtime.options(runtime),
      id,
    )
    |> result.map_error(from_runner),
  )
  use #(activation, current) <- result.try(case state.phase {
    control.AwaitingApproval(activation, current)
      if current.activation == approval.activation
      && current.attempt == approval.attempt
      && current.revision == approval.revision
      && current.requirement == approval.requirement
    -> Ok(#(activation, current))
    _ -> Error(unanswerable(state, approval))
  })
  use due <- result.try(
    runner.approval_due(runs, state) |> result.map_error(from_runner),
  )
  case due {
    // The answer came too late: the request expires instead.
    Some(#(expiring, at)) ->
      case commit_expiry(runtime, entry, state, expiring, at) {
        Ok(_) -> Error(ApprovalExpired)
        Error(Contended) if tries > 1 ->
          answer_approval(handle, approval, answering, tries - 1)
        Error(error) -> Error(error)
      }
    None -> {
      use _ <- result.try(
        runner.check_ancestry(runs, state) |> result.map_error(from_runner),
      )
      use #(event, body) <- result.try(case answering {
        Rejecting(reviewer, verifier, reason) ->
          Ok(#(control.Rejected(current, reason, reviewer, verifier), None))
        Approving(reviewer, verifier, context) ->
          case
            runner.admit(
              runs,
              graph_runtime.work_with(runtime, context),
              graph_runtime.options(runtime),
              state,
              activation,
            )
          {
            Ok(live.Admission(decision, body)) -> {
              use expires <- result.map(
                runner.deadline_for(
                  runs,
                  graph_runtime.options(runtime),
                  Ok(decision),
                )
                |> result.map_error(from_runner),
              )
              #(
                control.Approved(
                  current,
                  Ok(decision),
                  reviewer,
                  verifier,
                  expires,
                ),
                Some(body),
              )
            }
            Error(runner.PolicyRejected(reason)) ->
              Ok(#(
                control.Approved(
                  current,
                  Error(reason),
                  reviewer,
                  verifier,
                  None,
                ),
                None,
              ))
            Error(runner.BudgetLimited(reason)) ->
              Ok(#(
                control.BudgetRefused(
                  control.reference(state, activation),
                  reason,
                ),
                None,
              ))
            Error(runner.BudgetUnavailable(reason)) ->
              Error(StoreUnavailable(reason))
            // An ancestor closed after the ancestry check above.
            Error(runner.AncestorStopping) -> Error(RunEnded)
          }
      })
      use #(next, effects) <- result.try(
        control.step(state, event) |> result.map_error(rejected),
      )
      case
        runner.launch(
          runs,
          graph_runtime.work(runtime),
          graph_runtime.options(runtime),
          Some(#(entry.revision, state)),
          next,
          effects,
          body,
          False,
        )
      {
        Ok(_) ->
          case next.phase {
            control.AwaitingApproval(_, reissued)
              if reissued.revision != current.revision
            ->
              Error(
                RequirementChanged(ApprovalRef(
                  graph_handle.id(handle),
                  reissued.activation,
                  reissued.attempt,
                  reissued.revision,
                  reissued.requirement,
                )),
              )
            _ -> snapshot(handle)
          }
        Error(runner.StoreFailed(backend.Conflict(_))) if tries > 1 ->
          answer_approval(handle, approval, answering, tries - 1)
        Error(error) -> Error(from_runner(error))
      }
    }
  }
}

/// Supply the actual result of the original operation, encoded with its
/// output codec. This is an explicit application reconciliation, not a
/// repeated body. After cancellation the result is retained without running
/// a route callback. A managed child's uncertain effect is
/// `ReconcileChildFirst`.
pub fn reconcile(
  handle: Handle(context, state, answer),
  reference: Reconciliation,
  content: String,
) -> Result(Status(answer), Error) {
  reconcile_with(handle, reference, content, 3)
  |> result.map(fn(snapshot) { snapshot.status })
}

fn reconcile_with(
  handle: Handle(context, state, answer),
  reference: Reconciliation,
  output: String,
  tries: Int,
) -> Result(Snapshot(state, answer), Error) {
  let runtime = graph_handle.runtime(handle)
  let id = run.id_to_string(graph_handle.id(handle))
  use _ <- result.try(case reference.run == graph_handle.id(handle) {
    True -> Ok(Nil)
    False -> Error(WrongReference)
  })
  use #(entry, state) <- result.try(
    runner.load(
      graph_runtime.store(runtime),
      graph_runtime.work(runtime),
      graph_runtime.options(runtime),
      id,
    )
    |> result.map_error(from_runner),
  )
  use #(activation, cancelled) <- result.try(case state.phase {
    control.Blocked(a, _) -> Ok(#(a, False))
    control.Ended(control.Cancelled(a, control.UnresolvedCancellation(_)))
    | control.Ended(control.Expired(a, control.UnresolvedCancellation(_))) ->
      Ok(#(a, True))
    _ -> Error(NotReconcilable)
  })
  use _ <- result.try(
    case
      cancelled
      && {
        activation.prepared.kind == operation.Subgraph
        || activation.prepared.kind == operation.Agent
      }
    {
      True -> Error(ReconcileChildFirst)
      False -> Ok(Nil)
    },
  )
  use _ <- result.try(case cancelled {
    True -> Ok(Nil)
    False ->
      runner.check_ancestry(graph_runtime.store(runtime), state)
      |> result.map_error(from_runner)
  })
  use _ <- result.try(
    case
      reference.activation == activation.id
      && reference.attempt == activation.attempt
    {
      True -> Ok(Nil)
      False -> Error(not_current(state, reference.activation))
    },
  )
  let due = fn() {
    case cancelled {
      True -> Ok(None)
      False ->
        runner.managed_due(graph_runtime.store(runtime), state)
        |> result.map(fn(due) { option.map(due, fn(entry) { entry.1 }) })
        |> result.map_error(from_runner)
    }
  }
  use before <- result.try(due())
  use event <- result.try(case before {
    Some(now) ->
      Ok(control.ExpireWait(control.reference(state, activation), now))
    None -> {
      let accepted =
        bounded.call(graph_runtime.options(runtime).callback_timeout, fn() {
          case cancelled {
            True -> {
              use _ <- result.map(graph_runtime.work(runtime)().check_output(
                activation,
                output,
              ))
              control.CancelledResult(
                control.reference(state, activation),
                output,
              )
            }
            False -> {
              use decision <- result.map(graph_runtime.work(runtime)().accept(
                state,
                activation,
                output,
              ))
              control.Reconciled(
                activation.id,
                activation.attempt,
                output,
                decision,
              )
            }
          }
        })
        |> result.map_error(callback_failed)
        |> result.try(fn(event) { event |> result.map_error(ValueRefused) })
      use after <- result.try(due())
      case after {
        Some(now) ->
          Ok(control.ExpireWait(control.reference(state, activation), now))
        None -> accepted
      }
    }
  })
  use #(next, effects) <- result.try(
    control.step(state, event) |> result.map_error(rejected),
  )
  case
    runner.launch(
      graph_runtime.store(runtime),
      graph_runtime.work(runtime),
      graph_runtime.options(runtime),
      Some(#(entry.revision, state)),
      next,
      effects,
      None,
      False,
    )
  {
    Ok(_) -> snapshot(handle)
    Error(runner.StoreFailed(backend.Conflict(_))) if tries > 1 ->
      reconcile_with(handle, reference, output, tries - 1)
    Error(error) -> Error(from_runner(error))
  }
}

fn view(
  runtime: Runtime(context, state, answer),
  entry: store_core.Entry,
  state: control.State,
) -> Result(Snapshot(state, answer), Error) {
  let definition = graph_runtime.definition(runtime)
  use value <- result.try(
    compiled.decode_state(definition, state.value)
    |> result.map_error(IncompatibleDefinition),
  )
  use status <- result.try(case state.phase {
    control.WaitingFork(a, mode) -> {
      use active <- result.try(
        runner.fork_has_activity(
          graph_runtime.store(runtime),
          graph_runtime.work(runtime),
          state,
          a,
        )
        |> result.map_error(CallbackFailed),
      )
      use saved <- result.try(
        list.find(state.forks, fn(saved) { saved.occurrence.activation == a.id })
        |> result.replace_error(CorruptRecord("missing fork scope")),
      )
      Ok(case active {
        True -> Working
        False ->
          Fork(saved, case mode {
            control.JoiningFork -> None
            control.ClosingFork(cause) -> Some(cause)
          })
      })
    }
    control.ChildBlocked(a, id, reason) ->
      Ok(Child(
        child.Reference(
          run_id.from_string(state.run),
          a.id,
          run_id.from_string(id),
        ),
        child.Uncertain(reason),
      ))
    control.WaitingChild(a, id) -> {
      use driver <- result.try(
        runner.checked_child(
          graph_runtime.store(runtime),
          graph_runtime.work(runtime),
          a,
        )
        |> result.map_error(CallbackFailed),
      )
      use progress <- result.try(
        driver.read(child.Parent(state.run, a.id), id, child_driver.Observe)
        |> result.map_error(CallbackFailed),
      )
      Ok(Child(
        child.Reference(
          run_id.from_string(state.run),
          a.id,
          run_id.from_string(id),
        ),
        progress,
      ))
    }
    control.StoppingChild(a, id, cause) ->
      Ok(case runner.driven(entry, state) {
        False -> Unattended
        True ->
          CancellingChild(
            child.Reference(
              run_id.from_string(state.run),
              a.id,
              run_id.from_string(id),
            ),
            cause,
          )
      })
    control.Joining(a, id) ->
      Ok(case runner.driven(entry, state) {
        False -> Unattended
        True -> {
          let progress = case
            runner.checked_child(
              graph_runtime.store(runtime),
              graph_runtime.work(runtime),
              a,
            )
          {
            Error(error) -> child.Uncertain(error)
            Ok(driver) ->
              case
                driver.read(
                  child.Parent(state.run, a.id),
                  id,
                  child_driver.Observe,
                )
              {
                Ok(progress) -> progress
                Error(reason) -> child.Uncertain(reason)
              }
          }
          Child(
            child.Reference(
              run_id.from_string(state.run),
              a.id,
              run_id.from_string(id),
            ),
            progress,
          )
        }
      })
    control.PreparingFork(_)
    | control.Forking(..)
    | control.Ready(_)
    | control.ArmingWait(_)
    | control.Queued(_)
    | control.Running(_)
    | control.Stopping(_) ->
      Ok(case runner.driven(entry, state) {
        True -> Working
        False -> Unattended
      })
    control.AwaitingApproval(_, reference) ->
      Ok(
        AwaitingApproval(ApprovalRef(
          run_id.from_string(state.run),
          reference.activation,
          reference.attempt,
          reference.revision,
          reference.requirement,
        )),
      )
    control.WaitingJob(a) ->
      Ok(
        AwaitingJob(job.Reference(
          run_id.from_string(state.run),
          a.id,
          a.attempt,
          a.prepared.operation,
        )),
      )
    control.StoppingJob(a, progress, cause) ->
      Ok(case control.needs_runner(state) && !runner.driven(entry, state) {
        True -> Unattended
        False ->
          CancellingJob(
            job.Reference(
              run_id.from_string(state.run),
              a.id,
              a.attempt,
              a.prepared.operation,
            ),
            progress,
            cause,
          )
      })
    control.WaitingSignal(a) ->
      Ok(
        AwaitingSignal(SignalReference(
          run_id.from_string(state.run),
          a.id,
          a.attempt,
          a.prepared.operation,
        )),
      )
    control.Blocked(a, problem) ->
      Ok(Blocked(
        Reconciliation(run_id.from_string(state.run), a.id, a.attempt),
        public_problem(problem),
      ))
    control.Ended(control.Completed(answer)) ->
      compiled.decode_answer(definition, answer)
      |> result.map(Completed)
      |> result.map_error(IncompatibleDefinition)
    control.Ended(control.Exhausted(_)) -> Ok(Exhausted)
    control.Ended(control.Failed(_, fault)) -> Ok(Failed(failure(fault)))
    control.Ended(control.Expired(a, disposition)) ->
      case a.deadline {
        Some(due) ->
          Ok(Expired(due, public_cancellation(state, a, disposition)))
        None -> Error(CorruptRecord("an expired activation has no deadline"))
      }
    control.Ended(control.Cancelled(a, cancellation)) ->
      Ok(Cancelled(public_cancellation(state, a, cancellation)))
  })
  let current = current_activation(state)
  Ok(Snapshot(
    revision: entry.revision,
    value:,
    status:,
    current: option.map(current, fn(a) {
      action(state, a.id, a.attempt, a.prepared)
    }),
    approvals: case current {
      Some(a) -> a.approvals
      None -> []
    },
    receipts: public_receipts(state),
    deadline: case state.phase {
      control.AwaitingApproval(_, approval) -> approval.expires
      control.WaitingSignal(a)
      | control.WaitingJob(a)
      | control.StoppingJob(a, _, _)
      | control.PreparingFork(a)
      | control.Forking(a, _)
      | control.WaitingFork(a, _)
      | control.Joining(a, _)
      | control.WaitingChild(a, _)
      | control.ChildBlocked(a, _, _)
      | control.StoppingChild(a, _, _)
      | control.Blocked(a, _)
      | control.Ended(control.Failed(a, control.DeadlineExpired(_)))
      | control.Ended(control.Expired(a, _)) -> a.deadline
      control.Ended(control.Failed(_, control.ApprovalExpired(due))) ->
        Some(due)
      _ -> None
    },
    forks: state.forks,
  ))
}

fn public_cancellation(
  state: control.State,
  a: control.Activation,
  cancellation: control.Cancellation,
) -> Cancellation {
  case cancellation {
    control.AfterFork -> ForkSettled(a.id)
    control.BeforeStart -> BeforeStart
    control.JobDetached ->
      JobDetached(job.Reference(
        run_id.from_string(state.run),
        a.id,
        a.attempt,
        a.prepared.operation,
      ))
    control.JobStopped ->
      JobStopped(job.Reference(
        run_id.from_string(state.run),
        a.id,
        a.attempt,
        a.prepared.operation,
      ))
    control.AfterResult -> AfterResult
    control.AfterFailure(fault) -> AfterFailure(failure(fault))
    control.AfterChild(id) ->
      ChildSettled(child.Reference(
        run_id.from_string(state.run),
        a.id,
        run_id.from_string(id),
      ))
    control.UnresolvedCancellation(problem)
      if {
        a.prepared.kind == operation.Subgraph
        || a.prepared.kind == operation.Agent
      }
    ->
      ChildUnresolved(
        child.Reference(
          run_id.from_string(state.run),
          a.id,
          run_id.from_string(attachment.reserved_id(state.run, a.id)),
        ),
        public_problem(problem),
      )
    control.UnresolvedCancellation(problem) ->
      Unresolved(
        Reconciliation(run_id.from_string(state.run), a.id, a.attempt),
        public_problem(problem),
      )
  }
}

fn current_activation(state: control.State) -> Option(control.Activation) {
  case state.phase {
    control.Ready(a)
    | control.Queued(a)
    | control.Running(a)
    | control.AwaitingApproval(a, _)
    | control.WaitingSignal(a)
    | control.ArmingWait(a)
    | control.WaitingJob(a)
    | control.StoppingJob(a, _, _)
    | control.PreparingFork(a)
    | control.Forking(a, _)
    | control.WaitingFork(a, _)
    | control.Joining(a, _)
    | control.WaitingChild(a, _)
    | control.ChildBlocked(a, _, _)
    | control.StoppingChild(a, _, _)
    | control.Blocked(a, _)
    | control.Stopping(a)
    | control.Ended(control.Failed(a, _))
    | control.Ended(control.Expired(a, _))
    | control.Ended(control.Cancelled(a, _)) -> Some(a)
    control.Ended(control.Completed(_)) | control.Ended(control.Exhausted(_)) ->
      None
  }
}

fn public_receipts(state: control.State) -> List(Receipt) {
  list.map(state.receipts, fn(receipt) {
    let a = receipt.activation
    Receipt(
      activation: a.id,
      attempt: a.attempt,
      node: a.prepared.node,
      operation: a.prepared.operation,
      input_json: a.prepared.input,
      output_json: receipt.output,
      state_json: receipt.state,
      route: case receipt.route {
        control.Next(node) -> Next(node)
        control.Finished -> Finished
        control.StoppedRoute -> Stopped
      },
      approvals: a.approvals,
    )
  })
}

fn failure(fault: control.Fault) -> Failure {
  case fault {
    control.DeadlineExpired(due) -> DeadlineExpired(due)
    control.ApprovalExpired(due) -> ExpiredApproval(due)
    control.Denied(reason) -> Denied(reason)
    control.PolicyFailed(reason) -> PolicyFailed(reason)
    control.OperationFailed(reason) -> OperationFailed(reason)
    control.FamilyBudget(reason) -> FamilyBudget(reason)
  }
}

fn public_problem(problem: control.Problem) -> Problem {
  case problem {
    control.Uncertain(evidence) -> EffectUncertain(evidence)
    control.InvalidResult(output, reason) -> InvalidResult(output, reason)
  }
}

fn callback_failed(failure: bounded.Failure) -> Error {
  case failure {
    bounded.TimedOut -> CallbackFailed("timed out")
    bounded.Crashed(reason) -> CallbackFailed("crashed: " <> reason)
  }
}

fn store_failed(error: backend.StoreError) -> Error {
  case error {
    backend.NotFound -> RunNotFound
    backend.Unavailable(reason) -> StoreUnavailable(reason)
    backend.Conflict(_) -> Contended
    backend.LeaseRefused(_) -> RunUnattended
    backend.AlreadyExists -> StoreUnavailable("the run already exists")
  }
}

fn rejected(rejection: control.Rejection) -> Error {
  case rejection {
    control.AlreadyEnded -> RunEnded
    control.WrongPhase | control.StaleInvocation | control.StaleApproval ->
      StaleReference
    control.InvalidDefinition(detail) | control.InvalidPrepared(detail) ->
      CorruptRecord(detail)
  }
}

fn from_runner(error: runner.Error) -> Error {
  case error {
    runner.StoreFailed(error) -> store_failed(error)
    runner.Unreadable(record.Corrupt(reason)) -> CorruptRecord(reason)
    runner.Unreadable(record.UnsupportedVersion(version)) ->
      UnsupportedVersion(version)
    runner.Incompatible(error) -> IncompatibleDefinition(error)
    runner.CallbackFailed(reason) -> CallbackFailed(reason)
    runner.Refused(rejection) -> rejected(rejection)
    runner.AncestorClosed -> RunEnded
    runner.Busy -> RunnerBusy
    runner.Contended -> Contended
    runner.OwnerUnknown -> RunUnattended
  }
}

//// What a run is and what it can become. These are plain data: a suspended
//// run is exactly its stored `Snapshot`, with no process behind it.

import fabric/model.{type Message, type ModelError, type ToolCall}
import fabric/policy.{type ActionId, type Requirement}
import gleam/option.{type Option}

pub type Status {
  /// A model call or a tool is in flight.
  Working
  /// Nothing is in flight and the run cannot continue without outside
  /// input: approvals to answer or uncertain effects to reconcile.
  Suspended(approvals: List(PendingApproval), uncertain: List(UncertainAction))
  Finished(Outcome)
}

/// Identifies one approval request. `revision` is unique within the run
/// and survives restarts, so a reference stays answerable until it is
/// answered, superseded by a new requirement, or voided by the run ending.
/// References are plain data: an application may serialize one (into a link
/// or a form) and rebuild it later; `fabric.answer` checks it against the
/// stored record.
pub type ApprovalRef {
  ApprovalRef(
    run: String,
    id: ActionId,
    requirement: Requirement,
    revision: Int,
  )
}

pub type PendingApproval {
  PendingApproval(reference: ApprovalRef, tool: String, arguments_json: String)
}

/// A reviewer's answer to an approval request.
pub type Answer {
  Approve
  /// The action does not run; the model sees `reason`.
  Reject(reason: String)
}

/// An answered approval request, kept on its action. `reviewer` is the
/// identity the application passed to `fabric.answer`, as given: Fabric
/// records it and does not authenticate it.
pub type Approval {
  Approval(
    requirement: Requirement,
    revision: Int,
    answer: Answer,
    reviewer: Option(String),
  )
}

/// The agent definition a run was started with. A stored run continues
/// only under the same name and version.
pub type Identity {
  Identity(name: String, version: Int)
}

/// Why a stored run cannot continue under a given agent.
pub type Incompatibility {
  /// The run was started by another agent definition.
  OtherAgent(stored: Identity)
  /// An action that may still run names a tool the agent does not have.
  ToolNotRegistered(id: ActionId, tool: String)
  /// An action that has not started yet names a tool whose input codec no
  /// longer accepts its arguments.
  ArgumentsNotAccepted(id: ActionId, tool: String, detail: String)
}

/// An effect of unknown status in `run`: this run, or one of its
/// sub-agent runs (reconcile it on that run's handle, see `fabric.child`).
pub type UncertainAction {
  UncertainAction(run: String, id: ActionId, tool: String, evidence: String)
}

/// The action of the parent run that started a sub-agent run.
pub type Parent {
  Parent(run: String, action: ActionId)
}

pub type Outcome {
  Completed(text: String)
  Refused(reason: String)
  OutputLimited(partial_text: String)
  /// A limit was reached. Outstanding tool calls are kept as `NotStarted`.
  BudgetExhausted(Budget)
  /// A token budget is set but the provider did not report usage for the
  /// reply of this turn, so the budget cannot be enforced.
  BudgetUnverifiable(turn: Int)
  Cancelled
  Failed(HostFailure)
}

/// The run-wide budget that ended a run.
pub type Budget {
  TurnLimit(limit: Int)
  TokenLimit(limit: Int, used: Int)
}

/// The sub-agent limit that refused one delegation; the run continues.
pub type DelegationLimit {
  /// A run starts at most `limit` sub-agent runs.
  ChildLimit(limit: Int)
  /// Sub-agents nest at most `limit` levels below the root run.
  DepthLimit(limit: Int)
}

/// Failures of the host rather than of the model or a tool's business logic.
pub type HostFailure {
  PolicyFailed(id: ActionId, reason: String)
  OutputEncodingFailed(id: ActionId, detail: String)
  /// The call's arguments were admitted, but when its tool started they no
  /// longer decode, or no tool of that name is registered: the tool changed
  /// between admission and start. The handler did not run. It is not shown
  /// to the model, whose arguments were valid.
  ToolChanged(id: ActionId, detail: String)
  ModelFailed(ModelError)
  ModelProtocolViolation(reason: String)
}

pub type ActionState {
  /// Allowed and waiting for a concurrency slot.
  Queued
  /// The start was committed before the tool body ran.
  Running
  AwaitingApproval(requirement: Requirement, revision: Int)
  Succeeded(content: String)
  /// A typed failure; `content` is what the model sees.
  ToolFailed(content: String)
  Denied(reason: String)
  /// A reviewer rejected the action; the model sees `reason`.
  Rejected(reason: String)
  InvalidArguments(detail: String)
  UnknownTool
  /// The effect may or may not have happened; the next model turn waits for
  /// reconciliation.
  Uncertain(evidence: String)
  Reconciled(content: String)
  /// Withdrawn before it started (cancellation, a budget, or a host failure).
  NotStarted
  /// A sub-agent run (`ActionRecord.child`) is working on it; its outcome
  /// becomes this action's result.
  Delegated
  /// A delegation refused before the policy because it would exceed a
  /// sub-agent limit; the model sees why.
  LimitReached(DelegationLimit)
  /// The host could not complete the action: its output could not be
  /// encoded, or its tool changed after admission. The run stopped.
  Faulted(detail: String)
}

/// `approvals` lists the answered approval requests of the action, oldest
/// first. `child` names the sub-agent run a delegation started, from the
/// moment it is started, and stays after the action settles.
pub type ActionRecord {
  ActionRecord(
    id: ActionId,
    call: ToolCall,
    state: ActionState,
    approvals: List(Approval),
    child: Option(String),
  )
}

/// Token totals over every reply. `unreported_replies` counts replies that
/// arrived without usage; they are not counted as zero.
pub type TokenUsage {
  TokenUsage(input_tokens: Int, output_tokens: Int, unreported_replies: Int)
}

pub type Snapshot {
  Snapshot(
    run: String,
    agent: Identity,
    /// Increases by one each time recovery takes over work that no live
    /// runner owned.
    incarnation: Int,
    /// The parent action of a sub-agent run; `None` for a root run.
    parent: Option(Parent),
    status: Status,
    turns_used: Int,
    max_turns: Int,
    usage: TokenUsage,
    transcript: List(Message),
    actions: List(ActionRecord),
  )
}

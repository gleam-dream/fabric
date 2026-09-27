//// What a run is and what it can become. These are plain data: a suspended
//// run is exactly its stored `Snapshot`, with no process behind it.

import fabric/model.{type Message, type ModelError, type ToolCall}
import fabric/policy.{type ActionId, type Requirement}

pub type Status {
  /// A model call or a tool is in flight.
  Working
  /// Nothing is in flight and the run cannot continue without outside
  /// input: approvals to answer (slice 2) or uncertain effects to reconcile.
  Suspended(approvals: List(PendingApproval), uncertain: List(UncertainAction))
  Finished(Outcome)
}

pub type PendingApproval {
  PendingApproval(
    id: ActionId,
    tool: String,
    arguments_json: String,
    requirement: Requirement,
    revision: Int,
  )
}

pub type UncertainAction {
  UncertainAction(id: ActionId, tool: String, evidence: String)
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

pub type Budget {
  TurnLimit(limit: Int)
  TokenLimit(limit: Int, used: Int)
}

/// Failures of the host rather than of the model or a tool's business logic.
pub type HostFailure {
  PolicyFailed(id: ActionId, reason: String)
  OutputEncodingFailed(id: ActionId, detail: String)
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
  InvalidArguments(detail: String)
  UnknownTool
  /// The effect may or may not have happened; the next model turn waits for
  /// reconciliation.
  Uncertain(evidence: String)
  Reconciled(content: String)
  /// Withdrawn before it started (cancellation, a budget, or a host failure).
  NotStarted
  /// The handler finished but its output could not be encoded.
  Faulted(detail: String)
}

pub type ActionRecord {
  ActionRecord(id: ActionId, call: ToolCall, state: ActionState)
}

/// Token totals over every reply. `unreported_replies` counts replies that
/// arrived without usage; they are not counted as zero.
pub type TokenUsage {
  TokenUsage(input_tokens: Int, output_tokens: Int, unreported_replies: Int)
}

pub type Snapshot {
  Snapshot(
    run: String,
    status: Status,
    turns_used: Int,
    max_turns: Int,
    usage: TokenUsage,
    transcript: List(Message),
    actions: List(ActionRecord),
  )
}

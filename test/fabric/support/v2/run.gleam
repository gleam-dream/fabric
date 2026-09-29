//// Frozen v2 types from Git 570502e928496b0203909f164a5e8fd021b8ddc8.
//// See README.md in this directory; do not adapt to current domain types.

import fabric/support/v2/model.{type ModelError, type ToolCall}
import fabric/support/v2/policy.{type ActionId, type Requirement}
import gleam/option.{type Option}

pub type Answer {
  Approve
  /// The action does not run; the model sees `reason`.
  Reject(reason: String)
}

pub type Approval {
  Approval(
    requirement: Requirement,
    revision: Int,
    answer: Answer,
    reviewer: Option(String),
  )
}

pub type Identity {
  Identity(name: String, version: Int)
}

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

pub type Budget {
  TurnLimit(limit: Int)
  TokenLimit(limit: Int, used: Int)
  /// A run starts at most `limit` sub-agent runs.
  ChildLimit(limit: Int)
  /// Sub-agents nest at most `limit` levels below the root run.
  DepthLimit(limit: Int)
}

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
  /// sub-agent budget; the model sees why.
  LimitReached(Budget)
  /// The host could not complete the action: its output could not be
  /// encoded, or its tool changed after admission. The run stopped.
  Faulted(detail: String)
}

pub type ActionRecord {
  ActionRecord(
    id: ActionId,
    call: ToolCall,
    state: ActionState,
    approvals: List(Approval),
    child: Option(String),
  )
}

pub type TokenUsage {
  TokenUsage(input_tokens: Int, output_tokens: Int, unreported_replies: Int)
}

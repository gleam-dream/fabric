//// What a run is and what it can become. These are plain data: a suspended
//// run is exactly its stored `Snapshot`, with no process behind it.

import fabric/budget
import fabric/internal/run_id
import fabric/model.{type Message, type ModelError, type ToolCall}
import fabric/reviewer.{type Reviewer}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/string
import gleam/time/calendar
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}

/// The id of a run. The caller chooses it when it starts a run
/// (`fabric.start`, `graph.start`): `new_id()` for a fresh one, or
/// `parse_id` of an application key (a job id, an order id) so that a
/// retried start finds the run it already started. A string from outside (a
/// link, a form, a job payload) becomes one only through `parse_id`.
pub type RunId =
  run_id.RunId

/// A bound on a wait. `Infinity` is never a default: a caller that wants
/// a wait unbounded says so.
pub type Timeout {
  After(Duration)
  Infinity
}

/// A fresh run id: `run-` and 32 random lowercase hexadecimal characters
/// (128 random bits), so fresh ids do not collide.
pub fn new_id() -> RunId {
  run_id.from_string("run-" <> random_id())
}

@external(erlang, "fabric_ffi", "random_id")
fn random_id() -> String

/// A run id in the shape Fabric issues: 1 to 128 letters, digits, `-` and
/// `_`. Anything else names no run. A well-formed id may still name no
/// stored run; commands then report `RunNotFound`.
pub fn parse_id(text: String) -> Result(RunId, Nil) {
  let length = string.length(text)
  let allowed =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
  case
    length >= 1
    && length <= 128
    && list.all(string.to_graphemes(text), string.contains(allowed, _))
  {
    True -> Ok(run_id.from_string(text))
    False -> Error(Nil)
  }
}

/// A run id derived from an application key, for a start that must be
/// idempotent: the same parts always give the same id, so a start retried
/// with them finds its run (`AlreadyStarted`). Unlike `parse_id` it is total.
///
/// `prefix` names the kind of work, is written in source code, and must be 1
/// to 32 ASCII letters and digits; any other prefix is a bug and panics.
/// The parts are joined to it with `-`: `id_from_parts("job", ["42", "1"])`
/// is `job-42-1`. When that text is not a valid id (a part has other
/// characters, or it is longer than 128 characters), the id is the prefix,
/// `_` and the SHA-256 of the parts in hexadecimal instead, which stays
/// unique and stable. Give each part a fixed shape (digits, a uuid), since
/// `["4-2"]` and `["4", "2"]` join to the same text.
///
/// When a retry must start a fresh run rather than find the old one,
/// include the attempt among the parts.
pub fn id_from_parts(prefix: String, parts: List(String)) -> RunId {
  let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  let length = string.length(prefix)
  case
    length >= 1
    && length <= 32
    && list.all(string.to_graphemes(prefix), string.contains(letters, _))
  {
    False ->
      panic as {
        "run.id_from_parts: the prefix must be 1 to 32 ASCII letters and digits: "
        <> string.inspect(prefix)
      }
    True -> {
      let text = string.join([prefix, ..parts], "-")
      case parse_id(text) {
        Ok(id) -> id
        Error(Nil) ->
          run_id.from_string(
            prefix <> "_" <> sha256_hex(string.join(parts, "\u{0}")),
          )
      }
    }
  }
}

@external(erlang, "fabric_ffi", "sha256_hex")
fn sha256_hex(text: String) -> String

pub fn id_to_string(id: RunId) -> String {
  run_id.to_string(id)
}

/// Identifies an action within one run. A provider call id alone is not
/// unique: providers reuse ids on later turns.
pub type ActionId {
  ActionId(turn: Int, call_id: String)
}

/// Names one action of one run: the delegation that started a sub-agent
/// run, or an uncertain effect to reconcile.
pub type ActionRef {
  ActionRef(run: RunId, id: ActionId)
}

/// The durable attachment that owns a run. Graph visits and chat actions
/// have different identities; neither is encoded as the other.
pub type Parent {
  AgentParent(run: RunId, id: ActionId)
  GraphParent(run: RunId, activation: Int)
  GraphBranch(run: RunId, activation: Int, member: Int)
}

/// Which approval an action needs. `version` lets an application change the
/// requirement for an action and have stale approvals refused.
pub type Requirement {
  Requirement(name: String, version: Int)
}

/// A run's status. `answer` is the agent's answer type
/// (`agent.with_answer`): `String` for a plain agent, and for commands that
/// read the store without an agent (`fabric.cancel_stored`).
pub type Status(answer) {
  /// A model call or a tool is in flight, driven by a runner.
  Working
  /// Work is in flight but no runner known to this store drives it: its
  /// runner was lost, or the run is driven through another `Store`.
  /// `fabric.recover` takes it over. On an unleased store the previous
  /// owner must be known to be gone; a leased store checks ownership.
  /// A configured sweeper recovers it after the lease expires.
  Unattended
  /// Nothing is in flight and the run cannot continue without outside
  /// input: approvals to answer or uncertain effects to reconcile.
  Suspended(approvals: List(PendingApproval), uncertain: List(UncertainAction))
  Finished(Outcome(answer))
}

/// Identifies one approval request. `revision` is unique within the run and
/// survives restarts, so a reference stays answerable until it is answered,
/// superseded by a new requirement, or voided by the run ending. References are
/// plain data: an application may serialize one (into a link or a form) and
/// rebuild it later; `fabric.approve` and `fabric.reject` check it against the
/// stored record.
pub type ApprovalRef {
  ApprovalRef(run: RunId, id: ActionId, requirement: Requirement, revision: Int)
}

/// An approval request waiting for an answer. Read it by label: Fabric may
/// add fields. `expires` is when it expires unanswered (`None`: never); an
/// expired request rejects its action (see `agent.with_approval_expiry`).
pub type PendingApproval {
  PendingApproval(
    reference: ApprovalRef,
    tool: String,
    arguments_json: String,
    expires: Option(Timestamp),
  )
}

/// The answer to an approval request.
pub type Answer {
  Approve
  /// The action does not run; the model sees `reason`.
  Reject(reason: String)
  /// No one answered before the request's deadline: the action does not
  /// run, and the model sees that its approval expired.
  Expired
}

/// An answered approval request, kept on its action. Read it by label.
/// `reviewer` is the identity the application passed to `fabric.approve` or
/// `fabric.reject`: Fabric records it and does not authenticate it. It is
/// `None` for an `Expired` answer, and for an answer stored before reviewers
/// were required.
pub type Approval {
  Approval(
    requirement: Requirement,
    revision: Int,
    answer: Answer,
    reviewer: Option(Reviewer),
  )
}

/// The agent definition a run was started with. A stored run continues
/// only under the same name and version.
pub type DefinitionId {
  DefinitionId(name: String, version: Int)
}

/// Why a stored run cannot continue under a given agent.
pub type Incompatibility {
  /// The run was started by another agent definition.
  OtherAgent(stored: DefinitionId)
  /// An action that may still run names a tool the agent does not have.
  ToolNotRegistered(id: ActionId, tool: String)
  /// An action that has not started yet names a tool whose input codec no
  /// longer accepts its arguments.
  ArgumentsNotAccepted(id: ActionId, tool: String, detail: String)
}

/// An effect of unknown status. `reference` names its run (this run, or one
/// of its sub-agent runs) and action; `fabric.reconcile` takes it.
pub type UncertainAction {
  UncertainAction(reference: ActionRef, tool: String, evidence: String)
}

/// How a run ended. This union may grow: keep a catch-all.
pub type Outcome(answer) {
  /// The model's final answer, read with the agent's answer codec
  /// (`agent.with_answer`), or its text for a plain agent.
  Completed(answer: answer)
  /// The model's final answer is not one the agent's codec reads: `raw` is
  /// the text it sent last, `reason` the codec's complaint. A run ends this
  /// way when the model answers so on its last answer attempt
  /// (`agent.with_answer_attempts`) or with no turn or token left for a
  /// correction; a stored run reads this way when the agent
  /// that reads it has another codec than the one it completed under (a run
  /// stored before `with_answer`, say). Its effects have happened.
  AnswerInvalid(raw: String, reason: String)
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

/// One line for logs and for a caller that reports why a run did not
/// complete, such as an MCP tool that served the run.
pub fn describe_outcome(outcome: Outcome(answer)) -> String {
  case outcome {
    Completed(_) -> "the run completed"
    AnswerInvalid(reason:, ..) ->
      "the model's final answer is invalid: " <> reason
    Refused(reason) -> "the model refused: " <> reason
    OutputLimited(_) -> "the model's reply reached its output limit"
    BudgetExhausted(TurnLimit(limit)) ->
      "the run used all of its " <> int.to_string(limit) <> " model attempts"
    BudgetExhausted(TokenLimit(limit, used)) ->
      "the run used "
      <> int.to_string(used)
      <> " tokens of its budget of "
      <> int.to_string(limit)
    BudgetExhausted(FamilyLimit(_)) -> "the run family's shared budget is spent"
    BudgetUnverifiable(turn) ->
      "the provider reported no token usage for model attempt "
      <> int.to_string(turn)
      <> ", so the token budget cannot be enforced"
    Cancelled -> "the run was cancelled"
    Failed(failure) -> describe_host_failure(failure)
  }
}

/// The run-wide budget that ended a run.
pub type Budget {
  TurnLimit(limit: Int)
  TokenLimit(limit: Int, used: Int)
  /// Shared by the root and all managed descendants.
  FamilyLimit(budget.Denial)
}

/// The sub-agent limit that refused one delegation; the run continues.
pub type DelegationLimit {
  /// A run starts at most `limit` sub-agent runs.
  ChildLimit(limit: Int)
  /// Sub-agents nest at most `limit` levels below the root run.
  DepthLimit(limit: Int)
}

/// Failures of the host rather than of the model or a tool's business logic.
/// This union may grow: keep a catch-all, or branch on `host_failure_kind`.
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

/// A stable classification of `HostFailure`, by the part of the host to
/// look at. It never gains variants.
pub type HostFailureKind {
  /// The policy failed on an action (`PolicyFailed`).
  PolicyFault
  /// A tool's result could not be recorded, or the tool changed between
  /// admission and start (`OutputEncodingFailed`, `ToolChanged`).
  ToolFault
  /// The model call failed after its retries, or the model broke the
  /// protocol (`ModelFailed`, `ModelProtocolViolation`). A `ModelFailed`
  /// carries its own `model.error_kind`.
  ModelFault
}

pub fn host_failure_kind(failure: HostFailure) -> HostFailureKind {
  case failure {
    PolicyFailed(..) -> PolicyFault
    OutputEncodingFailed(..) | ToolChanged(..) -> ToolFault
    ModelFailed(_) | ModelProtocolViolation(_) -> ModelFault
  }
}

/// One line for logs; `describe_outcome` uses it for `Failed`.
pub fn describe_host_failure(failure: HostFailure) -> String {
  case failure {
    PolicyFailed(reason:, ..) -> "the policy failed: " <> reason
    OutputEncodingFailed(detail:, ..) ->
      "a tool's result could not be recorded: " <> detail
    ToolChanged(detail:, ..) ->
      "a tool changed after its call was admitted: " <> detail
    ModelFailed(error) -> "the model failed: " <> model.describe_error(error)
    ModelProtocolViolation(reason) -> "the model broke the protocol: " <> reason
  }
}

/// Where one action stands. This union may grow: keep a catch-all, or
/// branch on `action_state_kind`.
pub type ActionState {
  /// Allowed and waiting for a concurrency slot.
  Queued
  /// The start was committed before the tool body ran.
  Running
  /// Waiting for an answer to its approval request. `expires` is the
  /// request's deadline (`agent.with_approval_expiry`): after it the
  /// request expires, and the action is rejected. `None` never expires.
  AwaitingApproval(
    requirement: Requirement,
    revision: Int,
    expires: Option(Timestamp),
  )
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
  /// A finished parent's uncertain delegation was settled from the child's
  /// saved outcome. This is evidence only, never a model-visible tool result.
  /// Its answer is the child's stored text.
  ChildSettled(outcome: Outcome(String))
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

/// A stable classification of `ActionState`, by what the caller does next.
/// It never gains variants.
pub type ActionStateKind {
  /// The action settles without the caller (`Queued`, `Running`,
  /// `Delegated`). A delegation's sub-agent run may itself wait for input.
  Active
  /// The action waits for an answer to its approval request
  /// (`AwaitingApproval`): `fabric.approve` or `fabric.reject` it.
  NeedsApproval
  /// The action's effect is of unknown status (`Uncertain`):
  /// `fabric.reconcile` it.
  NeedsReconciliation
  /// The action has its final state: a result the model sees or saw, a
  /// refusal, a settlement, a withdrawal or a host fault.
  Ended
}

pub fn action_state_kind(state: ActionState) -> ActionStateKind {
  case state {
    Queued | Running | Delegated -> Active
    AwaitingApproval(..) -> NeedsApproval
    Uncertain(_) -> NeedsReconciliation
    Succeeded(_)
    | ToolFailed(_)
    | Denied(_)
    | Rejected(_)
    | InvalidArguments(_)
    | UnknownTool
    | Reconciled(_)
    | ChildSettled(_)
    | NotStarted
    | LimitReached(_)
    | Faulted(_) -> Ended
  }
}

/// One line for logs. It names a tool's result (`Succeeded`, `ToolFailed`,
/// `Reconciled`) and a sub-agent's answer only by their presence: they may
/// carry application data.
pub fn describe_action_state(state: ActionState) -> String {
  case state {
    Queued -> "queued for a concurrency slot"
    Running -> "running"
    AwaitingApproval(requirement:, revision:, expires:) ->
      "awaiting approval ("
      <> requirement.name
      <> " version "
      <> int.to_string(requirement.version)
      <> ", revision "
      <> int.to_string(revision)
      <> ")"
      <> case expires {
        option.Some(at) ->
          ", expires at " <> timestamp.to_rfc3339(at, calendar.utc_offset)
        option.None -> ""
      }
    Succeeded(_) -> "succeeded"
    ToolFailed(_) -> "the tool failed; the model sees its failure"
    Denied(reason) -> "denied by the policy: " <> reason
    Rejected(reason) -> "rejected by a reviewer: " <> reason
    InvalidArguments(detail) -> "its arguments are invalid: " <> detail
    UnknownTool -> "no tool of that name"
    Uncertain(evidence) -> "its effect is uncertain: " <> evidence
    Reconciled(_) -> "reconciled"
    ChildSettled(outcome) ->
      "settled from its sub-agent run: " <> describe_outcome(outcome)
    NotStarted -> "withdrawn before it started"
    Delegated -> "delegated to a sub-agent run"
    LimitReached(ChildLimit(limit)) ->
      "refused: a run starts at most "
      <> int.to_string(limit)
      <> " sub-agent runs"
    LimitReached(DepthLimit(limit)) ->
      "refused: sub-agents nest at most "
      <> int.to_string(limit)
      <> " levels below the root run"
    Faulted(detail) -> "the host could not complete it: " <> detail
  }
}

/// One action of a run. Read it by label: Fabric may add fields.
/// `approvals` lists the answered approval requests of the action, oldest
/// first. `child` names the sub-agent run a delegation started, from the
/// moment it is started, and stays after the action settles. `replays`
/// counts how often a replayable tool's body was started again after a
/// crash, a timeout or a lost runner (`tool.with_replay`).
pub type ActionRecord {
  ActionRecord(
    id: ActionId,
    call: ToolCall,
    state: ActionState,
    approvals: List(Approval),
    child: Option(RunId),
    replays: Int,
  )
}

/// Token totals over every reply. `unreported_replies` counts replies that
/// arrived without usage; they are not counted as zero.
pub type TokenUsage {
  TokenUsage(input_tokens: Int, output_tokens: Int, unreported_replies: Int)
}

/// A run as stored. Read it by label: Fabric may add fields.
pub type Snapshot(answer) {
  Snapshot(
    run: RunId,
    agent: DefinitionId,
    /// Increases by one each time recovery takes over work that no live
    /// runner owned.
    incarnation: Int,
    /// The action or graph activation that owns this run; `None` for a root.
    parent: Option(Parent),
    status: Status(answer),
    turns_used: Int,
    max_turns: Int,
    usage: TokenUsage,
    transcript: List(Message),
    actions: List(ActionRecord),
  )
}

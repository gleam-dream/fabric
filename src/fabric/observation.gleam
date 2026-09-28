//// Fabric's Sinal events: what a run did, for logs, metrics, and traces.
////
//// Observation is diagnostic, never a source of truth: the run's record is.
//// Every event is emitted after the commit of the transition it describes, by
//// the process that made the commit (a runner, or the caller of `start`,
//// `approve`, `reject`, `cancel`, `reconcile`, `recover`, or `cancel_stored`),
//// and never by the pure controller. The lease events of a leased store
//// (`lease_lost`, `renewal_failed`) describe no commit: a process its
//// store's process starts emits each, after the kill or the failed
//// renewal, so that no handler holds up the store. Every event is emitted
//// with `sinal/forwarder.emit_routed`, so the application chooses where
//// handlers run:
////
//// - By default, synchronously in the committing process. A handler that
////   blocks holds up that run's progress.
//// - If the application routes `[fabric]` (or a longer prefix) through a
////   forwarder with `forwarder.route`, in the forwarder's process. A
////   blocked handler then stalls the forwarder, never the run, and a
////   handler cannot read the committing process's dictionary. Route at
////   application start, once the forwarder is supervised, and `unroute`
////   at shutdown.
////
//// A handler that fails (returns an error or raises) is detached by Sinal
//// and telemetry and never affects the run.
////
//// A command (`approve`, `reject`, `cancel`, `reconcile`, `cancel_stored`)
//// that a live runner applies is answered once its commit is stored, before
//// that commit's events are emitted. A command applied with no runner (to a
//// suspended run, or a cancellation that takes over a lost or held run) is
//// committed by its caller, which emits the commit's events itself before the
//// command returns: a synchronous handler then holds up the caller, while a
//// runner the commit started is already working. A synchronous handler running
//// in a runner holds that runner: a command it sends to the run it observes is
//// refused at once with `fabric.RunnerBusy`, and a command from elsewhere that
//// the runner does not take within the agent's command timeout is refused the
//// same way and never applied later. A cancellation is the exception: it is
//// committed to the record, abandoning the held runner's work. A runner held
//// by a handler of another process is then killed, with its model call and
//// tool bodies; a runner whose own handler cancelled its run calls no model
//// and starts no child afterwards, and stops at its next commit. Handlers that
//// call Fabric should run in a forwarder.
////
//// An event may be missing: a process that dies between its commit and
//// its emit, or a commit made through a store in another VM, emits
//// nothing here. A routed event is also dropped when its forwarder is full
//// or not running (both counted and reported through the forwarder's
//// `dropped_event`, those made while it is down by its next incarnation),
//// and in-flight events are lost if the forwarder stops. Events
//// of one commit are emitted in the order listed below, and one process's
//// events keep their order through one route; events of different runs,
//// of one run through several processes, or split across a route change
//// have no global order.
////
//// | Event | Name | When |
//// | --- | --- | --- |
//// | `run_started` | `[fabric, run, start]` | the run's first record is stored
//// (a sub-agent run names its parent) |
//// | `run_recovered` | `[fabric, run, recover]` | a recovery took over lost
//// work (new incarnation) |
//// | `run_handed_off` | `[fabric, run, hand_off]` | a runner drained by a
//// shutdown committed its run's handoff (see `store.supervised`) |
//// | `run_taken_over` | `[fabric, run, take_over]` | a recovery through a
//// leased store took over a run whose lease another owner held, after the
//// commit (with `run_recovered`) |
//// | `lease_lost` | `[fabric, lease, lose]` | a leased store killed a
//// runner whose lease it lost (`Revoked`) or could no longer renew in time
//// (`Unrenewed`) |
//// | `renewal_failed` | `[fabric, lease, renew, fail]` | a leased store's
//// batch renewal failed |
//// | `model_turn` | `[fabric, model, stop]` | a model attempt's reply or
//// failure was committed |
//// | `approval_answered` | `[fabric, approval, answer]` | an answer was
//// committed (also one a changed requirement superseded) |
//// | `approval_requested` | `[fabric, approval, request]` | an action started
//// waiting for an approval |
//// | `tool_dispatched` | `[fabric, tool, start]` | a tool's fence was
//// committed: its body may run |
//// | `tool_settled` | `[fabric, tool, stop]` | a dispatched tool's result was
//// committed |
//// | `child_started` | `[fabric, child, start]` | a delegation's child run is
//// stored and runs |
//// | `child_settled` | `[fabric, child, stop]` | a child run's end was applied
//// to its delegation |
//// | `settlement_refused` | `[fabric, tool, settlement, refuse]` | a late
//// settlement was refused (see below) |
//// | `run_cancelled` | `[fabric, run, cancel]` | a cancellation was committed
//// |
//// | `run_finished` | `[fabric, run, stop]` | the run ended |
////
//// A late settlement (`tool.bind_settling`) of a stopped action is
//// observed as that action's `tool_settled`; one that resolves an
//// uncertain effect emits nothing, like a reconciliation. A settlement the
//// run refused commits nothing: `settlement_refused` is emitted by the
//// process that offered it, once it has its answer, with why it was
//// refused. `NotAwaited` and `NotReached` mean what the settlement knew is
//// not in the record and needs a person.
////
//// Metadata carries identifiers and closed kinds only, never arguments,
//// tool results, or model text, with one exception: `settlement_refused`
//// carries the refused settlement's summary as the tool gave it to
//// `tool.settle`, so that a person can reconcile the action. A tool's
//// summary must therefore not carry secrets; `fabric_saga`'s
//// name outcome kinds and step addresses only. `turn` and `call_id`
//// identify an action only within its `run`.

import fabric/model.{type Usage, Usage}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/list
import gleam/option.{type Option}
import sinal.{type Event}
import sinal/fields.{type Fields}

/// An action of a run: model turn, provider call id, and tool or
/// delegation name.
pub type ActionRef {
  ActionRef(run: String, turn: Int, call_id: String, tool: String)
}

pub type RunStarted {
  RunStarted(
    run: String,
    agent: String,
    agent_version: Int,
    parent: Option(String),
  )
}

pub type RunRecovered {
  RunRecovered(run: String, incarnation: Int)
}

/// The incarnation whose runner handed the run off; `fabric.recover` goes
/// on with the next.
pub type RunHandedOff {
  RunHandedOff(run: String, incarnation: Int)
}

/// A recovery took over a run whose lease another owner held (expired, or
/// of an earlier process of the recovering store), as `incarnation`.
pub type RunTakenOver {
  RunTakenOver(run: String, incarnation: Int, previous_owner: String)
}

/// Why a leased store killed a runner.
pub type LeaseLoss {
  /// The renewal no longer returned the run: another owner took it over,
  /// or a cancellation took its lease.
  Revoked
  /// No renewal succeeded for so long that the lease could have expired
  /// (the backend was unreachable).
  Unrenewed
}

/// A leased store (`owner`) killed the runner of `run`, with its model call
/// and tool bodies.
pub type LeaseLost {
  LeaseLost(run: String, owner: String, reason: LeaseLoss)
}

/// A leased store's renewal of the leases of its `runs` runners failed.
pub type RenewalFailed {
  RenewalFailed(owner: String, runs: Int)
}

/// What a model attempt produced.
pub type TurnResult {
  /// Tool or delegation calls.
  ToolRequest
  FinalAnswer
  Refusal
  Truncated
  /// A retryable failure; the model is called again.
  Retry
  /// A failure that ends the run.
  ModelFailure
  ProtocolViolation
  /// A reply whose calls a budget did not allow.
  BudgetStop
}

pub type ModelTurn {
  ModelTurn(run: String, turn: Int, result: TurnResult)
}

pub type Answered {
  Approved
  Rejected
}

pub type ApprovalRequested {
  ApprovalRequested(
    action: ActionRef,
    requirement: String,
    requirement_version: Int,
    revision: Int,
  )
}

pub type ApprovalAnswered {
  ApprovalAnswered(action: ActionRef, revision: Int, answer: Answered)
}

pub type ToolDispatched {
  ToolDispatched(action: ActionRef)
}

/// How an action's result reached the run.
pub type Disposition {
  /// The model sees the result (a success or a typed failure).
  ModelVisible
  /// The effect may or may not have happened; the run waits for
  /// reconciliation.
  EffectUncertain
  /// The host failed (for example an unencodable output); the run stops.
  HostFailure
  /// A child run that was never stored; nothing happened.
  Withdrawn
}

pub type ToolSettled {
  ToolSettled(action: ActionRef, disposition: Disposition)
}

pub type ChildStarted {
  ChildStarted(action: ActionRef, child: String)
}

pub type ChildSettled {
  ChildSettled(action: ActionRef, child: String, disposition: Disposition)
}

/// Why a late settlement was not recorded.
pub type SettlementRefusal {
  /// The action already has a definite result: nothing is lost.
  AlreadyRecorded
  /// The action does not await a settlement and has no definite result.
  NotAwaited
  /// The store could not be read or written.
  NotReached
}

pub type SettlementRefused {
  SettlementRefused(
    action: ActionRef,
    /// What the settlement offered.
    offered: Disposition,
    reason: SettlementRefusal,
    /// What a person needs to reconcile the action, as the tool gave it to
    /// `tool.settle`.
    summary: String,
  )
}

pub type RunCancelled {
  RunCancelled(run: String)
}

pub type OutcomeKind {
  Completed
  Refused
  OutputLimited
  BudgetExhausted
  BudgetUnverifiable
  Cancelled
  Failed
}

pub type RunFinished {
  RunFinished(run: String, outcome: OutcomeKind)
}

/// Totals over the whole run.
pub type RunTotals {
  RunTotals(turns: Int, input_tokens: Int, output_tokens: Int)
}

// --- descriptors
// ---------------------------------------------------------------

pub fn run_started() -> Event(Nil, RunStarted) {
  let assert Ok(parent) = fields.optional(text("parent"))
  event(
    ["run", "start"],
    fields.empty(),
    both(both(text("run"), text("agent")), both(int("agent_version"), parent))
      |> fields.imap(
        fn(values) {
          let #(#(run, agent), #(version, parent)) = values
          RunStarted(run, agent, version, parent)
        },
        fn(started) {
          #(
            #(started.run, started.agent),
            #(started.agent_version, started.parent),
          )
        },
      ),
  )
}

pub fn run_recovered() -> Event(Nil, RunRecovered) {
  event(
    ["run", "recover"],
    fields.empty(),
    both(text("run"), int("incarnation"))
      |> fields.imap(
        fn(values) { RunRecovered(values.0, values.1) },
        fn(recovered) { #(recovered.run, recovered.incarnation) },
      ),
  )
}

pub fn run_handed_off() -> Event(Nil, RunHandedOff) {
  event(
    ["run", "hand_off"],
    fields.empty(),
    both(text("run"), int("incarnation"))
      |> fields.imap(
        fn(values) { RunHandedOff(values.0, values.1) },
        fn(handed) { #(handed.run, handed.incarnation) },
      ),
  )
}

pub fn run_taken_over() -> Event(Nil, RunTakenOver) {
  event(
    ["run", "take_over"],
    fields.empty(),
    both(text("run"), both(int("incarnation"), text("previous_owner")))
      |> fields.imap(
        fn(values) {
          let #(run, #(incarnation, previous)) = values
          RunTakenOver(run, incarnation, previous)
        },
        fn(taken) { #(taken.run, #(taken.incarnation, taken.previous_owner)) },
      ),
  )
}

pub fn lease_lost() -> Event(Nil, LeaseLost) {
  event(
    ["lease", "lose"],
    fields.empty(),
    both(
      both(text("run"), text("owner")),
      kind("reason", lease_loss_name, [Revoked, Unrenewed]),
    )
      |> fields.imap(
        fn(values) {
          let #(#(run, owner), reason) = values
          LeaseLost(run, owner, reason)
        },
        fn(lost) { #(#(lost.run, lost.owner), lost.reason) },
      ),
  )
}

fn lease_loss_name(reason: LeaseLoss) -> String {
  case reason {
    Revoked -> "revoked"
    Unrenewed -> "unrenewed"
  }
}

pub fn renewal_failed() -> Event(Nil, RenewalFailed) {
  event(
    ["lease", "renew", "fail"],
    fields.empty(),
    both(text("owner"), int("runs"))
      |> fields.imap(
        fn(values) { RenewalFailed(values.0, values.1) },
        fn(failed) { #(failed.owner, failed.runs) },
      ),
  )
}

/// Its measurements are the tokens the provider reported for this attempt
/// (zero when it reported none).
pub fn model_turn() -> Event(Usage, ModelTurn) {
  event(
    ["model", "stop"],
    tokens(),
    both(
      both(text("run"), int("turn")),
      kind("result", turn_result_name, [
        ToolRequest,
        FinalAnswer,
        Refusal,
        Truncated,
        Retry,
        ModelFailure,
        ProtocolViolation,
        BudgetStop,
      ]),
    )
      |> fields.imap(
        fn(values) {
          let #(#(run, turn), result) = values
          ModelTurn(run, turn, result)
        },
        fn(turn) { #(#(turn.run, turn.turn), turn.result) },
      ),
  )
}

pub fn approval_requested() -> Event(Nil, ApprovalRequested) {
  event(
    ["approval", "request"],
    fields.empty(),
    both(
      action_fields(),
      both(
        text("requirement"),
        both(int("requirement_version"), int("revision")),
      ),
    )
      |> fields.imap(
        fn(values) {
          let #(action, #(requirement, #(version, revision))) = values
          ApprovalRequested(action, requirement, version, revision)
        },
        fn(requested) {
          #(
            requested.action,
            #(
              requested.requirement,
              #(requested.requirement_version, requested.revision),
            ),
          )
        },
      ),
  )
}

pub fn approval_answered() -> Event(Nil, ApprovalAnswered) {
  event(
    ["approval", "answer"],
    fields.empty(),
    both(
      action_fields(),
      both(int("revision"), kind("answer", answered_name, [Approved, Rejected])),
    )
      |> fields.imap(
        fn(values) {
          let #(action, #(revision, answer)) = values
          ApprovalAnswered(action, revision, answer)
        },
        fn(answered) {
          #(answered.action, #(answered.revision, answered.answer))
        },
      ),
  )
}

pub fn tool_dispatched() -> Event(Nil, ToolDispatched) {
  event(
    ["tool", "start"],
    fields.empty(),
    action_fields() |> fields.imap(ToolDispatched, fn(tool) { tool.action }),
  )
}

pub fn tool_settled() -> Event(Nil, ToolSettled) {
  event(
    ["tool", "stop"],
    fields.empty(),
    both(action_fields(), disposition())
      |> fields.imap(
        fn(values) { ToolSettled(values.0, values.1) },
        fn(settled) { #(settled.action, settled.disposition) },
      ),
  )
}

pub fn child_started() -> Event(Nil, ChildStarted) {
  event(
    ["child", "start"],
    fields.empty(),
    both(action_fields(), text("child"))
      |> fields.imap(
        fn(values) { ChildStarted(values.0, values.1) },
        fn(started) { #(started.action, started.child) },
      ),
  )
}

pub fn child_settled() -> Event(Nil, ChildSettled) {
  event(
    ["child", "stop"],
    fields.empty(),
    both(action_fields(), both(text("child"), disposition()))
      |> fields.imap(
        fn(values) {
          let #(action, #(child, disposition)) = values
          ChildSettled(action, child, disposition)
        },
        fn(settled) { #(settled.action, #(settled.child, settled.disposition)) },
      ),
  )
}

pub fn settlement_refused() -> Event(Nil, SettlementRefused) {
  event(
    ["tool", "settlement", "refuse"],
    fields.empty(),
    both(
      action_fields(),
      both(
        disposition(),
        both(
          kind("reason", refusal_name, [AlreadyRecorded, NotAwaited, NotReached]),
          text("summary"),
        ),
      ),
    )
      |> fields.imap(
        fn(values) {
          let #(action, #(offered, #(reason, evidence))) = values
          SettlementRefused(action, offered, reason, evidence)
        },
        fn(refused) {
          #(
            refused.action,
            #(refused.offered, #(refused.reason, refused.summary)),
          )
        },
      ),
  )
}

pub fn run_cancelled() -> Event(Nil, RunCancelled) {
  event(
    ["run", "cancel"],
    fields.empty(),
    text("run") |> fields.imap(RunCancelled, fn(cancelled) { cancelled.run }),
  )
}

pub fn run_finished() -> Event(RunTotals, RunFinished) {
  let assert Ok(totals) =
    fields.pair(int("turns"), both(int("input_tokens"), int("output_tokens")))
  event(
    ["run", "stop"],
    totals
      |> fields.imap(
        fn(values) {
          let #(turns, #(input, output)) = values
          RunTotals(turns, input, output)
        },
        fn(totals) {
          #(totals.turns, #(totals.input_tokens, totals.output_tokens))
        },
      ),
    both(
      text("run"),
      kind("outcome", outcome_name, [
        Completed,
        Refused,
        OutputLimited,
        BudgetExhausted,
        BudgetUnverifiable,
        Cancelled,
        Failed,
      ]),
    )
      |> fields.imap(
        fn(values) { RunFinished(values.0, values.1) },
        fn(finished) { #(finished.run, finished.outcome) },
      ),
  )
}

// --- field helpers
// -------------------------------------------------------------

fn event(
  name: List(String),
  measurements: Fields(m),
  metadata: Fields(d),
) -> Event(m, d) {
  // The names are constant and non-empty, so this cannot fail.
  let assert Ok(event) =
    sinal.event(
      [atom.create("fabric"), ..list.map(name, atom.create)],
      measurements,
      metadata,
    )
  event
}

fn text(key: String) -> Fields(String) {
  fields.string(atom.create(key))
}

fn int(key: String) -> Fields(Int) {
  fields.int(atom.create(key))
}

/// Pairs field groups with distinct keys (the keys here are constant).
fn both(left: Fields(a), right: Fields(b)) -> Fields(#(a, b)) {
  let assert Ok(pair) = fields.pair(left, right)
  pair
}

fn action_fields() -> Fields(ActionRef) {
  both(both(text("run"), int("turn")), both(text("call_id"), text("tool")))
  |> fields.imap(
    fn(values) {
      let #(#(run, turn), #(call_id, tool)) = values
      ActionRef(run, turn, call_id, tool)
    },
    fn(action) { #(#(action.run, action.turn), #(action.call_id, action.tool)) },
  )
}

fn tokens() -> Fields(Usage) {
  both(int("input_tokens"), int("output_tokens"))
  |> fields.imap(fn(values) { Usage(values.0, values.1) }, fn(tokens) {
    #(tokens.input_tokens, tokens.output_tokens)
  })
}

fn disposition() -> Fields(Disposition) {
  kind("disposition", disposition_name, [
    ModelVisible,
    EffectUncertain,
    HostFailure,
    Withdrawn,
  ])
}

/// A closed kind carried as a string, decoded back by name.
fn kind(key: String, name: fn(a) -> String, all: List(a)) -> Fields(a) {
  fields.field(
    atom.create(key),
    fn(value) { Ok(dynamic.string(name(value))) },
    fn(raw) {
      case decode.run(raw, decode.string) {
        Error(_) -> Error(fields.FieldDecodeError("expected a string"))
        Ok(found) ->
          case list.find(all, fn(value) { name(value) == found }) {
            Ok(value) -> Ok(value)
            Error(Nil) ->
              Error(fields.FieldDecodeError("unknown " <> key <> ": " <> found))
          }
      }
    },
  )
}

fn turn_result_name(result: TurnResult) -> String {
  case result {
    ToolRequest -> "tool_request"
    FinalAnswer -> "final_answer"
    Refusal -> "refusal"
    Truncated -> "truncated"
    Retry -> "retry"
    ModelFailure -> "model_failure"
    ProtocolViolation -> "protocol_violation"
    BudgetStop -> "budget_stop"
  }
}

fn answered_name(answer: Answered) -> String {
  case answer {
    Approved -> "approved"
    Rejected -> "rejected"
  }
}

fn disposition_name(disposition: Disposition) -> String {
  case disposition {
    ModelVisible -> "model_visible"
    EffectUncertain -> "effect_uncertain"
    HostFailure -> "host_failure"
    Withdrawn -> "withdrawn"
  }
}

fn refusal_name(refusal: SettlementRefusal) -> String {
  case refusal {
    AlreadyRecorded -> "already_recorded"
    NotAwaited -> "not_awaited"
    NotReached -> "not_reached"
  }
}

fn outcome_name(outcome: OutcomeKind) -> String {
  case outcome {
    Completed -> "completed"
    Refused -> "refused"
    OutputLimited -> "output_limited"
    BudgetExhausted -> "budget_exhausted"
    BudgetUnverifiable -> "budget_unverifiable"
    Cancelled -> "cancelled"
    Failed -> "failed"
  }
}

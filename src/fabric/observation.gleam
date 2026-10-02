//// Fabric's Sinal events: what a run did, for logs, metrics, and traces.
////
//// Observation is diagnostic, never a source of truth: the run's record is.
//// Every event is emitted after the commit of the transition it describes, by
//// the process that made the commit (a runner, or the caller of `start`,
//// `approve`, `reject`, `cancel`, `reconcile`, `recover`, or `cancel_stored`),
//// and never by the pure controller. The lease events of a leased store
//// (`lease_lost`, `renewal_failed`) describe no commit: a process its
//// store's process starts emits each, after the kill or the failed
//// renewal, so that no handler holds up the store. The `sweep` event is
//// emitted after a scan in a separate process with a 1-second deadline;
//// a blocked synchronous handler is stopped, so scans cannot accumulate
//// blocked emitters. Shutdown emits `drain` or `drain_unavailable` with
//// the same bound before the store closes. Every event uses `sinal.emit`,
//// which follows forwarder routes, so the application chooses where
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
//// | `sweep` | `[fabric, sweep, stop]` | a bounded recovery scan finished;
//// reports claimed runs, recovered candidates, unknown root identities and failures |
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
//// | `drain` | `[fabric, drain, stop]` | the factory stopped; runner exit
//// and handoff evidence were collected within the accounting deadline |
//// | `drain_unavailable` | `[fabric, drain, unavailable]` | shutdown
//// accounting could not be read; no successful empty summary is inferred |
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
import gleam/option.{type Option, None, Some}
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

/// Totals over the whole run. The token counts sum the replies that
/// reported usage; `unreported_replies` counts the replies that arrived
/// without it, which are not counted as zero (see `run.TokenUsage`).
pub type RunTotals {
  RunTotals(
    turns: Int,
    input_tokens: Int,
    output_tokens: Int,
    unreported_replies: Int,
  )
}

// --- descriptors
// ---------------------------------------------------------------

pub fn run_started() -> Event(Nil, RunStarted) {
  event(
    ["run", "start"],
    fields.empty(),
    fields.record({
      use run <- fields.parameter
      use agent <- fields.parameter
      use agent_version <- fields.parameter
      use parent <- fields.parameter
      RunStarted(run:, agent:, agent_version:, parent:)
    })
      |> fields.and(fields.string("run"), fn(started: RunStarted) {
        started.run
      })
      |> fields.and(fields.string("agent"), fn(started) { started.agent })
      |> fields.and(fields.int("agent_version"), fn(started) {
        started.agent_version
      })
      |> fields.and(fields.optional(fields.string("parent")), fn(started) {
        started.parent
      })
      |> fields.build,
  )
}

pub fn run_recovered() -> Event(Nil, RunRecovered) {
  event(
    ["run", "recover"],
    fields.empty(),
    fields.record({
      use run <- fields.parameter
      use incarnation <- fields.parameter
      RunRecovered(run:, incarnation:)
    })
      |> fields.and(fields.string("run"), fn(recovered: RunRecovered) {
        recovered.run
      })
      |> fields.and(fields.int("incarnation"), fn(recovered) {
        recovered.incarnation
      })
      |> fields.build,
  )
}

pub fn run_handed_off() -> Event(Nil, RunHandedOff) {
  event(
    ["run", "hand_off"],
    fields.empty(),
    fields.record({
      use run <- fields.parameter
      use incarnation <- fields.parameter
      RunHandedOff(run:, incarnation:)
    })
      |> fields.and(fields.string("run"), fn(handed: RunHandedOff) {
        handed.run
      })
      |> fields.and(fields.int("incarnation"), fn(handed) { handed.incarnation })
      |> fields.build,
  )
}

pub fn run_taken_over() -> Event(Nil, RunTakenOver) {
  event(
    ["run", "take_over"],
    fields.empty(),
    fields.record({
      use run <- fields.parameter
      use incarnation <- fields.parameter
      use previous_owner <- fields.parameter
      RunTakenOver(run:, incarnation:, previous_owner:)
    })
      |> fields.and(fields.string("run"), fn(taken: RunTakenOver) { taken.run })
      |> fields.and(fields.int("incarnation"), fn(taken) { taken.incarnation })
      |> fields.and(fields.string("previous_owner"), fn(taken) {
        taken.previous_owner
      })
      |> fields.build,
  )
}

pub fn lease_lost() -> Event(Nil, LeaseLost) {
  event(
    ["lease", "lose"],
    fields.empty(),
    fields.record({
      use run <- fields.parameter
      use owner <- fields.parameter
      use reason <- fields.parameter
      LeaseLost(run:, owner:, reason:)
    })
      |> fields.and(fields.string("run"), fn(lost: LeaseLost) { lost.run })
      |> fields.and(fields.string("owner"), fn(lost) { lost.owner })
      |> fields.and(
        fields.enum("reason", [Revoked, Unrenewed], lease_loss_name),
        fn(lost) { lost.reason },
      )
      |> fields.build,
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
    fields.record({
      use owner <- fields.parameter
      use runs <- fields.parameter
      RenewalFailed(owner:, runs:)
    })
      |> fields.and(fields.string("owner"), fn(failed: RenewalFailed) {
        failed.owner
      })
      |> fields.and(fields.int("runs"), fn(failed) { failed.runs })
      |> fields.build,
  )
}

/// Its measurements are the tokens the provider reported for this attempt:
/// `None` when the attempt got no reply (`Retry`, `ModelFailure`, a budget
/// stop before a reply) or the reply did not report usage. A missing report
/// is never zero; the measurement map then omits `input_tokens` and
/// `output_tokens`.
pub fn model_turn() -> Event(Option(Usage), ModelTurn) {
  event(
    ["model", "stop"],
    tokens(),
    fields.record({
      use run <- fields.parameter
      use turn <- fields.parameter
      use result <- fields.parameter
      ModelTurn(run:, turn:, result:)
    })
      |> fields.and(fields.string("run"), fn(turn: ModelTurn) { turn.run })
      |> fields.and(fields.int("turn"), fn(turn) { turn.turn })
      |> fields.and(
        fields.enum(
          "result",
          [
            ToolRequest,
            FinalAnswer,
            Refusal,
            Truncated,
            Retry,
            ModelFailure,
            ProtocolViolation,
            BudgetStop,
          ],
          turn_result_name,
        ),
        fn(turn) { turn.result },
      )
      |> fields.build,
  )
}

pub fn approval_requested() -> Event(Nil, ApprovalRequested) {
  event(
    ["approval", "request"],
    fields.empty(),
    fields.record({
      use action <- fields.parameter
      use requirement <- fields.parameter
      use requirement_version <- fields.parameter
      use revision <- fields.parameter
      ApprovalRequested(action:, requirement:, requirement_version:, revision:)
    })
      |> fields.and(action_fields(), fn(requested: ApprovalRequested) {
        requested.action
      })
      |> fields.and(fields.string("requirement"), fn(requested) {
        requested.requirement
      })
      |> fields.and(fields.int("requirement_version"), fn(requested) {
        requested.requirement_version
      })
      |> fields.and(fields.int("revision"), fn(requested) { requested.revision })
      |> fields.build,
  )
}

pub fn approval_answered() -> Event(Nil, ApprovalAnswered) {
  event(
    ["approval", "answer"],
    fields.empty(),
    fields.record({
      use action <- fields.parameter
      use revision <- fields.parameter
      use answer <- fields.parameter
      ApprovalAnswered(action:, revision:, answer:)
    })
      |> fields.and(action_fields(), fn(answered: ApprovalAnswered) {
        answered.action
      })
      |> fields.and(fields.int("revision"), fn(answered) { answered.revision })
      |> fields.and(
        fields.enum("answer", [Approved, Rejected], answered_name),
        fn(answered) { answered.answer },
      )
      |> fields.build,
  )
}

pub fn tool_dispatched() -> Event(Nil, ToolDispatched) {
  event(
    ["tool", "start"],
    fields.empty(),
    fields.record({
      use action <- fields.parameter
      ToolDispatched(action:)
    })
      |> fields.and(action_fields(), fn(tool: ToolDispatched) { tool.action })
      |> fields.build,
  )
}

pub fn tool_settled() -> Event(Nil, ToolSettled) {
  event(
    ["tool", "stop"],
    fields.empty(),
    fields.record({
      use action <- fields.parameter
      use disposition <- fields.parameter
      ToolSettled(action:, disposition:)
    })
      |> fields.and(action_fields(), fn(settled: ToolSettled) { settled.action })
      |> fields.and(disposition("disposition"), fn(settled) {
        settled.disposition
      })
      |> fields.build,
  )
}

pub fn child_started() -> Event(Nil, ChildStarted) {
  event(
    ["child", "start"],
    fields.empty(),
    fields.record({
      use action <- fields.parameter
      use child <- fields.parameter
      ChildStarted(action:, child:)
    })
      |> fields.and(action_fields(), fn(started: ChildStarted) {
        started.action
      })
      |> fields.and(fields.string("child"), fn(started) { started.child })
      |> fields.build,
  )
}

pub fn child_settled() -> Event(Nil, ChildSettled) {
  event(
    ["child", "stop"],
    fields.empty(),
    fields.record({
      use action <- fields.parameter
      use child <- fields.parameter
      use disposition <- fields.parameter
      ChildSettled(action:, child:, disposition:)
    })
      |> fields.and(action_fields(), fn(settled: ChildSettled) {
        settled.action
      })
      |> fields.and(fields.string("child"), fn(settled) { settled.child })
      |> fields.and(disposition("disposition"), fn(settled) {
        settled.disposition
      })
      |> fields.build,
  )
}

pub fn settlement_refused() -> Event(Nil, SettlementRefused) {
  event(
    ["tool", "settlement", "refuse"],
    fields.empty(),
    fields.record({
      use action <- fields.parameter
      use offered <- fields.parameter
      use reason <- fields.parameter
      use summary <- fields.parameter
      SettlementRefused(action:, offered:, reason:, summary:)
    })
      |> fields.and(action_fields(), fn(refused: SettlementRefused) {
        refused.action
      })
      |> fields.and(disposition("disposition"), fn(refused) { refused.offered })
      |> fields.and(
        fields.enum(
          "reason",
          [AlreadyRecorded, NotAwaited, NotReached],
          refusal_name,
        ),
        fn(refused) { refused.reason },
      )
      |> fields.and(fields.string("summary"), fn(refused) { refused.summary })
      |> fields.build,
  )
}

pub fn run_cancelled() -> Event(Nil, RunCancelled) {
  event(
    ["run", "cancel"],
    fields.empty(),
    fields.record({
      use run <- fields.parameter
      RunCancelled(run:)
    })
      |> fields.and(fields.string("run"), fn(cancelled: RunCancelled) {
        cancelled.run
      })
      |> fields.build,
  )
}

pub fn run_finished() -> Event(RunTotals, RunFinished) {
  event(
    ["run", "stop"],
    fields.record({
      use turns <- fields.parameter
      use input_tokens <- fields.parameter
      use output_tokens <- fields.parameter
      use unreported_replies <- fields.parameter
      RunTotals(turns:, input_tokens:, output_tokens:, unreported_replies:)
    })
      |> fields.and(fields.int("turns"), fn(totals: RunTotals) { totals.turns })
      |> fields.and(fields.int("input_tokens"), fn(totals) {
        totals.input_tokens
      })
      |> fields.and(fields.int("output_tokens"), fn(totals) {
        totals.output_tokens
      })
      |> fields.and(fields.int("unreported_replies"), fn(totals) {
        totals.unreported_replies
      })
      |> fields.build,
    fields.record({
      use run <- fields.parameter
      use outcome <- fields.parameter
      RunFinished(run:, outcome:)
    })
      |> fields.and(fields.string("run"), fn(finished: RunFinished) {
        finished.run
      })
      |> fields.and(
        fields.enum(
          "outcome",
          [
            Completed,
            Refused,
            OutputLimited,
            BudgetExhausted,
            BudgetUnverifiable,
            Cancelled,
            Failed,
          ],
          outcome_name,
        ),
        fn(finished) { finished.outcome },
      )
      |> fields.build,
  )
}

// --- field helpers
// -------------------------------------------------------------

fn event(
  name: List(String),
  measurements: Fields(m),
  metadata: Fields(d),
) -> Event(m, d) {
  sinal.event(["fabric", ..name], measurements, metadata)
}

fn action_fields() -> Fields(ActionRef) {
  fields.record({
    use run <- fields.parameter
    use turn <- fields.parameter
    use call_id <- fields.parameter
    use tool <- fields.parameter
    ActionRef(run:, turn:, call_id:, tool:)
  })
  |> fields.and(fields.string("run"), fn(action: ActionRef) { action.run })
  |> fields.and(fields.int("turn"), fn(action) { action.turn })
  |> fields.and(fields.string("call_id"), fn(action) { action.call_id })
  |> fields.and(fields.string("tool"), fn(action) { action.tool })
  |> fields.build
}

/// Both keys present, or both absent for an unreported attempt. A map with
/// only one of them is a partial report and decodes as `None` too.
fn tokens() -> Fields(Option(Usage)) {
  fields.record({
    use input <- fields.parameter
    use output <- fields.parameter
    case input, output {
      Some(input), Some(output) -> Some(Usage(input, output))
      _, _ -> None
    }
  })
  |> fields.and(
    fields.optional(fields.int("input_tokens")),
    fn(tokens: Option(Usage)) {
      option.map(tokens, fn(usage) { usage.input_tokens })
    },
  )
  |> fields.and(fields.optional(fields.int("output_tokens")), fn(tokens) {
    option.map(tokens, fn(usage) { usage.output_tokens })
  })
  |> fields.build
}

fn disposition(key: String) -> Fields(Disposition) {
  fields.enum(
    key,
    [ModelVisible, EffectUncertain, HostFailure, Withdrawn],
    disposition_name,
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

/// One completed sweep: candidate rows claimed, candidates advanced to a
/// new incarnation or acknowledged after completion, unmatched root agent
/// identities, and failed candidates/roots (or one failed backend scan).
pub type Sweep {
  Sweep(claimed: Int, recovered: Int, unmatched: Int, failed: Int)
}

pub fn sweep() -> Event(Sweep, Nil) {
  event(
    ["sweep", "stop"],
    fields.record({
      use claimed <- fields.parameter
      use recovered <- fields.parameter
      use unmatched <- fields.parameter
      use failed <- fields.parameter
      Sweep(claimed:, recovered:, unmatched:, failed:)
    })
      |> fields.and(fields.int("claimed"), fn(sweep: Sweep) { sweep.claimed })
      |> fields.and(fields.int("recovered"), fn(sweep) { sweep.recovered })
      |> fields.and(fields.int("unmatched"), fn(sweep) { sweep.unmatched })
      |> fields.and(fields.int("failed"), fn(sweep) { sweep.failed })
      |> fields.build,
    fields.empty(),
  )
}

/// One factory's shutdown cohort. Exit counts partition runners; handoff
/// evidence is independent. A killed runner may already have handed off.
/// Pending or unobserved evidence makes the report incomplete. Elapsed time
/// is monotonic milliseconds since admission closed, not a per-run duration.
pub type Drain {
  Drain(
    runners: Int,
    handed_off: Int,
    failed_handoffs: Int,
    pending_handoffs: Int,
    killed: Int,
    exited: Int,
    unobserved: Int,
    elapsed_ms: Int,
  )
}

/// Emitted after the factory stops and before its store stops. Metadata is
/// the store's registered name. Killed means a forced exit, including but
/// not limited to the supervisor's deadline. Failed means unconfirmed, not
/// proof that a backend write had no effect. Reporting is bounded and best
/// effort, as for other events; it never owns recovery.
pub fn drain() -> Event(Drain, String) {
  event(
    ["drain", "stop"],
    fields.record({
      use runners <- fields.parameter
      use handed_off <- fields.parameter
      use failed_handoffs <- fields.parameter
      use pending_handoffs <- fields.parameter
      use killed <- fields.parameter
      use exited <- fields.parameter
      use unobserved <- fields.parameter
      use elapsed_ms <- fields.parameter
      Drain(
        runners:,
        handed_off:,
        failed_handoffs:,
        pending_handoffs:,
        killed:,
        exited:,
        unobserved:,
        elapsed_ms:,
      )
    })
      |> fields.and(fields.int("runners"), fn(drain: Drain) { drain.runners })
      |> fields.and(fields.int("handed_off"), fn(drain) { drain.handed_off })
      |> fields.and(fields.int("failed_handoffs"), fn(drain) {
        drain.failed_handoffs
      })
      |> fields.and(fields.int("pending_handoffs"), fn(drain) {
        drain.pending_handoffs
      })
      |> fields.and(fields.int("killed"), fn(drain) { drain.killed })
      |> fields.and(fields.int("exited"), fn(drain) { drain.exited })
      |> fields.and(fields.int("unobserved"), fn(drain) { drain.unobserved })
      |> fields.and(fields.int("elapsed_ms"), fn(drain) { drain.elapsed_ms })
      |> fields.build,
    fields.string("store"),
  )
}

/// Shutdown accounting could not be read. No zero-run success is inferred.
pub fn drain_unavailable() -> Event(Nil, String) {
  event(["drain", "unavailable"], fields.empty(), fields.string("store"))
}

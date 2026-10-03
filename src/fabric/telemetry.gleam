//// Fabric's Sinal events: what a run did, for logs, metrics, and traces.
////
//// Telemetry is diagnostic, never a source of truth: the run's record is.
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
//// Every event of a run (all but `renewal_failed`, `sweep`, `drain` and
//// `drain_unavailable`) carries the run's `correlation`, under the
//// `correlation` key that every gleam-dream package uses: the one given to
//// `fabric.start`, or one derived from the run id. It also carries `root`,
//// the id of the family's root run: the run itself for a root, its root's
//// for a sub-agent run, so a sub-agent's events join its root's. A
//// sub-agent run's events carry its root's correlation too. The same
//// correlation reaches the model's requests and the tools' calls, so their
//// own events join the run's. A graph run's `lease_lost` derives its
//// correlation from its run id and names the graph run as its root; graph
//// events are planned for wave 5.
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
import sinal/correlation.{type Correlation}
import sinal/fields.{type Fields}

/// An action of a run, in event metadata: its run, model turn, provider
/// call id, and tool or delegation name.
pub type Action {
  Action(run: String, turn: Int, call_id: String, tool: String)
}

pub type RunStarted {
  RunStarted(
    run: String,
    agent: String,
    agent_version: Int,
    parent: Option(String),
    root: String,
    correlation: Correlation,
  )
}

pub type RunRecovered {
  RunRecovered(
    run: String,
    incarnation: Int,
    root: String,
    correlation: Correlation,
  )
}

/// The incarnation whose runner handed the run off; `fabric.recover` goes
/// on with the next.
pub type RunHandedOff {
  RunHandedOff(
    run: String,
    incarnation: Int,
    root: String,
    correlation: Correlation,
  )
}

/// A recovery took over a run whose lease another owner held (expired, or
/// of an earlier process of the recovering store), as `incarnation`.
pub type RunTakenOver {
  RunTakenOver(
    run: String,
    incarnation: Int,
    previous_owner: String,
    root: String,
    correlation: Correlation,
  )
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
  LeaseLost(
    run: String,
    owner: String,
    reason: LeaseLoss,
    root: String,
    correlation: Correlation,
  )
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
  ModelTurn(
    run: String,
    turn: Int,
    result: TurnResult,
    root: String,
    correlation: Correlation,
  )
}

pub type Answered {
  Approved
  Rejected
  /// The request's deadline passed unanswered (`agent.with_approval_expiry`).
  Expired
}

pub type ApprovalRequested {
  ApprovalRequested(
    action: Action,
    requirement: String,
    requirement_version: Int,
    revision: Int,
    root: String,
    correlation: Correlation,
  )
}

pub type ApprovalAnswered {
  ApprovalAnswered(
    action: Action,
    revision: Int,
    answer: Answered,
    root: String,
    correlation: Correlation,
  )
}

pub type ToolDispatched {
  ToolDispatched(action: Action, root: String, correlation: Correlation)
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
  ToolSettled(
    action: Action,
    disposition: Disposition,
    root: String,
    correlation: Correlation,
  )
}

pub type ChildStarted {
  ChildStarted(
    action: Action,
    child: String,
    root: String,
    correlation: Correlation,
  )
}

pub type ChildSettled {
  ChildSettled(
    action: Action,
    child: String,
    disposition: Disposition,
    root: String,
    correlation: Correlation,
  )
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
    action: Action,
    /// What the settlement offered.
    offered: Disposition,
    reason: SettlementRefusal,
    /// What a person needs to reconcile the action, as the tool gave it to
    /// `tool.settle`.
    summary: String,
    root: String,
    correlation: Correlation,
  )
}

pub type RunCancelled {
  RunCancelled(run: String, root: String, correlation: Correlation)
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
  RunFinished(
    run: String,
    outcome: OutcomeKind,
    root: String,
    correlation: Correlation,
  )
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
  event(["run", "start"], fields.empty(), {
    use run <- fields.include(fields.string("run"), get: fn(started) {
      started.run
    })
    use agent <- fields.include(fields.string("agent"), get: fn(started) {
      started.agent
    })
    use agent_version <- fields.include(
      fields.int("agent_version"),
      get: fn(started) { started.agent_version },
    )
    use parent <- fields.include(
      fields.optional(fields.string("parent")),
      get: fn(started) { started.parent },
    )
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(RunStarted(
      run:,
      agent:,
      agent_version:,
      parent:,
      root:,
      correlation:,
    ))
  })
}

pub fn run_recovered() -> Event(Nil, RunRecovered) {
  event(["run", "recover"], fields.empty(), {
    use run <- fields.include(fields.string("run"), get: fn(recovered) {
      recovered.run
    })
    use incarnation <- fields.include(
      fields.int("incarnation"),
      get: fn(recovered) { recovered.incarnation },
    )
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(RunRecovered(run:, incarnation:, root:, correlation:))
  })
}

pub fn run_handed_off() -> Event(Nil, RunHandedOff) {
  event(["run", "hand_off"], fields.empty(), {
    use run <- fields.include(fields.string("run"), get: fn(handed) {
      handed.run
    })
    use incarnation <- fields.include(
      fields.int("incarnation"),
      get: fn(handed) { handed.incarnation },
    )
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(RunHandedOff(run:, incarnation:, root:, correlation:))
  })
}

pub fn run_taken_over() -> Event(Nil, RunTakenOver) {
  event(["run", "take_over"], fields.empty(), {
    use run <- fields.include(fields.string("run"), get: fn(taken) { taken.run })
    use incarnation <- fields.include(fields.int("incarnation"), get: fn(taken) {
      taken.incarnation
    })
    use previous_owner <- fields.include(
      fields.string("previous_owner"),
      get: fn(taken) { taken.previous_owner },
    )
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(RunTakenOver(
      run:,
      incarnation:,
      previous_owner:,
      root:,
      correlation:,
    ))
  })
}

pub fn lease_lost() -> Event(Nil, LeaseLost) {
  event(["lease", "lose"], fields.empty(), {
    use run <- fields.include(fields.string("run"), get: fn(lost) { lost.run })
    use owner <- fields.include(fields.string("owner"), get: fn(lost) {
      lost.owner
    })
    use reason <- fields.include(
      fields.enum("reason", [Revoked, Unrenewed], lease_loss_name),
      get: fn(lost) { lost.reason },
    )
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(LeaseLost(run:, owner:, reason:, root:, correlation:))
  })
}

fn lease_loss_name(reason: LeaseLoss) -> String {
  case reason {
    Revoked -> "revoked"
    Unrenewed -> "unrenewed"
  }
}

pub fn renewal_failed() -> Event(Nil, RenewalFailed) {
  event(["lease", "renew", "fail"], fields.empty(), {
    use owner <- fields.include(fields.string("owner"), get: fn(failed) {
      failed.owner
    })
    use runs <- fields.include(fields.int("runs"), get: fn(failed) {
      failed.runs
    })
    fields.success(RenewalFailed(owner:, runs:))
  })
}

/// Its measurements are the tokens the provider reported for this attempt:
/// `None` when the attempt got no reply (`Retry`, `ModelFailure`, a budget
/// stop before a reply) or the reply did not report usage. A missing report
/// is never zero; the measurement map then omits `input_tokens` and
/// `output_tokens`.
pub fn model_turn() -> Event(Option(Usage), ModelTurn) {
  event(["model", "stop"], tokens(), {
    use run <- fields.include(fields.string("run"), get: fn(turn) { turn.run })
    use turn <- fields.include(fields.int("turn"), get: fn(turn) { turn.turn })
    use result <- fields.include(
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
      get: fn(turn) { turn.result },
    )
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(ModelTurn(run:, turn:, result:, root:, correlation:))
  })
}

pub fn approval_requested() -> Event(Nil, ApprovalRequested) {
  event(["approval", "request"], fields.empty(), {
    use action <- fields.include(action_fields(), get: fn(requested) {
      requested.action
    })
    use requirement <- fields.include(
      fields.string("requirement"),
      get: fn(requested) { requested.requirement },
    )
    use requirement_version <- fields.include(
      fields.int("requirement_version"),
      get: fn(requested) { requested.requirement_version },
    )
    use revision <- fields.include(fields.int("revision"), get: fn(requested) {
      requested.revision
    })
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(ApprovalRequested(
      action:,
      requirement:,
      requirement_version:,
      revision:,
      root:,
      correlation:,
    ))
  })
}

pub fn approval_answered() -> Event(Nil, ApprovalAnswered) {
  event(["approval", "answer"], fields.empty(), {
    use action <- fields.include(action_fields(), get: fn(answered) {
      answered.action
    })
    use revision <- fields.include(fields.int("revision"), get: fn(answered) {
      answered.revision
    })
    use answer <- fields.include(
      fields.enum("answer", [Approved, Rejected, Expired], answered_name),
      get: fn(answered) { answered.answer },
    )
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(ApprovalAnswered(
      action:,
      revision:,
      answer:,
      root:,
      correlation:,
    ))
  })
}

pub fn tool_dispatched() -> Event(Nil, ToolDispatched) {
  event(["tool", "start"], fields.empty(), {
    use action <- fields.include(action_fields(), get: fn(tool) { tool.action })
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(ToolDispatched(action:, root:, correlation:))
  })
}

pub fn tool_settled() -> Event(Nil, ToolSettled) {
  event(["tool", "stop"], fields.empty(), {
    use action <- fields.include(action_fields(), get: fn(settled) {
      settled.action
    })
    use disposition <- fields.include(
      disposition("disposition"),
      get: fn(settled) { settled.disposition },
    )
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(ToolSettled(action:, disposition:, root:, correlation:))
  })
}

pub fn child_started() -> Event(Nil, ChildStarted) {
  event(["child", "start"], fields.empty(), {
    use action <- fields.include(action_fields(), get: fn(started) {
      started.action
    })
    use child <- fields.include(fields.string("child"), get: fn(started) {
      started.child
    })
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(ChildStarted(action:, child:, root:, correlation:))
  })
}

pub fn child_settled() -> Event(Nil, ChildSettled) {
  event(["child", "stop"], fields.empty(), {
    use action <- fields.include(action_fields(), get: fn(settled) {
      settled.action
    })
    use child <- fields.include(fields.string("child"), get: fn(settled) {
      settled.child
    })
    use disposition <- fields.include(
      disposition("disposition"),
      get: fn(settled) { settled.disposition },
    )
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(ChildSettled(
      action:,
      child:,
      disposition:,
      root:,
      correlation:,
    ))
  })
}

pub fn settlement_refused() -> Event(Nil, SettlementRefused) {
  event(["tool", "settlement", "refuse"], fields.empty(), {
    use action <- fields.include(action_fields(), get: fn(refused) {
      refused.action
    })
    use offered <- fields.include(disposition("disposition"), get: fn(refused) {
      refused.offered
    })
    use reason <- fields.include(
      fields.enum(
        "reason",
        [AlreadyRecorded, NotAwaited, NotReached],
        refusal_name,
      ),
      get: fn(refused) { refused.reason },
    )
    use summary <- fields.include(fields.string("summary"), get: fn(refused) {
      refused.summary
    })
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(SettlementRefused(
      action:,
      offered:,
      reason:,
      summary:,
      root:,
      correlation:,
    ))
  })
}

pub fn run_cancelled() -> Event(Nil, RunCancelled) {
  event(["run", "cancel"], fields.empty(), {
    use run <- fields.include(fields.string("run"), get: fn(cancelled) {
      cancelled.run
    })
    use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    fields.success(RunCancelled(run:, root:, correlation:))
  })
}

pub fn run_finished() -> Event(RunTotals, RunFinished) {
  event(
    ["run", "stop"],
    {
      use turns <- fields.include(fields.int("turns"), get: fn(totals) {
        totals.turns
      })
      use input_tokens <- fields.include(
        fields.int("input_tokens"),
        get: fn(totals) { totals.input_tokens },
      )
      use output_tokens <- fields.include(
        fields.int("output_tokens"),
        get: fn(totals) { totals.output_tokens },
      )
      use unreported_replies <- fields.include(
        fields.int("unreported_replies"),
        get: fn(totals) { totals.unreported_replies },
      )
      fields.success(RunTotals(
        turns:,
        input_tokens:,
        output_tokens:,
        unreported_replies:,
      ))
    },
    {
      use run <- fields.include(fields.string("run"), get: fn(finished) {
        finished.run
      })
      use outcome <- fields.include(
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
        get: fn(finished) { finished.outcome },
      )
      use root <- fields.include(fields.string("root"), get: fn(m) { m.root })
      use correlation <- fields.include(
        correlation.required_field(),
        get: fn(m) { m.correlation },
      )
      fields.success(RunFinished(run:, outcome:, root:, correlation:))
    },
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

fn action_fields() -> Fields(Action) {
  use run <- fields.include(fields.string("run"), get: fn(action) { action.run })
  use turn <- fields.include(fields.int("turn"), get: fn(action) { action.turn })
  use call_id <- fields.include(fields.string("call_id"), get: fn(action) {
    action.call_id
  })
  use tool <- fields.include(fields.string("tool"), get: fn(action) {
    action.tool
  })
  fields.success(Action(run:, turn:, call_id:, tool:))
}

/// Both keys present, or both absent for an unreported attempt. A map with
/// only one of them is a partial report and decodes as `None` too.
fn tokens() -> Fields(Option(Usage)) {
  use input <- fields.include(
    fields.optional(fields.int("input_tokens")),
    get: fn(tokens) { option.map(tokens, fn(usage) { usage.input_tokens }) },
  )
  use output <- fields.include(
    fields.optional(fields.int("output_tokens")),
    get: fn(tokens) { option.map(tokens, fn(usage) { usage.output_tokens }) },
  )
  fields.success(case input, output {
    Some(input), Some(output) -> Some(Usage(input, output))
    _, _ -> None
  })
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
    Expired -> "expired"
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
    {
      use claimed <- fields.include(fields.int("claimed"), get: fn(sweep) {
        sweep.claimed
      })
      use recovered <- fields.include(fields.int("recovered"), get: fn(sweep) {
        sweep.recovered
      })
      use unmatched <- fields.include(fields.int("unmatched"), get: fn(sweep) {
        sweep.unmatched
      })
      use failed <- fields.include(fields.int("failed"), get: fn(sweep) {
        sweep.failed
      })
      fields.success(Sweep(claimed:, recovered:, unmatched:, failed:))
    },
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
    {
      use runners <- fields.include(fields.int("runners"), get: fn(drain) {
        drain.runners
      })
      use handed_off <- fields.include(fields.int("handed_off"), get: fn(drain) {
        drain.handed_off
      })
      use failed_handoffs <- fields.include(
        fields.int("failed_handoffs"),
        get: fn(drain) { drain.failed_handoffs },
      )
      use pending_handoffs <- fields.include(
        fields.int("pending_handoffs"),
        get: fn(drain) { drain.pending_handoffs },
      )
      use killed <- fields.include(fields.int("killed"), get: fn(drain) {
        drain.killed
      })
      use exited <- fields.include(fields.int("exited"), get: fn(drain) {
        drain.exited
      })
      use unobserved <- fields.include(fields.int("unobserved"), get: fn(drain) {
        drain.unobserved
      })
      use elapsed_ms <- fields.include(fields.int("elapsed_ms"), get: fn(drain) {
        drain.elapsed_ms
      })
      fields.success(Drain(
        runners:,
        handed_off:,
        failed_handoffs:,
        pending_handoffs:,
        killed:,
        exited:,
        unobserved:,
        elapsed_ms:,
      ))
    },
    fields.string("store"),
  )
}

/// Shutdown accounting could not be read. No zero-run success is inferred.
pub fn drain_unavailable() -> Event(Nil, String) {
  event(["drain", "unavailable"], fields.empty(), fields.string("store"))
}

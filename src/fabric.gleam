//// Fabric runs bounded, typed LLM agents whose runs can pause durably,
//// wait for a human, survive a restart, and be cancelled at any point.
////
//// ```gleam
//// let runs = store.in_memory(process.new_name("runs"))  // or store.directory
//// let assert Ok(Nil) = store.start(runs)   // or store.supervised(runs)
//// let assert Ok(agent) =
////   agent.new("desk", model, [weather_tool, transfer_tool], my_policy)
////   |> agent.with_approvers(desk_approvers)
////   |> agent.build
//// let assert Ok(handle) =
////   fabric.start(runs, agent, id: run.new_id(), context:, prompt: "Pay Bob",
////     correlation: None)
//// case fabric.await(handle, within: duration.seconds(5)) {
////   Ok(run.Suspended([pending, ..], _)) -> {
////     // `desk_approvers` verify the reviewer's token (`fabric/approvers`)
////     let assert Ok(proof) =
////       approvers.check(desk_approvers, token, pending.reference.requirement)
////     fabric.approve(handle, pending.reference, proof:,
////       context: current_context)
////   }
////   ...
//// }
//// ```
////
//// A run ends with the agent's answer: its model's text, or the value its
//// answer codec decodes (`agent.with_answer`), so `Run`, `run.Status` and
//// `run.Snapshot` carry the answer type. `await` and every command return
//// the run's status.
////
//// Every function returns the one `Error` type. Branch on `error_kind`
//// (`NotFound`, `Refused`, `Retry`, `Unavailable`, `Incompatible`) and log
//// with `describe_error`; match a variant only where it decides something,
//// such as `AlreadyStarted`.
////
//// A run's record lives in a store, and a run is named by its `run.RunId`,
//// which the caller chooses: `run.new_id()`, or `run.parse_id` of an
//// application key (a job id) so that a retried start finds the run it
//// started (`AlreadyStarted`). A string from outside becomes an id only
//// through `run.parse_id`. A runner
//// process exists only while a model call or a tool is in flight; a
//// suspended or finished run has no process.
//// Commands (`approve`, `reject`, `cancel`, `reconcile`) go to the live
//// runner, or are applied to the stored record when there is none, and a
//// runner is started if the command produced work.
////
//// Any process can hold a handle. `open` rebuilds one from a run id
//// without taking anything over: the handle a request handler uses.
//// `recover` takes over work whose runner is gone: on an unleased store,
//// use it at boot, never on a run another process may still be driving; on
//// a leased store (`store.leased`, several nodes sharing one database) it
//// leaves a live foreign lease alone. It can also recover this store's
//// own run whose runner is gone, so it is safe at any time. Runners run
//// under their store's subtree (`store.supervised`). When the application
//// stops, each drains and hands its run off, and
//// `recover` goes on with it after the restart with nothing uncertain.
////
//// A delegation (`agent.with_sub_agent`) starts a sub-agent run in the same
//// store, behind the same policy gate as a tool. The family is read together:
//// a child's pending approvals and uncertain effects are the parent's (their
//// references name the child run), `approve`, `reject` and `reconcile` route
//// by the reference, `child` opens a child's handle, cancelling a parent
//// cancels its children, and recovering a parent recovers its children.
////
//// A run's context is a live value, never stored: the one given to
//// `start`, `open` or `recover`, held by the handle and its runner. An approved action is
//// the exception: it runs with the context its answer was checked with
//// (see `approve`).
////
//// After a restart, `recover` reopens a stored run under the same agent. If
//// work was in flight when its runner was lost, recovery takes it over as a
//// new incarnation: tools that had started become uncertain effects, which
//// are never retried and must be reconciled; queued tools and a lost model
//// call are started again, except approved ones, which ask for their
//// approval again. "Never retried" holds as long as the store keeps
//// every commit it acknowledged: the directory store does not flush the
//// directory entry, so after an operating-system crash or power loss (not
//// a process or VM crash) the latest revisions may be missing, and a tool
//// whose start was among them could run again. The directory store is for
//// development, tests, and one host; production uses a database backend
//// (`store.new`).

import fabric/agent.{type Agent}
import fabric/approvers.{type Proof, type ProofError}
import fabric/internal/answer as answers
import fabric/internal/answerer
import fabric/internal/budget/model as reservations
import fabric/internal/checked_agent
import fabric/internal/clock
import fabric/internal/controller.{type State}
import fabric/internal/family
import fabric/internal/run_id
import fabric/internal/runner
import fabric/internal/settlement
import fabric/internal/store as store_core
import fabric/reviewer
import fabric/run.{
  type ActionRef, type Answer, type ApprovalRef, type Incompatibility,
  type PendingApproval, type RunId, type Snapshot, type Status, id_to_string,
}
import fabric/store.{type Store}
import fabric/store/backend
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import sinal/correlation.{type Correlation}

/// A handle on one run, for the agent and context it was started, opened
/// or recovered with; `answer` is the agent's answer type
/// (`agent.with_answer`). It holds no process: it can be dropped and
/// rebuilt with `open`.
pub opaque type Run(context, answer) {
  Run(id: String, setup: runner.Setup(context), answer: answers.Answer(answer))
}

/// Why a call to Fabric failed: one type for every function of this module.
/// Branch on `error_kind` and log with `describe_error`; this union may
/// grow, so match a variant only where it decides something (keep a
/// catch-all).
pub type Error {
  /// A run with this id is already stored: this start stored nothing. A
  /// start retried with the same id (by a job delivered again, say) gets
  /// this once the first start landed; `open` the run to read or command
  /// it, or `recover` it to take over its work. `same_input` says whether
  /// the stored run was started by the same agent with the same prompt and
  /// correlation, so that a retry can tell its own run from another start's
  /// that reused the id. A run's context is never stored, so it is not
  /// compared. When the id is taken but the stored run cannot be read, the
  /// start returns the read's error instead: `StoreUnavailable` (start again
  /// to compare), or `UnsupportedVersion` or `CorruptRecord` (the id holds a
  /// record this Fabric cannot read).
  AlreadyStarted(id: RunId, same_input: Bool)
  /// The store did not confirm the run's first record, so its outcome is
  /// unknown: the backend may still store it later, as the run `id` with
  /// work in flight and no runner (`await` then reports `Unattended`).
  /// Starting again with the same id is safe: it is `AlreadyStarted` if the
  /// first start landed. `cancel_stored(store, id)` ends such a run instead.
  StartUnconfirmed(id: RunId, reason: String)
  /// The agent declares a family budget (`agent.with_family_budget`) and
  /// the store writes agent records older than version 7, which cannot hold
  /// one. Nothing was stored.
  FamilyBudgetUnsupported
  RunNotFound
  /// The store failed. A write it reported unavailable has an unknown
  /// outcome: the backend may still perform it later.
  StoreUnavailable(reason: String)
  /// The record was written by a Fabric version this one cannot read.
  UnsupportedVersion(found: Int)
  CorruptRecord(detail: String)
  /// The run cannot continue under this agent.
  IncompatibleAgent(List(Incompatibility))
  /// The run has finished (completed, failed, or cancelled); execution
  /// cannot continue. Terminal evidence can still be settled through
  /// `reconcile_stored` and `settle_stored`. A pending approval is void. Also
  /// returned for a sub-agent run one of whose ancestors is stopping or has
  /// ended: cancelling an ancestor wins over answering or reconciling its
  /// descendants.
  RunEnded
  /// Terminal evidence commands require a finished run. Cancel or finish
  /// it first; these commands never stop or resume execution themselves.
  RunNotFinished
  /// No approval request or eligible action of this run matches the
  /// reference (the current batch, or history for terminal settlement).
  WrongReference
  /// The action's approval request has another revision or requirement.
  StaleReference
  /// This approval request was already answered.
  AlreadyAnswered
  /// The approval request's deadline passed before this answer
  /// (`agent.with_approval_expiry`): it expired, its action was rejected,
  /// and the model sees that. The run goes on without the action.
  ApprovalExpired
  /// The current policy now requires another approval for the action; the
  /// answer was not applied. Answer the new request, with a proof checked
  /// for its requirement.
  RequirementChanged(PendingApproval)
  /// The answer's proof is not one this run's approvers accept for the
  /// request: the agent has none, they did not make it, it was checked for
  /// another requirement, or it is too old (see `fabric/approvers`).
  /// Nothing was changed.
  ProofRefused(ProofError)
  /// The action is not an uncertain effect, or the run is in a phase that
  /// accepts no reconciliation (for example while the model is called).
  NotReconcilable
  /// The command is valid for the stored record, but work is in flight
  /// and no runner known to this store drives it: its runner was lost, or
  /// the run is driven through another `Store` (possibly in another VM).
  /// Nothing was changed. `cancel` never needs a runner.
  RunUnattended
  /// The run's runner did not take the command within the agent's command
  /// timeout (`agent.with_command_timeout`): a synchronous telemetry
  /// handler holds it, or the command was sent from such a handler running
  /// in the run's own runner. Nothing was changed, and the command will not
  /// be applied later. Try again, or route Fabric's events through a
  /// forwarder (see `fabric/telemetry`). `cancel` and `cancel_stored`
  /// never return it: they commit the cancellation to the record instead.
  RunnerBusy
  /// The command lost every retry against concurrent commits.
  Contended
}

/// A stable classification of `Error`, for callers that decide by kind.
pub type ErrorKind {
  /// The run or the action the reference names does not exist:
  /// `RunNotFound`, `WrongReference`.
  NotFound
  /// The run's state refuses the request; trying it again unchanged does
  /// not help: `AlreadyStarted`, `RunEnded`, `RunNotFinished`,
  /// `StaleReference`, `AlreadyAnswered`, `ApprovalExpired`,
  /// `RequirementChanged`, `ProofRefused`, `NotReconcilable`.
  Refused
  /// A transient conflict: the same call may succeed soon (`RunnerBusy`,
  /// `Contended`).
  Retry
  /// The store or the run's runner cannot be reached, and a write's
  /// outcome may be unknown: `StartUnconfirmed`, `StoreUnavailable`,
  /// `RunUnattended`.
  Unavailable
  /// The record and this Fabric, agent or store do not fit:
  /// `UnsupportedVersion`, `CorruptRecord`, `IncompatibleAgent`,
  /// `FamilyBudgetUnsupported`.
  Incompatible
}

pub fn error_kind(error: Error) -> ErrorKind {
  case error {
    RunNotFound | WrongReference -> NotFound
    AlreadyStarted(..)
    | RunEnded
    | RunNotFinished
    | StaleReference
    | AlreadyAnswered
    | ApprovalExpired
    | RequirementChanged(_)
    | ProofRefused(_)
    | NotReconcilable -> Refused
    RunnerBusy | Contended -> Retry
    StartUnconfirmed(..) | StoreUnavailable(_) | RunUnattended -> Unavailable
    UnsupportedVersion(_)
    | CorruptRecord(_)
    | IncompatibleAgent(_)
    | FamilyBudgetUnsupported -> Incompatible
  }
}

/// One line for logs.
pub fn describe_error(error: Error) -> String {
  case error {
    AlreadyStarted(id, same_input) ->
      "the run "
      <> id_to_string(id)
      <> " is already started"
      <> case same_input {
        True -> " with the same input"
        False -> " with other input"
      }
    StartUnconfirmed(id, reason) ->
      "the start of the run "
      <> id_to_string(id)
      <> " was not confirmed: "
      <> reason
    FamilyBudgetUnsupported ->
      "a family budget needs a store that writes agent records of version 7 or later"
    RunNotFound -> "the run does not exist"
    StoreUnavailable(reason) -> "the store is unavailable: " <> reason
    UnsupportedVersion(found) ->
      "the record has version "
      <> int.to_string(found)
      <> ", which this Fabric cannot read"
    CorruptRecord(detail) -> "the record is corrupt: " <> detail
    IncompatibleAgent(problems) ->
      "the run cannot continue under this agent ("
      <> int.to_string(list.length(problems))
      <> " incompatibilities)"
    RunEnded -> "the run has ended"
    RunNotFinished -> "the run has not finished"
    WrongReference -> "no action of the run matches the reference"
    StaleReference -> "the approval request has been superseded"
    AlreadyAnswered -> "the approval request was already answered"
    ApprovalExpired -> "the approval request expired before this answer"
    RequirementChanged(_) -> "the policy now requires another approval"
    ProofRefused(error) ->
      "the answer's proof is refused: " <> approvers.describe_proof_error(error)
    NotReconcilable -> "the action is not an uncertain effect to reconcile"
    RunUnattended -> "work is in flight and no runner drives the run"
    RunnerBusy -> "the run's runner did not take the command in time"
    Contended -> "the command lost every retry against concurrent commits"
  }
}

const retries = 3

/// Starts a run of `agent` in `store` under `id`: stores its first record
/// and hands the first model call to a new runner. `id` is the caller's:
/// `run.new_id()` for a fresh run, or an id derived from the work that
/// starts it (`run.id_from_parts("job", [job_id])`), so that starting again
/// finds the run (`AlreadyStarted`) instead of starting a second one. A
/// retry that must start afresh rather than continue (a job's next attempt
/// after a business failure) includes its attempt among the parts. An agent
/// with a family budget (`agent.with_family_budget`) declares it for this
/// root run.
///
/// `correlation` is carried in every event of the run, its sub-agent runs
/// included, in every `model.Request` (which `fabric/llm` puts on its HTTP
/// requests) and in every tool's `tool.Call`; it is stored with the run, so
/// a recovered run keeps it. `None` derives it from the id
/// (`correlation.from_key(run.id_to_string(id))`); pass the correlation of
/// the request or job that starts the run to join their events.
pub fn start(
  store: Store,
  agent: Agent(context, answer),
  id id: RunId,
  context context: context,
  prompt prompt: String,
  correlation correlation: Option(Correlation),
) -> Result(Run(context, answer), Error) {
  let admitted = checked_agent.admitted(agent)
  use declaration <- result.try(case admitted.family_budget {
    None -> Ok(None)
    Some(limits) ->
      case store_core.supports_family_budget(store) {
        True -> Ok(Some(reservations.Declaration(limits, False)))
        False -> Error(FamilyBudgetUnsupported)
      }
  })
  let setup = runner.setup(store, admitted, context, None)
  let text = id_to_string(id)
  let correlation =
    option.lazy_unwrap(correlation, fn() { correlation.from_key(text) })
  let #(state, effects) = runner.root_state(setup, text, prompt, correlation)
  let state = controller.State(..state, family_budget: declaration)
  case runner.launch_new(setup, state, effects) {
    Ok(_) -> Ok(Run(id: text, setup:, answer: checked_agent.answer(agent)))
    Error(backend.AlreadyExists) ->
      same_input(store, state)
      |> result.map_error(record_error)
      |> result.try(fn(same) { Error(AlreadyStarted(id, same)) })
    Error(error) -> Error(StartUnconfirmed(id, describe_store(error)))
  }
}

/// Whether the stored run `fresh.run` is a root started by the same agent
/// with the same prompt and correlation as `fresh`, the state a start
/// wanted to store; the read's error when the stored run cannot be read.
fn same_input(store: Store, fresh: State) -> Result(Bool, runner.ReadError) {
  use #(_, stored) <- result.map(runner.load(store, fresh.run))
  stored.parent == None
  && stored.agent == fresh.agent
  && stored.correlation == fresh.correlation
  && list.first(stored.transcript) == list.first(fresh.transcript)
}

/// Opens the stored run `id` under `agent` and `context`. When work was in
/// flight and no runner in this store drives it, recovery takes the work
/// over as a new incarnation (committed with compare-and-set, so concurrent
/// recoveries have one winner): running tools become uncertain effects
/// (replayable ones, `tool.with_replay`, are started again while they have
/// attempts left), queued tools are dispatched again, and a lost model call
/// is issued again against the turn budget. A suspended or finished run is
/// opened unchanged, except that an approval request whose deadline passed
/// is rejected (the model sees it, and the run goes on). Calling it again
/// is harmless.
///
/// An approved tool or sub-agent start that had not started is not run
/// with `context`: the context its answer was checked with is gone, and a
/// stored approval alone does not authorize a later incarnation. It asks
/// for its approval again, as a new request under the requirement last
/// answered (the old reference is then stale).
///
/// Sub-agent runs are recovered with their parent: a child that was never
/// stored is started, a child whose end the parent missed is applied to
/// it, an active child is recovered in turn, and a child that cannot be
/// read or continued becomes an uncertain effect of the delegation.
///
/// A run handed off by a drained shutdown (`store.supervised`) has nothing
/// running: its results are committed, a model call it never issued is
/// issued as the same turn, and its queued tools are dispatched, except
/// approved ones, which ask for their approval again (the handoff already
/// asked).
///
/// On a leased store (`store.leased`) it is safe to call at any time: a run
/// whose lease another node holds live is left exactly as it is (the
/// handle is returned, and the run reads `Working`), and only a free or
/// expired lease, one of an earlier process of this store, or this store's
/// own lease whose runner is gone is taken over. This node reads that last
/// case as `Unattended`; another node reads it as `Working` until expiry.
/// Of several nodes recovering one run at once, exactly one takes it over.
/// A live foreign parent keeps its runner; eligible children can recover
/// independently, and that parent reads their committed outcomes.
///
/// An unleased store knows only the runners it started. Recovering
/// through another unleased `Store` (for example in another VM) while the
/// run's runner is still alive takes the run over: the older runner can no
/// longer commit and stops, and its running tools become uncertain
/// effects. On an unleased store, recover only when the previous owner is
/// known to be gone (for example at boot); to read or command a run someone
/// else may be driving, `open` it.
pub fn recover(
  store: Store,
  agent: Agent(context, answer),
  context: context,
  id: RunId,
) -> Result(Run(context, answer), Error) {
  let id = id_to_string(id)
  let setup = runner.setup(store, checked_agent.admitted(agent), context, None)
  case family.take_over(setup, id, retries) {
    Ok(Nil) -> Ok(Run(id:, setup:, answer: checked_agent.answer(agent)))
    Error(family.TakeOverContended) -> Error(Contended)
    Error(family.TakeOverUnreadable(problem)) -> Error(record_error(problem))
  }
}

/// Opens the stored run `id` under `agent` and `context`, for a caller
/// that did not start it: a request handler reading, awaiting, answering,
/// reconciling or cancelling a run. It only reads the record and checks
/// that the run can continue under `agent` (`IncompatibleAgent`
/// otherwise); it never takes the run over and starts nothing, so a live
/// runner, in this store or behind another `Store`, keeps its work.
///
/// Commands through the handle behave exactly as through the handle
/// `start` returned: each is checked against the stored record, one that
/// produces work with no runner live in this store starts a runner, and
/// one that needs the live runner of another `Store` is `RunUnattended`.
/// A sub-agent run is reached through its root's handle (`child`).
///
/// `recover` takes over work in flight. Leased stores permit it at any
/// time; on an unleased store the previous owner must be known to be gone.
pub fn open(
  store: Store,
  agent: Agent(context, answer),
  context: context,
  id: RunId,
) -> Result(Run(context, answer), Error) {
  let id = id_to_string(id)
  let setup = runner.setup(store, checked_agent.admitted(agent), context, None)
  runner.load_checked(setup, id)
  |> result.replace(Run(id:, setup:, answer: checked_agent.answer(agent)))
  |> result.map_error(record_error)
}

pub fn id(run: Run(context, answer)) -> RunId {
  run_id.from_string(run.id)
}

/// Opens the sub-agent run `id`, a descendant of `run`, with `run`'s agent
/// and context: its snapshot, reconciling its uncertain effects, answering
/// or cancelling it. Its end still reaches its parent. Its answer reads as
/// the text it stored (its delegation reads it with the child's own answer
/// codec).
pub fn child(
  run: Run(context, answer),
  id: RunId,
) -> Result(Run(context, String), Error) {
  let id = id_to_string(id)
  family.locate(run.setup, run.id, id)
  |> result.map(fn(setup) { Run(id:, setup:, answer: answers.text()) })
  |> result.map_error(record_error)
}

/// Blocks until the run is no longer `Working`, or until `within` passes,
/// and returns its status: `Working` when the time ran
/// out, `Suspended` or `Finished`, or `Unattended` when work is in flight
/// but no runner known to this store drives it. On an unleased store,
/// `Unattended` means the runner was lost or handed the run off at
/// shutdown, or the run is driven through another `Store`; only the
/// application knows which, and `recover` takes the run over, so call it
/// only when the previous owner is known to be gone. On a leased store a
/// run whose lease is live elsewhere is `Working`. `Unattended` means its
/// lease is free or expired, belongs to an earlier process of this store,
/// or belongs to this store with no runner: `recover` takes it over.
///
/// It wakes on commits made through this run's store and when a runner
/// exits; on a leased store it also reads the run again at least every
/// third of the lease (at most every second), since another node's commits
/// wake nothing here.
/// If the store's process stops meanwhile, it waits, until `within` runs
/// out, for a supervisor to register the next one, and goes on through it;
/// that process knows no runner, so work in flight then reads `Unattended`.
/// With no store process running when it starts, or none registered again
/// in time, it is `StoreUnavailable`. A run whose
/// sub-agents work is working; one waiting only on paused sub-agents is
/// suspended on their approvals. A suspended run with an approval request
/// whose deadline passed is not returned as is: the request is rejected
/// first, and the wait goes on with the run. A `within` of zero (or less)
/// reads the
/// status now; one longer than the runtime's longest timer (2^32 - 1 ms) is
/// waited in parts.
///
/// To wait for the run or for something else at once (a caller's
/// cancellation, a shutdown message), use `await_with`.
pub fn await(
  run: Run(context, answer),
  within within: Duration,
) -> Result(Status(answer), Error) {
  case await_with(run, within:, or: process.new_selector()) {
    Ok(Reached(status)) -> Ok(status)
    // An empty selector receives nothing: this branch never runs.
    Ok(Interrupted(never)) -> never
    Error(error) -> Error(error)
  }
}

/// What `await_with` ended with.
pub type Awaited(answer, message) {
  /// The run's status, as `await` returns it.
  Reached(Status(answer))
  /// A message of the caller's selector arrived first. The wait changed
  /// nothing: the run goes on, and the caller decides (for example
  /// `cancel`).
  Interrupted(message)
}

/// `await`, ending early when `or` receives a message: one receive waits for
/// the run and for the caller's own messages, so a handler needs no helper
/// process. The message is returned as `Interrupted(message)` and is
/// consumed; the run is left as it is. A request handler that must stop
/// the run when its caller goes away selects on that signal:
///
/// ```gleam
/// let cancelled = relay_tool.cancelled(call)   // a process.Selector(Nil)
/// case fabric.await_with(handle, within: duration.seconds(30), or: cancelled) {
///   Ok(fabric.Interrupted(Nil)) -> {
///     let _ = fabric.cancel(handle)
///     Error(Cancelled)
///   }
///   Ok(fabric.Reached(run.Finished(outcome))) -> Ok(outcome)
///   Ok(fabric.Reached(_)) -> Error(NotFinished)
///   Error(error) -> Error(Unreadable(error))
/// }
/// ```
///
/// The selector is checked whenever the wait blocks, and a message already
/// queued for it wins over a status read in the same moment only if it
/// arrived first.
pub fn await_with(
  run: Run(context, answer),
  within within: Duration,
  or interrupt: process.Selector(message),
) -> Result(Awaited(answer, message), Error) {
  let deadline = now() + int.max(0, duration.to_milliseconds(within))
  case attend(run, process.new_subject(), interrupt, deadline, None) {
    Ok(Reached(status)) -> Ok(Reached(answers.status(run.answer, status)))
    Ok(Interrupted(message)) -> Ok(Interrupted(message))
    Error(error) -> Error(error)
  }
}

/// What a wait ended with: an outcome, or the store process stopped (its
/// watches are gone with it).
type Waited(message) {
  Waited(Result(Awaited(String, message), Error))
  StoreStopped
}

/// Waits through the store process running now, and again through the next
/// one if a supervisor restarts it meanwhile. `stopped` is the process
/// that stopped last.
fn attend(
  run: Run(context, answer),
  watcher: process.Subject(Nil),
  interrupt: process.Selector(message),
  deadline: Int,
  stopped: Option(Pid),
) -> Result(Awaited(String, message), Error) {
  case store_process(run.setup.store, interrupt, stopped, deadline) {
    Error(Nil) -> Error(StoreUnavailable("the store is not running"))
    Ok(Error(message)) -> Ok(Interrupted(message))
    Ok(Ok(pid)) -> {
      let monitor = process.monitor(pid)
      let waited =
        wait(run, watcher, interrupt, pid, monitor, [], deadline, False)
      process.demonitor_process(monitor)
      case waited {
        Waited(outcome) -> outcome
        StoreStopped -> attend(run, watcher, interrupt, deadline, Some(pid))
      }
    }
  }
}

/// The store's process. After `stopped` stopped, the next process
/// registered under the store's name, waited for until `deadline` or a
/// message of `interrupt` (`Ok(Error(message))`).
fn store_process(
  store: Store,
  interrupt: process.Selector(message),
  stopped: Option(Pid),
  deadline: Int,
) -> Result(Result(Pid, message), Nil) {
  case store_core.pid(store), stopped {
    Ok(pid), Some(old) if pid != old -> Ok(Ok(pid))
    Ok(pid), None -> Ok(Ok(pid))
    Error(Nil), None -> Error(Nil)
    _, Some(_) ->
      case deadline - now() {
        left if left > 0 ->
          case process.selector_receive(interrupt, int.min(left, 5)) {
            Ok(message) -> Ok(Error(message))
            Error(Nil) -> store_process(store, interrupt, stopped, deadline)
          }
        _ -> Error(Nil)
      }
  }
}

fn wait(
  run: Run(context, answer),
  watcher: process.Subject(Nil),
  interrupt: process.Selector(message),
  pid: Pid,
  monitor: process.Monitor,
  watched: List(String),
  deadline: Int,
  expiring: Bool,
) -> Waited(message) {
  let done = fn(outcome) {
    list.each(watched, store_core.unwatch(run.setup.store, _, watcher))
    Waited(outcome)
  }
  let reached = fn(status) { done(Ok(Reached(status))) }
  // A store call that failed because the process stopped under it is the
  // stop, not an outcome.
  let failed = fn(error) {
    case process.is_alive(pid) {
      True -> done(Error(error))
      False -> StoreStopped
    }
  }
  case family.load(run.setup.store, run.id) {
    Error(problem) -> failed(record_error(problem))
    Ok(node) -> {
      // Watch every record of the family before deciding; a record seen
      // for the first time is read again after it is watched, so no
      // commit is missed.
      let fresh =
        list.filter(family.ids(node), fn(id) { !list.contains(watched, id) })
      let watching =
        list.try_each(fresh, fn(id) {
          store_core.watch(run.setup.store, id, watcher)
        })
      case watching, fresh, family.view(node) {
        Error(error), _, _ -> failed(store_error(error))
        Ok(Nil), [_, ..], _ ->
          wait(
            run,
            watcher,
            interrupt,
            pid,
            monitor,
            list.append(watched, fresh),
            deadline,
            expiring,
          )
        // Unattended only when a second read finds the family unchanged.
        Ok(Nil), [], family.View(run.Working, False) ->
          case family.load(run.setup.store, run.id) {
            Ok(again) if again == node -> reached(run.Unattended)
            _ ->
              wait(
                run,
                watcher,
                interrupt,
                pid,
                monitor,
                watched,
                deadline,
                expiring,
              )
          }
        Ok(Nil), [], family.View(run.Working, True) -> {
          // Commits made through another node's store wake no watcher here:
          // a leased store reads the family again at least every poll.
          let wake = case store_core.poll_interval(run.setup.store) {
            Some(poll) -> int.min(deadline, now() + poll)
            None -> deadline
          }
          let woken =
            process.new_selector()
            |> process.select_map(watcher, fn(_) { Woken })
            |> process.select_specific_monitor(monitor, fn(_) { Stopped })
            |> process.merge_selector(process.map_selector(interrupt, Caller))
            |> receive_until(wake)
          case woken {
            Error(Nil) if wake < deadline ->
              wait(
                run,
                watcher,
                interrupt,
                pid,
                monitor,
                watched,
                deadline,
                expiring,
              )
            Error(Nil) -> reached(run.Working)
            Ok(Stopped) -> StoreStopped
            Ok(Caller(message)) -> done(Ok(Interrupted(message)))
            Ok(Woken) ->
              wait(
                run,
                watcher,
                interrupt,
                pid,
                monitor,
                watched,
                deadline,
                expiring,
              )
          }
        }
        // An approval request whose deadline passed is expired once, and
        // the run read again: it goes on without the rejected action.
        Ok(Nil), [], family.View(run.Suspended(approvals, _) as status, _) ->
          case expiring, due(run.setup.store, approvals) {
            False, [_, ..] as due -> {
              expire(run, due)
              wait(
                run,
                watcher,
                interrupt,
                pid,
                monitor,
                watched,
                deadline,
                True,
              )
            }
            _, _ -> reached(status)
          }
        Ok(Nil), [], family.View(status, _) -> reached(status)
      }
    }
  }
}

/// The runs of the family that have an approval request whose deadline has
/// passed by the store's clock (none when it cannot be read).
fn due(store: Store, approvals: List(PendingApproval)) -> List(RunId) {
  let now = case store_core.now(store) {
    Ok(now) -> now
    Error(_) -> -1
  }
  list.filter_map(approvals, fn(pending) {
    case pending.expires {
      Some(at) ->
        case now >= 0 && clock.to_milliseconds(at) <= now {
          True -> Ok(pending.reference.run)
          False -> Error(Nil)
        }
      None -> Error(Nil)
    }
  })
  |> list.unique
}

/// Expires the due approval requests of each of `runs`; a run that refuses
/// (its requests were answered meanwhile) is read again by the caller.
fn expire(run: Run(context, answer), runs: List(RunId)) -> Nil {
  list.each(runs, fn(id) {
    case locate(run, id) {
      Ok(#(target_id, target)) -> {
        let _ =
          runner.command(
            target,
            target_id,
            target.env,
            controller.ExpireApprovals,
            retries,
          )
        Nil
      }
      Error(_) -> Nil
    }
  })
}

/// What woke a blocked wait.
type Wake(message) {
  /// A commit of a watched record.
  Woken
  /// The store's process stopped.
  Stopped
  /// The caller's selector.
  Caller(message)
}

/// The longest timer the runtime can set, in milliseconds.
const longest_timer = 4_294_967_295

/// Receives from `selector` until `deadline`, waiting at most the longest
/// timer at a time, so that a longer wait does not crash the caller.
fn receive_until(
  selector: process.Selector(message),
  deadline: Int,
) -> Result(message, Nil) {
  let left = int.max(0, deadline - now())
  case process.selector_receive(selector, int.min(left, longest_timer)) {
    Error(Nil) if left > longest_timer -> receive_until(selector, deadline)
    received -> received
  }
}

/// The run's own record, with the status of the run and its sub-agents
/// (see `await`).
pub fn snapshot(run: Run(context, answer)) -> Result(Snapshot(answer), Error) {
  use node <- result.map(
    family.load_settled(run.setup.store, run.id)
    |> result.map_error(record_error),
  )
  run.Snapshot(..controller.snapshot(node.state), status: family.status(node))
  |> answers.snapshot(run.answer, _)
}

/// The approval requests waiting for an answer: the run's own, oldest
/// first, then its sub-agents'. They can be answered while other work
/// still runs.
pub fn pending(
  run: Run(context, answer),
) -> Result(List(PendingApproval), Error) {
  family.load(run.setup.store, run.id)
  |> result.map(family.pending)
  |> result.map_error(record_error)
}

/// Approves an approval request of the run or of one of its sub-agents
/// (the reference names the run). `context` is the application's current
/// context: the policy is checked again with it, and a current denial or
/// policy failure wins over the approval; a policy that now requires another
/// approval refuses it with `RequirementChanged`. The approved action runs
/// with exactly this context, whether or not a runner was live: the tool
/// body receives it, and an approved sub-agent start starts the child run
/// with it. It does not become the run's context: the run's other actions
/// keep the context it was started or recovered with. If the run's runner
/// is lost before the approved action starts, recovery asks again (see
/// `recover`).
///
/// Works with no process holding the run: the answer is committed to the
/// stored record with compare-and-set, so of concurrent answers exactly one
/// wins and the others get `AlreadyAnswered` (or `RunEnded` after a cancel).
/// The caller then emits the commit's events before `approve` returns (see
/// `fabric/telemetry`); the approved work has already started.
///
/// An answer to a sub-agent run whose ancestor is stopping or has ended is
/// refused with `RunEnded`, even if the sub-agent's own cancellation has
/// not been committed yet. An answer checked just before an ancestor's
/// cancellation was committed may still commit, but nothing it approved
/// starts: a sub-agent run checks its ancestors again before each tool or
/// sub-agent start, and one that finds an ancestor stopping or ended starts
/// nothing and cancels itself.
///
/// An answer after the request's deadline (`agent.with_approval_expiry`)
/// is refused with `ApprovalExpired`: the request expires instead, its
/// action is rejected, and the run goes on.
///
/// `proof` says who answers: `approvers.check` made it for the request's
/// requirement (`reference.requirement`) with the approvers of the agent
/// whose run issued the request (`agent.with_approvers`). Any other proof,
/// or one older than the proof lifetime, is refused with `ProofRefused`
/// before the request is checked. The reviewer it names
/// and the approvers' name are recorded with the answer
/// (`run.Approval.reviewer`, `run.Approval.verifier`).
pub fn approve(
  run: Run(context, answer),
  reference: ApprovalRef,
  proof proof: Proof,
  context context: context,
) -> Result(Status(answer), Error) {
  use #(target_id, target) <- result.try(locate(run, reference.run))
  use answerer <- result.try(answerer_of(target, proof, reference))
  let recheck = controller.Env(..target.env, context:)
  use state <- result.try(answer(
    run,
    target_id,
    target,
    recheck,
    reference,
    run.Approve,
    answerer,
  ))
  let reissued =
    list.find(family.own_pending(state), fn(pending) {
      pending.reference.id == reference.id
      && pending.reference.revision != reference.revision
    })
  case reissued, expired(state, reference) {
    _, True -> Error(ApprovalExpired)
    Ok(pending), False -> Error(RequirementChanged(pending))
    Error(Nil), False -> family_status_after(run, target_id, state)
  }
}

/// Whether `state` records the request `reference` names as expired.
fn expired(state: State, reference: ApprovalRef) -> Bool {
  controller.snapshot(state).actions
  |> list.any(fn(action) {
    action.id == reference.id
    && list.any(action.approvals, fn(approval) {
      approval.revision == reference.revision && approval.answer == run.Expired
    })
  })
}

/// Rejects an approval request of the run or of one of its sub-agents (the
/// reference names the run): the action does not run, and the model sees
/// `reason`. A rejection is not checked again, so it takes no context and
/// never runs the policy; the run continues with its own context. It is
/// committed like an approval (see `approve`), with the same refusals
/// except `RequirementChanged`; a rejection after the request's deadline is
/// `ApprovalExpired`. `proof` is checked and recorded as for `approve`.
pub fn reject(
  run: Run(context, answer),
  reference: ApprovalRef,
  proof proof: Proof,
  reason reason: String,
) -> Result(Status(answer), Error) {
  use #(target_id, target) <- result.try(locate(run, reference.run))
  use answerer <- result.try(answerer_of(target, proof, reference))
  use state <- result.try(answer(
    run,
    target_id,
    target,
    target.env,
    reference,
    run.Reject(reason),
    answerer,
  ))
  case expired(state, reference) {
    True -> Error(ApprovalExpired)
    False -> family_status_after(run, target_id, state)
  }
}

/// The reviewer and verifier of an answer to `reference` with `proof`, by
/// the approvers of `target`, the run that issued the request.
fn answerer_of(
  target: runner.Setup(context),
  proof: Proof,
  reference: ApprovalRef,
) -> Result(#(reviewer.Reviewer, String), Error) {
  answerer.check(target.approvers, proof, reference.requirement)
  |> result.map_error(ProofRefused)
}

/// The run `id` of `run`'s family, located by following the child links:
/// `WrongReference` when it is not a descendant.
fn locate(
  run: Run(context, answer),
  id: RunId,
) -> Result(#(String, runner.Setup(context)), Error) {
  let id = id_to_string(id)
  case id == run.id {
    True -> Ok(#(id, run.setup))
    False ->
      case family.locate(run.setup, run.id, id) {
        Ok(setup) -> Ok(#(id, setup))
        Error(runner.NotFound) -> Error(WrongReference)
        Error(problem) -> Error(record_error(problem))
      }
  }
}

fn answer(
  run: Run(context, answer),
  target_id: String,
  target: runner.Setup(context),
  env: controller.Env(context),
  reference: ApprovalRef,
  answer: Answer,
  answerer: #(reviewer.Reviewer, String),
) -> Result(State, Error) {
  use Nil <- result.try(open_to_commands(run, target_id))
  let #(reviewer, verifier) = answerer
  runner.command(
    target,
    target_id,
    env,
    controller.Answer(reference, answer, Some(reviewer), Some(verifier)),
    retries,
  )
  |> result.map_error(command_error)
}

/// The family's status after `state` of its run `target_id` was committed.
fn family_status_after(
  run: Run(context, answer),
  target_id: String,
  state: State,
) -> Result(Status(answer), Error) {
  case target_id == run.id {
    True -> Ok(status_after(run, state))
    False ->
      family.load_settled(run.setup.store, run.id)
      |> result.map(fn(node) { answers.status(run.answer, family.status(node)) })
      |> result.map_error(record_error)
  }
}

/// Cancels a run that is active, suspended, or whose runner was lost, and
/// its sub-agent runs through the store. A stopped tool bound with
/// `tool.bind_settling` is waited for, up to its bound, until its late
/// settlement records what happened. A sub-agent's cancellation that
/// fails on a store error is tried again with a bounded backoff; one that
/// still fails makes the delegation an uncertain effect, and the sub-agent
/// then accepts no answer or reconciliation (see `RunEnded`). Cancelling a
/// run that is still stopping asks its sub-agents to cancel again. A
/// sub-agent run that was never stored is stored as cancelled before it
/// started, so a start or a recovery racing the cancellation never runs
/// it. Running tools are stopped and
/// recorded as uncertain effects, never retried; queued actions and pending
/// approvals are recorded as not started. Returns the status right after
/// the cancellation was committed: `Working` while tools are being stopped
/// or sub-agents cancelled, then `Finished(Cancelled)` (see `await`).
///
/// Through a `Store` that does not drive the run (another `Store` over the
/// same backend), the cancellation is committed to the record at once and
/// reported `Finished(Cancelled)`, but the owner's tool bodies keep running
/// until its runner next tries to commit and stops; they are recorded as
/// uncertain effects. A runner that does not take the cancellation within
/// the command timeout (a synchronous handler holds it) has its work
/// abandoned in the record the same way, and is then killed, with its
/// model call and running tool bodies (recorded as uncertain effects): it
/// calls no model, starts no tool body or sub-agent, and commits nothing
/// after the cancellation. A handler that cancels the run whose runner it
/// runs in cannot kill that runner; the runner calls no model and starts
/// no sub-agent once its record moved on, and commits nothing more.
/// A sub-agent is cancelled the same way; its delegation becomes an
/// uncertain effect only when the store keeps failing.
pub fn cancel(run: Run(context, answer)) -> Result(Status(answer), Error) {
  runner.command(run.setup, run.id, run.setup.env, controller.Cancel, retries)
  |> result.map(status_after(run, _))
  |> result.map_error(command_error)
}

/// Cancels the run when `owner` stops, for a run that must not outlive the
/// process that asked for it: a request handler, a connection, a Relay
/// tool call. A watcher process monitors `owner` and `cancel`s the run as
/// soon as `owner` exits, for any reason (also when it had already exited);
/// it then stops. It also stops, cancelling nothing, once the run has
/// finished. A suspended run is checked for its end every 5 seconds.
///
/// The watcher is not linked to the caller and is not supervised: a VM that
/// stops takes it with it, and the run is then recovered like any other.
/// Call it once per owner; each call adds one watcher.
pub fn cancel_when_down(run: Run(context, answer), owner owner: Pid) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      let monitor = process.monitor(owner)
      let down =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Nil })
      guard(run, down)
    })
  Nil
}

fn guard(run: Run(context, answer), down: process.Selector(Nil)) -> Nil {
  case await_with(run, within: duration.minutes(1), or: down) {
    Ok(Interrupted(Nil)) -> {
      let _ = cancel(run)
      Nil
    }
    Ok(Reached(run.Finished(_))) -> Nil
    // Suspended, unattended, or the store could not be read: nothing wakes
    // the wait, so the run is read again a little later.
    Ok(Reached(_)) | Error(_) ->
      case process.selector_receive(down, 5000) {
        Ok(Nil) -> {
          let _ = cancel(run)
          Nil
        }
        Error(Nil) -> guard(run, down)
      }
  }
}

/// Cancels the stored run `id` with no agent: for a run that cannot be
/// recovered because its agent changed (another identity, or a pending tool
/// that no longer exists). Cancelling a sub-agent run this way does not apply
/// its end to its parent, which needs its agent to map it: `recover` the parent
/// to apply it (`await` on the parent reports `Unattended` until then). A run
/// whose runner is live in this store is cancelled through that runner, as
/// `cancel` would, which must take it within
/// 5 seconds (there is no agent to configure it); otherwise (a lost runner, or one a handler holds) the work of a lost
/// runner is abandoned (running tools become uncertain effects) and the run
/// ends `Cancelled` in one commit. Active sub-agent runs are cancelled first,
/// the same way; their delegations are recorded as uncertain effects, since no
/// agent maps their outcome. A sub-agent that is still stopping (it waits for a
/// stopped tool's settlement) is recorded as such, and ends on its own. A
/// sub-agent run that was never stored is stored as cancelled before it started
/// (naming no agent), and its delegation is recorded as not started.
pub fn cancel_stored(store: Store, id: RunId) -> Result(Status(String), Error) {
  let id = id_to_string(id)
  runner.cancel_unattended(store, id, 5000, retries)
  |> result.map(committed_status(store, id, _))
  |> result.map_error(command_error)
}

/// Records evidence for an uncertain tool of a finished run, without an
/// agent definition or any execution callbacks. The outcome, transcript,
/// usage and counters stay unchanged. The same content is an idempotent
/// acknowledgement; different content cannot overwrite a saved result.
/// Active runs return `RunNotFinished`; use `reconcile` to continue them.
/// A delegation cannot be reconciled by supplying content: settle its child
/// and then use `settle_stored` on the parent. Returns this run's updated
/// snapshot, including any remaining uncertain actions.
pub fn reconcile_stored(
  store: Store,
  effect: ActionRef,
  content: String,
) -> Result(Snapshot(String), Error) {
  settlement.reconcile(store, effect, content)
  |> result.map(controller.snapshot)
  |> result.map_error(settlement_error)
}

/// Settles uncertain delegations of a finished agent family from their saved
/// child outcomes. Descendants must name the exact parent action. Missing or
/// unreadable children return an error; active or uncertain children leave
/// the delegation uncertain. No agent code runs and no work resumes.
/// The returned root snapshot retains every unresolved action; successful
/// observation does not imply that every effect has been settled.
///
/// Each record commits independently, from the leaves outward. A failed
/// parent write may follow successful descendant writes; repeat this command
/// to finish propagation. Repeating an unchanged walk performs no writes.
/// For a graph-owned family, settle this agent root, then recover its graph
/// parent to observe the saved outcome. The graph remains cancelled.
pub fn settle_stored(
  store: Store,
  id: RunId,
) -> Result(Snapshot(String), Error) {
  settlement.settle(store, id_to_string(id))
  |> result.map(controller.snapshot)
  |> result.map_error(settlement_error)
}

fn settlement_error(error: settlement.Error) -> Error {
  case error {
    settlement.NotFinished -> RunNotFinished
    settlement.UnknownAction -> WrongReference
    settlement.NotReconcilable -> NotReconcilable
    settlement.Unreadable(error) -> record_error(error)
    settlement.Contended -> Contended
  }
}

/// Records what actually happened for an uncertain effect of the run or of
/// one of its sub-agents (`UncertainAction.reference` names both the run and
/// the action; it is routed through the family like `approve`). `content`
/// is what the model will see as that call's result. When nothing else is
/// pending the run continues with its next model turn. Reconciliation does
/// not consume a turn.
///
/// An effect of a run outside this handle's family, or an action that the
/// run's current tool batch does not have, is refused with
/// `WrongReference`; an action that is not uncertain, or a run whose model
/// is being called, with `NotReconcilable`. A sub-agent run whose ancestor
/// is stopping or has ended accepts none (`RunEnded`).
/// After a run has finished, use `reconcile_stored` to retain evidence
/// without resuming work, then `settle_stored` for its finished ancestors.
pub fn reconcile(
  run: Run(context, answer),
  effect: ActionRef,
  content: String,
) -> Result(Status(answer), Error) {
  use #(target_id, target) <- result.try(locate(run, effect.run))
  use Nil <- result.try(open_to_commands(run, target_id))
  use state <- result.try(
    runner.command(
      target,
      target_id,
      target.env,
      controller.Reconcile(effect.id, content),
      retries,
    )
    |> result.map_error(command_error),
  )
  family_status_after(run, target_id, state)
}

/// `RunEnded` when an ancestor of the run `id` is stopping or has ended:
/// cancelling an ancestor wins over answers and reconciliations of its
/// descendants.
fn open_to_commands(
  run: Run(context, answer),
  id: String,
) -> Result(Nil, Error) {
  case family.ancestors_open(run.setup.store, id) {
    Ok(True) -> Ok(Nil)
    Ok(False) -> Error(RunEnded)
    Error(problem) -> Error(record_error(problem))
  }
}

/// The family's status right after `state` of this run was committed, with
/// its children read now.
fn status_after(run: Run(context, answer), state: State) -> Status(answer) {
  answers.status(run.answer, committed_status(run.setup.store, run.id, state))
}

/// The family's status right after `state` of the run `id` was committed,
/// with its children and its runner read now. A family that reads
/// `Unattended` is read again, as `snapshot` does.
fn committed_status(store: Store, id: String, state: State) -> Status(String) {
  case store_core.get(store, id) {
    Ok(entry) ->
      family.with_children(store, id, entry, state)
      |> family.settle(store, _, 3)
      |> result.map(family.status)
      |> result.unwrap(run.Unattended)
    Error(_) -> controller.status(state)
  }
}

fn command_error(failure: runner.Failure) -> Error {
  case failure {
    runner.CommandRefused(rejection) -> refusal(rejection)
    runner.OwnerUnknown -> RunUnattended
    runner.Contended
    | runner.Unreadable(runner.StoreFailed(backend.Conflict(_))) -> Contended
    runner.Busy -> RunnerBusy
    runner.Unreadable(problem) -> record_error(problem)
  }
}

fn refusal(rejection: controller.Rejection) -> Error {
  case rejection {
    controller.RunEnded -> RunEnded
    controller.UnknownAction(_)
    | controller.ReportNotExpected(_)
    | controller.WrongReference -> WrongReference
    controller.NotReconcilable(_)
    | controller.StaleEvent
    | controller.SettlementNotAwaited(_)
    | controller.SettlementEarly(_)
    | controller.SettlementRecorded(_) -> NotReconcilable
    controller.StaleReference -> StaleReference
    controller.AlreadyAnswered -> AlreadyAnswered
    controller.ApprovalExpired -> ApprovalExpired
  }
}

fn record_error(problem: runner.ReadError) -> Error {
  case problem {
    runner.NotFound -> RunNotFound
    runner.StoreFailed(error) -> store_error(error)
    runner.UnsupportedVersion(found) -> UnsupportedVersion(found)
    runner.Corrupt(detail) -> CorruptRecord(detail)
    runner.Incompatible(problems) -> IncompatibleAgent(problems)
  }
}

/// A store failure a caller sees. Only `Unavailable` reaches here in
/// practice: a conflict is retried (and reported `Contended`), and a read
/// reports a missing record as not found. A backend that breaks its
/// contract is reported unavailable with what it said.
fn store_error(error: backend.StoreError) -> Error {
  case error {
    backend.NotFound -> RunNotFound
    backend.Unavailable(reason) -> StoreUnavailable(reason)
    backend.AlreadyExists | backend.Conflict(_) | backend.LeaseRefused(_) ->
      StoreUnavailable(describe_store(error))
  }
}

fn describe_store(error: backend.StoreError) -> String {
  case error {
    backend.Unavailable(reason) -> reason
    backend.NotFound -> "the run does not exist"
    backend.AlreadyExists -> "the run already exists"
    backend.Conflict(current) ->
      "the run moved on to revision " <> int.to_string(current)
    backend.LeaseRefused(backend.Held(owner:, ..)) ->
      "the run's lease is held by " <> owner
    backend.LeaseRefused(backend.Free) -> "the run's lease is not held"
  }
}

@external(erlang, "fabric_ffi", "now_ms")
fn now() -> Int

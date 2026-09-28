//// Fabric runs bounded, typed LLM agents whose runs can pause durably,
//// wait for a human, survive a restart, and be cancelled at any point.
////
//// ```gleam
//// let runs = store.in_memory(process.new_name("runs"))  // or store.directory
//// let assert Ok(Nil) = store.start(runs)   // or store.supervised(runs)
//// let assert Ok(agent) =
////   agent.new("desk", model, [weather_tool, transfer_tool], my_policy)
////   |> agent.build
//// let assert Ok(handle) = fabric.start(runs, agent, context, "Pay Bob")
//// case fabric.await(handle, 5000) {
////   Ok(run.Suspended([pending, ..], _)) ->
////     fabric.approve(handle, pending.reference,
////       reviewer: Some("alice"), context: current_context)
////   ...
//// }
//// ```
////
//// A run's record lives in a store, and a run is named by its `run.RunId`:
//// a string from outside becomes one only through `run.parse_id`. A runner
//// process exists only while a model call or a tool is in flight; a
//// suspended or finished run has no process.
//// Commands (`approve`, `reject`, `cancel`, `reconcile`) go to the live
//// runner, or are applied to the stored record when there is none, and a
//// runner is started if the command produced work.
////
//// A delegation (`agent.with_sub_agent`) starts a sub-agent run in the same
//// store, behind the same policy gate as a tool. The family is read together:
//// a child's pending approvals and uncertain effects are the parent's (their
//// references name the child run), `approve`, `reject` and `reconcile` route
//// by the reference, `child` opens a child's handle, cancelling a parent
//// cancels its children, and recovering a parent recovers its children.
////
//// A run's context is a live value, never stored: the one given to `start`
//// or `recover`, held by the handle and its runner. An approved action is
//// the exception: it runs with the context its answer was checked with
//// (see `approve`).
////
//// After a restart, `recover` opens a stored run under the same agent. If
//// work was in flight when its runner was lost, recovery takes it over as a
//// new incarnation: tools that had started become uncertain effects, which
//// are never retried and must be reconciled; queued tools and a lost model
//// call are started again, except approved ones, which ask for their
//// approval again. "Never retried" holds as long as the store keeps
//// every commit it acknowledged: the directory store does not flush the
//// directory entry, so after an operating-system crash or power loss (not
//// a process or VM crash) the latest revisions may be missing, and a tool
//// whose start was among them could run again.

import fabric/agent.{type Agent}
import fabric/internal/controller.{type State}
import fabric/internal/family
import fabric/internal/runner
import fabric/run.{
  type ActionRef, type Answer, type ApprovalRef, type Incompatibility,
  type PendingApproval, type RunId, type Snapshot, type Status, id_to_string,
  issued,
}
import fabric/store.{type Store}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A handle on one run, for the agent and context it was started or
/// recovered with. It holds no process: it can be dropped and rebuilt with
/// `recover`.
pub opaque type Run(context) {
  Run(id: String, setup: runner.Setup(context))
}

pub type StartError {
  /// The store did not confirm the run's first record, so its outcome is
  /// unknown: the backend may still store it later, as the run `id` with
  /// work in flight and no runner (`await` then reports `Unattended`).
  /// `cancel_stored(store, id)` ends such a run if it lands.
  StartUnconfirmed(id: RunId, reason: String)
}

/// Why a stored run could not be read or continued.
pub type RecordError {
  RunNotFound
  /// The store failed. A write it reported unavailable has an unknown
  /// outcome: the backend may still perform it later.
  StoreUnavailable(reason: String)
  /// The record was written by a Fabric version this one cannot read.
  UnsupportedVersion(found: Int)
  CorruptRecord(detail: String)
  /// The run cannot continue under this agent.
  IncompatibleAgent(List(Incompatibility))
}

pub type CommandError {
  /// The run has finished (completed, failed, or cancelled); nothing more
  /// can change it. A pending approval of a cancelled run is void. Also
  /// returned for a sub-agent run one of whose ancestors is stopping or has
  /// ended: cancelling an ancestor wins over answering or reconciling its
  /// descendants.
  RunEnded
  /// No approval request, or no action of the current tool batch, of this
  /// run matches the reference.
  WrongReference
  /// The action's approval request has another revision or requirement.
  StaleReference
  /// This approval request was already answered.
  AlreadyAnswered
  /// The current policy now requires another approval for the action; the
  /// answer was not applied. Answer the new request.
  RequirementChanged(PendingApproval)
  /// The action is not an uncertain effect, or the run is in a phase that
  /// accepts no reconciliation (for example while the model is called).
  NotReconcilable
  /// The command is valid for the stored record, but work is in flight
  /// and no runner known to this store drives it: its runner was lost, or
  /// the run is driven through another `Store` (possibly in another VM).
  /// Nothing was changed. `cancel` never needs a runner.
  RunUnattended
  /// The run's runner did not take the command within the agent's command
  /// timeout (`agent.Limits.command_timeout`): a synchronous observation
  /// handler holds it, or the command was sent from such a handler running
  /// in the run's own runner. Nothing was changed, and the command will not
  /// be applied later. Try again, or route Fabric's events through a
  /// forwarder (see `fabric/observation`). `cancel` and `cancel_stored`
  /// never return it: they commit the cancellation to the record instead.
  RunnerBusy
  /// The command lost every retry against concurrent commits.
  Contended
  /// The record could not be read or written. A write the store reported
  /// unavailable (`Unreadable(StoreUnavailable(_))`) has an unknown
  /// outcome: the backend may still perform it later.
  Unreadable(RecordError)
}

const retries = 3

/// Starts a run of `agent` in `store`: stores its first record and hands the
/// first model call to a new runner.
pub fn start(
  store: Store,
  agent: Agent(context),
  context: context,
  prompt: String,
) -> Result(Run(context), StartError) {
  let setup = runner.setup(store, agent.admitted(agent), context, None)
  start_with(setup, prompt, retries)
}

/// Stores the first record under a fresh id. An id that exists already (a
/// collision of random ids) is replaced by another.
fn start_with(
  setup: runner.Setup(context),
  prompt: String,
  tries: Int,
) -> Result(Run(context), StartError) {
  let id = "run-" <> random_id()
  let #(state, effects) = runner.root_state(setup, id, prompt)
  case runner.launch(setup, None, state, effects) {
    Ok(_) -> Ok(Run(id:, setup:))
    Error(store.AlreadyExists) if tries > 1 ->
      start_with(setup, prompt, tries - 1)
    Error(error) -> Error(StartUnconfirmed(issued(id), describe_store(error)))
  }
}

/// Opens the stored run `id` under `agent` and `context`. When work was in
/// flight and no runner in this store drives it, recovery takes the work
/// over as a new incarnation (committed with compare-and-set, so concurrent
/// recoveries have one winner): running tools become uncertain effects,
/// queued tools are dispatched again, and a lost model call is issued again
/// against the turn budget. A suspended or finished run is opened
/// unchanged. Calling it again is harmless.
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
/// A store knows only the runners it started. Recovering through another
/// `Store` (for example in another VM) while the run's runner is still
/// alive takes the run over: the older runner can no longer commit and
/// stops, and its running tools become uncertain effects. Recover through
/// another store only when the previous owner is known to be gone (for
/// example at boot).
pub fn recover(
  store: Store,
  agent: Agent(context),
  context: context,
  id: RunId,
) -> Result(Run(context), CommandError) {
  let id = id_to_string(id)
  let setup = runner.setup(store, agent.admitted(agent), context, None)
  case family.take_over(setup, id, retries) {
    Ok(Nil) -> Ok(Run(id:, setup:))
    Error(family.TakeOverContended) -> Error(Contended)
    Error(family.TakeOverUnreadable(problem)) ->
      Error(Unreadable(record_error(problem)))
  }
}

pub fn id(run: Run(context)) -> RunId {
  issued(run.id)
}

/// Opens the sub-agent run `id`, a descendant of `run`, with `run`'s agent
/// and context: its snapshot, reconciling its uncertain effects, answering
/// or cancelling it. Its end still reaches its parent.
pub fn child(
  run: Run(context),
  id: RunId,
) -> Result(Run(context), RecordError) {
  let id = id_to_string(id)
  family.locate(run.setup, run.id, id)
  |> result.map(fn(setup) { Run(id:, setup:) })
  |> result.map_error(record_error)
}

/// Blocks until the run is no longer `Working`, or until `within`
/// milliseconds pass, and returns its status: `Working` when the time ran
/// out, `Suspended` or `Finished`, or `Unattended` when work is in flight
/// but no runner known to this store drives it. `Unattended` means the
/// runner was lost, or the run is driven through another `Store`; only the
/// application knows which. `recover` takes the run over, so call it only
/// when the previous owner is known to be gone.
///
/// It wakes on commits made through this run's store and when a runner exits.
/// If the store's process stops meanwhile, it waits, until `within` runs
/// out, for a supervisor to register the next one, and goes on through it;
/// that process knows no runner, so work in flight then reads `Unattended`.
/// With no store process running when it starts, or none registered again
/// in time, it is `StoreUnavailable`. A run whose
/// sub-agents work is working; one waiting only on paused sub-agents is
/// suspended on their approvals. `await(run, 0)` reads the status now.
pub fn await(run: Run(context), within: Int) -> Result(Status, RecordError) {
  attend(run, process.new_subject(), now() + within, None)
}

/// What a wait ended with: an outcome, or the store process stopped (its
/// watches are gone with it).
type Waited {
  Waited(Result(Status, RecordError))
  StoreStopped
}

/// Waits through the store process running now, and again through the next
/// one if a supervisor restarts it meanwhile. `stopped` is the process
/// that stopped last.
fn attend(
  run: Run(context),
  watcher: process.Subject(Nil),
  deadline: Int,
  stopped: Option(Pid),
) -> Result(Status, RecordError) {
  case store_process(run.setup.store, stopped, deadline) {
    Error(Nil) -> Error(StoreUnavailable("the store is not running"))
    Ok(pid) -> {
      let monitor = process.monitor(pid)
      let waited = wait(run, watcher, pid, monitor, [], deadline)
      process.demonitor_process(monitor)
      case waited {
        Waited(outcome) -> outcome
        StoreStopped -> attend(run, watcher, deadline, Some(pid))
      }
    }
  }
}

/// The store's process. After `stopped` stopped, the next process
/// registered under the store's name, waited for until `deadline`.
fn store_process(
  store: Store,
  stopped: Option(Pid),
  deadline: Int,
) -> Result(Pid, Nil) {
  case store.pid(store), stopped {
    Ok(pid), Some(old) if pid != old -> Ok(pid)
    Ok(pid), None -> Ok(pid)
    Error(Nil), None -> Error(Nil)
    _, Some(_) ->
      case deadline - now() {
        left if left > 0 -> {
          process.sleep(int.min(left, 5))
          store_process(store, stopped, deadline)
        }
        _ -> Error(Nil)
      }
  }
}

fn wait(
  run: Run(context),
  watcher: process.Subject(Nil),
  pid: Pid,
  monitor: process.Monitor,
  watched: List(String),
  deadline: Int,
) -> Waited {
  let done = fn(outcome) {
    list.each(watched, store.unwatch(run.setup.store, _, watcher))
    Waited(outcome)
  }
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
          store.watch(run.setup.store, id, watcher)
        })
      case watching, fresh, family.view(node) {
        Error(error), _, _ -> failed(store_error(error))
        Ok(Nil), [_, ..], _ ->
          wait(
            run,
            watcher,
            pid,
            monitor,
            list.append(watched, fresh),
            deadline,
          )
        // Unattended only when a second read finds the family unchanged.
        Ok(Nil), [], family.View(run.Working, False) ->
          case family.load(run.setup.store, run.id) {
            Ok(again) if again == node -> done(Ok(run.Unattended))
            _ -> wait(run, watcher, pid, monitor, watched, deadline)
          }
        Ok(Nil), [], family.View(run.Working, True) -> {
          let woken =
            process.new_selector()
            |> process.select_map(watcher, Ok)
            |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
            |> process.selector_receive(int.max(0, deadline - now()))
          case woken {
            Error(Nil) -> done(Ok(run.Working))
            Ok(Error(Nil)) -> StoreStopped
            Ok(Ok(Nil)) -> wait(run, watcher, pid, monitor, watched, deadline)
          }
        }
        Ok(Nil), [], family.View(status, _) -> done(Ok(status))
      }
    }
  }
}

/// The run's own record, with the status of the run and its sub-agents
/// (see `await`).
pub fn snapshot(run: Run(context)) -> Result(Snapshot, RecordError) {
  use node <- result.map(
    family.load(run.setup.store, run.id) |> result.map_error(record_error),
  )
  run.Snapshot(..controller.snapshot(node.state), status: family.status(node))
}

/// The approval requests waiting for an answer: the run's own, oldest
/// first, then its sub-agents'. They can be answered while other work
/// still runs.
pub fn pending(
  run: Run(context),
) -> Result(List(PendingApproval), RecordError) {
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
/// `fabric/observation`); the approved work has already started.
///
/// An answer to a sub-agent run whose ancestor is stopping or has ended is
/// refused with `RunEnded`, even if the sub-agent's own cancellation has
/// not been committed yet. An answer checked just before an ancestor's
/// cancellation was committed may still commit, but nothing it approved
/// starts: a sub-agent run checks its ancestors again before each tool or
/// sub-agent start, and one that finds an ancestor stopping or ended starts
/// nothing and cancels itself.
///
/// `reviewer` is recorded with the answer as given. Fabric does not
/// authenticate it: the application must authenticate and authorize whoever
/// answers before calling this.
pub fn approve(
  run: Run(context),
  reference: ApprovalRef,
  reviewer reviewer: Option(String),
  context context: context,
) -> Result(Status, CommandError) {
  use #(target_id, target) <- result.try(locate(run, reference.run))
  let recheck = controller.Env(..target.env, context:)
  use state <- result.try(answer(
    run,
    target_id,
    target,
    recheck,
    reference,
    run.Approve,
    reviewer,
  ))
  let reissued =
    list.find(family.own_pending(state), fn(pending) {
      pending.reference.id == reference.id
      && pending.reference.revision != reference.revision
    })
  case reissued {
    Ok(pending) -> Error(RequirementChanged(pending))
    Error(Nil) -> family_status_after(run, target_id, state)
  }
}

/// Rejects an approval request of the run or of one of its sub-agents (the
/// reference names the run): the action does not run, and the model sees
/// `reason`. A rejection is not checked again, so it takes no context and
/// never runs the policy; the run continues with its own context. It is
/// committed like an approval (see `approve`), with the same refusals
/// except `RequirementChanged`. `reviewer` is recorded as given.
pub fn reject(
  run: Run(context),
  reference: ApprovalRef,
  reason reason: String,
  reviewer reviewer: Option(String),
) -> Result(Status, CommandError) {
  use #(target_id, target) <- result.try(locate(run, reference.run))
  use state <- result.try(answer(
    run,
    target_id,
    target,
    target.env,
    reference,
    run.Reject(reason),
    reviewer,
  ))
  family_status_after(run, target_id, state)
}

/// The run `id` of `run`'s family, located by following the child links:
/// `WrongReference` when it is not a descendant.
fn locate(
  run: Run(context),
  id: RunId,
) -> Result(#(String, runner.Setup(context)), CommandError) {
  let id = id_to_string(id)
  case id == run.id {
    True -> Ok(#(id, run.setup))
    False ->
      case family.locate(run.setup, run.id, id) {
        Ok(setup) -> Ok(#(id, setup))
        Error(runner.NotFound) -> Error(WrongReference)
        Error(problem) -> Error(Unreadable(record_error(problem)))
      }
  }
}

fn answer(
  run: Run(context),
  target_id: String,
  target: runner.Setup(context),
  env: controller.Env(context),
  reference: ApprovalRef,
  answer: Answer,
  reviewer: Option(String),
) -> Result(State, CommandError) {
  use Nil <- result.try(open_to_commands(run, target_id))
  runner.command(
    target,
    target_id,
    env,
    controller.Answer(reference, answer, reviewer),
    retries,
  )
  |> result.map_error(command_error)
}

/// The family's status after `state` of its run `target_id` was committed.
fn family_status_after(
  run: Run(context),
  target_id: String,
  state: State,
) -> Result(Status, CommandError) {
  case target_id == run.id {
    True -> Ok(status_after(run, state))
    False ->
      family.load(run.setup.store, run.id)
      |> result.map(family.status)
      |> result.map_error(fn(problem) { Unreadable(record_error(problem)) })
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
pub fn cancel(run: Run(context)) -> Result(Status, CommandError) {
  runner.command(run.setup, run.id, run.setup.env, controller.Cancel, retries)
  |> result.map(status_after(run, _))
  |> result.map_error(command_error)
}

/// Cancels the stored run `id` with no agent: for a run that cannot be
/// recovered because its agent changed (another identity, or a pending tool
/// that no longer exists). Cancelling a sub-agent run this way does not apply
/// its end to its parent, which needs its agent to map it: `recover` the parent
/// to apply it (`await` on the parent reports `Unattended` until then). A run
/// whose runner is live in this store is cancelled through that runner, as
/// `cancel` would, which must take it within
/// `agent.default_limits().command_timeout` (there is no agent to configure
/// it); otherwise (a lost runner, or one a handler holds) the work of a lost
/// runner is abandoned (running tools become uncertain effects) and the run
/// ends `Cancelled` in one commit. Active sub-agent runs are cancelled first,
/// the same way; their delegations are recorded as uncertain effects, since no
/// agent maps their outcome. A sub-agent that is still stopping (it waits for a
/// stopped tool's settlement) is recorded as such, and ends on its own. A
/// sub-agent run that was never stored is stored as cancelled before it started
/// (naming no agent), and its delegation is recorded as not started.
pub fn cancel_stored(store: Store, id: RunId) -> Result(Status, CommandError) {
  let id = id_to_string(id)
  runner.cancel_unattended(
    store,
    id,
    agent.default_limits().command_timeout,
    retries,
  )
  |> result.map(committed_status(store, id, _))
  |> result.map_error(command_error)
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
pub fn reconcile(
  run: Run(context),
  effect: ActionRef,
  content: String,
) -> Result(Status, CommandError) {
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
  run: Run(context),
  id: String,
) -> Result(Nil, CommandError) {
  case family.ancestors_open(run.setup.store, id) {
    Ok(True) -> Ok(Nil)
    Ok(False) -> Error(RunEnded)
    Error(problem) -> Error(Unreadable(record_error(problem)))
  }
}

/// The family's status right after `state` of this run was committed, with
/// its children read now.
fn status_after(run: Run(context), state: State) -> Status {
  committed_status(run.setup.store, run.id, state)
}

/// The family's status right after `state` of the run `id` was committed,
/// with its children and its runner read now.
fn committed_status(store: Store, id: String, state: State) -> Status {
  case store.get(store, id) {
    Ok(entry) -> family.status(family.with_children(store, id, entry, state))
    Error(_) -> controller.status(state)
  }
}

fn command_error(failure: runner.Failure) -> CommandError {
  case failure {
    runner.CommandRefused(rejection) -> refusal(rejection)
    runner.OwnerUnknown -> RunUnattended
    runner.Contended
    | runner.Unreadable(runner.StoreFailed(store.Conflict(_))) -> Contended
    runner.Busy -> RunnerBusy
    runner.Unreadable(problem) -> Unreadable(record_error(problem))
  }
}

fn refusal(rejection: controller.Rejection) -> CommandError {
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
  }
}

fn record_error(problem: runner.ReadError) -> RecordError {
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
fn store_error(error: store.StoreError) -> RecordError {
  case error {
    store.NotFound -> RunNotFound
    store.Unavailable(reason) -> StoreUnavailable(reason)
    store.AlreadyExists | store.Conflict(_) ->
      StoreUnavailable(describe_store(error))
  }
}

fn describe_store(error: store.StoreError) -> String {
  case error {
    store.Unavailable(reason) -> reason
    store.NotFound -> "the run does not exist"
    store.AlreadyExists -> "the run already exists"
    store.Conflict(current) ->
      "the run moved on to revision " <> int.to_string(current)
  }
}

@external(erlang, "fabric_ffi", "random_id")
fn random_id() -> String

@external(erlang, "fabric_ffi", "now_ms")
fn now() -> Int

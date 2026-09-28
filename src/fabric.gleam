//// Fabric runs bounded, typed LLM agents whose runs can pause durably,
//// wait for a human, survive a restart, and be cancelled at any point.
////
//// ```gleam
//// let store = store.in_memory()            // or store.directory(path)
//// let agent = agent.new(model, [weather_tool, transfer_tool], my_policy)
//// let assert Ok(handle) = fabric.start(store, agent, context, "Pay Bob")
//// case fabric.await(handle, 5000) {
////   Ok(run.Suspended([pending, ..], _)) ->
////     fabric.answer(handle, pending.reference, run.Approve,
////       reviewer: Some("alice"), context: current_context)
////   ...
//// }
//// ```
////
//// A run's record lives in a store. A runner process exists only while a
//// model call or a tool is in flight; a suspended or finished run has no
//// process. Commands (`answer`, `cancel`, `reconcile`) go to the live
//// runner, or are applied to the stored record when there is none, and a
//// runner is started if the command produced work.
////
//// A delegation (`agent.with_sub_agent`) starts a sub-agent run in the
//// same store, behind the same policy gate as a tool. The family is read
//// together: a child's pending approvals and uncertain effects are the
//// parent's (their references name the child run), `answer` routes by the
//// reference, `child` opens a child's handle, cancelling a parent cancels
//// its children, and recovering a parent recovers its children.
////
//// A run's context is a live value, never stored: the one given to `start`
//// or `recover`, held by the handle and its runner. An approved action is
//// the exception: it runs with the context its answer was checked with
//// (see `answer`).
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

import fabric/agent.{type Agent, type ConfigError}
import fabric/internal/controller.{type State}
import fabric/internal/family
import fabric/internal/runner
import fabric/policy.{type ActionId}
import fabric/run.{
  type Answer, type ApprovalRef, type Incompatibility, type PendingApproval,
  type Snapshot, type Status,
}
import fabric/store.{type Store}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/result

/// A handle on one run, for the agent and context it was started or
/// recovered with. It holds no process: it can be dropped and rebuilt with
/// `recover`.
pub opaque type Run(context) {
  Run(id: String, setup: runner.Setup(context))
}

pub type StartError {
  InvalidAgent(List(ConfigError))
  /// The store refused the first record. `Unavailable` means the outcome
  /// is unknown: the backend may still store the record later, as a run
  /// with work in flight and no runner (`await` then reports `NoRunner`).
  StartFailed(store.StoreError)
}

/// Why a stored run could not be read or continued.
pub type RecordError {
  RunNotFound
  StoreFailed(store.StoreError)
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
  /// No action with this identity exists in the current tool batch.
  UnknownAction(ActionId)
  /// The action is not an uncertain effect.
  NotReconcilable(ActionId)
  /// The run is in a phase that does not accept this command (for example
  /// reconciling while the model is being called).
  WrongPhase
  /// No approval request of this run matches the reference.
  WrongReference
  /// The action's approval request has another revision or requirement.
  StaleReference
  /// This approval request was already answered.
  AlreadyAnswered
  /// The current policy now requires another approval for the action; the
  /// answer was not applied. Answer the new request.
  RequirementChanged(PendingApproval)
  /// The command is valid for the stored record, but work is in flight
  /// and no runner known to this store drives it: its runner was lost, or
  /// the run is driven through another `Store` (possibly in another VM).
  /// Nothing was changed. `cancel` never needs a runner.
  OwnerUnknown
  /// The command lost every retry against concurrent commits.
  Contended
  /// The run's runner did not take the command within the agent's command
  /// timeout (`agent.with_command_timeout`): a synchronous observation
  /// handler holds it, or the command was sent from such a handler running
  /// in the run's own runner. Nothing was changed, and the command will not
  /// be applied later. Try again, or route Fabric's events through a
  /// forwarder (see `fabric/observation`).
  RunnerBusy
  /// The record could not be read or written. A write the store reports
  /// `Unavailable` (as `Unreadable(StoreFailed(Unavailable(_)))`) has an
  /// unknown outcome: the backend may still perform it later.
  Unreadable(RecordError)
}

pub type AwaitError {
  /// The run was still working when the time ran out.
  StillWorking
  /// Work is in flight but no runner known to this store drives it: the
  /// runner was lost, or the run is driven through another `Store`. Only
  /// the application knows which: `recover` takes the run over, so call it
  /// only when the previous owner is known to be gone.
  NoRunner
  AwaitUnreadable(RecordError)
}

pub type RecoverError {
  RecoverInvalidAgent(List(ConfigError))
  RecoverUnreadable(RecordError)
  /// Recovery lost every retry against concurrent commits.
  RecoverContended
}

const retries = 3

/// Validates `agent`, then starts a run in `store`: stores its first record
/// and hands the first model call to a new runner.
pub fn start(
  store: Store,
  agent: Agent(context),
  context: context,
  prompt: String,
) -> Result(Run(context), StartError) {
  use admitted <- result.try(
    agent.admit(agent) |> result.map_error(InvalidAgent),
  )
  let setup = runner.setup(store, admitted, context, None)
  let id = "run-" <> random_id()
  let #(state, effects) = runner.root_state(setup, id, prompt)
  use _ <- result.map(
    runner.launch(setup, None, state, effects) |> result.map_error(StartFailed),
  )
  Run(id:, setup:)
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
  id: String,
) -> Result(Run(context), RecoverError) {
  use admitted <- result.try(
    agent.admit(agent) |> result.map_error(RecoverInvalidAgent),
  )
  let setup = runner.setup(store, admitted, context, None)
  case family.take_over(setup, id, retries) {
    Ok(Nil) -> Ok(Run(id:, setup:))
    Error(family.TakeOverContended) -> Error(RecoverContended)
    Error(family.TakeOverUnreadable(problem)) ->
      Error(RecoverUnreadable(record_error(problem)))
  }
}

pub fn id(run: Run(context)) -> String {
  run.id
}

/// Opens the sub-agent run `id`, a descendant of `run`, with `run`'s agent
/// and context: its snapshot, reconciling its uncertain effects, answering
/// or cancelling it. Its end still reaches its parent.
pub fn child(
  run: Run(context),
  id: String,
) -> Result(Run(context), RecordError) {
  family.locate(run.setup, run.id, id)
  |> result.map(fn(setup) { Run(id:, setup:) })
  |> result.map_error(record_error)
}

/// Blocks until the run is no longer `Working` (suspended or finished), or
/// until `within` milliseconds pass. It wakes on commits made through this
/// run's store and when a runner exits. A run whose sub-agents work is
/// working; one waiting only on paused sub-agents is suspended on their
/// approvals.
pub fn await(run: Run(context), within: Int) -> Result(Status, AwaitError) {
  let watcher = process.new_subject()
  let deadline = now() + within
  let monitor = process.monitor(store.pid(run.setup.store))
  let outcome = wait(run, watcher, monitor, [], deadline)
  process.demonitor_process(monitor)
  outcome
}

fn wait(
  run: Run(context),
  watcher: process.Subject(Nil),
  monitor: process.Monitor,
  watched: List(String),
  deadline: Int,
) -> Result(Status, AwaitError) {
  let done = fn(outcome) {
    list.each(watched, store.unwatch(run.setup.store, _, watcher))
    outcome
  }
  case family.load(run.setup.store, run.id) {
    Error(problem) -> done(Error(AwaitUnreadable(record_error(problem))))
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
        Error(error), _, _ -> done(Error(AwaitUnreadable(StoreFailed(error))))
        Ok(Nil), [_, ..], _ ->
          wait(run, watcher, monitor, list.append(watched, fresh), deadline)
        Ok(Nil), [], family.View(run.Working, False) ->
          case family.load(run.setup.store, run.id) {
            Ok(again) if again == node -> done(Error(NoRunner))
            _ -> wait(run, watcher, monitor, watched, deadline)
          }
        Ok(Nil), [], family.View(run.Working, True) -> {
          let woken =
            process.new_selector()
            |> process.select_map(watcher, Ok)
            |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
            |> process.selector_receive(int.max(0, deadline - now()))
          case woken {
            Error(Nil) -> done(Error(StillWorking))
            Ok(Error(Nil)) ->
              done(
                Error(
                  AwaitUnreadable(
                    StoreFailed(store.Unavailable("the store is closed")),
                  ),
                ),
              )
            Ok(Ok(Nil)) -> wait(run, watcher, monitor, watched, deadline)
          }
        }
        Ok(Nil), [], family.View(status, _) -> done(Ok(status))
      }
    }
  }
}

/// The status of the run and its sub-agents (see `await`).
pub fn status(run: Run(context)) -> Result(Status, RecordError) {
  family.load(run.setup.store, run.id)
  |> result.map(fn(node) { family.view(node).status })
  |> result.map_error(record_error)
}

/// The run's own record; `status` covers its sub-agents too.
pub fn snapshot(run: Run(context)) -> Result(Snapshot, RecordError) {
  use node <- result.map(
    family.load(run.setup.store, run.id) |> result.map_error(record_error),
  )
  run.Snapshot(
    ..controller.snapshot(node.state),
    status: family.view(node).status,
  )
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

/// Answers an approval request of the run or of one of its sub-agents (the
/// reference names the run). `context` is the application's current
/// context: the policy is checked again with it, and a current denial or
/// policy failure wins over an approval. The approved action runs with
/// exactly this context, whether or not a runner was live: the tool body
/// receives it, and an approved sub-agent start starts the child run with
/// it. It does not become the run's context: the run's other actions keep
/// the context it was started or recovered with. If the run's runner is
/// lost before the approved action starts, recovery asks again (see
/// `recover`).
///
/// Works with no process holding the run: the answer is committed to the
/// stored record with compare-and-set, so of concurrent answers exactly one
/// wins and the others get `AlreadyAnswered` (or `RunEnded` after a cancel).
/// The caller then emits the commit's events before `answer` returns (see
/// `fabric/observation`); the approved work has already started.
///
/// An answer to a sub-agent run whose ancestor is stopping or has ended is
/// refused with `RunEnded`, even if the sub-agent's own cancellation has
/// not been committed yet.
///
/// `reviewer` is recorded with the answer as given. Fabric does not
/// authenticate it: the application must authenticate and authorize whoever
/// answers before calling this.
pub fn answer(
  run: Run(context),
  reference: ApprovalRef,
  answer: Answer,
  reviewer reviewer: Option(String),
  context context: context,
) -> Result(Status, CommandError) {
  use target <- result.try(case reference.run == run.id {
    True -> Ok(run.setup)
    False ->
      case family.locate(run.setup, run.id, reference.run) {
        Ok(setup) -> Ok(setup)
        Error(runner.NotFound) -> Error(WrongReference)
        Error(problem) -> Error(Unreadable(record_error(problem)))
      }
  })
  use Nil <- result.try(open_to_commands(run, reference.run))
  let recheck = controller.Env(..target.env, context:)
  use state <- result.try(
    runner.command(
      target,
      reference.run,
      recheck,
      controller.Answer(reference, answer, reviewer),
      retries,
    )
    |> result.map_error(command_error),
  )
  let reissued =
    list.find(family.own_pending(state), fn(pending) {
      pending.reference.id == reference.id
      && pending.reference.revision != reference.revision
    })
  case reissued, reference.run == run.id {
    Ok(pending), _ -> Error(RequirementChanged(pending))
    Error(Nil), True -> Ok(status_after(run, state))
    Error(Nil), False -> status(run) |> result.map_error(Unreadable)
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
/// uncertain effects.
pub fn cancel(run: Run(context)) -> Result(Status, CommandError) {
  runner.command(run.setup, run.id, run.setup.env, controller.Cancel, retries)
  |> result.map(status_after(run, _))
  |> result.map_error(command_error)
}

/// Cancels the stored run `id` with no agent: for a run that cannot be
/// recovered because its agent changed (another identity, or a pending tool
/// that no longer exists). Cancelling a sub-agent run this way does not
/// apply its end to its parent, which needs its agent to map it: `recover`
/// the parent to apply it (`await` on the parent reports `NoRunner` until
/// then). A run whose runner is live in this store is cancelled through
/// that runner, as `cancel` would, which must take it within
/// `agent.default_command_timeout` (there is no agent to configure it);
/// otherwise the work of
/// a lost runner is abandoned (running tools become uncertain effects) and
/// the run ends `Cancelled` in one commit. Active sub-agent runs are
/// cancelled first, the same way; their delegations are recorded as
/// uncertain effects, since no agent maps their outcome. A sub-agent run
/// that was never stored is stored as cancelled before it started (naming
/// no agent), and its delegation is recorded as not started.
pub fn cancel_stored(store: Store, id: String) -> Result(Status, CommandError) {
  runner.cancel_unattended(store, id, agent.default_command_timeout, retries)
  |> result.map(controller.status)
  |> result.map_error(command_error)
}

/// Records what actually happened for an uncertain effect of this run (for
/// a sub-agent's, use its handle: `child`). `content` is what the model
/// will see as that call's result. When nothing else is pending the run
/// continues with its next model turn. Reconciliation does not consume a
/// turn.
pub fn reconcile(
  run: Run(context),
  action: ActionId,
  content: String,
) -> Result(Status, CommandError) {
  use Nil <- result.try(open_to_commands(run, run.id))
  runner.command(
    run.setup,
    run.id,
    run.setup.env,
    controller.Reconcile(action, content),
    retries,
  )
  |> result.map(status_after(run, _))
  |> result.map_error(command_error)
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
  case store.get(run.setup.store, run.id) {
    Ok(entry) ->
      family.view(family.with_children(run.setup.store, run.id, entry, state)).status
    Error(_) -> controller.status(state)
  }
}

fn command_error(failure: runner.Failure) -> CommandError {
  case failure {
    runner.CommandRefused(rejection) -> refusal(rejection)
    runner.OwnerUnknown -> OwnerUnknown
    runner.Contended -> Contended
    runner.Busy -> RunnerBusy
    runner.Unreadable(problem) -> Unreadable(record_error(problem))
  }
}

fn refusal(rejection: controller.Rejection) -> CommandError {
  case rejection {
    controller.RunEnded -> RunEnded
    controller.UnknownAction(id) | controller.ReportNotExpected(id) ->
      UnknownAction(id)
    controller.NotReconcilable(id) -> NotReconcilable(id)
    controller.StaleEvent -> WrongPhase
    controller.WrongReference -> WrongReference
    controller.StaleReference -> StaleReference
    controller.AlreadyAnswered -> AlreadyAnswered
    controller.SettlementNotAwaited(id)
    | controller.SettlementEarly(id)
    | controller.SettlementRecorded(id) -> NotReconcilable(id)
  }
}

fn record_error(problem: runner.ReadError) -> RecordError {
  case problem {
    runner.NotFound -> RunNotFound
    runner.StoreFailed(error) -> StoreFailed(error)
    runner.UnsupportedVersion(found) -> UnsupportedVersion(found)
    runner.Corrupt(detail) -> CorruptRecord(detail)
    runner.Incompatible(problems) -> IncompatibleAgent(problems)
  }
}

@external(erlang, "fabric_ffi", "random_id")
fn random_id() -> String

@external(erlang, "fabric_ffi", "now_ms")
fn now() -> Int

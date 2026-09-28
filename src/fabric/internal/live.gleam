//// The messages a live runner accepts. Kept apart from the runner so that
//// the store can name a runner's mailbox without depending on the runner.

import fabric/internal/claim.{type Claim}
import fabric/internal/controller.{type Effect, type Rejection, type State}
import fabric/internal/executor
import fabric/internal/invocation
import fabric/model.{type ModelError, type Reply, type ToolCall}
import fabric/run.{type ActionId}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option}

/// The work a committed transition starts, bound to the context it runs
/// with: how a dispatched tool's body is invoked (run id, action, call),
/// and how a delegation's child run (`parent` state, action, child run id,
/// call) is started, returning the event that reports the start.
pub type Work {
  Work(
    invoke: fn(String, ActionId, ToolCall) -> invocation.Outcome,
    start_child: fn(State, ActionId, String, ToolCall) -> controller.Event,
  )
}

pub type Message {
  /// A command from outside. A runner that takes it (`claim.accept`)
  /// answers `Accepted`, applies `step` to its current state, commits the
  /// result, answers, and then performs its effects with `work` (`None`:
  /// the run's own). A runner that cannot take it drops it: the caller has
  /// withdrawn it.
  Command(
    step: fn(State) -> Result(#(State, List(Effect)), Rejection),
    work: Option(Work),
    claim: Claim,
    reply: Subject(CommandReply),
  )
  ModelDone(turn: Int, result: Result(Reply, ModelError))
  /// The fence: a tool task asks to start an action's body.
  Fence(ActionId, reply: Subject(Bool))
  Executed(executor.Report)
  /// A linked process (the model task or the executor) exited.
  Exited(pid: Pid, reason: process.ExitReason)
  /// An event the runner reports to itself after performing an effect (a
  /// child run was started).
  Apply(controller.Event)
  StoreDown
}

pub type CommandReply {
  /// The runner took the command in time; its outcome follows.
  Accepted
  /// The step was committed; this is the committed state.
  Applied(State)
  Refused(Rejection)
  /// The runner's commit lost to a newer owner; it has stopped. Read the
  /// record again.
  Superseded
}

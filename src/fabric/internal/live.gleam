//// The messages a live runner accepts. Kept apart from the runner so that
//// the store can name a runner's mailbox without depending on the runner.

import fabric/internal/controller.{type Effect, type Rejection, type State}
import fabric/internal/executor
import fabric/internal/invocation
import fabric/model.{type ModelError, type Reply, type ToolCall}
import fabric/policy.{type ActionId}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option}

/// The work a committed transition starts, bound to the context it runs
/// with: how a dispatched tool's body is invoked, and how a delegation's
/// child run (`parent` state, action, child run id, call) is started.
pub type Work {
  Work(
    invoke: fn(ToolCall) -> invocation.Outcome,
    start_child: fn(State, ActionId, String, ToolCall) -> Result(Nil, String),
  )
}

pub type Message {
  /// A command from outside: the runner applies `step` to its current
  /// state, commits the result, performs its effects with `work` (`None`:
  /// the run's own), and answers.
  Command(
    step: fn(State) -> Result(#(State, List(Effect)), Rejection),
    work: Option(Work),
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
  /// The step was committed; this is the committed state.
  Applied(State)
  Refused(Rejection)
  /// The runner's commit lost to a newer owner; it has stopped. Read the
  /// record again.
  Superseded
}

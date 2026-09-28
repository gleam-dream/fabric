//// The messages a live runner accepts. Kept apart from the runner so that
//// the store can name a runner's mailbox without depending on the runner.

import fabric/internal/controller.{type Effect, type Rejection, type State}
import fabric/internal/executor
import fabric/model.{type ModelError, type Reply}
import fabric/policy.{type ActionId}
import gleam/erlang/process.{type Pid, type Subject}

pub type Message {
  /// A command from outside: the runner applies `step` to its current
  /// state, commits the result, and answers.
  Command(
    step: fn(State) -> Result(#(State, List(Effect)), Rejection),
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

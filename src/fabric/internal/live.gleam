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
import sinal/correlation.{type Correlation}

/// The work a committed transition starts, bound to the context it runs
/// with: the body a dispatched tool's task runs (prepared in the runner from
/// run id, its family's root run id, the run's correlation, action, call;
/// it holds that one tool, never the agent, since it is copied into the
/// executor and the task),
/// and how a delegation's child run (`parent` state, action, child run id,
/// call) is started, returning the event that reports the start.
pub type Work {
  Work(
    invoke: fn(String, String, Correlation, ActionId, ToolCall) ->
      fn() -> invocation.Outcome,
    start_child: fn(State, ActionId, String, ToolCall) ->
      Result(controller.Event, String),
  )
}

pub type Message {
  /// A command from outside. A runner that takes it (`claim.accept`)
  /// answers `Accepted`, applies `step` to its current state, commits the
  /// result, answers, and then performs its effects with the work the step
  /// returned (`None`: the run's own). The step makes that work in the
  /// runner, so the command copies only what makes them (an agent's
  /// builder, `runner.carried`). A runner that cannot take it drops it: the
  /// caller has withdrawn it.
  Command(
    step: fn(State) -> Result(#(State, List(Effect), Option(Work)), Rejection),
    claim: Claim,
    reply: Subject(CommandReply),
  )
  ModelDone(turn: Int, result: Result(Reply, ModelError))
  /// Storage could not grant capacity. Leave the committed work for recovery.
  CapacityUnavailable(String)
  /// The fence: a tool task asks to start an action's body.
  Fence(ActionId, reply: Subject(Bool))
  Executed(executor.Report(ActionId, invocation.Outcome))
  /// A linked process (the model task or the executor) exited.
  Exited(pid: Pid, reason: process.ExitReason)
  /// An event the runner reports to itself after performing an effect (a
  /// child run was started).
  Apply(controller.Event)
  /// A leased parent checks durable child results from other nodes.
  PollChildren
  ChildrenRead(List(#(ActionId, controller.ChildResult)))
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

//// Frozen v2 types from Git 570502e928496b0203909f164a5e8fd021b8ddc8.
//// See README.md in this directory; do not adapt to current domain types.

import fabric/support/v2/model.{type Message}
import fabric/support/v2/run.{
  type ActionRecord, type HostFailure, type Identity, type Outcome,
  type TokenUsage,
}
import gleam/option.{type Option}

pub type Limits {
  Limits(
    max_turns: Int,
    token_budget: Option(Int),
    max_children: Int,
    max_depth: Int,
  )
}

pub type StopReason {
  CancelRequested
  HostFault(HostFailure)
}

pub type Phase {
  /// Model attempt `turn` is in flight.
  AwaitingModel(turn: Int)
  /// The tool batch requested by the reply to `turn`.
  Acting(turn: Int, actions: List(ActionRecord))
  /// Waiting for the executor to confirm that no tool of the batch runs
  /// (`tools_stopped`), for the late settlements of stopped tools, and for
  /// every child run of the batch to end. Once `tools_stopped`, a tool
  /// action still `Running` is a stopped tool awaiting its settlement.
  Stopping(
    turn: Int,
    actions: List(ActionRecord),
    reason: StopReason,
    tools_stopped: Bool,
  )
  Ended(Outcome)
}

pub type State {
  State(
    run: String,
    agent: Identity,
    /// Increases by one each time a lost runner's work is taken over.
    incarnation: Int,
    /// The action that started this run, for a sub-agent run.
    parent: Option(run.Parent),
    /// Levels below the root run: 0 for a root run.
    depth: Int,
    limits: Limits,
    turns_used: Int,
    usage: TokenUsage,
    transcript: List(Message),
    /// Actions of earlier batches, oldest first.
    history: List(ActionRecord),
    approvals_issued: Int,
    phase: Phase,
  )
}

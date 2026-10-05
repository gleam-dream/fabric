//// Typed graph runner messages, separate from the runner so the shared store
//// can retain its endpoint without depending on execution code.

import fabric/graph/definition
import fabric/graph/job
import fabric/internal/claim
import fabric/internal/executor
import fabric/internal/graph/child_driver
import fabric/internal/graph/controller as g
import fabric/internal/graph/fork_driver
import fabric/policy
import gleam/erlang/process.{type Pid, type Subject}

pub type Body =
  fn() -> Result(String, definition.Error)

pub type Admission {
  Admission(decision: policy.Decision, body: Body)
}

/// Keep one environment while crossing process boundaries. Construct individual
/// callbacks inside the worker so descendant definitions are not copied once
/// for every callback in the table.
pub type Work =
  fn() -> Callbacks

pub type Callbacks {
  Work(
    admit: fn(g.State, g.Activation) -> Result(Admission, String),
    accept: fn(g.State, g.Activation, String) ->
      Result(g.Decision, definition.Error),
    check_output: fn(g.Activation, String) -> Result(Nil, definition.Error),
    observe_job: fn(g.State, g.Activation) ->
      Result(job.Progress(String), definition.Error),
    cancel_job: fn(g.State, g.Activation) -> Body,
    validate: fn(g.State) -> Result(Nil, definition.Error),
    child: fn(g.Activation) -> Result(child_driver.Driver, definition.Error),
    fork: fn(g.Activation) -> Result(fork_driver.Driver, definition.Error),
  )
}

pub type Execution {
  Returned(Result(String, definition.Error))
  Interrupted(String)
}

pub type Message {
  PollChild
  PollFork
  Fence(g.Reference, Subject(Bool))
  Executed(executor.Report(g.Reference, Execution))
  Cancel(claim.Claim, Subject(Reply))
  Exited(Pid, process.ExitReason)
  StoreDown
}

pub type Reply {
  Accepted
  Applied(g.State)
  Refused(g.Rejection)
  Superseded
}

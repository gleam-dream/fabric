//// Deployed child commands are never serialized. Each acts on a reserved
//// identity and is bounded separately from the parent's activity executor.

import fabric/graph/child
import gleam/erlang/process.{type Pid}

pub type Reservation {
  Start
  /// Recover existing work without rewriting unchanged, unclaimed waits.
  Discover
  Cancel
}

pub type Observation {
  Observe
  /// Cancellation observes the retained outcome without interpreting a
  /// business reply through application callbacks.
  Settle
}

pub type Driver {
  Driver(
    store: fn() -> Result(Pid, Nil),
    reserve: fn(child.Parent, String, String, Reservation) ->
      Result(Nil, String),
    read: fn(child.Parent, String, Observation) ->
      Result(child.Progress, String),
  )
}

//// Deployed child commands are never serialized. Each acts on a reserved
//// identity and is bounded separately from the parent's activity executor.

import fabric/graph/child
import gleam/erlang/process.{type Pid}

pub type Reservation {
  Start
  Cancel
}

pub type Driver {
  Driver(
    store: fn() -> Result(Pid, Nil),
    reserve: fn(child.Parent, String, String, Reservation) ->
      Result(Nil, String),
    read: fn(child.Parent, String) -> Result(child.Progress, String),
  )
}

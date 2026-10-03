//// Several nodes in one VM: leased stores of distinct node ids over one
//// shared in-memory leased backend, whose clock the test moves.

import fabric/run.{type RunId}
import fabric/store.{type LeasedBackend, type Store}
import fabric/support
import gleam/erlang/process
import gleam/string
import gleam/time/duration

/// A lease long enough that no renewal falls within a test: the backend's
/// clock is moved past it instead.
pub const long = 60_000

/// A leased store of `node` over `backend`, started and linked to the
/// caller.
pub fn node(backend: LeasedBackend, node: String, lease: Int) -> Store {
  let assert Ok(leased) =
    store.leased(
      process.new_name("fabric-test-node"),
      node:,
      lease: duration.milliseconds(lease),
      backend:,
    )
  support.started(leased)
}

/// The run's lease as the backend has it.
pub fn holder(backend: LeasedBackend, id: RunId) -> store.Holder {
  let assert Ok(current) = backend.get(run.id_to_string(id))
  current.holder
}

/// The node whose store holds the run's lease, and whether it is live;
/// `Error` when it is free.
pub fn holding(
  backend: LeasedBackend,
  id: RunId,
) -> Result(#(String, Bool), Nil) {
  case holder(backend, id) {
    store.Held(owner, live) ->
      case string.split_once(owner, "/") {
        Ok(#(node, _)) -> Ok(#(node, live))
        Error(Nil) -> Ok(#(owner, live))
      }
    store.Free -> Error(Nil)
  }
}

/// The run's revision in the backend.
pub fn revision(backend: LeasedBackend, id: RunId) -> Int {
  let assert Ok(current) = backend.get(run.id_to_string(id))
  current.revision
}

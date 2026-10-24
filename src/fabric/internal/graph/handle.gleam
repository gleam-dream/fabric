//// The representation behind `fabric/graph.Handle`: a run id with the
//// runtime it was opened with, and that runtime's store, which
//// `fabric/graph/agent` compares when it attaches a child. It is generic
//// over the runtime so that `fabric/graph` can define it and still alias
//// this type.

import fabric/internal/store.{type Store}
import fabric/run

pub opaque type Handle(runtime) {
  Handle(runtime: runtime, id: run.RunId, store: Store)
}

pub fn new(runtime: runtime, id: run.RunId, store: Store) -> Handle(runtime) {
  Handle(runtime:, id:, store:)
}

pub fn runtime(handle: Handle(runtime)) -> runtime {
  handle.runtime
}

pub fn id(handle: Handle(runtime)) -> run.RunId {
  handle.id
}

pub fn store(handle: Handle(runtime)) -> Store {
  handle.store
}

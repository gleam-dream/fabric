//// Shorthands that keep the tests about behaviour rather than set-up.

import fabric/agent.{type Agent, type Spec}
import fabric/run.{type RunId}
import fabric/store.{type Store}
import gleam/erlang/process
import gleam/int

/// The run id `text`, which must have the shape Fabric issues.
pub fn id(text: String) -> RunId {
  let assert Ok(id) = run.parse_id(text)
  id
}

/// The text of a run id, for backend-level instruments that key by it.
pub fn text(id: RunId) -> String {
  run.id_to_string(id)
}

/// The id of the `n`th sub-agent run that `parent` starts.
pub fn child_id(parent: RunId, n: Int) -> RunId {
  id(run.id_to_string(parent) <> "-" <> int.to_string(n))
}

/// The agent `spec` describes, which must be valid.
pub fn agent(spec: Spec(context)) -> Agent(context) {
  let assert Ok(agent) = agent.build(spec)
  agent
}

/// A started in-memory store, linked to the caller.
pub fn store() -> Store {
  started(store.in_memory(process.new_name("fabric-test-store")))
}

/// A started directory store over `path`, linked to the caller.
pub fn directory(path: String) -> Store {
  started(store.directory(process.new_name("fabric-test-store"), path))
}

/// `store`, started and linked to the caller.
pub fn started(store: Store) -> Store {
  let assert Ok(Nil) = store.start(store)
  store
}

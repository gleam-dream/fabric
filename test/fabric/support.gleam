//// Shorthands that keep the tests about behaviour rather than set-up.

import fabric/agent.{type Agent, type Spec}
import fabric/run.{type RunId}
import fabric/store.{type Store}
import fabric/store/conformance
import gleam/erlang/process
import gleam/int
import gleam/time/duration

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

/// A started in-memory store, linked to the caller. Within `leased`, a
/// leased store over its own in-memory leased backend instead.
pub fn store() -> Store {
  case leasing() {
    False -> started(store.in_memory(process.new_name("fabric-test-store")))
    True -> started(leased_store())
  }
}

fn leased_store() -> Store {
  let assert Ok(leased) =
    store.leased(
      process.new_name("fabric-test-store"),
      node: "fabric-test",
      lease: duration.milliseconds(1500),
      backend: conformance.leased_memory().backend,
    )
  leased
}

/// Runs `body` with `store` making leased stores, in the calling process
/// only: a test written for an in-memory store runs on a leased one.
pub fn leased(body: fn() -> a) -> Nil {
  set_leasing(True)
  let _ = body()
  set_leasing(False)
}

@external(erlang, "fabric_test_ffi", "leasing")
fn leasing() -> Bool

@external(erlang, "fabric_test_ffi", "set_leasing")
fn set_leasing(leasing: Bool) -> Nil

/// A started directory store over `path`, linked to the caller.
pub fn directory(path: String) -> Store {
  started(store.directory(process.new_name("fabric-test-store"), path))
}

/// `store`, started and linked to the caller.
pub fn started(store: Store) -> Store {
  let assert Ok(Nil) = store.start(store)
  store
}

/// An unstarted store whose records survive its subtree: files by default,
/// or a leased backend owned by the test process within `leased`.
pub fn restartable_store(path: String) -> Store {
  case leasing() {
    False -> store.directory(process.new_name("fabric-test-store"), path)
    True -> leased_store()
  }
}

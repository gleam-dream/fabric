//// Shorthands that keep the tests about behaviour rather than set-up.

import fabric/agent.{type Agent, type Spec}
import fabric/budget
import fabric/graph
import fabric/graph/definition
import fabric/graph/job
import fabric/graph/operation
import fabric/internal/graph/runtime as graph_runtime
import fabric/policy
import fabric/reviewer.{type Reviewer}
import fabric/run.{type ActionId, type DefinitionId, type RunId}
import fabric/store.{type Store}
import fabric/store/conformance
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/time/duration

/// The run id `text`, which must have the shape Fabric issues.
pub fn id(text: String) -> RunId {
  let assert Ok(id) = run.parse_id(text)
  id
}

/// The reviewer `subject`, which must be valid.
pub fn reviewer(subject: String) -> Reviewer {
  let assert Ok(reviewer) = reviewer.new(subject)
  reviewer
}

/// The graph run `id` opened under `runtime`, which must fit it.
pub fn open_graph(
  runtime: graph.Runtime(context, state, answer),
  id: RunId,
) -> graph.Handle(context, state, answer) {
  let assert Ok(handle) = graph.open(runtime, id)
  handle
}

/// `runtime` with a family budget, for a test that builds its runtime in a
/// helper: `graph.with_family_budget` sets one on a spec, before
/// `graph.build`.
pub fn budgeted(
  runtime: graph.Runtime(context, state, answer),
  limits: budget.Limits,
) -> graph.Runtime(context, state, answer) {
  graph_runtime.with_family_budget(runtime, limits)
}

/// The id of an agent action the policy sees.
pub fn action_id(action: policy.Action) -> ActionId {
  let assert policy.ToolCall(id) = action.step
  id
}

/// The node of a graph action the policy sees.
pub fn node(action: policy.Action) -> String {
  let assert policy.RunOperation(node:, ..) = action.target
  node
}

/// The operation of a graph action the policy sees.
pub fn operation(action: policy.Action) -> DefinitionId {
  let assert policy.RunOperation(operation:, ..) = action.target
  operation
}

/// The operation kind of a graph action the policy sees.
pub fn kind(action: policy.Action) -> policy.OperationKind {
  let assert policy.RunOperation(kind:, ..) = action.target
  kind
}

/// What `definition.build` refuses about `op`'s settings.
pub fn operation_problems(
  op: operation.Operation(context, input, output),
) -> List(operation.ConfigurationError) {
  let id = definition.node_id("probe")
  let node =
    definition.node(
      id,
      op,
      fn(state) { Ok(state) },
      fn(state, _) { Ok(definition.Finish(state, state)) },
      [],
    )
  let codec = operation.input_codec(op)
  case
    definition.build(definition.new(
      run.DefinitionId("probe", 1),
      entry: id,
      nodes: [node],
      state: codec,
      answer: codec,
    ))
  {
    Ok(_) -> []
    Error(problems) ->
      list.filter_map(problems, fn(problem) {
        case problem {
          definition.InvalidOperation(_, problem) -> Ok(problem)
          _ -> Error(Nil)
        }
      })
  }
}

/// What `definition.build` refuses about a job wait on `observer`.
pub fn observer_problems(
  observer: job.Observer(context, receipt, output),
) -> List(operation.ConfigurationError) {
  operation_problems(operation.await_job(observer))
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
pub fn agent(spec: Spec(context, answer)) -> Agent(context, answer) {
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

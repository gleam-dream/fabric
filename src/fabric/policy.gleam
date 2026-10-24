//// The action-authorization gate, one for agent and graph runs.
////
//// A `Policy(context)` is supplied by the application and runs before any
//// effect. It sees one `Action` at a time: its run, where it comes from
//// (`step`: a tool call of an agent's model turn, or an attempt of a graph
//// node's activation), what it calls (`name`), the exact arguments (already
//// validated against the input codec), and what it does once allowed
//// (`target`). It allows the action, denies it with a reason, or requires
//// an approval. An `Error` is a policy failure: an agent run stops as a
//// host failure, a graph run fails, and nothing is allowed by default.
////
//// ```gleam
//// fn policy(user: User, action: policy.Action) {
////   case action.target {
////     policy.RunOperation(kind: policy.Signal, ..) -> Ok(policy.Allow)
////     _ -> {
////       use refund <- result.try(tool.input(refund_definition, action))
////       case refund {
////         Some(Refund(amount:)) if amount > 100 ->
////           Ok(policy.RequireApproval(run.Requirement("manager", 1)))
////         _ -> Ok(policy.Allow)
////       }
////     }
////   }
//// }
//// ```

import fabric/run.{
  type ActionId, type DefinitionId, type Requirement, type RunId,
}

/// One action to authorize. Read it by label: Fabric may add fields.
///
/// `name` is what the action calls: the tool's name for an agent's tool
/// call or delegation, the operation's name for a graph node. For a graph
/// node, `arguments_json` is the operation's encoded input.
pub type Action {
  Action(
    run: RunId,
    step: Step,
    name: String,
    arguments_json: String,
    target: Target,
  )
}

/// Where an action comes from.
pub type Step {
  /// A call in an agent's model reply; `id` names it within its run.
  ToolCall(id: ActionId)
  /// Attempt `attempt` (from 1) of activation `activation` of a graph run.
  /// A recovered activation that replays its operation is a new attempt.
  Activation(activation: Int, attempt: Int)
}

/// What an action does when it is allowed.
pub type Target {
  /// An agent's tool runs.
  InvokeTool
  /// A sub-agent run starts: the agent definition named `name` and
  /// `version`, reached through the delegation `Action.name`.
  StartAgent(name: String, version: Int)
  /// The operation of the graph node `node` runs (an activity), or its wait
  /// starts: a signal, a job, a child run or a fork.
  RunOperation(node: String, operation: DefinitionId, kind: OperationKind)
}

/// The kind of a graph node's operation (see `fabric/graph/operation`).
/// This union may grow: keep a catch-all.
pub type OperationKind {
  /// A body runs, bounded by the runtime's operation timeout.
  Activity
  /// The run waits for a signal (`operation.await_signal`).
  Signal
  /// The run waits for a job it observes (`operation.await_job`).
  Job
  /// The run waits for a job it owns and may stop (`operation.own_job`).
  OwnedJob
  /// A child graph run starts (`graph.as_subgraph`).
  Subgraph
  /// A child agent run starts (`fabric/graph/agent`).
  Agent
  /// Child graph runs start together (`graph.both`, `graph.map`).
  Fork
}

pub type Decision {
  Allow
  /// An agent's model sees `reason` and its run continues; a graph run
  /// fails with `graph.Denied(reason)`.
  Deny(reason: String)
  /// The action waits for an approval. A run whose remaining work is only
  /// waiting approvals suspends as stored data.
  RequireApproval(Requirement)
}

pub type Policy(context) =
  fn(context, Action) -> Result(Decision, String)

/// Allows every action. Use it deliberately: it is the only policy without a
/// decision of the application's own.
pub fn always_allow() -> Policy(context) {
  fn(_, _) { Ok(Allow) }
}

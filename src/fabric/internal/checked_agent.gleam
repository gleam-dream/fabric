//// The checked agent behind `fabric/agent.Agent`: every bound in
//// milliseconds, the tool registry and the checked sub-agents.

import fabric/budget
import fabric/internal/registry.{type Registry}
import fabric/model.{type Model}
import fabric/policy.{type Policy}
import fabric/run.{type DefinitionId}
import gleam/dict.{type Dict}
import gleam/option.{type Option}

/// A checked agent. Only `fabric/agent.build` makes one.
pub opaque type Agent(context) {
  Agent(admitted: Admitted(context))
}

pub fn new(admitted: Admitted(context)) -> Agent(context) {
  Agent(admitted)
}

pub fn admitted(agent: Agent(context)) -> Admitted(context) {
  agent.admitted
}

/// A validated agent, ready for the runtime.
pub type Admitted(context) {
  Admitted(
    identity: DefinitionId,
    model: Model,
    registry: Registry(context),
    policy: Policy(context),
    system_prompt: Option(String),
    max_turns: Int,
    max_concurrency: Int,
    token_budget: Option(Int),
    /// Milliseconds, like every bound below.
    policy_timeout: Int,
    model_retry_delay: Int,
    command_timeout: Int,
    /// `None`: unbounded.
    model_timeout: Option(Int),
    tool_timeout: Option(Int),
    max_result_bytes: Int,
    /// The deadline of an approval request after it is issued; `None`:
    /// never.
    approval_expiry: Option(Int),
    /// The family budget a root run of this agent declares.
    family_budget: Option(budget.Limits),
    /// The admitted sub-agent of each delegation, by delegation name.
    children: Dict(String, Admitted(context)),
    max_children: Int,
    max_depth: Int,
  )
}

//// The checked agent behind `fabric/agent.Agent`: every bound in
//// milliseconds, the tool registry, the checked sub-agents and the answer.
//// The runtime works with `Admitted`, whose answer is its stored text; the
//// typed answer is read at the facade.

import fabric/budget
import fabric/internal/answer.{type Answer}
import fabric/internal/answerer.{type Answerer}
import fabric/internal/registry.{type Registry}
import fabric/model.{type Model}
import fabric/policy.{type Policy}
import fabric/run.{type DefinitionId}
import gleam/dict.{type Dict}
import gleam/option.{type Option}
import json/blueprint/codec

/// A checked agent. Only `fabric/agent.build` makes one.
pub opaque type Agent(context, answer) {
  Agent(admitted: Admitted(context), answer: Answer(answer))
}

pub fn new(
  admitted: Admitted(context),
  answer: Answer(answer),
) -> Agent(context, answer) {
  Agent(admitted, answer)
}

pub fn admitted(agent: Agent(context, answer)) -> Admitted(context) {
  agent.admitted
}

pub fn answer(agent: Agent(context, answer)) -> Answer(answer) {
  agent.answer
}

/// A validated agent, ready for the runtime.
pub type Admitted(context) {
  Admitted(
    identity: DefinitionId,
    model: Model,
    registry: Registry(context),
    policy: Policy(context),
    system_prompt: Option(String),
    /// The schema of the final answer given to the model; `None` for text.
    answer_schema: Option(codec.Schema),
    /// The check a final answer passes before the run commits it.
    check_answer: fn(String) -> Result(Nil, String),
    /// How many final answers a run asks for in all
    /// (`agent.with_answer_attempts`).
    answer_attempts: Int,
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
    /// Who may answer the agent's approval requests
    /// (`agent.with_approvers`).
    approvers: Option(Answerer),
    /// The admitted sub-agent of each delegation, by delegation name.
    children: Dict(String, Admitted(context)),
    max_children: Int,
    max_depth: Int,
  )
}

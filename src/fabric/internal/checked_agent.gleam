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
import gleam/int
import gleam/option.{type Option, None, Some}
import json/blueprint/codec

/// A checked agent. Only `fabric/agent.build` and `build_with` make one.
pub opaque type Agent(context, answer) {
  /// A built agent; `builder` builds it again in another process when it
  /// was built from a builder (`built`).
  Agent(
    admitted: Admitted(context),
    answer: Answer(answer),
    builder: Option(fn() -> Admitted(context)),
  )
  /// An agent kept as its builder (`agent.build_with`), checked once when
  /// it was made: it is built in each process that uses it, so that only
  /// the builder is ever copied between processes. `identity` is what the
  /// first build was.
  Deferred(
    identity: DefinitionId,
    build: fn() -> #(Admitted(context), Answer(answer)),
  )
}

pub fn new(
  admitted: Admitted(context),
  answer: Answer(answer),
) -> Agent(context, answer) {
  Agent(admitted, answer, None)
}

/// An agent that `build` makes wherever it is used; the first build was
/// `identity`.
pub fn deferred(
  identity: DefinitionId,
  build: fn() -> #(Admitted(context), Answer(answer)),
) -> Agent(context, answer) {
  Deferred(identity, build)
}

/// The agent built: itself, or what its builder builds now, which must be
/// the agent it built first (a builder is deterministic). Build once with
/// this where several parts of an agent are read; it keeps the builder.
pub fn built(agent: Agent(context, answer)) -> Agent(context, answer) {
  case agent {
    Agent(..) -> agent
    Deferred(identity:, build:) -> {
      let #(made, answer) = build()
      case made.identity == identity {
        True -> Agent(made, answer, Some(fn() { admitted(agent) }))
        False ->
          panic as {
            "the agent's builder (agent.build_with) built "
            <> describe_identity(made.identity)
            <> " after building "
            <> describe_identity(identity)
            <> ": a builder must build the same agent every time"
          }
      }
    }
  }
}

fn describe_identity(identity: DefinitionId) -> String {
  identity.name <> " version " <> int.to_string(identity.version)
}

/// How another process builds this agent's admitted form, for an agent
/// kept as its builder; `None` for one built once.
pub fn builder(
  agent: Agent(context, answer),
) -> Option(fn() -> Admitted(context)) {
  case agent {
    Agent(builder:, ..) -> builder
    Deferred(..) -> Some(fn() { admitted(agent) })
  }
}

pub fn admitted(agent: Agent(context, answer)) -> Admitted(context) {
  let assert Agent(admitted:, ..) = built(agent)
  admitted
}

pub fn answer(agent: Agent(context, answer)) -> Answer(answer) {
  let assert Agent(answer:, ..) = built(agent)
  answer
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

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
import gleam/option.{type Option}
import json/blueprint/codec

/// A checked agent. Only `fabric/agent.build` makes one.
pub opaque type Agent(context, answer) {
  /// The agent built in this process; `builder` builds it again in
  /// another process (`built`).
  Agent(
    admitted: Admitted(context),
    answer: Answer(answer),
    builder: fn() -> Admitted(context),
  )
  /// An agent kept as its builder (`agent.build`), checked once when
  /// it was made: it is built in each process that uses it, so that only
  /// the builder is ever copied between processes. `facts` are what the
  /// first build was.
  Deferred(
    facts: Facts,
    build: fn() -> Result(#(Admitted(context), Answer(answer)), String),
  )
}

/// The few settings a caller reads without running the agent, kept by an
/// agent made from its builder so that reading them builds nothing.
pub type Facts {
  Facts(
    identity: DefinitionId,
    command_timeout: Int,
    max_turns: Int,
    token_budget: Option(Int),
    max_children: Int,
    max_depth: Int,
  )
}

/// The settings of `admitted` a caller reads without running it.
pub fn facts_of(admitted: Admitted(context)) -> Facts {
  Facts(
    identity: admitted.identity,
    command_timeout: admitted.command_timeout,
    max_turns: admitted.max_turns,
    token_budget: admitted.token_budget,
    max_children: admitted.max_children,
    max_depth: admitted.max_depth,
  )
}

/// `agent`'s settings, read without building it.
pub fn facts(agent: Agent(context, answer)) -> Facts {
  case agent {
    Agent(admitted:, ..) -> facts_of(admitted)
    Deferred(facts:, ..) -> facts
  }
}

/// An agent that `build` makes wherever it is used; the first build had
/// `facts`.
pub fn deferred(
  facts: Facts,
  build: fn() -> Result(#(Admitted(context), Answer(answer)), String),
) -> Agent(context, answer) {
  Deferred(facts, build)
}

/// The agent built: itself, or what its builder builds now, which must be
/// the agent it built first (a builder is deterministic); otherwise why it
/// is not. Build once with this where several parts of an agent are read;
/// it keeps the builder.
pub fn try_built(
  agent: Agent(context, answer),
) -> Result(Agent(context, answer), String) {
  case agent {
    Agent(..) -> Ok(agent)
    Deferred(facts: Facts(identity:, ..), build:) ->
      case rescue(build) {
        Error(crash) ->
          Error("the agent's builder (agent.build) crashed: " <> crash)
        Ok(Error(reason)) -> Error(reason)
        Ok(Ok(#(made, answer))) if made.identity == identity ->
          Ok(Agent(made, answer, fn() { admitted(agent) }))
        Ok(Ok(#(made, _))) ->
          Error(
            "the agent's builder (agent.build) built "
            <> describe_identity(made.identity)
            <> " after building "
            <> describe_identity(identity)
            <> ": a builder must build the same agent every time",
          )
      }
  }
}

/// `try_built`, crashing the process when the agent cannot be built: for a
/// process that is already running the agent's work (a runner's command,
/// a tool's task), where its first build in that process succeeded.
pub fn built(agent: Agent(context, answer)) -> Agent(context, answer) {
  case try_built(agent) {
    Ok(agent) -> agent
    Error(reason) -> panic as reason
  }
}

/// The name and version of `agent`, without building it.
pub fn identity(agent: Agent(context, answer)) -> DefinitionId {
  facts(agent).identity
}

@external(erlang, "fabric_ffi", "rescue")
fn rescue(body: fn() -> a) -> Result(a, String)

fn describe_identity(identity: DefinitionId) -> String {
  identity.name <> " version " <> int.to_string(identity.version)
}

/// How another process builds this agent's admitted form.
pub fn builder(agent: Agent(context, answer)) -> fn() -> Admitted(context) {
  case agent {
    Agent(builder:, ..) -> builder
    Deferred(..) -> fn() { admitted(agent) }
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

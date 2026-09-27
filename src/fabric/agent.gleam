//// Pure agent configuration.
////
//// Building an `Agent` starts nothing. `validate` reports every problem at
//// once; `fabric.start` validates again before it allocates a process.

import fabric/internal/registry.{type Registry}
import fabric/model.{type Model}
import fabric/policy.{type Policy}
import fabric/run.{type Identity, Identity}
import fabric/tool.{type Tool}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub opaque type Agent(context) {
  Agent(
    identity: Identity,
    model: Model,
    tools: List(Tool(context)),
    policy: Policy(context),
    system_prompt: Option(String),
    max_turns: Int,
    max_concurrency: Int,
    token_budget: Option(Int),
    policy_timeout: Int,
    model_retry_delay: Int,
  )
}

pub type ConfigError {
  DuplicateToolName(String)
  /// Providers accept tool names matching `^[a-zA-Z0-9_-]{1,64}$`.
  InvalidToolName(String)
  /// The tool's input codec has no JSON Schema to declare to the model.
  ToolSchemaUnavailable(String)
  MaxTurnsNotPositive(Int)
  MaxConcurrencyNotPositive(Int)
  TokenBudgetNotPositive(Int)
  PolicyTimeoutNotPositive(Int)
  ModelRetryDelayNegative(Int)
  /// The name is empty or the version is not positive.
  InvalidIdentity(name: String, version: Int)
}

pub const default_max_turns = 8

pub const default_max_concurrency = 4

pub const default_policy_timeout = 5000

pub const default_model_retry_delay = 200

pub const default_identity = Identity("agent", 1)

/// An agent with the given model, tools, and policy. The policy is required:
/// there is no implicit allow (`policy.always_allow()` is the explicit one).
pub fn new(
  model: Model,
  tools: List(Tool(context)),
  policy: Policy(context),
) -> Agent(context) {
  Agent(
    identity: default_identity,
    model:,
    tools:,
    policy:,
    system_prompt: None,
    max_turns: default_max_turns,
    max_concurrency: default_max_concurrency,
    token_budget: None,
    policy_timeout: default_policy_timeout,
    model_retry_delay: default_model_retry_delay,
  )
}

/// Names this agent definition. A stored run records the name and version
/// it started with and continues only under the same pair: change the
/// version when a change to the agent must not continue older runs.
pub fn with_identity(
  agent: Agent(context),
  name: String,
  version: Int,
) -> Agent(context) {
  Agent(..agent, identity: Identity(name, version))
}

pub fn with_system_prompt(
  agent: Agent(context),
  text: String,
) -> Agent(context) {
  Agent(..agent, system_prompt: Some(text))
}

/// Limits model attempts, counting the first request and every retry.
pub fn with_max_turns(agent: Agent(context), limit: Int) -> Agent(context) {
  Agent(..agent, max_turns: limit)
}

/// Limits how many tool bodies of one run execute at the same time.
pub fn with_max_concurrency(
  agent: Agent(context),
  limit: Int,
) -> Agent(context) {
  Agent(..agent, max_concurrency: limit)
}

/// Limits input plus output tokens as reported by the provider. A reply
/// without usage stops the run with `run.BudgetUnverifiable`.
pub fn with_token_budget(agent: Agent(context), tokens: Int) -> Agent(context) {
  Agent(..agent, token_budget: Some(tokens))
}

/// Bounds how long one policy decision may take, in milliseconds. A policy
/// that gives no decision in time has failed: the run stops closed. The
/// policy runs in its own process.
pub fn with_policy_timeout(
  agent: Agent(context),
  milliseconds: Int,
) -> Agent(context) {
  Agent(..agent, policy_timeout: milliseconds)
}

/// Sets the delay before the first retry of a retryable model failure, in
/// milliseconds (default 200). The delay doubles with each consecutive
/// retryable failure, up to 64 times this value, and every attempt still
/// counts against the turn limit. A cancelled run does not wait for it.
pub fn with_model_retry_delay(
  agent: Agent(context),
  milliseconds: Int,
) -> Agent(context) {
  Agent(..agent, model_retry_delay: milliseconds)
}

pub fn validate(agent: Agent(context)) -> Result(Nil, List(ConfigError)) {
  admit(agent) |> result.replace(Nil)
}

/// A validated agent, ready for the runtime.
@internal
pub type Admitted(context) {
  Admitted(
    identity: Identity,
    model: Model,
    registry: Registry(context),
    policy: Policy(context),
    system_prompt: Option(String),
    max_turns: Int,
    max_concurrency: Int,
    token_budget: Option(Int),
    policy_timeout: Int,
    model_retry_delay: Int,
  )
}

@internal
pub fn admit(
  agent: Agent(context),
) -> Result(Admitted(context), List(ConfigError)) {
  let registry =
    registry.new(agent.tools)
    |> result.map_error(list.map(_, tool_error))
  let limits =
    [
      positive(agent.max_turns, MaxTurnsNotPositive),
      positive(agent.max_concurrency, MaxConcurrencyNotPositive),
      case agent.token_budget {
        Some(tokens) -> positive(tokens, TokenBudgetNotPositive)
        None -> Ok(Nil)
      },
      positive(agent.policy_timeout, PolicyTimeoutNotPositive),
      case agent.model_retry_delay >= 0 {
        True -> Ok(Nil)
        False -> Error(ModelRetryDelayNegative(agent.model_retry_delay))
      },
      case agent.identity {
        Identity(name, version) if name == "" || version < 1 ->
          Error(InvalidIdentity(name, version))
        Identity(..) -> Ok(Nil)
      },
    ]
    |> list.filter_map(fn(check) {
      case check {
        Ok(Nil) -> Error(Nil)
        Error(error) -> Ok(error)
      }
    })
  case registry, limits {
    Ok(registry), [] ->
      Ok(Admitted(
        identity: agent.identity,
        model: agent.model,
        registry:,
        policy: agent.policy,
        system_prompt: agent.system_prompt,
        max_turns: agent.max_turns,
        max_concurrency: agent.max_concurrency,
        token_budget: agent.token_budget,
        policy_timeout: agent.policy_timeout,
        model_retry_delay: agent.model_retry_delay,
      ))
    Ok(_), errors -> Error(errors)
    Error(tool_errors), errors -> Error(list.append(tool_errors, errors))
  }
}

fn positive(
  value: Int,
  error: fn(Int) -> ConfigError,
) -> Result(Nil, ConfigError) {
  case value > 0 {
    True -> Ok(Nil)
    False -> Error(error(value))
  }
}

fn tool_error(error: registry.RegistryError) -> ConfigError {
  case error {
    registry.DuplicateName(name) -> DuplicateToolName(name)
    registry.InvalidName(name) -> InvalidToolName(name)
    registry.SchemaUnavailable(name) -> ToolSchemaUnavailable(name)
  }
}

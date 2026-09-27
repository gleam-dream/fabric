//// Pure agent configuration.
////
//// Building an `Agent` starts nothing. `validate` reports every problem at
//// once; `fabric.start` validates again before it allocates a process.

import fabric/internal/registry.{type Registry}
import fabric/model.{type Model}
import fabric/policy.{type Policy}
import fabric/tool.{type Tool}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub opaque type Agent(context) {
  Agent(
    model: Model,
    tools: List(Tool(context)),
    policy: Policy(context),
    system_prompt: Option(String),
    max_turns: Int,
    max_concurrency: Int,
    token_budget: Option(Int),
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
}

pub const default_max_turns = 8

pub const default_max_concurrency = 4

/// An agent with the given model, tools, and policy. The policy is required:
/// there is no implicit allow (`policy.always_allow()` is the explicit one).
pub fn new(
  model: Model,
  tools: List(Tool(context)),
  policy: Policy(context),
) -> Agent(context) {
  Agent(
    model:,
    tools:,
    policy:,
    system_prompt: None,
    max_turns: default_max_turns,
    max_concurrency: default_max_concurrency,
    token_budget: None,
  )
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

pub fn validate(agent: Agent(context)) -> Result(Nil, List(ConfigError)) {
  admit(agent) |> result.replace(Nil)
}

/// A validated agent, ready for the runtime.
@internal
pub type Admitted(context) {
  Admitted(
    model: Model,
    registry: Registry(context),
    policy: Policy(context),
    system_prompt: Option(String),
    max_turns: Int,
    max_concurrency: Int,
    token_budget: Option(Int),
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
        model: agent.model,
        registry:,
        policy: agent.policy,
        system_prompt: agent.system_prompt,
        max_turns: agent.max_turns,
        max_concurrency: agent.max_concurrency,
        token_budget: agent.token_budget,
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

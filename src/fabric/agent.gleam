//// Pure agent configuration.
////
//// Building an `Agent` starts nothing. `validate` reports every problem at
//// once; `fabric.start` validates again before it allocates a process.

import fabric/internal/registry.{type Registry}
import fabric/model.{type Model}
import fabric/policy.{type Policy}
import fabric/run.{type Identity, Identity}
import fabric/tool.{type Tool}
import gleam/dict.{type Dict}
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
    command_timeout: Int,
    /// The sub-agent each delegation starts, by delegation name.
    children: List(#(String, Agent(context))),
    max_children: Int,
    max_depth: Int,
  )
}

pub type ConfigError {
  DuplicateToolName(String)
  /// Providers accept tool names matching `^[a-zA-Z0-9_-]{1,64}$`.
  InvalidToolName(String)
  /// The tool's input codec has no JSON Schema to declare to the model.
  ToolSchemaUnavailable(String)
  /// A tool bound with `tool.bind_settling` waits no positive time for its
  /// settlement.
  SettlementBoundNotPositive(name: String, within: Int)
  /// A tool bound with `tool.bind_settling` waits longer than the longest
  /// timer the runtime can set (2^32 - 1 ms): its bound would never pass.
  SettlementBoundTooLarge(name: String, within: Int)
  MaxTurnsNotPositive(Int)
  MaxConcurrencyNotPositive(Int)
  TokenBudgetNotPositive(Int)
  PolicyTimeoutNotPositive(Int)
  ModelRetryDelayNegative(Int)
  CommandTimeoutNotPositive(Int)
  /// The name is empty or the version is not positive.
  InvalidIdentity(name: String, version: Int)
  MaxChildrenNegative(Int)
  MaxDepthNegative(Int)
  /// More sub-agent runs per run than `max_children_limit`.
  MaxChildrenTooLarge(Int)
  /// Deeper nesting than `max_depth_limit`.
  MaxDepthTooLarge(Int)
  /// The sub-agent of the delegation `name` is invalid.
  InvalidChild(name: String, errors: List(ConfigError))
}

pub const default_max_turns = 8

pub const default_max_concurrency = 4

pub const default_policy_timeout = 5000

pub const default_model_retry_delay = 200

pub const default_command_timeout = 5000

pub const default_identity = Identity("agent", 1)

pub const default_max_children = 4

pub const default_max_depth = 1

/// The most sub-agent runs one run may start. With `max_depth_limit`, it
/// keeps every child run id (the parent's id, `-`, and a sequence number)
/// within the 128 characters of a run id.
pub const max_children_limit = 999

/// The deepest nesting of sub-agent runs below a root run.
pub const max_depth_limit = 16

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
    command_timeout: default_command_timeout,
    children: [],
    max_children: default_max_children,
    max_depth: default_max_depth,
  )
}

/// Lets the model delegate to a sub-agent: a call to `definition` (declared
/// to the model like any tool) starts a run of `child` in the same store,
/// with `prompt(input)` as its prompt, once the policy allows it. The
/// policy sees `policy.StartAgent` as the action's target, and may require
/// an approval like for any tool; no child run exists before it is
/// allowed. The child is its own run with its own budgets and policy, and
/// shares this agent's context type and store. It starts with the context
/// its start was allowed with: this run's, or for an approved start, the
/// context the answer was checked with. Its approvals are this
/// run's pending approvals (their references name the child run), and
/// cancelling this run cancels it.
///
/// When the child finishes, `result(outcome)` is the call's result. A child
/// that ended with effects of unknown status (for example cancelled while a
/// tool ran) makes the call an uncertain effect whatever `result` says.
pub fn with_sub_agent(
  agent: Agent(context),
  definition: tool.Definition(input, output),
  to child: Agent(context),
  prompt prompt: fn(input) -> String,
  result result: fn(run.Outcome) -> Result(output, tool.Failure),
) -> Agent(context) {
  let delegation = tool.delegation(definition, child.identity, prompt, result)
  Agent(
    ..agent,
    tools: list.append(agent.tools, [delegation]),
    children: list.append(agent.children, [#(tool.name(delegation), child)]),
  )
}

/// Limits how many sub-agent runs one run starts (default 4, at most
/// `max_children_limit`). A delegation beyond it is refused before the
/// policy, and the model sees why.
pub fn with_max_children(agent: Agent(context), limit: Int) -> Agent(context) {
  Agent(..agent, max_children: limit)
}

/// Limits how many levels of sub-agents may exist below a run started with
/// this agent (default 1: its children may not delegate in turn; at most
/// `max_depth_limit`). A child is bounded by its own setting and by what
/// its parent has left.
pub fn with_max_depth(agent: Agent(context), levels: Int) -> Agent(context) {
  Agent(..agent, max_depth: levels)
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

/// Bounds how long a command (`approve`, `reject`, `cancel`, `reconcile`) waits
/// for the run's live runner to take it, in milliseconds (default 5000). A
/// runner busy for longer (for example held by a synchronous observation
/// handler) refuses the command with `fabric.RunnerBusy`, and never applies it
/// later.
pub fn with_command_timeout(
  agent: Agent(context),
  milliseconds: Int,
) -> Agent(context) {
  Agent(..agent, command_timeout: milliseconds)
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
    command_timeout: Int,
    /// The admitted sub-agent of each delegation, by delegation name.
    children: Dict(String, Admitted(context)),
    max_children: Int,
    max_depth: Int,
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
      positive(agent.command_timeout, CommandTimeoutNotPositive),
      case agent.model_retry_delay >= 0 {
        True -> Ok(Nil)
        False -> Error(ModelRetryDelayNegative(agent.model_retry_delay))
      },
      case agent.identity {
        Identity(name, version) if name == "" || version < 1 ->
          Error(InvalidIdentity(name, version))
        Identity(..) -> Ok(Nil)
      },
      not_negative(agent.max_children, MaxChildrenNegative),
      not_negative(agent.max_depth, MaxDepthNegative),
      case agent.max_children > max_children_limit {
        True -> Error(MaxChildrenTooLarge(agent.max_children))
        False -> Ok(Nil)
      },
      case agent.max_depth > max_depth_limit {
        True -> Error(MaxDepthTooLarge(agent.max_depth))
        False -> Ok(Nil)
      },
    ]
    |> list.filter_map(fn(check) {
      case check {
        Ok(Nil) -> Error(Nil)
        Error(error) -> Ok(error)
      }
    })
  let children =
    list.map(agent.children, fn(entry) {
      let #(name, child) = entry
      admit(child)
      |> result.map(fn(admitted) { #(name, admitted) })
      |> result.map_error(InvalidChild(name, _))
    })
  let limits =
    list.append(
      limits,
      list.filter_map(children, fn(child) {
        case child {
          Ok(_) -> Error(Nil)
          Error(error) -> Ok(error)
        }
      }),
    )
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
        command_timeout: agent.command_timeout,
        children: children |> result.values |> dict.from_list,
        max_children: agent.max_children,
        max_depth: agent.max_depth,
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

fn not_negative(
  value: Int,
  error: fn(Int) -> ConfigError,
) -> Result(Nil, ConfigError) {
  case value >= 0 {
    True -> Ok(Nil)
    False -> Error(error(value))
  }
}

fn tool_error(error: registry.RegistryError) -> ConfigError {
  case error {
    registry.DuplicateName(name) -> DuplicateToolName(name)
    registry.InvalidName(name) -> InvalidToolName(name)
    registry.SchemaUnavailable(name) -> ToolSchemaUnavailable(name)
    registry.SettlementBoundNotPositive(name, within) ->
      SettlementBoundNotPositive(name, within)
    registry.SettlementBoundTooLarge(name, within) ->
      SettlementBoundTooLarge(name, within)
  }
}

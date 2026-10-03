//// Pure agent configuration.
////
//// A `Spec` describes an agent: its name, model, tools, policy, and
//// `Limits`. `build` checks it once and reports every problem at once; only
//// `build` makes the `Agent` that `fabric.start`, `fabric.open` and
//// `fabric.recover` take,
//// so a run never starts under an invalid agent. Building starts nothing.

import fabric/internal/checked_agent.{type Admitted, Admitted}
import fabric/internal/registry
import fabric/internal/tool as core_tool
import fabric/model.{type Model}
import fabric/policy.{type Policy}
import fabric/run.{
  type DefinitionId, type Timeout, After, DefinitionId, Infinity,
}
import fabric/tool.{type Tool}
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration.{type Duration}

/// An agent's description, checked by `build`.
pub opaque type Spec(context) {
  Spec(
    identity: DefinitionId,
    model: Model,
    tools: List(Tool(context)),
    policy: Policy(context),
    system_prompt: Option(String),
    limits: Limits,
    /// The sub-agent each delegation starts, by delegation name.
    children: List(#(String, Agent(context))),
  )
}

/// A checked agent. Only `build` makes one.
pub type Agent(context) =
  checked_agent.Agent(context)

/// The bounds of every run of an agent. Start from `default_limits()` and
/// override what differs, by label:
///
/// ```gleam
/// agent.Limits(..agent.default_limits(), max_turns: 4,
///   tool_timeout: run.After(duration.minutes(5)))
/// ```
///
/// Every wait is bounded by default. A timeout that may be unbounded is a
/// `run.Timeout`; `run.Infinity` must be asked for. Fabric may add fields:
/// update from `default_limits()` rather than listing every field.
pub type Limits {
  Limits(
    /// Model attempts per run, counting the first request and every retry.
    max_turns: Int,
    /// Tool bodies of one run that execute at the same time.
    max_concurrency: Int,
    /// Input plus output tokens as reported by the provider. A reply without
    /// usage then stops the run with `run.BudgetUnverifiable`.
    token_budget: Option(Int),
    /// Sub-agent runs one run starts, at most 999. A delegation beyond it is
    /// refused before the policy, and the model sees why.
    max_children: Int,
    /// Levels of sub-agents below a run of this agent, at most 16 (1: its
    /// children may not delegate in turn). A child is bounded by its own
    /// setting and by what its parent has left.
    max_depth: Int,
    /// How long one policy decision may take. A policy that gives no
    /// decision in time has failed: the run stops closed. The policy runs in
    /// its own process. At most 2^32 - 1 ms, the longest timer the runtime
    /// can set.
    policy_timeout: Duration,
    /// The wait before the first retry of a retryable model failure. The
    /// delay doubles with each consecutive retryable failure, up to 64 times
    /// this value, and every attempt still counts against the turn limit. A
    /// cancelled run does not wait for it. At most (2^32 - 1) / 64 ms, so the
    /// longest delay still fits a timer.
    model_retry_delay: Duration,
    /// How long a command (`approve`, `reject`, `cancel`, `reconcile`)
    /// waits for the run's live runner to take it. A runner busy for longer
    /// (for example held by a synchronous telemetry handler) refuses the
    /// command with `fabric.RunnerBusy`, and never applies it later. At most
    /// 2^32 - 1 ms.
    command_timeout: Duration,
    /// How long one model call may take, from the moment it is issued (a
    /// retry's delay is not counted). A call still running then is stopped
    /// and counts as a retryable `ModelError`, which spends a turn like any
    /// other retry. The default matches llm_wire's whole-call deadline, so
    /// `fabric/llm` is never cut short by it. At most 2^32 - 1 ms.
    model_timeout: Timeout,
    /// How long one tool body may run once it has started. A body still
    /// running then is stopped and its action becomes an uncertain effect
    /// (it may have acted), which the run waits to have reconciled; a tool
    /// bound with `tool.bind_settling` may still settle it. `tool.with_timeout`
    /// overrides it for one tool. Sub-agent runs are bounded by their own
    /// limits instead. At most 2^32 - 1 ms.
    tool_timeout: Timeout,
    /// The largest tool result, in bytes of its encoded content, that a run
    /// keeps: a result is stored and sent to the model on every later turn.
    /// A larger result stops the run with `run.OutputEncodingFailed`, naming
    /// this limit; the tool's effect has happened.
    max_result_bytes: Int,
  )
}

/// 8 turns, 4 concurrent tools, no token budget, 4 children one level deep,
/// 5 s for a policy decision and for a command, a first model retry after
/// 200 ms, 600 s for a model call, 60 s for a tool body, and tool results
/// of at most 1 MiB.
pub fn default_limits() -> Limits {
  Limits(
    max_turns: 8,
    max_concurrency: 4,
    token_budget: None,
    max_children: 4,
    max_depth: 1,
    policy_timeout: duration.seconds(5),
    model_retry_delay: duration.milliseconds(200),
    command_timeout: duration.seconds(5),
    model_timeout: After(duration.seconds(600)),
    tool_timeout: After(duration.seconds(60)),
    max_result_bytes: 1_048_576,
  )
}

pub type ConfigError {
  DuplicateToolName(String)
  /// Providers accept tool names matching `^[a-zA-Z0-9_-]{1,64}$`.
  InvalidToolName(String)
  /// The tool's input codec has no JSON Schema to declare to the model.
  ToolSchemaUnavailable(String)
  /// A tool bound with `tool.bind_settling` waits less than 1 ms for its
  /// settlement.
  SettlementBoundNotPositive(name: String, within: Duration)
  /// A tool bound with `tool.bind_settling` waits longer than the longest
  /// timer the runtime can set (2^32 - 1 ms): its bound would never pass.
  SettlementBoundTooLarge(name: String, within: Duration)
  /// A tool's own timeout (`tool.with_timeout`) is shorter than 1 ms or
  /// longer than the longest timer the runtime can set (2^32 - 1 ms).
  InvalidToolTimeout(name: String, timeout: Duration)
  MaxTurnsNotPositive(Int)
  MaxConcurrencyNotPositive(Int)
  TokenBudgetNotPositive(Int)
  /// Shorter than 1 ms.
  PolicyTimeoutNotPositive(Duration)
  /// The policy timeout is longer than the longest timer the runtime can
  /// set (`limit`, 2^32 - 1 ms).
  PolicyTimeoutTooLarge(value: Duration, limit: Duration)
  ModelRetryDelayNegative(Duration)
  /// The first model retry delay, doubled up to 64 times, would exceed the
  /// longest timer the runtime can set: `limit` is (2^32 - 1) / 64 ms.
  ModelRetryDelayTooLarge(value: Duration, limit: Duration)
  /// Shorter than 1 ms.
  CommandTimeoutNotPositive(Duration)
  /// The command timeout is longer than the longest timer the runtime can
  /// set (`limit`, 2^32 - 1 ms).
  CommandTimeoutTooLarge(value: Duration, limit: Duration)
  /// Shorter than 1 ms.
  ModelTimeoutNotPositive(Duration)
  /// Longer than the longest timer the runtime can set (`limit`, 2^32 - 1
  /// ms); `run.Infinity` leaves a model call unbounded.
  ModelTimeoutTooLarge(value: Duration, limit: Duration)
  /// Shorter than 1 ms.
  ToolTimeoutNotPositive(Duration)
  /// Longer than the longest timer the runtime can set (`limit`, 2^32 - 1
  /// ms); `run.Infinity` leaves tool bodies unbounded.
  ToolTimeoutTooLarge(value: Duration, limit: Duration)
  MaxResultBytesNotPositive(Int)
  /// The name is empty or the version is not positive.
  InvalidIdentity(name: String, version: Int)
  MaxChildrenNegative(Int)
  MaxDepthNegative(Int)
  /// More sub-agent runs per run than `limit`. With the depth limit, it
  /// keeps every child run id (the parent's id, `-`, and a sequence number)
  /// within the 128 characters of a run id.
  MaxChildrenTooLarge(value: Int, limit: Int)
  /// Deeper nesting of sub-agent runs below a root run than `limit`.
  MaxDepthTooLarge(value: Int, limit: Int)
}

const max_children_limit = 999

const max_depth_limit = 16

/// The longest timer the runtime can set, in milliseconds: a longer wait
/// crashes the process that waits.
const longest_timer = 4_294_967_295

/// How many times the first model retry delay is doubled, at most (64
/// times the first delay).
const retry_delay_factor = 64

/// An agent named `name`, with the given model, tools, and policy, version
/// 1 and `default_limits()`. A stored run records the name and version it
/// started with and continues only under the same pair. The policy is
/// required: there is no implicit allow (`policy.always_allow()` is the
/// explicit one).
pub fn new(
  name: String,
  model: Model,
  tools: List(Tool(context)),
  policy: Policy(context),
) -> Spec(context) {
  Spec(
    identity: DefinitionId(name, 1),
    model:,
    tools:,
    policy:,
    system_prompt: None,
    limits: default_limits(),
    children: [],
  )
}

/// Changes the version a run records. Change it when a change to the agent
/// must not continue older runs.
pub fn with_version(spec: Spec(context), version: Int) -> Spec(context) {
  Spec(..spec, identity: DefinitionId(spec.identity.name, version))
}

pub fn with_system_prompt(spec: Spec(context), text: String) -> Spec(context) {
  Spec(..spec, system_prompt: Some(text))
}

pub fn with_limits(spec: Spec(context), limits: Limits) -> Spec(context) {
  Spec(..spec, limits:)
}

/// Lets the model delegate to a sub-agent: a call to `definition` (declared
/// to the model like any tool) starts a run of `child` in the same store,
/// with `prompt(input)` as its prompt, once the policy allows it. The
/// policy sees `policy.StartAgent` as the action's target, and may require
/// an approval like for any tool; no child run exists before it is
/// allowed. The child is its own run with its own limits and policy, and
/// shares this agent's context type and store. It starts with the context
/// its start was allowed with: this run's, or for an approved start, the
/// context the answer was checked with. Its approvals are this
/// run's pending approvals (their references name the child run), and
/// cancelling this run cancels it.
///
/// When the child completes, `output(answer)` parses its answer into the
/// call's output; an `Error(text)` is a definite failure whose `text` the
/// model sees. A child that ended otherwise (refused, cancelled, out of
/// budget, failed) is a definite failure that names how it ended. A child
/// that ended with effects of unknown status (for example cancelled while a
/// tool ran) makes the call an uncertain effect however it ended.
pub fn with_sub_agent(
  spec: Spec(context),
  definition: tool.Definition(input, output),
  to child: Agent(context),
  prompt prompt: fn(input) -> String,
  output output: fn(String) -> Result(output, String),
) -> Spec(context) {
  let delegation =
    core_tool.delegation(
      definition,
      checked_agent.admitted(child).identity,
      prompt,
      output:,
    )
  Spec(
    ..spec,
    tools: list.append(spec.tools, [delegation]),
    children: list.append(spec.children, [#(core_tool.name(delegation), child)]),
  )
}

/// Checks `spec` and reports every problem at once. A sub-agent was checked
/// by its own `build`.
pub fn build(spec: Spec(context)) -> Result(Agent(context), List(ConfigError)) {
  admit(spec) |> result.map(checked_agent.new)
}

fn admit(spec: Spec(context)) -> Result(Admitted(context), List(ConfigError)) {
  let registry =
    registry.new(spec.tools)
    |> result.map_error(list.map(_, tool_error))
  let Limits(
    max_turns:,
    max_concurrency:,
    token_budget:,
    max_children:,
    max_depth:,
    policy_timeout:,
    model_retry_delay:,
    command_timeout:,
    model_timeout:,
    tool_timeout:,
    max_result_bytes:,
  ) = spec.limits
  let longest = duration.milliseconds(longest_timer)
  let problems =
    [
      positive(max_turns, MaxTurnsNotPositive),
      positive(max_concurrency, MaxConcurrencyNotPositive),
      case token_budget {
        Some(tokens) -> positive(tokens, TokenBudgetNotPositive)
        None -> Ok(Nil)
      },
      timer(policy_timeout, PolicyTimeoutNotPositive, PolicyTimeoutTooLarge(
        _,
        longest,
      )),
      timer(command_timeout, CommandTimeoutNotPositive, CommandTimeoutTooLarge(
        _,
        longest,
      )),
      case duration.to_milliseconds(model_retry_delay) >= 0 {
        True -> Ok(Nil)
        False -> Error(ModelRetryDelayNegative(model_retry_delay))
      },
      case
        duration.to_milliseconds(model_retry_delay)
        > longest_timer / retry_delay_factor
      {
        True ->
          Error(ModelRetryDelayTooLarge(
            model_retry_delay,
            duration.milliseconds(longest_timer / retry_delay_factor),
          ))
        False -> Ok(Nil)
      },
      case model_timeout {
        After(within) ->
          timer(within, ModelTimeoutNotPositive, ModelTimeoutTooLarge(
            _,
            longest,
          ))
        Infinity -> Ok(Nil)
      },
      case tool_timeout {
        After(within) ->
          timer(within, ToolTimeoutNotPositive, ToolTimeoutTooLarge(_, longest))
        Infinity -> Ok(Nil)
      },
      positive(max_result_bytes, MaxResultBytesNotPositive),
      case spec.identity {
        DefinitionId(name, version) if name == "" || version < 1 ->
          Error(InvalidIdentity(name, version))
        DefinitionId(..) -> Ok(Nil)
      },
      not_negative(max_children, MaxChildrenNegative),
      not_negative(max_depth, MaxDepthNegative),
      case max_children > max_children_limit {
        True -> Error(MaxChildrenTooLarge(max_children, max_children_limit))
        False -> Ok(Nil)
      },
      case max_depth > max_depth_limit {
        True -> Error(MaxDepthTooLarge(max_depth, max_depth_limit))
        False -> Ok(Nil)
      },
    ]
    |> list.filter_map(fn(check) {
      case check {
        Ok(Nil) -> Error(Nil)
        Error(error) -> Ok(error)
      }
    })
  case registry, problems {
    Ok(registry), [] ->
      Ok(Admitted(
        identity: spec.identity,
        model: spec.model,
        registry:,
        policy: spec.policy,
        system_prompt: spec.system_prompt,
        max_turns:,
        max_concurrency:,
        token_budget:,
        policy_timeout: duration.to_milliseconds(policy_timeout),
        model_retry_delay: duration.to_milliseconds(model_retry_delay),
        command_timeout: duration.to_milliseconds(command_timeout),
        model_timeout: milliseconds(model_timeout),
        tool_timeout: milliseconds(tool_timeout),
        max_result_bytes:,
        children: spec.children
          |> list.map(fn(entry) { #(entry.0, checked_agent.admitted(entry.1)) })
          |> dict.from_list,
        max_children:,
        max_depth:,
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

/// A wait the runtime sets a timer for: at least 1 ms and at most the
/// longest timer.
fn timer(
  value: Duration,
  not_positive: fn(Duration) -> ConfigError,
  too_large: fn(Duration) -> ConfigError,
) -> Result(Nil, ConfigError) {
  let ms = duration.to_milliseconds(value)
  case ms < 1, ms > longest_timer {
    True, _ -> Error(not_positive(value))
    _, True -> Error(too_large(value))
    False, False -> Ok(Nil)
  }
}

fn milliseconds(timeout: Timeout) -> Option(Int) {
  case timeout {
    After(within) -> Some(duration.to_milliseconds(within))
    Infinity -> None
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
    registry.InvalidTimeout(name, timeout) -> InvalidToolTimeout(name, timeout)
  }
}

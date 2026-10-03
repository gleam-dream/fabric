//// Pure agent configuration.
////
//// A `Spec` describes an agent: its name, model, tools, policy, and the
//// bounds of its runs, set with the `with_*` functions. `build` checks it
//// once and reports every problem at once; only `build` makes the `Agent`
//// that `fabric.start`, `fabric.open` and `fabric.recover` take, so a run
//// never starts under an invalid agent. Building starts nothing.
////
//// ```gleam
//// let assert Ok(desk) =
////   agent.new("desk", model, [refund_tool], policy)
////   |> agent.with_max_turns(6)
////   |> agent.with_approval_expiry(run.After(duration.hours(24)))
////   |> agent.build
//// ```
////
//// Every wait is bounded by default:
////
//// | Bound | Default | Setter |
//// | --- | --- | --- |
//// | model attempts per run | 8 | `with_max_turns` |
//// | tool bodies at once | 4 | `with_max_concurrency` |
//// | tokens per run | none (opt-in) | `with_token_budget` |
//// | sub-agent runs per run | 4 | `with_max_children` |
//// | sub-agent nesting | 1 level | `with_max_depth` |
//// | policy decision | 5 s | `with_policy_timeout` |
//// | first model retry delay | 200 ms, doubling up to 64 times | `with_model_retry_delay` |
//// | command waiting for the runner | 5 s | `with_command_timeout` |
//// | model call | 600 s | `with_model_timeout` |
//// | tool body | 60 s | `with_tool_timeout`, `tool.with_timeout` |
//// | tool result | 1 MiB | `with_max_result_bytes` |
//// | approval request | 7 days | `with_approval_expiry` |
//// | family budget | none (opt-in) | `with_family_budget` |
////
//// A timeout that may be unbounded is a `run.Timeout`: `run.Infinity` must
//// be asked for.

import fabric/budget
import fabric/internal/budget/model as reservations
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
import gleam/int
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
    /// The sub-agent each delegation starts, by delegation name.
    children: List(#(String, Agent(context))),
    max_turns: Int,
    max_concurrency: Int,
    token_budget: Option(Int),
    max_children: Int,
    max_depth: Int,
    policy_timeout: Duration,
    model_retry_delay: Duration,
    command_timeout: Duration,
    model_timeout: Timeout,
    tool_timeout: Timeout,
    max_result_bytes: Int,
    approval_expiry: Timeout,
    family_budget: Option(budget.Limits),
  )
}

/// A checked agent. Only `build` makes one.
pub type Agent(context) =
  checked_agent.Agent(context)

/// Why `build` refused a spec. This union may grow: match the variants you
/// handle and keep a catch-all, or use `describe_config_error`.
pub type ConfigError {
  DuplicateToolName(String)
  /// Providers accept tool names matching `^[a-zA-Z0-9_-]{1,64}$`.
  InvalidToolName(String)
  /// The tool's input codec has no JSON Schema to declare to the model.
  ToolSchemaUnavailable(String)
  /// The name is empty or the version is not positive.
  InvalidIdentity(name: String, version: Int)
  /// A bound is outside `minimum..maximum` (both included). Durations are
  /// in milliseconds.
  InvalidLimit(limit: Limit, value: Int, minimum: Int, maximum: Int)
  /// A bound one tool sets for itself (`tool.bind_settling`,
  /// `tool.with_timeout`, `tool.with_replay`) is outside
  /// `minimum..maximum`.
  InvalidToolLimit(
    tool: String,
    limit: Limit,
    value: Int,
    minimum: Int,
    maximum: Int,
  )
}

/// A bound `build` checks, named after its setter. This union may grow.
pub type Limit {
  MaxTurns
  MaxConcurrency
  TokenBudget
  /// At most 999: with the depth limit, every child run id (the parent's
  /// id, `-`, and a sequence number) fits the 128 characters of a run id.
  MaxChildren
  /// At most 16.
  MaxDepth
  /// At most 2^32 - 1 ms, the longest timer the runtime can set, like
  /// every timeout below.
  PolicyTimeout
  /// At most (2^32 - 1) / 64 ms, so that the longest delay still fits a
  /// timer.
  ModelRetryDelay
  CommandTimeout
  ModelTimeout
  ToolTimeout
  MaxResultBytes
  ApprovalExpiry
  /// `budget.limits(work:)`.
  FamilyWork
  /// `budget.with_children`.
  FamilyChildren
  /// `budget.with_depth`, at most 63.
  FamilyDepth
  /// `tool.bind_settling`'s `settle_within`.
  SettleWithin
  /// `tool.with_replay`'s attempts, at most 100.
  ReplayAttempts
}

const max_children_limit = 999

const max_depth_limit = 16

/// The longest timer the runtime can set, in milliseconds: a longer wait
/// crashes the process that waits.
const longest_timer = 4_294_967_295

/// The largest count or duration a record keeps exactly (2^53 - 1, the
/// largest integer JSON readers agree on), the maximum of bounds that have
/// no other.
const largest = 9_007_199_254_740_991

/// How many times the first model retry delay is doubled, at most (64
/// times the first delay).
const retry_delay_factor = 64

/// An agent named `name`, with the given model, tools, and policy, version
/// 1 and the default bounds (see the module documentation). A stored run
/// records the name and version it started with and continues only under
/// the same pair. The policy is required: there is no implicit allow
/// (`policy.always_allow()` is the explicit one).
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
    children: [],
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
    approval_expiry: After(duration.hours(7 * 24)),
    family_budget: None,
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

/// Model attempts per run, counting the first request and every retry.
/// Default 8.
pub fn with_max_turns(spec: Spec(context), turns: Int) -> Spec(context) {
  Spec(..spec, max_turns: turns)
}

/// Tool bodies of one run that execute at the same time. Default 4.
pub fn with_max_concurrency(spec: Spec(context), tools: Int) -> Spec(context) {
  Spec(..spec, max_concurrency: tools)
}

/// Input plus output tokens per run, as the provider reports them. A reply
/// without usage then stops the run with `run.BudgetUnverifiable`, which
/// is why there is no default.
pub fn with_token_budget(spec: Spec(context), tokens: Int) -> Spec(context) {
  Spec(..spec, token_budget: Some(tokens))
}

/// Sub-agent runs one run starts, at most 999. A delegation beyond it is
/// refused before the policy, and the model sees why. Default 4.
pub fn with_max_children(spec: Spec(context), children: Int) -> Spec(context) {
  Spec(..spec, max_children: children)
}

/// Levels of sub-agents below a run of this agent, at most 16 (1: its
/// children may not delegate in turn). A child is bounded by its own
/// setting and by what its parent has left. Default 1.
pub fn with_max_depth(spec: Spec(context), levels: Int) -> Spec(context) {
  Spec(..spec, max_depth: levels)
}

/// How long one policy decision may take. A policy that gives no decision
/// in time has failed: the run stops closed. The policy runs in its own
/// process. Default 5 s.
pub fn with_policy_timeout(
  spec: Spec(context),
  timeout: Duration,
) -> Spec(context) {
  Spec(..spec, policy_timeout: timeout)
}

/// The wait before the first retry of a retryable model failure. The delay
/// doubles with each consecutive retryable failure, up to 64 times this
/// value; a provider's own delay (`model.retry_after`) is waited when it is
/// longer, up to 10 minutes. Every attempt still counts against the turn
/// limit, and a cancelled run does not wait. Default 200 ms.
pub fn with_model_retry_delay(
  spec: Spec(context),
  delay: Duration,
) -> Spec(context) {
  Spec(..spec, model_retry_delay: delay)
}

/// How long a command (`approve`, `reject`, `cancel`, `reconcile`) waits
/// for the run's live runner to take it. A runner busy for longer (for
/// example held by a synchronous telemetry handler) refuses the command
/// with `fabric.RunnerBusy`, and never applies it later. Default 5 s.
pub fn with_command_timeout(
  spec: Spec(context),
  timeout: Duration,
) -> Spec(context) {
  Spec(..spec, command_timeout: timeout)
}

/// How long one model call may take, from the moment it is issued (a
/// retry's delay is not counted). A call still running then is stopped and
/// is a `model.TimedOut` error, retried like any other and spending a turn.
/// The default, 600 s, matches llm_wire's whole-call deadline, so
/// `fabric/llm` is never cut short by it. `run.Infinity` leaves a model call
/// unbounded.
pub fn with_model_timeout(
  spec: Spec(context),
  timeout: Timeout,
) -> Spec(context) {
  Spec(..spec, model_timeout: timeout)
}

/// How long one tool body may run once it has started. A body still
/// running then is stopped and its action becomes an uncertain effect (it
/// may have acted), which the run waits to have reconciled, unless the tool
/// is replayable (`tool.with_replay`); a tool bound with
/// `tool.bind_settling` may still settle it. `tool.with_timeout` overrides
/// it for one tool. Sub-agent runs are bounded by their own limits instead.
/// Default 60 s; `run.Infinity` leaves tool bodies unbounded.
pub fn with_tool_timeout(
  spec: Spec(context),
  timeout: Timeout,
) -> Spec(context) {
  Spec(..spec, tool_timeout: timeout)
}

/// The largest tool result, in bytes of its encoded content, that a run
/// keeps: a result is stored and sent to the model on every later turn. A
/// larger result stops the run with `run.OutputEncodingFailed`, naming this
/// limit; the tool's effect has happened. Default 1 MiB.
pub fn with_max_result_bytes(spec: Spec(context), bytes: Int) -> Spec(context) {
  Spec(..spec, max_result_bytes: bytes)
}

/// How long an approval request this agent issues waits for an answer. Its
/// deadline is stored with the request (`run.PendingApproval.expires`).
/// After it the request expires: the action is rejected as `run.Expired`,
/// the model sees that its approval expired, and the run goes on. A late
/// `fabric.approve` or `fabric.reject` is refused with
/// `fabric.ApprovalExpired`.
///
/// An expired request is rejected by whoever touches the run next:
/// `fabric.await`, an answer, `fabric.recover`, or on a leased store the
/// sweeper (`fabric/sweeper`), which finds it when it is due. Deadlines are
/// judged by the UTC clock of the node that checks them. Default 7 days;
/// `run.Infinity` never expires. Requests stored without a deadline never
/// expire.
pub fn with_approval_expiry(
  spec: Spec(context),
  expiry: Timeout,
) -> Spec(context) {
  Spec(..spec, approval_expiry: expiry)
}

/// One budget shared by a root run of this agent and all the runs it
/// delegates to (see `fabric/budget`), stored with the root. Failed or
/// uncertain reservations keep their charge. It complements the agent's
/// own turn, token and delegation limits, and applies only when this agent
/// starts a root run: a sub-agent shares its root's. The store must write
/// agent records of version 7 or later (`fabric.FamilyBudgetUnsupported`).
pub fn with_family_budget(
  spec: Spec(context),
  limits: budget.Limits,
) -> Spec(context) {
  Spec(..spec, family_budget: Some(limits))
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

/// One line naming the problem and the setter that changes it.
pub fn describe_config_error(error: ConfigError) -> String {
  case error {
    DuplicateToolName(name) -> "two tools are named " <> name
    InvalidToolName(name) ->
      "the tool name "
      <> name
      <> " does not match ^[a-zA-Z0-9_-]{1,64}$, which providers require"
    ToolSchemaUnavailable(name) ->
      "the input codec of the tool " <> name <> " has no JSON Schema"
    InvalidIdentity(name, version) ->
      "the agent identity "
      <> name
      <> " version "
      <> int.to_string(version)
      <> " needs a name and a positive version"
    InvalidLimit(limit, value, minimum, maximum) ->
      range(setter(limit), value, minimum, maximum)
    InvalidToolLimit(name, limit, value, minimum, maximum) ->
      range(setter(limit) <> " of the tool " <> name, value, minimum, maximum)
  }
}

fn range(name: String, value: Int, minimum: Int, maximum: Int) -> String {
  name
  <> " is "
  <> int.to_string(value)
  <> ", outside "
  <> int.to_string(minimum)
  <> ".."
  <> int.to_string(maximum)
}

fn setter(limit: Limit) -> String {
  case limit {
    MaxTurns -> "agent.with_max_turns"
    MaxConcurrency -> "agent.with_max_concurrency"
    TokenBudget -> "agent.with_token_budget"
    MaxChildren -> "agent.with_max_children"
    MaxDepth -> "agent.with_max_depth"
    PolicyTimeout -> "agent.with_policy_timeout (ms)"
    ModelRetryDelay -> "agent.with_model_retry_delay (ms)"
    CommandTimeout -> "agent.with_command_timeout (ms)"
    ModelTimeout -> "agent.with_model_timeout (ms)"
    ToolTimeout -> "agent.with_tool_timeout or tool.with_timeout (ms)"
    MaxResultBytes -> "agent.with_max_result_bytes"
    ApprovalExpiry -> "agent.with_approval_expiry (ms)"
    FamilyWork -> "budget.limits(work:)"
    FamilyChildren -> "budget.with_children"
    FamilyDepth -> "budget.with_depth"
    SettleWithin -> "tool.bind_settling's settle_within (ms)"
    ReplayAttempts -> "tool.with_replay"
  }
}

fn admit(spec: Spec(context)) -> Result(Admitted(context), List(ConfigError)) {
  let registry =
    registry.new(spec.tools)
    |> result.map_error(list.map(_, tool_error))
  let ms = duration.to_milliseconds
  let timeout = fn(timeout) {
    case timeout {
      After(within) -> Some(ms(within))
      Infinity -> None
    }
  }
  let family = fn(read: fn(budget.Limits) -> Int) {
    option.map(spec.family_budget, read)
  }
  let bounds = [
    #(MaxTurns, Some(spec.max_turns), 1, largest),
    #(MaxConcurrency, Some(spec.max_concurrency), 1, largest),
    #(TokenBudget, spec.token_budget, 1, largest),
    #(MaxChildren, Some(spec.max_children), 0, max_children_limit),
    #(MaxDepth, Some(spec.max_depth), 0, max_depth_limit),
    #(PolicyTimeout, Some(ms(spec.policy_timeout)), 1, longest_timer),
    #(
      ModelRetryDelay,
      Some(ms(spec.model_retry_delay)),
      0,
      longest_timer / retry_delay_factor,
    ),
    #(CommandTimeout, Some(ms(spec.command_timeout)), 1, longest_timer),
    #(ModelTimeout, timeout(spec.model_timeout), 1, longest_timer),
    #(ToolTimeout, timeout(spec.tool_timeout), 1, longest_timer),
    #(MaxResultBytes, Some(spec.max_result_bytes), 1, largest),
    #(ApprovalExpiry, timeout(spec.approval_expiry), 1, largest),
    #(FamilyWork, family(fn(limits) { limits.work }), 0, largest),
    #(FamilyChildren, family(fn(limits) { limits.children }), 0, largest),
    #(
      FamilyDepth,
      family(fn(limits) { limits.depth }),
      0,
      reservations.max_depth,
    ),
  ]
  let problems =
    list.filter_map(bounds, fn(bound) {
      case bound {
        #(limit, Some(value), minimum, maximum)
          if value < minimum || value > maximum
        -> Ok(InvalidLimit(limit, value, minimum, maximum))
        _ -> Error(Nil)
      }
    })
  let problems = case spec.identity {
    DefinitionId(name, version) if name == "" || version < 1 -> [
      InvalidIdentity(name, version),
      ..problems
    ]
    DefinitionId(..) -> problems
  }
  case registry, problems {
    Ok(registry), [] ->
      Ok(Admitted(
        identity: spec.identity,
        model: spec.model,
        registry:,
        policy: spec.policy,
        system_prompt: spec.system_prompt,
        max_turns: spec.max_turns,
        max_concurrency: spec.max_concurrency,
        token_budget: spec.token_budget,
        policy_timeout: ms(spec.policy_timeout),
        model_retry_delay: ms(spec.model_retry_delay),
        command_timeout: ms(spec.command_timeout),
        model_timeout: timeout(spec.model_timeout),
        tool_timeout: timeout(spec.tool_timeout),
        max_result_bytes: spec.max_result_bytes,
        approval_expiry: timeout(spec.approval_expiry),
        family_budget: spec.family_budget,
        children: spec.children
          |> list.map(fn(entry) { #(entry.0, checked_agent.admitted(entry.1)) })
          |> dict.from_list,
        max_children: spec.max_children,
        max_depth: spec.max_depth,
      ))
    Ok(_), errors -> Error(errors)
    Error(tool_errors), errors -> Error(list.append(tool_errors, errors))
  }
}

fn tool_error(error: registry.RegistryError) -> ConfigError {
  case error {
    registry.DuplicateName(name) -> DuplicateToolName(name)
    registry.InvalidName(name) -> InvalidToolName(name)
    registry.SchemaUnavailable(name) -> ToolSchemaUnavailable(name)
    registry.InvalidToolLimit(name, limit, value, minimum, maximum) ->
      InvalidToolLimit(
        name,
        case limit {
          registry.SettleWithin -> SettleWithin
          registry.Timeout -> ToolTimeout
          registry.ReplayAttempts -> ReplayAttempts
        },
        value,
        minimum,
        maximum,
      )
  }
}

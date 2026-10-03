//// The registry of one agent's tools: admission, declarations, and dispatch
//// derived from the same definitions.

import fabric/internal/invocation.{type Outcome}
import fabric/internal/tool
import fabric/model
import fabric/policy
import fabric/run
import fabric/tool as fabric_tool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration
import llm_wire/tool as wire_tool

pub opaque type Registry(context) {
  Registry(order: List(String), tools: Dict(String, fabric_tool.Tool(context)))
}

pub type RegistryError {
  DuplicateName(String)
  /// Providers accept `^[a-zA-Z0-9_-]{1,64}$`.
  InvalidName(String)
  /// The input codec has no JSON Schema to declare.
  SchemaUnavailable(String)
  /// A tool's own bound is outside `minimum..maximum`.
  InvalidToolLimit(
    name: String,
    limit: ToolLimit,
    value: Int,
    minimum: Int,
    maximum: Int,
  )
}

/// A bound one tool sets for itself.
pub type ToolLimit {
  /// `tool.bind_settling`'s `settle_within`, in milliseconds.
  SettleWithin
  /// `tool.with_timeout`, in milliseconds.
  Timeout
  /// `tool.with_replay`'s attempts.
  ReplayAttempts
}

/// The longest timer the runtime sets, in milliseconds (2^32 - 1).
pub const max_settlement_bound = 4_294_967_295

/// The most attempts `tool.with_replay` allows.
pub const max_replay_attempts = 100

pub type AdmissionError {
  NotRegistered
  MalformedArguments(detail: String)
}

/// Collects every problem, in tool order, before any process starts.
pub fn new(
  tools: List(fabric_tool.Tool(context)),
) -> Result(Registry(context), List(RegistryError)) {
  let #(registry, errors) =
    list.fold(tools, #(Registry([], dict.new()), []), fn(acc, tool) {
      let #(Registry(order, by_name), errors) = acc
      let name = tool.name(tool)
      case dict.has_key(by_name, name) {
        True -> #(Registry(order, by_name), [DuplicateName(name), ..errors])
        False -> {
          let errors = case valid_name(name) {
            True -> errors
            False -> [InvalidName(name), ..errors]
          }
          let errors = case tool.input_schema(tool) {
            Ok(_) -> errors
            Error(_) -> [SchemaUnavailable(name), ..errors]
          }
          let bounded = fn(errors, value, limit, minimum, maximum) {
            case value {
              Some(value) if value < minimum || value > maximum -> [
                InvalidToolLimit(name, limit, value, minimum, maximum),
                ..errors
              ]
              _ -> errors
            }
          }
          let errors =
            bounded(
              errors,
              option.map(tool.settles_within(tool), duration.to_milliseconds),
              SettleWithin,
              1,
              max_settlement_bound,
            )
          let errors =
            bounded(
              errors,
              case tool.timeout(tool) {
                Some(run.After(within)) ->
                  Some(duration.to_milliseconds(within))
                _ -> None
              },
              Timeout,
              1,
              max_settlement_bound,
            )
          let errors =
            bounded(
              errors,
              tool.replay(tool),
              ReplayAttempts,
              1,
              max_replay_attempts,
            )
          #(Registry([name, ..order], dict.insert(by_name, name, tool)), errors)
        }
      }
    })
  case errors {
    [] -> Ok(Registry(..registry, order: list.reverse(registry.order)))
    _ -> Error(list.reverse(errors))
  }
}

/// The providers' grammar, `^[a-zA-Z0-9_-]{1,64}$`, as llm_wire admits it.
fn valid_name(name: String) -> Bool {
  wire_tool.check_name(name) |> result.is_ok
}

pub fn declarations(registry: Registry(context)) -> List(model.ToolSpec) {
  list.filter_map(registry.order, fn(name) {
    use tool <- result.try(dict.get(registry.tools, name))
    use schema <- result.map(
      tool.input_schema(tool) |> result.replace_error(Nil),
    )
    model.ToolSpec(name, tool.description(tool), schema)
  })
}

/// Checks that `name` is registered and its arguments decode with the
/// tool's input codec. Nothing runs.
pub fn admit(
  registry: Registry(context),
  name: String,
  arguments: String,
) -> Result(Nil, AdmissionError) {
  case dict.get(registry.tools, name) {
    Error(Nil) -> Error(NotRegistered)
    Ok(tool) ->
      tool.check(tool, arguments) |> result.map_error(MalformedArguments)
  }
}

/// Runs the handler in the calling process. The caller contains crashes.
/// `late` receives a settlement of this invocation after its task was
/// stopped (`tool.bind_settling`).
pub fn invoke(
  registry: Registry(context),
  context: context,
  call: fabric_tool.Call,
  name: String,
  arguments: String,
  late: tool.Late(fabric_tool.SettleError),
) -> Outcome {
  case dict.get(registry.tools, name) {
    Error(Nil) -> invocation.ArgumentsRejected("tool is not registered")
    Ok(tool) -> tool.invoke(tool, context, call, arguments, late)
  }
}

/// How long a stopped run waits for a settlement of `name`, in
/// milliseconds, for a tool bound with `tool.bind_settling`.
pub fn settles_within(
  registry: Registry(context),
  name: String,
) -> Option(Int) {
  case dict.get(registry.tools, name) {
    Ok(tool) -> option.map(tool.settles_within(tool), duration.to_milliseconds)
    Error(Nil) -> None
  }
}

/// The body timeout of `name` in milliseconds: its own (`tool.with_timeout`)
/// or else `default`; `None` when unbounded.
pub fn timeout(
  registry: Registry(context),
  name: String,
  default: Option(Int),
) -> Option(Int) {
  case result.map(dict.get(registry.tools, name), tool.timeout) {
    Ok(Some(run.After(within))) -> Some(duration.to_milliseconds(within))
    Ok(Some(run.Infinity)) -> None
    _ -> default
  }
}

/// How many times in all the body of `name` may start, for a replayable
/// tool (`tool.with_replay`).
pub fn replay_attempts(
  registry: Registry(context),
  name: String,
) -> Option(Int) {
  case dict.get(registry.tools, name) {
    Ok(tool) -> tool.replay(tool)
    Error(Nil) -> None
  }
}

/// What a call to `name` does: invoke a tool or start a sub-agent.
/// An unknown name is a tool call (admission refuses it first).
pub fn target(registry: Registry(context), name: String) -> policy.Target {
  case dict.get(registry.tools, name) {
    Ok(tool) ->
      case tool.kind(tool) {
        tool.Delegation(agent:, ..) ->
          policy.StartAgent(agent.name, agent.version)
        tool.Handler -> policy.InvokeTool
      }
    Error(Nil) -> policy.InvokeTool
  }
}

pub fn is_delegation(registry: Registry(context), name: String) -> Bool {
  case target(registry, name) {
    policy.StartAgent(..) -> True
    policy.InvokeTool | policy.RunOperation(..) -> False
  }
}

/// The prompt of the sub-agent a delegation call starts.
pub fn prompt(
  registry: Registry(context),
  name: String,
  arguments: String,
) -> Result(String, String) {
  case dict.get(registry.tools, name) {
    Ok(tool) ->
      case tool.kind(tool) {
        tool.Delegation(prompt:, ..) -> prompt(arguments)
        tool.Handler -> Error(name <> " is not a delegation")
      }
    Error(Nil) -> Error("no delegation named " <> name <> " is registered")
  }
}

/// A sub-agent's outcome as the delegation call's result, or `Error` when
/// no delegation of that name is registered.
pub fn settle(
  registry: Registry(context),
  name: String,
  outcome: run.Outcome,
) -> Result(Outcome, Nil) {
  case dict.get(registry.tools, name) {
    Ok(tool) ->
      case tool.kind(tool) {
        tool.Delegation(settle:, ..) -> Ok(settle(outcome))
        tool.Handler -> Error(Nil)
      }
    Error(Nil) -> Error(Nil)
  }
}

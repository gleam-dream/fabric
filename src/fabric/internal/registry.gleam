//// The registry of one agent's tools: admission, declarations, and dispatch
//// derived from the same definitions.

import fabric/internal/invocation.{type Outcome}
import fabric/model
import fabric/policy
import fabric/run
import fabric/tool.{type Tool}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import llm_wire/tool as wire_tool

pub opaque type Registry(context) {
  Registry(order: List(String), tools: Dict(String, Tool(context)))
}

pub type RegistryError {
  DuplicateName(String)
  /// Providers accept `^[a-zA-Z0-9_-]{1,64}$`.
  InvalidName(String)
  /// The input codec has no JSON Schema to declare.
  SchemaUnavailable(String)
  /// A tool bound with `tool.bind_settling` waits less than 1 ms.
  SettlementBoundNotPositive(name: String, within: Duration)
  /// A tool bound with `tool.bind_settling` waits longer than a timer can.
  SettlementBoundTooLarge(name: String, within: Duration)
  /// A tool's own timeout (`tool.with_timeout`) is under 1 ms or longer
  /// than a timer can wait.
  InvalidTimeout(name: String, timeout: Duration)
}

/// The longest timer the runtime sets, in milliseconds (2^32 - 1).
pub const max_settlement_bound = 4_294_967_295

pub type AdmissionError {
  NotRegistered
  MalformedArguments(detail: String)
}

/// Collects every problem, in tool order, before any process starts.
pub fn new(
  tools: List(Tool(context)),
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
          let errors = case
            option.map(tool.settles_within(tool), fn(within) {
              #(within, duration.to_milliseconds(within))
            })
          {
            Some(#(within, ms)) if ms <= 0 -> [
              SettlementBoundNotPositive(name, within),
              ..errors
            ]
            Some(#(within, ms)) if ms > max_settlement_bound -> [
              SettlementBoundTooLarge(name, within),
              ..errors
            ]
            _ -> errors
          }
          let errors = case tool.timeout(tool) {
            Some(run.After(within)) ->
              case duration.to_milliseconds(within) {
                ms if ms < 1 || ms > max_settlement_bound -> [
                  InvalidTimeout(name, within),
                  ..errors
                ]
                _ -> errors
              }
            _ -> errors
          }
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
  call: tool.Call,
  name: String,
  arguments: String,
  late: tool.Late,
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
    policy.InvokeTool -> False
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

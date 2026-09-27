//// The registry of one agent's tools: admission, declarations, and dispatch
//// derived from the same definitions.

import fabric/internal/invocation.{type Outcome}
import fabric/model
import fabric/tool.{type Tool}
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import llm_wire/types

pub opaque type Registry(context) {
  Registry(order: List(String), tools: Dict(String, Tool(context)))
}

pub type RegistryError {
  DuplicateName(String)
  /// Providers accept `^[a-zA-Z0-9_-]{1,64}$`.
  InvalidName(String)
  /// The input codec has no JSON Schema to declare.
  SchemaUnavailable(String)
}

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
  types.tool_name(name) |> result.is_ok
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
pub fn invoke(
  registry: Registry(context),
  context: context,
  name: String,
  arguments: String,
) -> Outcome {
  case dict.get(registry.tools, name) {
    Error(Nil) -> invocation.ArgumentsRejected("tool is not registered")
    Ok(tool) -> tool.invoke(tool, context, arguments)
  }
}

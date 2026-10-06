//// Workflow composition experiment: typed tools share one invocation
//// closure across every variant. This is not a production tool API.

import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/result
import wc/codec.{type Codec}

/// What one invocation reports, after erasure.
pub type Outcome {
  /// The model sees `content`; `failed` marks a typed domain failure.
  Visible(content: String, failed: Bool)
  /// The effect may or may not have happened. Blocks the run until an
  /// explicit reconciliation; never retried.
  Uncertain(evidence: String)
  /// The arguments or result could not cross the codec boundary.
  BoundaryFailure(reason: String)
}

/// Result of a tool body that can know its own effect is uncertain (an
/// ambiguous downstream timeout, an unresolved compensation).
pub type Report(o, e) {
  Done(Result(o, e))
  EffectUncertain(evidence: String)
}

pub opaque type Tool {
  Tool(name: String, invoke: fn(String) -> Outcome)
}

/// The ordinary constructor: a typed handler returning `Result`.
pub fn define(
  name: String,
  input: Codec(i),
  output: Codec(o),
  error: Codec(e),
  run: fn(i) -> Result(o, e),
) -> Tool {
  define_reporting(name, input, output, error, fn(value) { Done(run(value)) })
}

/// The advanced constructor: the handler may report an uncertain effect.
pub fn define_reporting(
  name: String,
  input: Codec(i),
  output: Codec(o),
  error: Codec(e),
  run: fn(i) -> Report(o, e),
) -> Tool {
  Tool(name, fn(arguments) {
    case codec.from_string(input, arguments) {
      Error(reason) -> BoundaryFailure(reason)
      Ok(value) ->
        case run(value) {
          Done(Ok(out)) -> Visible(codec.to_string(output, out), False)
          Done(Error(err)) ->
            Visible(
              json.to_string(json.object([#("error", error.encode(err))])),
              True,
            )
          EffectUncertain(evidence) -> Uncertain(evidence)
        }
    }
  })
}

pub fn name(tool: Tool) -> String {
  tool.name
}

pub fn invoke(tool: Tool, arguments: String) -> Outcome {
  tool.invoke(arguments)
}

pub opaque type Registry {
  Registry(tools: Dict(String, Tool))
}

pub type RegistryError {
  DuplicateName(String)
}

pub fn registry(tools: List(Tool)) -> Result(Registry, RegistryError) {
  list.try_fold(tools, dict.new(), fn(acc, tool) {
    case dict.has_key(acc, tool.name) {
      True -> Error(DuplicateName(tool.name))
      False -> Ok(dict.insert(acc, tool.name, tool))
    }
  })
  |> result.map(Registry)
}

pub fn lookup(registry: Registry, name: String) -> Result(Tool, Nil) {
  dict.get(registry.tools, name)
}

pub fn has(registry: Registry, name: String) -> Bool {
  dict.has_key(registry.tools, name)
}

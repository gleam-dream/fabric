//// Typed application tools.
////
//// A `Definition` owns a tool's name, description, and input and output
//// codecs. Binding it to a handler produces a `Tool(context)`: the typed
//// input, output, and error disappear behind one invocation, so tools with
//// unrelated types share one list. The declaration the model sees and the
//// decoder that checks its arguments come from the same input codec.
////
//// The handler receives the run's context separately from the decoded
//// business input.

import fabric/internal/invocation.{type Outcome}
import gleam/result
import json/blueprint/codec.{type Codec}

pub opaque type Definition(input, output) {
  Definition(
    name: String,
    description: String,
    input: Codec(input),
    output: Codec(output),
  )
}

/// What a typed handler error means.
pub type Failure {
  /// The action definitely failed without its effect. The model sees
  /// `{"error": message}` as the tool's result and the run continues.
  Explain(message: String)
  /// The effect may or may not have happened. The run stops before its next
  /// model turn until the action is reconciled; it is never retried.
  Uncertain(evidence: String)
}

pub opaque type Tool(context) {
  Tool(
    name: String,
    description: String,
    input_schema: Result(codec.Schema, codec.SchemaError),
    check: fn(String) -> Result(Nil, String),
    invoke: fn(context, String) -> Outcome,
  )
}

pub fn define(
  name: String,
  description: String,
  input: Codec(input),
  output: Codec(output),
) -> Definition(input, output) {
  Definition(name, description, input, output)
}

/// Binds a typed handler. `classify` decides, for every typed error, what
/// it means: a definite failure the model sees (`Explain`), or an effect that
/// may have happened (`Uncertain`), which blocks the run until it is
/// reconciled. There is no default: a timeout after a request was sent must
/// not look like a clean failure the model could simply retry.
pub fn bind(
  definition: Definition(input, output),
  handler: fn(context, input) -> Result(output, error),
  classify: fn(error) -> Failure,
) -> Tool(context) {
  let Definition(name:, description:, input:, output:) = definition
  Tool(
    name:,
    description:,
    input_schema: codec.schema(input),
    check: fn(arguments) {
      codec.decode_json(input, arguments)
      |> result.replace(Nil)
      |> result.map_error(invocation.describe_decode_error)
    },
    invoke: fn(context, arguments) {
      case codec.decode_json(input, arguments) {
        Error(error) ->
          invocation.ArgumentsRejected(invocation.describe_decode_error(error))
        Ok(value) ->
          case handler(context, value) {
            Ok(value) ->
              case codec.encode_json(output, value) {
                Ok(content) -> invocation.Returned(content)
                Error(error) ->
                  invocation.OutputUnencodable(invocation.describe_encode_error(
                    error,
                  ))
              }
            Error(error) ->
              case classify(error) {
                Explain(message) ->
                  invocation.FailedVisibly(invocation.error_content(message))
                Uncertain(evidence) -> invocation.EffectUncertain(evidence)
              }
          }
      }
    },
  )
}

pub fn name(tool: Tool(context)) -> String {
  tool.name
}

@internal
pub fn description(tool: Tool(context)) -> String {
  tool.description
}

@internal
pub fn input_schema(
  tool: Tool(context),
) -> Result(codec.Schema, codec.SchemaError) {
  tool.input_schema
}

@internal
pub fn check(tool: Tool(context), arguments: String) -> Result(Nil, String) {
  tool.check(arguments)
}

@internal
pub fn invoke(
  tool: Tool(context),
  context: context,
  arguments: String,
) -> Outcome {
  tool.invoke(context, arguments)
}

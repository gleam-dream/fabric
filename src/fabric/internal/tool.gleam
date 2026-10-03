//// The representation behind `fabric/tool.Definition` and
//// `fabric/tool.Tool`, and what the runtime reads from a tool.
////
//// A tool is generic over the call it answers and the refusal of a late
//// settlement, so that `fabric/tool` can define `Call` and `SettleError`
//// and still alias this type: `tool.Tool(context)` is
//// `Tool(context, tool.Call, tool.SettleError)`.

import fabric/internal/invocation.{type Outcome}
import fabric/model.{type ToolCall}
import fabric/run.{type DefinitionId, type Timeout}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import json/blueprint/codec.{type Codec}

pub opaque type Definition(input, output) {
  Definition(
    name: String,
    description: String,
    input: Codec(input),
    output: Codec(output),
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

pub fn definition_name(definition: Definition(input, output)) -> String {
  definition.name
}

pub fn definition_input(definition: Definition(input, output)) -> Codec(input) {
  definition.input
}

pub fn definition_output(
  definition: Definition(input, output),
) -> Codec(output) {
  definition.output
}

/// How the runtime receives one invocation's late settlement, with the
/// summary a refusal is observed with.
pub type Late(refusal) =
  fn(Outcome, String) -> Result(Nil, refusal)

pub opaque type Tool(context, call, refusal) {
  Tool(
    name: String,
    description: String,
    input_schema: Result(codec.Schema, codec.SchemaError),
    check: fn(String) -> Result(Nil, String),
    invoke: fn(context, call, String, Late(refusal)) -> Outcome,
    kind: Kind,
    /// For a tool bound with `bind_settling`: how long a stopped run waits
    /// for its settlement.
    settles_within: Option(Duration),
    /// This tool's own body timeout (`with_timeout`); `None`: the agent's
    /// `tool_timeout`.
    timeout: Option(Timeout),
    /// For a replayable tool (`with_replay`): how many times its body may
    /// start in all.
    replay: Option(Int),
  )
}

/// Whether a tool runs a handler or starts a sub-agent run (see
/// `agent.with_sub_agent`).
pub type Kind {
  Handler
  Delegation(
    agent: DefinitionId,
    /// Decodes the arguments and builds the sub-agent's prompt.
    prompt: fn(String) -> Result(String, String),
    /// The sub-agent's outcome as this call's result.
    settle: fn(run.Outcome) -> Outcome,
  )
}

/// A tool that runs a handler: `invoke` decodes the arguments itself.
pub fn handler(
  definition: Definition(input, output),
  invoke: fn(context, call, String, Late(refusal)) -> Outcome,
  settles_within: Option(Duration),
) -> Tool(context, call, refusal) {
  let Definition(name:, description:, input:, ..) = definition
  Tool(
    name:,
    description:,
    input_schema: codec.schema(input),
    check: checker(input),
    invoke:,
    kind: Handler,
    settles_within:,
    timeout: None,
    replay: None,
  )
}

/// A tool whose call starts a sub-agent run of `agent` (see
/// `agent.with_sub_agent`): `prompt` builds the sub-agent's prompt from the
/// decoded input, and `output` parses a completed sub-agent's answer into
/// this call's output (an `Error` is a definite failure the model sees).
/// Any other outcome is a definite failure that names it.
pub fn delegation(
  definition: Definition(input, output),
  agent: DefinitionId,
  prompt: fn(input) -> String,
  output parse: fn(String) -> Result(output, String),
) -> Tool(context, call, refusal) {
  let Definition(name:, description:, input:, output:) = definition
  Tool(
    name:,
    description:,
    input_schema: codec.schema(input),
    check: checker(input),
    settles_within: None,
    timeout: None,
    replay: None,
    invoke: fn(_, _, _, _) {
      invocation.ArgumentsRejected(
        "a delegation starts a run; it is not invoked",
      )
    },
    kind: Delegation(
      agent:,
      prompt: fn(arguments) {
        codec.decode_json(input, arguments)
        |> result.map(prompt)
        |> result.map_error(codec.describe_decode_error)
      },
      settle: fn(outcome) { delegated(outcome, parse, output) },
    ),
  )
}

/// A sub-agent's end as its delegation's result: a completed answer parsed
/// by `parse`, or a definite failure that names how the sub-agent ended.
fn delegated(
  outcome: run.Outcome,
  parse: fn(String) -> Result(output, String),
  output: Codec(output),
) -> Outcome {
  let explain = fn(message) {
    invocation.FailedVisibly(invocation.error_content(message))
  }
  case outcome {
    run.Completed(text) ->
      case parse(text) {
        Ok(value) -> encode(output, value)
        Error(message) -> explain(message)
      }
    run.Refused(reason) -> explain("the sub-agent refused: " <> reason)
    run.OutputLimited(_) ->
      explain("the sub-agent's answer exceeded its output limit")
    run.BudgetExhausted(run.TurnLimit(limit)) ->
      explain(
        "the sub-agent used its " <> int.to_string(limit) <> " model turns",
      )
    run.BudgetExhausted(run.TokenLimit(limit, _)) ->
      explain(
        "the sub-agent used its budget of " <> int.to_string(limit) <> " tokens",
      )
    run.BudgetExhausted(run.FamilyLimit(_)) ->
      explain("the sub-agent reached its shared family budget")
    run.BudgetUnverifiable(_) ->
      explain("the sub-agent's token budget could not be enforced")
    run.Cancelled -> explain("the sub-agent was cancelled")
    run.Failed(_) -> explain("the sub-agent failed")
  }
}

/// `value` encoded with `output`, as a returned result.
pub fn encode(output: Codec(output), value: output) -> Outcome {
  case codec.encode_json(output, value) {
    Ok(content) -> invocation.Returned(content)
    Error(error) ->
      invocation.OutputUnencodable(codec.describe_encode_error(error))
  }
}

fn checker(input: Codec(input)) -> fn(String) -> Result(Nil, String) {
  fn(arguments) {
    codec.decode_json(input, arguments)
    |> result.replace(Nil)
    |> result.map_error(codec.describe_decode_error)
  }
}

/// A call to `definition` with `input` encoded by its input codec; the
/// public form is `fabric/testing.call`.
pub fn call(
  definition: Definition(input, output),
  id: String,
  input: input,
) -> Result(ToolCall, codec.EncodeError) {
  use arguments <- result.map(codec.encode_json(definition.input, input))
  model.tool_call(id:, name: definition.name, arguments_json: arguments)
}

pub fn with_timeout(
  tool: Tool(context, call, refusal),
  timeout: Timeout,
) -> Tool(context, call, refusal) {
  Tool(..tool, timeout: Some(timeout))
}

pub fn with_replay(
  tool: Tool(context, call, refusal),
  max_attempts: Int,
) -> Tool(context, call, refusal) {
  Tool(..tool, replay: Some(max_attempts))
}

pub fn replay(tool: Tool(context, call, refusal)) -> Option(Int) {
  tool.replay
}

pub fn definition_description(definition: Definition(input, output)) -> String {
  definition.description
}

pub fn name(tool: Tool(context, call, refusal)) -> String {
  tool.name
}

pub fn description(tool: Tool(context, call, refusal)) -> String {
  tool.description
}

pub fn input_schema(
  tool: Tool(context, call, refusal),
) -> Result(codec.Schema, codec.SchemaError) {
  tool.input_schema
}

pub fn check(
  tool: Tool(context, call, refusal),
  arguments: String,
) -> Result(Nil, String) {
  tool.check(arguments)
}

pub fn kind(tool: Tool(context, call, refusal)) -> Kind {
  tool.kind
}

pub fn settles_within(tool: Tool(context, call, refusal)) -> Option(Duration) {
  tool.settles_within
}

pub fn timeout(tool: Tool(context, call, refusal)) -> Option(Timeout) {
  tool.timeout
}

pub fn invoke(
  tool: Tool(context, call, refusal),
  context: context,
  call: call,
  arguments: String,
  late: Late(refusal),
) -> Outcome {
  tool.invoke(context, call, arguments, late)
}

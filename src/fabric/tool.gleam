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
////
//// A tool bound with `bind_settling` also receives a `Settlement`: a
//// handle with which its result can be settled after the invocation's task
//// was stopped (a cancellation, a host fault in another action, or a task
//// that died), for a tool whose effect outlives its task, such as a
//// workflow that compensates after it is cancelled. The run accepts at most
//// one settlement per action, and only while the action awaits one:
////
//// - **The run is stopping.** Once the executor has confirmed that the
////   action's task no longer runs, the run waits, up to the tool's bound
////   (`within`), for the settlement before it ends, and records it as the
////   action's result, definite or uncertain. A settlement offered before
////   that confirmation waits for it (the task may still be acting); one
////   offered after the bound is refused, and the action stays an uncertain
////   effect.
//// - **The run continues.** An action that became an uncertain effect
////   while the run was not stopping (its task died, or its runner was lost
////   and the run recovered) accepts a definite settlement at any later
////   time, recorded like a reconciliation of exactly that action; the run
////   then continues. An uncertain settlement adds nothing and is refused.
////
//// Whichever is accepted first, a settlement or a reconciliation, is the
//// only one: every later settlement is refused. A refused settlement
//// changes nothing. `settle` then says whether that loses anything:
//// `AlreadyRecorded` when the action has a definite result (its task
//// reported, or it was settled or reconciled), `NotAwaited` when it does
//// not (the bound passed, or the run ended with the action uncertain), and
//// the refusal needs a person; `SettleUnconfirmed` when the store did not
//// confirm either way. A settlement offered while the action's
//// task may still run waits for it to report or be stopped, up to the
//// tool's bound between commits of the run; one the handler offers from
//// its own task is refused at once. The handle reaches the run through the
//// store its invocation ran with.

import fabric/internal/invocation.{type Outcome}
import fabric/model.{type ToolCall}
import fabric/policy
import fabric/run
import gleam/int
import gleam/option.{type Option, None, Some}
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
    invoke: fn(context, String, Late) -> Outcome,
    kind: Kind,
    /// For a tool bound with `bind_settling`: how long a stopped run waits
    /// for its settlement, in milliseconds.
    settles_within: Option(Int),
  )
}

/// How the runtime receives one invocation's late settlement, with the
/// summary a refusal is observed with.
@internal
pub type Late =
  fn(Outcome, String) -> Result(Nil, SettleError)

/// A handle on one invocation of a tool bound with `bind_settling`, to
/// settle its result after its task was stopped. Whoever holds it may
/// settle; the first settlement the run accepts is the only one.
pub opaque type Settlement(output) {
  Settlement(output: Codec(output), deliver: Late)
}

/// Why a settlement was not recorded. Nothing changed in either case.
pub type SettleError {
  /// The action already has a definite result: its task reported, or it
  /// was settled or reconciled. Nothing the settlement knows is lost.
  AlreadyRecorded
  /// The action does not await a settlement and has no definite result:
  /// its task did not stop within the tool's bound, the bound passed, the
  /// run ended with the action uncertain, or an uncertain settlement was
  /// offered for an action that is already uncertain. What the settlement
  /// knows reaches the run only through a person (`fabric.reconcile`); the
  /// refusal is observed as `settlement_refused` (`fabric/observation`).
  NotAwaited
  /// The run could not be read or written, or its runner did not take the
  /// settlement: whether it was recorded is not confirmed. A write the
  /// store reported unavailable has an unknown outcome.
  SettleUnconfirmed(reason: String)
}

/// Whether a tool runs a handler or starts a sub-agent run (see
/// `agent.with_sub_agent`).
@internal
pub type Kind {
  Handler
  Delegation(
    agent: run.Identity,
    /// Decodes the arguments and builds the sub-agent's prompt.
    prompt: fn(String) -> Result(String, String),
    /// The sub-agent's outcome as this call's result.
    settle: fn(run.Outcome) -> Outcome,
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
    check: checker(input),
    kind: Handler,
    settles_within: None,
    invoke: fn(context, arguments, _late) {
      case codec.decode_json(input, arguments) {
        Error(error) ->
          invocation.ArgumentsRejected(codec.render_json_decode_error(error))
        Ok(value) ->
          case handler(context, value) {
            Ok(value) -> encode(output, value)
            Error(error) -> failure(classify(error))
          }
      }
    },
  )
}

/// Binds a typed handler that also receives its invocation's `Settlement` (see
/// the module documentation), and whose stopped run waits up to `within`
/// milliseconds for that settlement before recording an uncertain effect.
/// `within` must be positive and at most 2^32 - 1, the longest timer the
/// runtime sets (`agent.build` checks it). The handler's own result is used
/// when it returns; the settlement matters only once its task was stopped.
/// `classify` is as for `bind`.
pub fn bind_settling(
  definition: Definition(input, output),
  handler: fn(context, input, Settlement(output)) -> Result(output, error),
  classify: fn(error) -> Failure,
  within milliseconds: Int,
) -> Tool(context) {
  let Definition(name:, description:, input:, output:) = definition
  Tool(
    name:,
    description:,
    input_schema: codec.schema(input),
    check: checker(input),
    kind: Handler,
    settles_within: Some(milliseconds),
    invoke: fn(context, arguments, late) {
      case codec.decode_json(input, arguments) {
        Error(error) ->
          invocation.ArgumentsRejected(codec.render_json_decode_error(error))
        Ok(value) ->
          case handler(context, value, Settlement(output, late)) {
            Ok(value) -> encode(output, value)
            Error(error) -> failure(classify(error))
          }
      }
    },
  )
}

/// Settles the invocation's result: an output, encoded with the tool's
/// output codec, or a typed failure, `Explain` (definite) or `Uncertain`.
/// Blocks until the run has recorded or refused it. A refusal is observed
/// (`settlement_refused`) with `summary`: what a person needs to reconcile
/// the action when the run did not record the settlement. The summary goes
/// to observation handlers, so it must not carry secrets.
pub fn settle(
  settlement: Settlement(output),
  result: Result(output, Failure),
  summary summary: String,
) -> Result(Nil, SettleError) {
  settlement.deliver(
    case result {
      Ok(value) -> encode(settlement.output, value)
      Error(error) -> failure(error)
    },
    summary,
  )
}

fn checker(input: Codec(input)) -> fn(String) -> Result(Nil, String) {
  fn(arguments) {
    codec.decode_json(input, arguments)
    |> result.replace(Nil)
    |> result.map_error(codec.render_json_decode_error)
  }
}

fn failure(failure: Failure) -> Outcome {
  case failure {
    Explain(message) ->
      invocation.FailedVisibly(invocation.error_content(message))
    Uncertain(evidence) -> invocation.EffectUncertain(evidence)
  }
}

fn encode(output: Codec(output), value: output) -> Outcome {
  case codec.encode_json(output, value) {
    Ok(content) -> invocation.Returned(content)
    Error(error) ->
      invocation.OutputUnencodable(invocation.describe_encode_error(error))
  }
}

/// A tool whose call starts a sub-agent run of `agent` (see
/// `agent.with_sub_agent`): `prompt` builds the sub-agent's prompt from the
/// decoded input, and `output` parses a completed sub-agent's answer into
/// this call's output (an `Error` is a definite failure the model sees).
/// Any other outcome is a definite failure that names it.
@internal
pub fn delegation(
  definition: Definition(input, output),
  agent: run.Identity,
  prompt: fn(input) -> String,
  output parse: fn(String) -> Result(output, String),
) -> Tool(context) {
  let Definition(name:, description:, input:, output:) = definition
  Tool(
    name:,
    description:,
    input_schema: codec.schema(input),
    check: checker(input),
    settles_within: None,
    invoke: fn(_, _, _) {
      invocation.ArgumentsRejected(
        "a delegation starts a run; it is not invoked",
      )
    },
    kind: Delegation(
      agent:,
      prompt: fn(arguments) {
        codec.decode_json(input, arguments)
        |> result.map(prompt)
        |> result.map_error(codec.render_json_decode_error)
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
  let explain = fn(message) { failure(Explain(message)) }
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

/// The typed input of `action` when it calls `definition`: the policy's
/// typed match on a tool. `Ok(None)` when the action calls another tool.
///
/// `Error(detail)` when the action names this definition's tool but its
/// arguments do not decode with this definition's input codec: the
/// definition the policy matches on is not the one the agent's tool was
/// bound from (another definition shares its name). The runtime decoded
/// the arguments with the bound tool's codec before the policy ran, so
/// this happens only when the two drifted apart. Pass it on as the
/// policy's error, which stops the run: an action the policy cannot read
/// is never allowed by a fall-through.
///
/// ```gleam
/// fn policy(member: Member, action: policy.Action) {
///   use reservation <- result.try(tool.input(reserve_definition(), action))
///   case reservation {
///     Some(Reservation(isbn:)) -> check_reservation(member, isbn)
///     None -> Ok(policy.Allow)
///   }
/// }
/// ```
pub fn input(
  definition: Definition(input, output),
  action: policy.Action,
) -> Result(Option(input), String) {
  case action.tool == definition.name {
    False -> Ok(None)
    True ->
      codec.decode_json(definition.input, action.arguments_json)
      |> result.map(Some)
      |> result.map_error(fn(error) {
        "the arguments of "
        <> definition.name
        <> " do not decode with the policy's definition: "
        <> codec.render_json_decode_error(error)
      })
  }
}

/// A call to `definition` with `input` encoded by its input codec; the
/// public form is `fabric/testing.call`.
@internal
pub fn call(
  definition: Definition(input, output),
  id: String,
  input: input,
) -> Result(ToolCall, codec.EncodeError) {
  use arguments <- result.map(codec.encode_json(definition.input, input))
  model.ToolCall(
    id:,
    name: definition.name,
    arguments_json: arguments,
    provider_id: None,
    provider_state: None,
  )
}

@internal
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
pub fn kind(tool: Tool(context)) -> Kind {
  tool.kind
}

@internal
pub fn settles_within(tool: Tool(context)) -> Option(Int) {
  tool.settles_within
}

@internal
pub fn invoke(
  tool: Tool(context),
  context: context,
  arguments: String,
  late: Late,
) -> Outcome {
  tool.invoke(context, arguments, late)
}

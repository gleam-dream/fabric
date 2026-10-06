//// Typed application tools.
////
//// A `Definition` owns a tool's name, description, and input and output
//// codecs. Binding it to a handler produces a `Tool(context)`: the typed
//// input, output, and error disappear behind one invocation, so tools with
//// unrelated types share one list. The declaration the model sees and the
//// decoder that checks its arguments come from the same input codec.
////
//// The handler receives the run's context, the `Call` it answers (its run,
//// its action and the run's correlation), and the decoded business input.
//// A handler that makes requests of its own tags them with
//// `call.correlation` (for example `http_gun.with_correlation`), so its
//// work joins the run's events.
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
////   (`settle_within`), for the settlement before it ends, and records it as the
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
////
//// ## With saga
////
//// Copy the recipe into a per-application module. Saga reports its outcome
//// after task cancellation; Fabric accepts settlement up to `rollback_within`.
//// The workflow and its steps inherit the run's correlation. The consumer
//// compiles this block verbatim and the `saga-recipe` gate compares both docs.
////
//// ```gleam
//// import fabric/tool
//// import gleam/result
//// import gleam/time/duration.{type Duration}
//// import saga
//// import saga/execution
//// import saga/outcome.{Definitely, Unknown}
//// import saga/reporting
////
//// pub fn tool(
////   definition: tool.Definition(input, output),
////   workflow: saga.Workflow(workflow_input, output, error, undo_error),
////   config: execution.Config,
////   input input: fn(context, tool.Call, input) -> workflow_input,
////   explain explain: fn(error) -> String,
////   rollback_within rollback_within: Duration,
//// ) -> tool.Tool(context) {
////   let project = fn(result) {
////     case result {
////       Ok(report) -> #(
////         outcome.classify(report, explain)
////           |> result.map_error(fn(failure) {
////             case failure {
////               Definitely(detail) -> tool.Explain(detail)
////               Unknown(detail) -> tool.Uncertain(detail)
////             }
////           }),
////         "Saga reported " <> outcome.summary(report),
////       )
////       Error(error) -> {
////         let detail = reporting.describe_error(error)
////         let failure = case reporting.effect_status(error) {
////           reporting.NotStarted -> tool.Explain(detail)
////           reporting.Unknown -> tool.Uncertain(detail)
////         }
////         #(Error(failure), detail)
////       }
////     }
////   }
////   tool.bind_settling(
////     definition,
////     fn(context, call: tool.Call, value, settlement) {
////       let reported =
////         reporting.run_owned(
////           workflow,
////           input(context, call, value),
////           execution.with_correlation(config, call.correlation),
////           fn(stopped) {
////             let #(result, summary) = project(stopped)
////             let _ = tool.settle(settlement, result, summary:)
////             Nil
////           },
////           rollback_within,
////         )
////       project(reported).0
////     },
////     fn(failure) { failure },
////     settle_within: rollback_within,
////   )
//// }
//// ```
////
//// ## Calling Relay tools
////
//// Copy `relay_tools` into the application; the consumer compiles this exact recipe.
//// See USAGE.md for composition and failure handling.
////
//// ```gleam
//// import fabric/tool
//// import gleam/option.{Some}
//// import relay/client
//// import relay/client/output
//// import relay/tool as remote
////
//// pub fn tool(
////   definition: remote.Definition(i, o),
////   peer peer: fn(c) -> client.Client,
//// ) -> tool.Tool(c) {
////   let declaration = remote.declaration(definition)
////   let assert Some(codec) = remote.output_codec(definition)
////   tool.bind(
////     tool.define(
////       declaration.name,
////       option.unwrap(declaration.description, ""),
////       remote.input_codec(definition),
////       codec,
////     ),
////     fn(context, call: tool.Call, input) {
////       peer(context)
////       |> client.with_correlation(call.correlation)
////       |> client.with_idempotency_key(tool.idempotency_key(call))
////       |> client.call(definition, input)
////       |> output.require
////     },
////     failure(declaration, _),
////   )
//// }
////
//// pub fn failure(
////   declaration: remote.Declaration,
////   error: output.Error,
//// ) -> tool.Failure {
////   let message = output.describe_error(error)
////   case output.evidence(error), declaration.annotations.read_only_hint {
////     client.MaybeSent, hint if hint != Some(True) -> tool.Uncertain(message)
////     _, _ -> tool.Explain(message)
////   }
//// }
//// ```
////
//// ## Discovering Relay tools
////
//// Copy `relay_discovery` into the application; the consumer compiles this exact recipe.
//// See USAGE.md for composition and failure handling.
////
//// ```gleam
//// import fabric/tool
//// import gleam/option
//// import gleam/result
//// import json/blueprint/codec
//// import json/blueprint/contract
//// import relay/client
//// import relay/client/output
//// import relay/tool as remote
//// import relay_tools
////
//// pub type Error {
////   UnsupportedName(String)
////   UnsupportedSchema(contract.DocumentError)
//// }
////
//// pub fn describe_error(error: Error) -> String {
////   case error {
////     UnsupportedName(name) -> "unsupported model tool name: " <> name
////     UnsupportedSchema(error) -> contract.describe_document_error(error)
////   }
//// }
////
//// pub fn discovered(
////   declaration: remote.Declaration,
////   peer peer: fn(c) -> client.Client,
//// ) -> Result(tool.Tool(c), Error) {
////   use Nil <- result.try(case tool.valid_name(declaration.name) {
////     True -> Ok(Nil)
////     False -> Error(UnsupportedName(declaration.name))
////   })
////   use schema <- result.map(
////     remote.input_contract(declaration) |> result.map_error(UnsupportedSchema),
////   )
////   tool.bind(
////     tool.define(
////       declaration.name,
////       option.unwrap(declaration.description, ""),
////       contract.value_codec(schema),
////       codec.value(),
////     ),
////     fn(context, call: tool.Call, input) {
////       peer(context)
////       |> client.with_correlation(call.correlation)
////       |> client.with_idempotency_key(tool.idempotency_key(call))
////       |> client.call_discovered(declaration, input)
////       |> output.require_discovered
////     },
////     relay_tools.failure(declaration, _),
////   )
//// }
//// ```

import gleam/int
import json/blueprint/value
import llm_wire/tool as wire_tool

import fabric/internal/invocation.{type Outcome}
import fabric/internal/tool as core
import fabric/policy
import fabric/run.{type Timeout}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import json/blueprint/codec.{type Codec}
import sinal/correlation.{type Correlation}

/// A tool's name, description, and input and output codecs. Build one with
/// `define`.
pub type Definition(input, output) =
  core.Definition(input, output)

/// What a typed handler error means.
pub type Failure {
  /// The action definitely failed without its effect. The model sees
  /// `{"error": message}` as the tool's result and the run continues.
  Explain(message: String)
  /// The effect may or may not have happened. The run stops before its next
  /// model turn until the action is reconciled; it is never retried.
  Uncertain(evidence: String)
}

/// The call a handler answers. Read it by label: Fabric may add fields.
///
/// `run` and `action` name this call durably (the action survives restarts,
/// so it can key an idempotent request), and `correlation` is the run's
/// (see `fabric.start`): pass it to the packages the handler calls, such as
/// `http_gun.with_correlation` or Saga's `execution.with_correlation`.
pub type Call {
  Call(run: run.RunId, action: run.ActionId, correlation: Correlation)
}

/// A tool bound to its handler, for an agent's tool list. Build one with
/// `bind` or `bind_settling`.
pub type Tool(context) =
  core.Tool(context, Call, SettleError)

/// A handle on one invocation of a tool bound with `bind_settling`, to
/// settle its result after its task was stopped. Whoever holds it may
/// settle; the first settlement the run accepts is the only one.
pub opaque type Settlement(output) {
  Settlement(
    output: Codec(output),
    deliver: core.Late(SettleError),
    action: run.ActionRef,
  )
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
  /// refusal is observed as `settlement_refused` (`fabric/telemetry`).
  NotAwaited
  /// The run could not be read or written, or its runner did not take the
  /// settlement: whether it was recorded is not confirmed. A write the
  /// store reported unavailable has an unknown outcome.
  SettleUnconfirmed(reason: String)
}

pub fn define(
  name: String,
  description: String,
  input: Codec(input),
  output: Codec(output),
) -> Definition(input, output) {
  core.define(name, description, input, output)
}

/// The name the model calls the tool by.
pub fn name(definition: Definition(input, output)) -> String {
  core.definition_name(definition)
}

/// The description the model reads.
pub fn description(definition: Definition(input, output)) -> String {
  core.definition_description(definition)
}

/// The codec of the tool's arguments: its JSON Schema is what the model is
/// told, and it decodes what the model sends. Another runtime that serves
/// the same tool (an MCP server, say) can declare and decode with it.
pub fn input_codec(definition: Definition(input, output)) -> Codec(input) {
  core.definition_input(definition)
}

/// The codec of the tool's result, as the model reads it.
pub fn output_codec(definition: Definition(input, output)) -> Codec(output) {
  core.definition_output(definition)
}

/// Binds a typed handler. `classify` decides, for every typed error, what
/// it means: a definite failure the model sees (`Explain`), or an effect that
/// may have happened (`Uncertain`), which blocks the run until it is
/// reconciled. There is no default: a timeout after a request was sent must
/// not look like a clean failure the model could simply retry.
///
/// The handler runs in its own task with the run's context, the `Call` it
/// answers and the decoded input. Its body is bounded by the agent's
/// timeout (`agent.with_tool_timeout`, 60 s by default) or `with_timeout`.
pub fn bind(
  definition: Definition(input, output),
  handler: fn(context, Call, input) -> Result(output, error),
  classify: fn(error) -> Failure,
) -> Tool(context) {
  let input = core.definition_input(definition)
  let output = core.definition_output(definition)
  core.handler(
    definition,
    fn(context, call, arguments, _late) {
      case codec.decode_json(input, arguments) {
        Error(error) ->
          invocation.ArgumentsRejected(codec.describe_decode_error(error))
        Ok(value) ->
          case handler(context, call, value) {
            Ok(value) -> core.encode(output, value)
            Error(error) -> failure(classify(error))
          }
      }
    },
    None,
  )
}

/// Binds a typed handler that also receives its invocation's `Settlement` (see
/// the module documentation), and whose stopped run waits up to `settle_within`
/// for that settlement before recording an uncertain effect. `settle_within` must
/// be at least 1 ms and at most 2^32 - 1 ms, the longest timer the runtime
/// sets (`agent.build` checks it). The handler's own result is used when it
/// returns; the settlement matters only once its task was stopped, also by
/// its body timeout. `classify` is as for `bind`.
pub fn bind_settling(
  definition: Definition(input, output),
  handler: fn(context, Call, input, Settlement(output)) -> Result(output, error),
  classify: fn(error) -> Failure,
  settle_within within: Duration,
) -> Tool(context) {
  let input = core.definition_input(definition)
  let output = core.definition_output(definition)
  core.handler(
    definition,
    fn(context, call, arguments, late) {
      case codec.decode_json(input, arguments) {
        Error(error) ->
          invocation.ArgumentsRejected(codec.describe_decode_error(error))
        Ok(value) -> {
          let call: Call = call
          let settlement =
            Settlement(output, late, run.ActionRef(call.run, call.action))
          case handler(context, call, value, settlement) {
            Ok(value) -> core.encode(output, value)
            Error(error) -> failure(classify(error))
          }
        }
      }
    },
    Some(within),
  )
}

/// Settles the invocation's result: an output, encoded with the tool's
/// output codec, or a typed failure, `Explain` (definite) or `Uncertain`.
/// Blocks until the run has recorded or refused it. A refusal is observed
/// (`settlement_refused`) with `summary`: what a person needs to reconcile
/// the action when the run did not record the settlement. The summary goes
/// to telemetry handlers, so it must not carry secrets.
pub fn settle(
  settlement: Settlement(output),
  result: Result(output, Failure),
  summary summary: String,
) -> Result(Nil, SettleError) {
  settlement.deliver(
    case result {
      Ok(value) -> core.encode(settlement.output, value)
      Error(error) -> failure(error)
    },
    summary,
  )
}

/// The action this settlement settles: its run and its action id, the
/// reference `fabric.reconcile` takes when the settlement is refused and a
/// person reconciles instead.
pub fn action(settlement: Settlement(output)) -> run.ActionRef {
  settlement.action
}

/// The content `fabric.reconcile` and `fabric.reconcile_stored` take for an
/// action of `definition`: the output encoded with the tool's output codec,
/// as the handler's result would have been, or for `Error(message)` the
/// definite failure the model sees (`{"error": message}`, as for
/// `Explain`). Use it instead of writing the JSON by hand.
///
/// ```gleam
/// let assert Ok(content) =
///   tool.reconciliation(refund_definition, Ok(Refund(id: "r-1")))
/// fabric.reconcile(handle, uncertain.reference, content)
/// ```
pub fn reconciliation(
  definition: Definition(input, output),
  result: Result(output, String),
) -> Result(String, codec.EncodeError) {
  case result {
    Ok(value) -> codec.encode_json(core.definition_output(definition), value)
    Error(message) -> Ok(invocation.error_content(message))
  }
}

/// The content `fabric.reconcile` takes when a person cannot yet say what
/// happened: `{"unconfirmed": note}`, which tells the model the effect may
/// or may not have happened and why, so it does not report the effect as
/// done or as failed.
///
/// An uncertain effect waits for a reconciliation, and the run with it. Leave
/// it unreconciled while the answer is near: the run stays `Suspended`, and
/// `fabric.reconcile` with `reconciliation` later records what happened.
/// Reconcile it as unconfirmed only to let the run go on without the
/// answer: the action then ends `Reconciled` and leaves the run's uncertain
/// effects, so the application tracks the open question from there, and a
/// policy that must not repeat the effect refuses a second call itself.
///
/// ```gleam
/// let content =
///   tool.unconfirmed_reconciliation("finance is checking with the provider")
/// fabric.reconcile(handle, uncertain.reference, content)
/// ```
pub fn unconfirmed_reconciliation(note: String) -> String {
  invocation.unconfirmed_content(note)
}

/// Lets the runtime start this tool's body again, up to `max_attempts`
/// starts in all, when an attempt ends without a result of its own: its
/// body crashed, ran past its timeout, or its runner was lost (a restart,
/// a lost node). Without it, such an action becomes an uncertain effect
/// that a person reconciles.
///
/// Use it only for a tool whose effect is safe to repeat: a read, or a
/// write the handler makes idempotent (keyed by `call.run` and
/// `call.action`, which stay the same across attempts). A typed failure the
/// handler returns (`Explain`, `Uncertain`) is never replayed, nor is a
/// tool stopped by a cancellation. An approved action that is replayed
/// after a lost runner asks for its approval again, as any approved action
/// does at recovery. `agent.build` refuses fewer than 1 or more than 100
/// attempts (`InvalidToolLimit`); `run.ActionRecord.replays` counts the
/// replays.
pub fn with_replay(tool: Tool(context), max_attempts: Int) -> Tool(context) {
  core.with_replay(tool, max_attempts)
}

fn failure(failure: Failure) -> Outcome {
  case failure {
    Explain(message) ->
      invocation.FailedVisibly(invocation.error_content(message))
    Uncertain(evidence) -> invocation.EffectUncertain(evidence)
  }
}

/// The typed input of `action` when it calls `definition`: the policy's
/// typed match on a tool. `Ok(None)` when the action calls another tool.
/// A graph node whose operation has the tool's name (built from the same
/// definition, say) matches too.
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
  let name = core.definition_name(definition)
  case action.name == name {
    False -> Ok(None)
    True ->
      codec.decode_json(
        core.definition_input(definition),
        action.arguments_json,
      )
      |> result.map(Some)
      |> result.map_error(fn(error) {
        "the arguments of "
        <> name
        <> " do not decode with the policy's definition: "
        <> codec.describe_decode_error(error)
      })
  }
}

/// Bounds this tool's body by `timeout` instead of the agent's
/// (`agent.with_tool_timeout`): `run.After(duration)`, or `run.Infinity` for
/// a body that may run as long as it needs. A body still running at its
/// timeout is stopped and its action becomes an uncertain effect (it may
/// have acted), unless the tool is replayable (`with_replay`).
/// `agent.build` refuses a timeout under 1 ms or over 2^32 - 1 ms
/// (`InvalidToolLimit`). A sub-agent delegation has no body: its child
/// run's own limits bound it.
pub fn with_timeout(tool: Tool(context), timeout: Timeout) -> Tool(context) {
  core.with_timeout(tool, timeout)
}

/// Whether a tool name fits the model providers' shared grammar:
/// 1–64 ASCII letters, digits, underscores or hyphens.
pub fn valid_name(name: String) -> Bool {
  wire_tool.check_name(name) |> result.is_ok
}

/// An external idempotency key for this logical action. Stable across
/// replay, independent of correlation, with unambiguous part boundaries.
pub fn idempotency_key(call: Call) -> String {
  run.id_from_parts("action", [
    value.to_string(
      value.Array([
        value.String(run.id_to_string(call.run)),
        value.String(int.to_string(call.action.turn)),
        value.String(call.action.call_id),
      ]),
    ),
  ])
  |> run.id_to_string
}

//// Relay MCP tools for Fabric agents and graphs, and Fabric agents served
//// as Relay MCP tools.
////
//// ## Calling an MCP server from an agent
////
//// `tool(definition, peer:)` turns a Relay tool `Definition` into a Fabric
//// tool: the model sees the definition's name, description and input
//// schema, and a call goes to the client `peer` returns for the run's
//// context. `discover` and `discovered` do the same for tools a server
//// lists at runtime, validating arguments against the advertised schema.
//// `operation(definition, version:, peer:)` is the same call as a graph
//// activity.
////
//// ```gleam
//// let inventory = fn(context: Context) { context.inventory }
//// agent.new("assistant", model, [
////   fabric_relay.tool(search_products(), peer: inventory),
////   fabric_relay.tool(reserve_stock(), peer: inventory),
//// ], policy)
//// ```
////
//// Every call carries the run's correlation (`client.with_correlation`), so
//// the server's events join the run's, and an idempotency key derived from
//// the run and the action (`client.with_idempotency_key`), which stays the
//// same when the action is replayed (`tool.with_replay`) or recovered.
////
//// How a failed call reaches the run:
////
//// | The call | Fabric failure |
//// | --- | --- |
//// | the tool answered `isError: true` | `Explain` with its text: the model sees it |
//// | the tool asked for client input | `Explain`: an agent cannot answer it |
//// | the client sent nothing (`client.NotSent`) | `Explain` |
//// | the server answered with an error (`client.Completed`) | `Explain` |
//// | the request may have reached the server (`client.MaybeSent`) | `Uncertain`, unless the server marks the tool read-only (`readOnlyHint`), then `Explain` |
////
//// An `Uncertain` call stops the run until a person reconciles it: a lost
//// call to a tool that changes state is never retried by the model.
////
//// ## Serving an agent over MCP
////
//// `serve(service(definition, runs:, agent:, start:))` publishes an agent
//// as one Relay tool. Each call starts a run with the call's correlation
//// (`tool.correlation`) and the context and prompt `start` builds, waits
//// for its answer, and answers with it, naming the run in the result's
//// `_meta` (`io.github.gleam-dream/run-id`). An agent whose answer type is
//// the definition's output (`agent.with_answer(output_codec)`) answers with
//// the typed value.
////
//// ```gleam
//// fabric_relay.service(ask_desk(), runs:, agent: desk, start: fn(_call, question) {
////   fabric_relay.start(Nil, prompt: question.text)
//// })
//// |> fabric_relay.serve
//// ```
////
//// A call that carries an idempotency key (`client.with_idempotency_key`)
//// names its run: the run id is derived from the tool, the call's principal
//// (`with_principal`, `anonymous` by default) and the key (`run_id`), so a
//// retried call reaches the same run instead of starting a second one, and
//// waits for it again. Such a run outlives its call: a disconnect or an
//// answer still pending leaves it running for the retry, bounded by the
//// agent's own limits (see `serve`). A call without a key owns its run,
//// which is cancelled when the call is cancelled or its wait ends.

import fabric
import fabric/agent.{type Agent}
import fabric/graph/operation
import fabric/model
import fabric/run.{type RunId}
import fabric/store.{type Store}
import fabric/tool as fabric_tool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import json/blueprint/codec
import json/blueprint/contract
import json/blueprint/value.{type Value}
import relay/client
import relay/content
import relay/tool as relay_tool
import sinal/correlation.{type Correlation}

// --- calling remote tools -------------------------------------------------------

/// A Fabric tool that calls the Relay tool `definition` on the client
/// `peer` returns for the run's context. The definition must have a
/// structured output (`relay/tool.define`); a content-only definition is a
/// bug and panics, so mount such a tool with `discovered` instead.
pub fn tool(
  definition: relay_tool.Definition(input, output),
  peer peer: fn(context) -> client.Client,
) -> fabric_tool.Tool(context) {
  let read_only = read_only(relay_tool.declaration(definition))
  fabric_tool.bind(
    fabric_tool.define(
      relay_tool.name(definition),
      description(relay_tool.declaration(definition)),
      relay_tool.input_codec(definition),
      structured_output(definition, "tool"),
    ),
    fn(context, call: fabric_tool.Call, input) {
      peer(context)
      |> view(call.correlation, action_key(call))
      |> client.call(definition, input)
      |> outcome
    },
    classify(read_only, _),
  )
}

/// The Relay tool `definition` as a graph activity named after it, at
/// `version` (see `operation.new`). Every attempt carries the run's
/// correlation and an idempotency key derived from the run and the
/// activation, the same for every attempt of a replayed activity
/// (`operation.with_replay`). Failures are classified as for `tool`. A
/// content-only definition panics, as for `tool`.
pub fn operation(
  definition: relay_tool.Definition(input, output),
  version version: Int,
  peer peer: fn(context) -> client.Client,
) -> operation.Operation(context, input, output) {
  let read_only = read_only(relay_tool.declaration(definition))
  operation.new(
    run.DefinitionId(relay_tool.name(definition), version),
    relay_tool.input_codec(definition),
    structured_output(definition, "operation"),
    fn(context, invocation: operation.Invocation, input) {
      let key =
        key("graph", [
          run.id_to_string(invocation.run),
          int.to_string(invocation.activation),
        ])
      peer(context)
      |> view(invocation.correlation, key)
      |> client.call(definition, input)
      |> outcome
    },
    classify(read_only, _),
  )
}

/// Why `discover` or `discovered` could not mount a listed tool.
pub type DiscoveryError {
  /// `tools/list` failed.
  ListingFailed(client.Error)
  /// The tool's name is not one a model provider accepts
  /// (`^[a-zA-Z0-9_-]{1,64}$`).
  UnsupportedName(tool: String)
  /// Blueprint cannot load the tool's input schema.
  UnsupportedSchema(tool: String, reason: String)
}

/// One line for logs.
pub fn describe_discovery_error(error: DiscoveryError) -> String {
  case error {
    ListingFailed(error) ->
      "the MCP tool listing failed: " <> client.describe_error(error)
    UnsupportedName(name) ->
      "the MCP tool name " <> name <> " is not a valid model tool name"
    UnsupportedSchema(name, reason) ->
      "the input schema of the MCP tool "
      <> name
      <> " cannot be used: "
      <> reason
  }
}

/// Lists `connected`'s tools now and mounts each with `discovered`, or
/// fails on the first tool that cannot be mounted. To skip such tools, list
/// with `client.list_tools` and mount each with `discovered`.
pub fn discover(
  connected: client.Client,
  peer peer: fn(context) -> client.Client,
) -> Result(List(fabric_tool.Tool(context)), DiscoveryError) {
  use declarations <- result.try(
    client.list_tools(connected) |> result.map_error(ListingFailed),
  )
  list.try_map(declarations, discovered(_, peer:))
}

/// A Fabric tool for a tool a server listed (`client.list_tools`), without a
/// native type: the model's arguments are validated against the advertised
/// input schema before the call, and the result the model sees is the
/// structured content as the server sent it, or the text of a content-only
/// result.
pub fn discovered(
  declaration: relay_tool.Declaration,
  peer peer: fn(context) -> client.Client,
) -> Result(fabric_tool.Tool(context), DiscoveryError) {
  use Nil <- result.try(case valid_name(declaration.name) {
    True -> Ok(Nil)
    False -> Error(UnsupportedName(declaration.name))
  })
  use remote <- result.map(
    relay_tool.input_contract(declaration)
    |> result.map_error(fn(error) {
      UnsupportedSchema(
        declaration.name,
        contract.describe_document_error(error),
      )
    }),
  )
  fabric_tool.bind(
    fabric_tool.define(
      declaration.name,
      description(declaration),
      contract.value_codec(remote),
      codec.value(),
    ),
    fn(context, call: fabric_tool.Call, arguments) {
      peer(context)
      |> view(call.correlation, action_key(call))
      |> client.call_discovered(declaration, arguments)
      |> result.map(fn(result) {
        case result, declaration.output_schema {
          client.Succeeded(value.Null, blocks), None ->
            client.Succeeded(value.String(text_of(blocks)), blocks)
          other, _ -> other
        }
      })
      |> outcome
    },
    classify(read_only(declaration), _),
  )
}

fn valid_name(name: String) -> Bool {
  let allowed =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
  let length = string.length(name)
  length >= 1
  && length <= 64
  && list.all(string.to_graphemes(name), string.contains(allowed, _))
}

fn structured_output(
  definition: relay_tool.Definition(input, output),
  caller: String,
) -> codec.Codec(output) {
  case relay_tool.output_codec(definition) {
    Some(output) -> output
    None ->
      panic as {
        "fabric_relay."
        <> caller
        <> ": the Relay tool "
        <> relay_tool.name(definition)
        <> " returns content only; mount it with fabric_relay.discovered"
      }
  }
}

fn description(declaration: relay_tool.Declaration) -> String {
  option.unwrap(declaration.description, "")
}

fn read_only(declaration: relay_tool.Declaration) -> Bool {
  declaration.annotations.read_only_hint == Some(True)
}

/// The client view one call goes through: the run's correlation and a key
/// that names the call across retries.
fn view(peer: client.Client, correlation: Correlation, key: String) {
  peer
  |> client.with_correlation(correlation)
  |> client.with_idempotency_key(key)
}

fn action_key(call: fabric_tool.Call) -> String {
  key("action", [
    run.id_to_string(call.run),
    int.to_string(call.action.turn),
    call.action.call_id,
  ])
}

/// 1 to 128 letters, digits, `-` and `_`, as Relay accepts: the text of a
/// run id derived from the parts.
fn key(prefix: String, parts: List(String)) -> String {
  run.id_to_string(run.id_from_parts(prefix, parts))
}

/// Why a call did not give its output.
type Failure {
  ToolFailed(message: String)
  InputRequired
  CallFailed(client.Error)
}

fn outcome(
  result: Result(client.ToolResult(output), client.Error),
) -> Result(output, Failure) {
  case result {
    Ok(client.Succeeded(output, _)) -> Ok(output)
    Ok(client.ToolFailed(blocks, _)) -> Error(ToolFailed(text_of(blocks)))
    Ok(client.InputRequired(..)) -> Error(InputRequired)
    Error(error) -> Error(CallFailed(error))
  }
}

fn classify(read_only: Bool, failure: Failure) -> fabric_tool.Failure {
  case failure {
    ToolFailed("") -> fabric_tool.Explain("the tool failed")
    ToolFailed(message) -> fabric_tool.Explain(message)
    InputRequired ->
      fabric_tool.Explain(
        "the tool asked for client input, which an agent cannot give",
      )
    CallFailed(error) -> {
      let detail =
        client.describe_error(error) <> " (" <> client.name(error) <> ")"
      case client.evidence(error), read_only {
        client.MaybeSent, False ->
          fabric_tool.Uncertain(
            "the call may have reached the MCP server: " <> detail,
          )
        client.MaybeSent, True | client.NotSent, _ | client.Completed, _ ->
          fabric_tool.Explain("the MCP call failed: " <> detail)
      }
    }
  }
}

fn text_of(blocks: List(content.ContentBlock)) -> String {
  blocks
  |> list.filter_map(fn(block) {
    case block {
      content.TextContent(text:, ..) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join("\n")
}

// --- serving an agent -------------------------------------------------------------

/// What one call starts: the run's context and prompt and the principal
/// it runs for, or a refusal. Build it with `start` (and `with_principal`)
/// or `refuse`.
pub opaque type Start(context) {
  Start(context: context, prompt: String, principal: String)
  Refuse(error: relay_tool.ToolError)
}

/// The principal of a call whose `start` names none: one trusted client,
/// as over stdio.
pub const anonymous = "anonymous"

/// The run a call starts, with `context` and `prompt`, for the `anonymous`
/// principal. Relay's call names no authenticated subject of its own (the
/// server's context holds it, `tool.context(call)`): a server with more
/// than one client names it with `with_principal`.
pub fn start(context: context, prompt prompt: String) -> Start(context) {
  Start(context:, prompt:, principal: anonymous)
}

/// Names who the call runs for (a token's subject, from the server's
/// context). An idempotency key is scoped by it, so one client cannot reach
/// another's run with the same key.
pub fn with_principal(
  start: Start(context),
  principal: String,
) -> Start(context) {
  case start {
    Start(..) -> Start(..start, principal:)
    Refuse(_) -> start
  }
}

/// Refuses the call with `error` as its `isError` result; no run starts.
pub fn refuse(error: relay_tool.ToolError) -> Start(context) {
  Refuse(error)
}

/// An agent served as the MCP tool `definition`: its store, the agent, how
/// a call starts its run, and how long a call waits for the answer. Build it
/// with `service` and the `with_*` setters, and publish it with `serve`.
pub opaque type Service(server_context, context, input, answer) {
  Service(
    definition: relay_tool.Definition(input, answer),
    runs: Store,
    agent: Agent(context, answer),
    start: fn(relay_tool.Call(server_context), input) -> Start(context),
    wait: Duration,
  )
}

const longest_timer = 4_294_967_295

/// A service that publishes `agent`, run in `runs`, as the tool
/// `definition`. For each call, `start` builds the run's context and prompt
/// from the call (`tool.context(call)` is the server's context, such as the
/// authenticated principal) and its decoded input, or refuses the call
/// (`refuse`). A call waits 25 seconds for the answer (`with_wait`).
///
/// ```gleam
/// fabric_relay.service(ask_desk(), runs:, agent: desk, start: fn(call, question) {
///   fabric_relay.start(Nil, prompt: question.text)
///   |> fabric_relay.with_principal(tool.context(call).subject)
/// })
/// |> fabric_relay.serve
/// ```
pub fn service(
  definition: relay_tool.Definition(input, answer),
  runs runs: Store,
  agent agent: Agent(context, answer),
  start start: fn(relay_tool.Call(server_context), input) -> Start(context),
) -> Service(server_context, context, input, answer) {
  Service(definition:, runs:, agent:, start:, wait: duration.seconds(25))
}

/// How long a call waits for its run's answer before it answers that the
/// run is still working. Keep it shorter than the server's request and
/// invocation timeouts (`relay/http.with_request_timeout`,
/// `relay/runtime.with_invocation_timeout`, 30 s by default): when Relay
/// ends the call first, a run the call owns is cancelled. From 1 ms to
/// 2^32 - 1 ms; another value is a bug and panics.
pub fn with_wait(
  service: Service(server_context, context, input, answer),
  wait: Duration,
) -> Service(server_context, context, input, answer) {
  let ms = duration.to_milliseconds(wait)
  case ms >= 1 && ms <= longest_timer {
    True -> Service(..service, wait:)
    False ->
      panic as {
        "fabric_relay.with_wait: the wait must be 1 ms to 2^32 - 1 ms, not "
        <> int.to_string(ms)
        <> " ms"
      }
  }
}

/// The run a call to `definition` with idempotency key `key` starts for
/// `principal`: the same parts always name the same run, so the
/// application can open it (`fabric.open`) to answer its approvals.
pub fn run_id(
  definition: relay_tool.Definition(input, answer),
  principal principal: String,
  key key: String,
) -> RunId {
  run.id_from_parts("mcp", [relay_tool.name(definition), principal, key])
}

/// Publishes `service`'s agent as its Relay tool, for `relay/server.new`.
/// A call answers with the run's answer when it completes in time; the
/// answer's text block names the run in its `_meta`
/// (`io.github.gleam-dream/run-id`; a content-only definition's answer has
/// none). Otherwise it answers `isError: true` with a line for people,
/// whose `_meta` names the run the same way, and, as structured content, an
/// object whose `error` names what happened and whose `run_id` names the
/// run:
///
/// | `error` | The run |
/// | --- | --- |
/// | `working` | still works after the wait; a retry with the same key waits again |
/// | `timed_out` | still worked after the wait; without a key, it was cancelled |
/// | `awaiting_approval` | waits for an approval (`approvals` lists the tools) |
/// | `outcome_unknown` | stopped on effects of unknown status (`uncertain` lists them) |
/// | `unattended` | has work in flight and no runner (`fabric.recover`) |
/// | `cancelled` | was cancelled, or the call was |
/// | `answer_invalid`, `refused`, `output_limited`, `budget_exhausted`, `budget_unverifiable`, `failed` | ended so (`run.describe_outcome`) |
/// | `key_reused` | the key names a run started with another prompt |
/// | `start_failed`, `unavailable` | could not be started or read (`fabric.describe_error`) |
///
/// The list may grow: match the values a client handles and keep a
/// default.
///
/// A call without a key owns its run, which ends with the call. A keyed
/// run outlives it, bounded by the agent's own limits: its model attempts
/// (`agent.with_max_turns`), model and tool timeouts, an optional token
/// budget, and its approval requests, which expire after 7 days by default
/// (`agent.with_approval_expiry`) and reject their action. One wait has no
/// bound: a run stopped on an effect of unknown status (`outcome_unknown`)
/// waits for a person to reconcile it, by design, since ending it would
/// hide the effect. Find such runs by the `run_id` the call answered, and
/// reconcile (`fabric.reconcile`) or cancel (`fabric.cancel`) them; an
/// `unattended` run waits for `fabric.recover` or a sweeper.
pub fn serve(
  service: Service(server_context, context, input, answer),
) -> relay_tool.Tool(server_context) {
  let definition = service.definition
  relay_tool.handle_call(definition, fn(call, input) {
    use #(context, prompt, principal) <- result.try(
      case service.start(call, input) {
        Start(context:, prompt:, principal:) ->
          Ok(#(context, prompt, principal))
        Refuse(error) -> Error(error)
      },
    )
    let key = relay_tool.idempotency_key(call)
    let id = case key {
      Some(key) -> run_id(definition, principal:, key:)
      None -> run.new_id()
    }
    use handle <- result.try(begin(service, id, key, context, prompt, call))
    let owned = key == None
    let ending = case owned {
      True -> relay_tool.cancelled(call)
      False -> process.new_selector()
    }
    case fabric.await_with(handle, within: service.wait, or: ending) {
      Ok(fabric.Reached(run.Finished(run.Completed(answer)))) ->
        Ok(completed(definition, answer, id))
      Ok(fabric.Reached(status)) -> Error(unfinished(handle, status, owned))
      Ok(fabric.Interrupted(Nil)) -> {
        let _ = fabric.cancel(handle)
        Error(failure("cancelled", id, "the call was cancelled", []))
      }
      Error(error) ->
        Error(failure("unavailable", id, fabric.describe_error(error), []))
    }
  })
}

/// The `_meta` key that names a served call's run.
const run_id_meta = "io.github.gleam-dream/run-id"

fn run_meta(id: RunId) -> content.Meta {
  [#(run_id_meta, value.String(run.id_to_string(id)))]
}

/// The run's answer, with a text block that mirrors it (as Relay's own
/// does) and names the run.
fn completed(
  definition: relay_tool.Definition(input, answer),
  answer: answer,
  id: RunId,
) -> relay_tool.Reply(answer) {
  let encoded =
    relay_tool.output_codec(definition)
    |> option.to_result(Nil)
    |> result.try(fn(output) {
      codec.encode(output, answer) |> result.replace_error(Nil)
    })
  case encoded {
    Ok(encoded) ->
      relay_tool.complete_with_content(answer, [
        content.text(case encoded {
          value.String(text) -> text
          other -> value.to_string(other)
        })
        |> content.with_meta(run_meta(id)),
      ])
    Error(Nil) -> relay_tool.complete(answer)
  }
}

/// Starts the call's run, or for a retried key opens the run it started.
fn begin(
  service: Service(server_context, context, input, answer),
  id: RunId,
  key: Option(String),
  context: context,
  prompt: String,
  call: relay_tool.Call(server_context),
) -> Result(fabric.Run(context, answer), relay_tool.ToolError) {
  let started =
    fabric.start(
      service.runs,
      service.agent,
      id:,
      context:,
      prompt:,
      correlation: Some(relay_tool.correlation(call)),
    )
  case started, key {
    Ok(handle), _ -> Ok(handle)
    Error(fabric.AlreadyStarted(..)), Some(_) -> {
      let opened =
        fabric.open(service.runs, service.agent, context, id)
        |> result.try(fn(handle) {
          fabric.snapshot(handle) |> result.map(fn(s) { #(handle, s) })
        })
      case opened {
        Ok(#(handle, snapshot)) ->
          case snapshot.transcript {
            [model.UserMessage(stored), ..] if stored == prompt -> Ok(handle)
            _ ->
              Error(
                failure(
                  "key_reused",
                  id,
                  "the idempotency key names a run started with another request",
                  [],
                ),
              )
          }
        Error(error) ->
          Error(failure("unavailable", id, fabric.describe_error(error), []))
      }
    }
    Error(error), _ ->
      Error(failure("start_failed", id, fabric.describe_error(error), []))
  }
}

/// The `isError` result for a run that did not complete in time. A run the
/// call owns is cancelled when it is still working.
fn unfinished(
  handle: fabric.Run(context, answer),
  status: run.Status(answer),
  owned: Bool,
) -> relay_tool.ToolError {
  let id = fabric.id(handle)
  case status {
    run.Working if owned -> {
      let _ = fabric.cancel(handle)
      failure("timed_out", id, "no answer in time; the run was cancelled", [])
    }
    run.Working ->
      failure(
        "working",
        id,
        "the run is still working; call again with the same idempotency key",
        [],
      )
    run.Unattended ->
      failure("unattended", id, "the run has work in flight and no runner", [])
    run.Suspended(_, [_, ..] as uncertain) ->
      failure(
        "outcome_unknown",
        id,
        "the run stopped on effects of unknown status; a person must reconcile them",
        [
          #(
            "uncertain",
            value.Array(
              list.map(uncertain, fn(effect) {
                value.Object([
                  #("tool", value.String(effect.tool)),
                  #("evidence", value.String(effect.evidence)),
                ])
              }),
            ),
          ),
        ],
      )
    run.Suspended(approvals, []) ->
      failure("awaiting_approval", id, "the run waits for an approval", [
        #(
          "approvals",
          value.Array(
            list.map(approvals, fn(pending) {
              value.Object([#("tool", value.String(pending.tool))])
            }),
          ),
        ),
      ])
    run.Finished(outcome) ->
      failure(outcome_name(outcome), id, run.describe_outcome(outcome), [])
  }
}

fn outcome_name(outcome: run.Outcome(answer)) -> String {
  case outcome {
    run.Completed(_) -> "completed"
    run.AnswerInvalid(..) -> "answer_invalid"
    run.Refused(_) -> "refused"
    run.OutputLimited(_) -> "output_limited"
    run.BudgetExhausted(_) -> "budget_exhausted"
    run.BudgetUnverifiable(_) -> "budget_unverifiable"
    run.Cancelled -> "cancelled"
    run.Failed(_) -> "failed"
  }
}

fn failure(
  name: String,
  id: RunId,
  text: String,
  facts: List(#(String, Value)),
) -> relay_tool.ToolError {
  relay_tool.error_with(
    [content.text(text) |> content.with_meta(run_meta(id))],
    Some(
      value.Object([
        #("error", value.String(name)),
        #("run_id", value.String(run.id_to_string(id))),
        ..facts
      ]),
    ),
  )
}

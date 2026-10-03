//// The versioned JSON encoding of a run record: the controller state with
//// no closures and no live values, so that a stored run can be decoded by
//// a later process, including after a restart.
////
//// ```json
//// {"format": "fabric.run", "version": 1, "run": "...", "agent": {...},
////  "incarnation": 2, "limits": {...}, "turns_used": 1, "usage": {...},
////  "transcript": [...], "history": [...], "approvals_issued": 1,
////  "phase": {"tag": "acting", ...}}
//// ```
////
//// Every encoding carries a fresh random `"write"` token, which decoding
//// ignores. Two writers that encode the same state therefore write
//// different records, so a writer that reads its write back after an
//// `Unavailable` recognises its own write, never an identical one by
//// another writer.
////
//// Sums are objects with a `"tag"`; an absent optional value is `null`.
//// Decoding checks the format and version first: an unknown version is
//// `UnsupportedVersion`, anything unreadable is `Corrupt`. Compatibility
//// with the agent that continues the run is a separate check.
////
//// Version 2 adds sub-agents: the run's `parent` and `depth`, the limits
//// `max_children` and `max_depth`, each action's `child`, and the action
//// states `delegated` and `limit_reached`. A version 1 record is read as a
//// root run (no parent, depth 0) that may start no sub-agents (both limits
//// 0) and whose actions started none. Writes use the store's chosen version,
//// defaulting to the current version.
////
//// Version 3 records a child run cancelled before it started as the phase
//// `never_started`. Version 2 stored it as an ended, cancelled run with no
//// transcript, which is read as `never_started`; any other version 1 or 2
//// record reads as it did.
////
//// Version 4 keeps each assistant turn's optional adapter data alongside its
//// text and calls. Earlier formats cannot retain it and are refused when it
//// is present. Legacy transcripts decode with no adapter data.
////
//// Version 5 distinguishes agent-action and graph-activation parents. An
//// agent parent can still be written in versions 2–4; a graph parent cannot.
//// Version 6 adds `child_settled`, retained evidence on a finished parent's
//// delegation. Earlier writers refuse this state instead of inventing a
//// model-visible result.
//// Version 7 retains optional family budget limits on roots. Earlier writers
//// refuse configured limits; children inherit from their saved root.
////
//// A run whose correlation the caller chose (`fabric.start`) or inherited
//// from its parent stores it as `"correlation"`, in any version; a reader
//// that ignores the key derives the correlation from the run id, which is
//// also what a record without it means. A run with that derived
//// correlation writes no key, so its bytes are as before.
////
//// An outcome's budget is written under its own tag (`turn_limit`,
//// `token_limit`). The tag `budget_exhausted`, which wraps a budget, is
//// still read; it was written only for a sub-agent limit ending a run,
//// which no run did, and a sub-agent limit now only refuses a delegation
//// (`limit_reached`).
////
//// The `stopping` phase records `tools_stopped`, whether the executor
//// confirmed that no tool task runs. A record without it reads as not yet
//// confirmed, which refuses late settlements until recovery completes the
//// stop.

import fabric/graph/child
import fabric/internal/budget/config as budget_config
import fabric/internal/controller.{type Phase, type State, State}
import fabric/internal/registry.{type Registry}
import fabric/internal/run_id
import fabric/model.{type Message, type ToolCall}
import fabric/run.{
  type ActionId, type ActionRecord, type ActionState, type Approval,
  type DefinitionId, type HostFailure, type Incompatibility, type Outcome,
  type Requirement, ActionId, ActionRecord, DefinitionId, Requirement,
}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import sinal/correlation.{type Correlation}

pub const format = "fabric.run"

pub const version = 7

/// The writer window is narrower than the reader's accepted versions.
pub type WriteVersion {
  V2
  V3
  V4
  V5
  V6
  V7
}

pub fn writer(version: Int) -> Result(WriteVersion, Nil) {
  case version {
    2 -> Ok(V2)
    3 -> Ok(V3)
    4 -> Ok(V4)
    5 -> Ok(V5)
    6 -> Ok(V6)
    7 -> Ok(V7)
    _ -> Error(Nil)
  }
}

pub type EncodeError {
  Unrepresentable(version: Int, detail: String)
}

/// Encodes without changing the record's meaning for the chosen reader.
/// Version 2 used an empty cancelled transcript for a child never started.
pub fn encode_as(
  state: State,
  target: WriteVersion,
) -> Result(String, EncodeError) {
  use Nil <- result.try(case state.parent {
    Some(run.GraphBranch(..)) ->
      Error(Unrepresentable(
        writer_number(target),
        "fork members must be graph runs",
      ))
    _ -> Ok(Nil)
  })
  use Nil <- result.try(
    budget_config.validate(state.parent == None, state.family_budget)
    |> result.map_error(Unrepresentable(writer_number(target), _)),
  )
  use Nil <- result.try(case target, state.family_budget {
    V7, _ | _, None -> Ok(Nil)
    _, Some(_) ->
      Error(Unrepresentable(
        writer_number(target),
        "family budgets require version 7",
      ))
  })
  use Nil <- result.try(case target == V7 || !has_family_refusal(state) {
    True -> Ok(Nil)
    False ->
      Error(Unrepresentable(
        writer_number(target),
        "family budget refusals require version 7",
      ))
  })
  use Nil <- result.try(case target, state.parent {
    V5, _ | V6, _ | V7, _ -> Ok(Nil)
    _, Some(run.GraphParent(..)) ->
      Error(Unrepresentable(
        writer_number(target),
        "a graph parent requires version 5",
      ))
    _, _ -> Ok(Nil)
  })
  use Nil <- result.try(case target {
    V6 | V7 -> Ok(Nil)
    _ -> {
      let settled =
        list.any(state_actions(state), fn(action) {
          case action.state {
            run.ChildSettled(_) -> True
            _ -> False
          }
        })
      case settled {
        False -> Ok(Nil)
        True ->
          Error(Unrepresentable(
            writer_number(target),
            "settled child evidence requires version 6",
          ))
      }
    }
  })
  let has_data =
    list.any(state.transcript, fn(message) {
      case message {
        model.AssistantMessage(model.AssistantTurn(data: Some(_), ..)) -> True
        _ -> False
      }
    })
  use Nil <- result.try(case target, has_data {
    V2, True ->
      Error(Unrepresentable(2, "assistant provider data requires version 4"))
    V3, True ->
      Error(Unrepresentable(3, "assistant provider data requires version 4"))
    _, _ -> Ok(Nil)
  })
  case target, state.phase, state.transcript {
    V7, _, _ -> Ok(encode(state))
    V6, _, _ -> Ok(encode_version(state, 6, state.phase))
    V5, _, _ -> Ok(encode_version(state, 5, state.phase))
    V4, _, _ -> Ok(encode_version(state, 4, state.phase))
    V3, _, _ -> Ok(encode_version(state, 3, state.phase))
    V2, controller.NeverStarted, [] ->
      Ok(encode_version(state, 2, controller.Ended(run.Cancelled)))
    V2, controller.NeverStarted, [_, ..] ->
      Error(Unrepresentable(2, "a never-started run has a transcript"))
    V2, controller.Ended(run.Cancelled), [] ->
      Error(Unrepresentable(
        2,
        "an empty cancelled run would mean never started",
      ))
    V2, _, _ -> Ok(encode_version(state, 2, state.phase))
  }
}

fn writer_number(target: WriteVersion) -> Int {
  case target {
    V2 -> 2
    V3 -> 3
    V4 -> 4
    V5 -> 5
    V6 -> 6
    V7 -> 7
  }
}

pub type DecodeError {
  UnsupportedVersion(found: Int)
  Corrupt(detail: String)
}

// --- encoding ------------------------------------------------------------------

/// Encodes `state` with a fresh write token: two calls never return the
/// same text. Encode once per write, and retry that write with the same
/// text.
pub fn encode(state: State) -> String {
  encode_version(state, version, state.phase)
}

fn encode_version(state: State, version: Int, phase: Phase) -> String {
  let fields = [
    #("format", json.string(format)),
    #("version", json.int(version)),
    #("write", json.string(write_token())),
    #("run", json.string(state.run)),
    #("agent", identity(state.agent)),
    #("incarnation", json.int(state.incarnation)),
    #(
      "parent",
      json.nullable(state.parent, fn(parent) {
        case parent {
          run.AgentParent(id, action) -> {
            let fields = [
              #("run", json.string(run.id_to_string(id))),
              #("action", action_id(action)),
            ]
            case version >= 5 {
              True -> tag("agent", fields)
              False -> json.object(fields)
            }
          }
          run.GraphParent(id, activation) ->
            tag("graph", [
              #("run", json.string(run.id_to_string(id))),
              #("activation", json.int(activation)),
            ])
          run.GraphBranch(id, activation, member) ->
            tag("graph_branch", [
              #("run", json.string(run.id_to_string(id))),
              #("activation", json.int(activation)),
              #("member", json.int(member)),
            ])
        }
      }),
    ),
    #("depth", json.int(state.depth)),
    #(
      "limits",
      json.object([
        #("max_turns", json.int(state.limits.max_turns)),
        #("token_budget", json.nullable(state.limits.token_budget, json.int)),
        #("max_children", json.int(state.limits.max_children)),
        #("max_depth", json.int(state.limits.max_depth)),
      ]),
    ),
    #("turns_used", json.int(state.turns_used)),
    #(
      "usage",
      json.object([
        #("input_tokens", json.int(state.usage.input_tokens)),
        #("output_tokens", json.int(state.usage.output_tokens)),
        #("unreported_replies", json.int(state.usage.unreported_replies)),
      ]),
    ),
    #(
      "transcript",
      json.array(state.transcript, fn(item) { message(item, version) }),
    ),
    #("history", json.array(state.history, action)),
    #("approvals_issued", json.int(state.approvals_issued)),
    #("phase", phase_json(phase)),
  ]
  let fields = case version >= 7 {
    True ->
      list.append(fields, [
        #(
          "family_budget",
          json.nullable(state.family_budget, budget_config.encode_declaration),
        ),
      ])
    False -> fields
  }
  // Only a correlation the caller chose is stored: a record with the
  // default one keeps the bytes it had before correlations existed.
  let fields = case state.correlation == correlation.from_key(state.run) {
    True -> fields
    False ->
      list.append(fields, [
        #("correlation", json.string(correlation.to_string(state.correlation))),
      ])
  }
  json.object(fields)
  |> json.to_string
}

@external(erlang, "fabric_ffi", "random_id")
fn write_token() -> String

fn tag(name: String, fields: List(#(String, Json))) -> Json {
  json.object([#("tag", json.string(name)), ..fields])
}

fn identity(identity: DefinitionId) -> Json {
  json.object([
    #("name", json.string(identity.name)),
    #("version", json.int(identity.version)),
  ])
}

fn message(message: Message, version: Int) -> Json {
  case message {
    model.UserMessage(text) -> tag("user", [#("text", json.string(text))])
    model.AssistantMessage(model.AssistantTurn(text, calls, data)) ->
      tag("assistant", [
        #("text", json.string(text)),
        #("calls", json.array(calls, tool_call)),
        ..case version >= 4 {
          True -> [
            #(
              "data",
              json.nullable(data, fn(data) {
                json.object([
                  #("format", json.string(data.format)),
                  #("value", json.string(data.value)),
                ])
              }),
            ),
          ]
          False -> []
        }
      ])
    model.ToolResultMessage(call_id, content) ->
      tag("tool_result", [
        #("call_id", json.string(call_id)),
        #("content", json.string(content)),
      ])
  }
}

fn tool_call(call: ToolCall) -> Json {
  json.object([
    #("id", json.string(call.id)),
    #("name", json.string(call.name)),
    #("arguments", json.string(call.arguments_json)),
    #("provider_id", json.nullable(call.provider_id, json.string)),
    #("provider_state", json.nullable(call.provider_state, json.string)),
  ])
}

fn run_id(id: run.RunId) -> Json {
  json.string(run.id_to_string(id))
}

fn action_id(id: ActionId) -> Json {
  json.object([
    #("turn", json.int(id.turn)),
    #("call_id", json.string(id.call_id)),
  ])
}

fn requirement(requirement: Requirement) -> Json {
  json.object([
    #("name", json.string(requirement.name)),
    #("version", json.int(requirement.version)),
  ])
}

fn action(action: ActionRecord) -> Json {
  json.object([
    #("id", action_id(action.id)),
    #("call", tool_call(action.call)),
    #("state", action_state(action.state)),
    #("approvals", json.array(action.approvals, approval)),
    #("child", json.nullable(action.child, run_id)),
  ])
}

fn approval(approval: Approval) -> Json {
  json.object([
    #("requirement", requirement(approval.requirement)),
    #("revision", json.int(approval.revision)),
    #("answer", case approval.answer {
      run.Approve -> tag("approve", [])
      run.Reject(reason) -> tag("reject", [#("reason", json.string(reason))])
    }),
    #("reviewer", json.nullable(approval.reviewer, json.string)),
  ])
}

fn action_state(state: ActionState) -> Json {
  case state {
    run.Queued -> tag("queued", [])
    run.Running -> tag("running", [])
    run.AwaitingApproval(required, revision) ->
      tag("awaiting_approval", [
        #("requirement", requirement(required)),
        #("revision", json.int(revision)),
      ])
    run.Succeeded(content) ->
      tag("succeeded", [#("content", json.string(content))])
    run.ToolFailed(content) ->
      tag("tool_failed", [#("content", json.string(content))])
    run.Denied(reason) -> tag("denied", [#("reason", json.string(reason))])
    run.Rejected(reason) -> tag("rejected", [#("reason", json.string(reason))])
    run.InvalidArguments(detail) ->
      tag("invalid_arguments", [#("detail", json.string(detail))])
    run.UnknownTool -> tag("unknown_tool", [])
    run.Uncertain(evidence) ->
      tag("uncertain", [#("evidence", json.string(evidence))])
    run.Reconciled(content) ->
      tag("reconciled", [#("content", json.string(content))])
    run.ChildSettled(outcome) ->
      tag("child_settled", [#("outcome", outcome_json(outcome))])
    run.NotStarted -> tag("not_started", [])
    run.Faulted(detail) -> tag("faulted", [#("detail", json.string(detail))])
    run.Delegated -> tag("delegated", [])
    run.LimitReached(limit) ->
      tag("limit_reached", [#("budget", delegation_limit(limit))])
  }
}

fn delegation_limit(limit: run.DelegationLimit) -> Json {
  case limit {
    run.ChildLimit(limit) -> tag("child_limit", [#("limit", json.int(limit))])
    run.DepthLimit(limit) -> tag("depth_limit", [#("limit", json.int(limit))])
  }
}

fn phase_json(phase: Phase) -> Json {
  case phase {
    controller.AwaitingModel(turn) ->
      tag("awaiting_model", [#("turn", json.int(turn))])
    controller.Acting(turn, actions) ->
      tag("acting", [
        #("turn", json.int(turn)),
        #("actions", json.array(actions, action)),
      ])
    controller.Stopping(turn, actions, reason, tools_stopped) ->
      tag("stopping", [
        #("turn", json.int(turn)),
        #("actions", json.array(actions, action)),
        #("tools_stopped", json.bool(tools_stopped)),
        #("reason", case reason {
          controller.CancelRequested -> tag("cancel_requested", [])
          controller.HostFault(failure) ->
            tag("host_fault", [#("failure", host_failure(failure))])
          controller.FamilyBudget(reason) ->
            tag("family_budget", [
              #("denial", budget_config.encode_denial(reason)),
            ])
        }),
      ])
    controller.Ended(outcome) ->
      tag("ended", [#("outcome", outcome_json(outcome))])
    controller.NeverStarted -> tag("never_started", [])
  }
}

fn outcome_json(outcome: Outcome) -> Json {
  case outcome {
    run.Completed(text) -> tag("completed", [#("text", json.string(text))])
    run.Refused(reason) -> tag("refused", [#("reason", json.string(reason))])
    run.OutputLimited(partial) ->
      tag("output_limited", [#("partial_text", json.string(partial))])
    run.BudgetExhausted(run.TurnLimit(limit)) ->
      tag("turn_limit", [#("limit", json.int(limit))])
    run.BudgetExhausted(run.TokenLimit(limit, used)) ->
      tag("token_limit", [
        #("limit", json.int(limit)),
        #("used", json.int(used)),
      ])
    run.BudgetExhausted(run.FamilyLimit(reason)) ->
      tag("family_budget", [#("denial", budget_config.encode_denial(reason))])
    run.BudgetUnverifiable(turn) ->
      tag("budget_unverifiable", [#("turn", json.int(turn))])
    run.Cancelled -> tag("cancelled", [])
    run.Failed(failure) -> tag("failed", [#("failure", host_failure(failure))])
  }
}

fn host_failure(failure: HostFailure) -> Json {
  case failure {
    run.PolicyFailed(id, reason) ->
      tag("policy_failed", [
        #("id", action_id(id)),
        #("reason", json.string(reason)),
      ])
    run.OutputEncodingFailed(id, detail) ->
      tag("output_encoding_failed", [
        #("id", action_id(id)),
        #("detail", json.string(detail)),
      ])
    run.ToolChanged(id, detail) ->
      tag("tool_changed", [
        #("id", action_id(id)),
        #("detail", json.string(detail)),
      ])
    run.ModelFailed(model.ModelError(reason, retryable)) ->
      tag("model_failed", [
        #("reason", json.string(reason)),
        #("retryable", json.bool(retryable)),
      ])
    run.ModelProtocolViolation(reason) ->
      tag("model_protocol_violation", [#("reason", json.string(reason))])
  }
}

// --- decoding ------------------------------------------------------------------

pub fn decode(text: String) -> Result(State, DecodeError) {
  let header = {
    use found_format <- decode.field("format", decode.string)
    use found_version <- decode.field("version", decode.int)
    decode.success(#(found_format, found_version))
  }
  case json.parse(text, header) {
    Error(error) -> Error(Corrupt(describe(error)))
    Ok(#(found, _)) if found != format ->
      Error(Corrupt("not a Fabric run record: format " <> found))
    Ok(#(_, found)) if found < 1 || found > version ->
      Error(UnsupportedVersion(found))
    Ok(#(_, found)) ->
      json.parse(text, state_decoder(found))
      |> result.map_error(fn(error) { Corrupt(describe(error)) })
      |> result.map(never_started_before_3(_, found))
      |> result.try(fn(state) {
        case found < 7 && has_family_refusal(state) {
          True -> Error(Corrupt("family budget refusals require version 7"))
          False -> Ok(state)
        }
      })
      |> result.try(linked)
  }
}

/// Before version 3, a child run cancelled before it started was stored
/// as an ended, cancelled run with no transcript. Every run that started
/// has its prompt in its transcript, so that record is read as
/// `NeverStarted`.
fn never_started_before_3(state: State, found: Int) -> State {
  case found < 3, state.phase, state.transcript {
    True, controller.Ended(run.Cancelled), [] ->
      State(..state, phase: controller.NeverStarted)
    _, _, _ -> state
  }
}

/// An agent delegation appends a positive sequence number to its parent's
/// id. A graph attachment uses the activation's stable reserved id instead.
/// Descendants started by this agent still follow the agent naming rule.
/// Cross-runtime ancestry is checked separately with a bounded walk.
fn linked(state: State) -> Result(State, DecodeError) {
  use Nil <- result.try(
    budget_config.validate(state.parent == None, state.family_budget)
    |> result.map_error(Corrupt),
  )
  let parent = case state.parent {
    Some(run.GraphBranch(..)) -> False
    Some(run.AgentParent(parent, _)) ->
      extends(state.run, run.id_to_string(parent))
    Some(run.GraphParent(parent, activation)) ->
      activation > 0
      && result.is_ok(run.parse_id(run.id_to_string(parent)))
      && state.run == child.reserved_id(run.id_to_string(parent), activation)
    None -> True
  }
  let actions = state_actions(state)
  let children =
    list.all(actions, fn(action) {
      case action.child {
        Some(child) -> extends(run.id_to_string(child), state.run)
        None -> True
      }
    })
  use Nil <- result.try(
    case
      list.all(actions, fn(action) {
        case action.state, action.child, state.phase {
          run.ChildSettled(_), Some(_), controller.Ended(_) -> True
          run.ChildSettled(_), _, _ -> False
          _, _, _ -> True
        }
      })
    {
      True -> Ok(Nil)
      False ->
        Error(Corrupt(
          "settled child evidence requires a finished parent and child reference",
        ))
    },
  )
  case parent, children {
    True, True -> Ok(state)
    False, _ ->
      Error(Corrupt(
        "the run " <> state.run <> " does not match its parent's reservation",
      ))
    _, False ->
      Error(Corrupt(
        "a child of the run " <> state.run <> " does not extend its id",
      ))
  }
}

fn has_family_refusal(state: State) -> Bool {
  let phase = case state.phase {
    controller.Stopping(reason: controller.FamilyBudget(_), ..) -> True
    controller.Ended(outcome) -> family_outcome(outcome)
    _ -> False
  }
  phase
  || list.any(state_actions(state), fn(action) {
    case action.state {
      run.ChildSettled(outcome) -> family_outcome(outcome)
      _ -> False
    }
  })
}

fn family_outcome(outcome: Outcome) -> Bool {
  case outcome {
    run.BudgetExhausted(run.FamilyLimit(_)) -> True
    _ -> False
  }
}

fn state_actions(state: State) -> List(ActionRecord) {
  case state.phase {
    controller.Acting(_, actions) | controller.Stopping(actions:, ..) ->
      list.append(state.history, actions)
    controller.AwaitingModel(_)
    | controller.Ended(_)
    | controller.NeverStarted -> state.history
  }
}

fn extends(child: String, parent: String) -> Bool {
  case string.starts_with(child, parent <> "-") {
    False -> False
    True -> {
      let number = string.drop_start(child, string.length(parent) + 1)
      number != ""
      && !string.starts_with(number, "0")
      && list.all(string.to_graphemes(number), fn(digit) {
        string.contains("0123456789", digit)
      })
    }
  }
}

fn describe(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "unexpected end of input"
    json.UnexpectedByte(byte) -> "unexpected byte " <> byte
    json.UnexpectedSequence(sequence) -> "unexpected sequence " <> sequence
    json.UnableToDecode(errors) ->
      errors
      |> list.map(fn(error) {
        "expected "
        <> error.expected
        <> ", found "
        <> error.found
        <> " at "
        <> string.join(error.path, ".")
      })
      |> string.join("; ")
  }
}

/// A field added in version 2: required from version 2 on, `default` in a
/// version 1 record.
fn since_2(
  found: Int,
  name: String,
  default: a,
  decoder: Decoder(a),
  next: fn(a) -> Decoder(b),
) -> Decoder(b) {
  case found {
    1 -> next(default)
    _ -> decode.field(name, decoder, next)
  }
}

fn state_decoder(found: Int) -> Decoder(State) {
  use run <- decode.field("run", decode.string)
  use agent <- decode.field("agent", identity_decoder())
  use incarnation <- decode.field("incarnation", decode.int)
  use parent <- since_2(
    found,
    "parent",
    None,
    decode.optional(parent_decoder(found)),
  )
  use depth <- since_2(found, "depth", 0, decode.int)
  use limits <- decode.field("limits", {
    use max_turns <- decode.field("max_turns", decode.int)
    use token_budget <- decode.field(
      "token_budget",
      decode.optional(decode.int),
    )
    use max_children <- since_2(found, "max_children", 0, decode.int)
    use max_depth <- since_2(found, "max_depth", 0, decode.int)
    decode.success(controller.Limits(
      max_turns:,
      token_budget:,
      max_children:,
      max_depth:,
    ))
  })
  use turns_used <- decode.field("turns_used", decode.int)
  use usage <- decode.field("usage", {
    use input <- decode.field("input_tokens", decode.int)
    use output <- decode.field("output_tokens", decode.int)
    use unreported <- decode.field("unreported_replies", decode.int)
    decode.success(run.TokenUsage(input, output, unreported))
  })
  use transcript <- decode.field(
    "transcript",
    decode.list(message_decoder(found)),
  )
  use history <- decode.field("history", decode.list(action_decoder(found)))
  use approvals_issued <- decode.field("approvals_issued", decode.int)
  use phase <- decode.field("phase", phase_decoder(found))
  use family_budget <- decode.then(budget_config.field(found >= 7))
  use correlation <- decode.optional_field(
    "correlation",
    correlation.from_key(run),
    correlation_decoder(),
  )
  decode.success(State(
    run:,
    agent:,
    incarnation:,
    parent:,
    depth:,
    limits:,
    turns_used:,
    usage:,
    transcript:,
    history:,
    approvals_issued:,
    phase:,
    family_budget:,
    correlation:,
  ))
}

fn correlation_decoder() -> Decoder(Correlation) {
  use text <- decode.then(decode.string)
  case correlation.from_string(text) {
    Ok(value) -> decode.success(value)
    Error(_) -> decode.failure(correlation.from_key(text), "a correlation")
  }
}

fn parent_decoder(found: Int) -> Decoder(run.Parent) {
  use id <- decode.field("run", decode.string)
  case found < 5 {
    True -> {
      use action <- decode.field("action", action_id_decoder())
      decode.success(run.AgentParent(run_id.from_string(id), action))
    }
    False -> {
      use tag <- decode.field("tag", decode.string)
      case tag {
        "agent" -> {
          use action <- decode.field("action", action_id_decoder())
          decode.success(run.AgentParent(run_id.from_string(id), action))
        }
        "graph" -> {
          use activation <- decode.field("activation", decode.int)
          decode.success(run.GraphParent(run_id.from_string(id), activation))
        }
        _ ->
          decode.failure(
            run.AgentParent(run_id.from_string(id), run.ActionId(0, "")),
            "a parent attachment",
          )
      }
    }
  }
}

fn tagged(zero: a, cases: fn(String) -> Result(Decoder(a), Nil)) -> Decoder(a) {
  use found <- decode.field("tag", decode.string)
  case cases(found) {
    Ok(decoder) -> decoder
    Error(Nil) -> decode.failure(zero, "a known tag, not " <> found)
  }
}

fn string_field(name: String, build: fn(String) -> a) -> Decoder(a) {
  decode.field(name, decode.string, fn(value) { decode.success(build(value)) })
}

fn identity_decoder() -> Decoder(DefinitionId) {
  use name <- decode.field("name", decode.string)
  use version <- decode.field("version", decode.int)
  decode.success(DefinitionId(name, version))
}

fn message_decoder(version: Int) -> Decoder(Message) {
  use found <- tagged(model.UserMessage(""))
  case found {
    "user" -> Ok(string_field("text", model.UserMessage))
    "assistant" ->
      Ok({
        use text <- decode.field("text", decode.string)
        use calls <- decode.field("calls", decode.list(tool_call_decoder()))
        let data_decoder = case version >= 4 {
          True ->
            decode.field(
              "data",
              decode.optional(provider_data_decoder()),
              decode.success,
            )
          False ->
            decode.optional_field(
              "data",
              None,
              decode.optional(provider_data_decoder()),
              decode.success,
            )
        }
        use data <- decode.then(data_decoder)
        case version < 4, data {
          True, Some(_) ->
            decode.failure(
              model.UserMessage(""),
              "provider data requires record version 4",
            )
          _, _ ->
            decode.success(
              model.AssistantMessage(model.AssistantTurn(text, calls, data)),
            )
        }
      })
    "tool_result" ->
      Ok({
        use call_id <- decode.field("call_id", decode.string)
        use content <- decode.field("content", decode.string)
        decode.success(model.ToolResultMessage(call_id, content))
      })
    _ -> Error(Nil)
  }
}

fn provider_data_decoder() -> Decoder(model.ProviderData) {
  use format <- decode.field("format", decode.string)
  use value <- decode.field("value", decode.string)
  decode.success(model.ProviderData(format, value))
}

fn tool_call_decoder() -> Decoder(ToolCall) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use arguments <- decode.field("arguments", decode.string)
  use provider_id <- decode.field("provider_id", decode.optional(decode.string))
  use provider_state <- decode.field(
    "provider_state",
    decode.optional(decode.string),
  )
  decode.success(model.ToolCall(
    id:,
    name:,
    arguments_json: arguments,
    provider_id:,
    provider_state:,
  ))
}

fn run_id_decoder() -> Decoder(run.RunId) {
  decode.map(decode.string, run_id.from_string)
}

fn action_id_decoder() -> Decoder(ActionId) {
  use turn <- decode.field("turn", decode.int)
  use call_id <- decode.field("call_id", decode.string)
  decode.success(ActionId(turn, call_id))
}

fn requirement_decoder() -> Decoder(Requirement) {
  use name <- decode.field("name", decode.string)
  use version <- decode.field("version", decode.int)
  decode.success(Requirement(name, version))
}

fn action_decoder(found: Int) -> Decoder(ActionRecord) {
  use id <- decode.field("id", action_id_decoder())
  use call <- decode.field("call", tool_call_decoder())
  use state <- decode.field("state", action_state_decoder(found))
  use approvals <- decode.field("approvals", decode.list(approval_decoder()))
  use child <- since_2(found, "child", None, decode.optional(run_id_decoder()))
  decode.success(ActionRecord(id, call, state, approvals, child))
}

fn approval_decoder() -> Decoder(Approval) {
  use required <- decode.field("requirement", requirement_decoder())
  use revision <- decode.field("revision", decode.int)
  use answer <- decode.field("answer", {
    use found <- tagged(run.Approve)
    case found {
      "approve" -> Ok(decode.success(run.Approve))
      "reject" -> Ok(string_field("reason", run.Reject))
      _ -> Error(Nil)
    }
  })
  use reviewer <- decode.field("reviewer", decode.optional(decode.string))
  decode.success(run.Approval(required, revision, answer, reviewer))
}

fn action_state_decoder(version: Int) -> Decoder(ActionState) {
  use found <- tagged(run.NotStarted)
  case found {
    "queued" -> Ok(decode.success(run.Queued))
    "running" -> Ok(decode.success(run.Running))
    "awaiting_approval" ->
      Ok({
        use required <- decode.field("requirement", requirement_decoder())
        use revision <- decode.field("revision", decode.int)
        decode.success(run.AwaitingApproval(required, revision))
      })
    "succeeded" -> Ok(string_field("content", run.Succeeded))
    "tool_failed" -> Ok(string_field("content", run.ToolFailed))
    "denied" -> Ok(string_field("reason", run.Denied))
    "rejected" -> Ok(string_field("reason", run.Rejected))
    "invalid_arguments" -> Ok(string_field("detail", run.InvalidArguments))
    "unknown_tool" -> Ok(decode.success(run.UnknownTool))
    "uncertain" -> Ok(string_field("evidence", run.Uncertain))
    "reconciled" -> Ok(string_field("content", run.Reconciled))
    "child_settled" if version >= 6 ->
      Ok({
        use outcome <- decode.field("outcome", outcome_decoder())
        decode.success(run.ChildSettled(outcome))
      })
    "not_started" -> Ok(decode.success(run.NotStarted))
    "faulted" -> Ok(string_field("detail", run.Faulted))
    "delegated" -> Ok(decode.success(run.Delegated))
    "limit_reached" ->
      Ok(
        decode.field("budget", delegation_limit_decoder(), fn(limit) {
          decode.success(run.LimitReached(limit))
        }),
      )
    _ -> Error(Nil)
  }
}

fn budget_decoder() -> Decoder(run.Budget) {
  use found <- tagged(run.TurnLimit(0))
  case found {
    "turn_limit" ->
      Ok(
        decode.field("limit", decode.int, fn(limit) {
          decode.success(run.TurnLimit(limit))
        }),
      )
    "token_limit" ->
      Ok({
        use limit <- decode.field("limit", decode.int)
        use used <- decode.field("used", decode.int)
        decode.success(run.TokenLimit(limit, used))
      })
    "family_budget" ->
      Ok(
        decode.field("denial", budget_config.denial_decoder(), fn(denial) {
          decode.success(run.FamilyLimit(denial))
        }),
      )
    _ -> Error(Nil)
  }
}

fn delegation_limit_decoder() -> Decoder(run.DelegationLimit) {
  use found <- tagged(run.ChildLimit(0))
  let limit = fn(build) {
    decode.field("limit", decode.int, fn(limit) { decode.success(build(limit)) })
  }
  case found {
    "child_limit" -> Ok(limit(run.ChildLimit))
    "depth_limit" -> Ok(limit(run.DepthLimit))
    _ -> Error(Nil)
  }
}

fn phase_decoder(version: Int) -> Decoder(Phase) {
  use found <- tagged(controller.AwaitingModel(0))
  case found {
    "awaiting_model" ->
      Ok(
        decode.field("turn", decode.int, fn(turn) {
          decode.success(controller.AwaitingModel(turn))
        }),
      )
    "acting" ->
      Ok({
        use turn <- decode.field("turn", decode.int)
        use actions <- decode.field(
          "actions",
          decode.list(action_decoder(version)),
        )
        decode.success(controller.Acting(turn, actions))
      })
    "stopping" ->
      Ok({
        use turn <- decode.field("turn", decode.int)
        use actions <- decode.field(
          "actions",
          decode.list(action_decoder(version)),
        )
        use reason <- decode.field("reason", {
          use found <- tagged(controller.CancelRequested)
          case found {
            "cancel_requested" -> Ok(decode.success(controller.CancelRequested))
            "family_budget" if version >= 7 ->
              Ok(
                decode.field(
                  "denial",
                  budget_config.denial_decoder(),
                  fn(denial) { decode.success(controller.FamilyBudget(denial)) },
                ),
              )
            "host_fault" ->
              Ok(
                decode.field("failure", host_failure_decoder(), fn(failure) {
                  decode.success(controller.HostFault(failure))
                }),
              )
            _ -> Error(Nil)
          }
        })
        // Absent before settlements were awaited: read as not yet
        // confirmed, which refuses settlements; recovery confirms it.
        use tools_stopped <- decode.optional_field(
          "tools_stopped",
          False,
          decode.bool,
        )
        decode.success(controller.Stopping(turn, actions, reason, tools_stopped))
      })
    "ended" ->
      Ok(
        decode.field("outcome", outcome_decoder(), fn(outcome) {
          decode.success(controller.Ended(outcome))
        }),
      )
    "never_started" -> Ok(decode.success(controller.NeverStarted))
    _ -> Error(Nil)
  }
}

fn outcome_decoder() -> Decoder(Outcome) {
  use found <- tagged(run.Cancelled)
  case found {
    "completed" -> Ok(string_field("text", run.Completed))
    "refused" -> Ok(string_field("reason", run.Refused))
    "output_limited" -> Ok(string_field("partial_text", run.OutputLimited))
    "turn_limit" ->
      Ok(
        decode.field("limit", decode.int, fn(limit) {
          decode.success(run.BudgetExhausted(run.TurnLimit(limit)))
        }),
      )
    "token_limit" ->
      Ok({
        use limit <- decode.field("limit", decode.int)
        use used <- decode.field("used", decode.int)
        decode.success(run.BudgetExhausted(run.TokenLimit(limit, used)))
      })
    "budget_exhausted" ->
      Ok(
        decode.field("budget", budget_decoder(), fn(budget) {
          decode.success(run.BudgetExhausted(budget))
        }),
      )
    "family_budget" ->
      Ok(
        decode.field("denial", budget_config.denial_decoder(), fn(denial) {
          decode.success(run.BudgetExhausted(run.FamilyLimit(denial)))
        }),
      )
    "budget_unverifiable" ->
      Ok(
        decode.field("turn", decode.int, fn(turn) {
          decode.success(run.BudgetUnverifiable(turn))
        }),
      )
    "cancelled" -> Ok(decode.success(run.Cancelled))
    "failed" ->
      Ok(
        decode.field("failure", host_failure_decoder(), fn(failure) {
          decode.success(run.Failed(failure))
        }),
      )
    _ -> Error(Nil)
  }
}

fn host_failure_decoder() -> Decoder(HostFailure) {
  use found <- tagged(run.ModelProtocolViolation(""))
  case found {
    "policy_failed" ->
      Ok({
        use id <- decode.field("id", action_id_decoder())
        use reason <- decode.field("reason", decode.string)
        decode.success(run.PolicyFailed(id, reason))
      })
    "output_encoding_failed" ->
      Ok({
        use id <- decode.field("id", action_id_decoder())
        use detail <- decode.field("detail", decode.string)
        decode.success(run.OutputEncodingFailed(id, detail))
      })
    "tool_changed" ->
      Ok({
        use id <- decode.field("id", action_id_decoder())
        use detail <- decode.field("detail", decode.string)
        decode.success(run.ToolChanged(id, detail))
      })
    "model_failed" ->
      Ok({
        use reason <- decode.field("reason", decode.string)
        use retryable <- decode.field("retryable", decode.bool)
        decode.success(run.ModelFailed(model.ModelError(reason, retryable)))
      })
    "model_protocol_violation" ->
      Ok(string_field("reason", run.ModelProtocolViolation))
    _ -> Error(Nil)
  }
}

// --- compatibility ---------------------------------------------------------------

/// Whether `state` can continue under an agent with `agent` identity and
/// `registry`: the identity must match, and every action that has not
/// started yet (queued or awaiting approval) must name a registered tool
/// that accepts its arguments. A running action is not checked: under
/// another runner it becomes an uncertain effect and never runs again.
pub fn check(
  state: State,
  agent: DefinitionId,
  registry: Registry(context),
) -> Result(State, List(Incompatibility)) {
  let identity = case state.agent == agent {
    True -> []
    False -> [run.OtherAgent(state.agent)]
  }
  let current = case state.phase {
    controller.Acting(_, actions) | controller.Stopping(actions:, ..) -> actions
    controller.AwaitingModel(_)
    | controller.Ended(_)
    | controller.NeverStarted -> []
  }
  let tools =
    list.filter_map(current, fn(action) {
      let name = action.call.name
      let pending = case action.state, action.child {
        run.Queued, _ | run.AwaitingApproval(..), _ -> True
        // A delegation whose child is active needs its delegation to map
        // the child's outcome, and to start the child again if it was
        // never stored.
        run.Delegated, _ | run.Running, Some(_) -> True
        _, _ -> False
      }
      case pending {
        True ->
          case registry.admit(registry, name, action.call.arguments_json) {
            Ok(Nil) -> Error(Nil)
            Error(registry.NotRegistered) ->
              Ok(run.ToolNotRegistered(action.id, name))
            Error(registry.MalformedArguments(detail)) ->
              Ok(run.ArgumentsNotAccepted(action.id, name, detail))
          }
        False -> Error(Nil)
      }
    })
  case list.append(identity, tools) {
    [] -> Ok(state)
    problems -> Error(problems)
  }
}

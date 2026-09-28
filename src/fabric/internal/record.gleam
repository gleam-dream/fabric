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
//// 0) and whose actions started none; it is written back as version 2.

import fabric/internal/controller.{type Phase, type State, State}
import fabric/internal/registry.{type Registry}
import fabric/model.{type Message, type ToolCall}
import fabric/policy.{type ActionId, type Requirement, ActionId, Requirement}
import fabric/run.{
  type ActionRecord, type ActionState, type Approval, type HostFailure,
  type Identity, type Incompatibility, type Outcome, ActionRecord, Identity,
}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub const format = "fabric.run"

pub const version = 2

pub type DecodeError {
  UnsupportedVersion(found: Int)
  Corrupt(detail: String)
}

// --- encoding ------------------------------------------------------------------

/// Encodes `state` with a fresh write token: two calls never return the
/// same text. Encode once per write, and retry that write with the same
/// text.
pub fn encode(state: State) -> String {
  json.object([
    #("format", json.string(format)),
    #("version", json.int(version)),
    #("write", json.string(write_token())),
    #("run", json.string(state.run)),
    #("agent", identity(state.agent)),
    #("incarnation", json.int(state.incarnation)),
    #(
      "parent",
      json.nullable(state.parent, fn(parent) {
        json.object([
          #("run", json.string(parent.run)),
          #("action", action_id(parent.action)),
        ])
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
    #("transcript", json.array(state.transcript, message)),
    #("history", json.array(state.history, action)),
    #("approvals_issued", json.int(state.approvals_issued)),
    #("phase", phase(state.phase)),
  ])
  |> json.to_string
}

@external(erlang, "fabric_ffi", "random_id")
fn write_token() -> String

fn tag(name: String, fields: List(#(String, Json))) -> Json {
  json.object([#("tag", json.string(name)), ..fields])
}

fn identity(identity: Identity) -> Json {
  json.object([
    #("name", json.string(identity.name)),
    #("version", json.int(identity.version)),
  ])
}

fn message(message: Message) -> Json {
  case message {
    model.UserMessage(text) -> tag("user", [#("text", json.string(text))])
    model.AssistantMessage(text, calls) ->
      tag("assistant", [
        #("text", json.string(text)),
        #("calls", json.array(calls, tool_call)),
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
    #("child", json.nullable(action.child, json.string)),
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
    run.NotStarted -> tag("not_started", [])
    run.Faulted(detail) -> tag("faulted", [#("detail", json.string(detail))])
    run.Delegated -> tag("delegated", [])
    run.LimitReached(limit) ->
      tag("limit_reached", [#("budget", budget(limit))])
  }
}

fn budget(budget: run.Budget) -> Json {
  case budget {
    run.TurnLimit(limit) -> tag("turn_limit", [#("limit", json.int(limit))])
    run.TokenLimit(limit, used) ->
      tag("token_limit", [
        #("limit", json.int(limit)),
        #("used", json.int(used)),
      ])
    run.ChildLimit(limit) -> tag("child_limit", [#("limit", json.int(limit))])
    run.DepthLimit(limit) -> tag("depth_limit", [#("limit", json.int(limit))])
  }
}

fn phase(phase: Phase) -> Json {
  case phase {
    controller.AwaitingModel(turn) ->
      tag("awaiting_model", [#("turn", json.int(turn))])
    controller.Acting(turn, actions) ->
      tag("acting", [
        #("turn", json.int(turn)),
        #("actions", json.array(actions, action)),
      ])
    controller.Stopping(turn, actions, reason) ->
      tag("stopping", [
        #("turn", json.int(turn)),
        #("actions", json.array(actions, action)),
        #("reason", case reason {
          controller.CancelRequested -> tag("cancel_requested", [])
          controller.HostFault(failure) ->
            tag("host_fault", [#("failure", host_failure(failure))])
        }),
      ])
    controller.Ended(outcome) ->
      tag("ended", [#("outcome", outcome_json(outcome))])
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
    run.BudgetExhausted(other) ->
      tag("budget_exhausted", [#("budget", budget(other))])
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
    Ok(#(_, found)) if found != version && found != 1 ->
      Error(UnsupportedVersion(found))
    Ok(#(_, found)) ->
      json.parse(text, state_decoder(found))
      |> result.map_error(fn(error) { Corrupt(describe(error)) })
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
    decode.optional({
      use run <- decode.field("run", decode.string)
      use action <- decode.field("action", action_id_decoder())
      decode.success(run.Parent(run, action))
    }),
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
  use transcript <- decode.field("transcript", decode.list(message_decoder()))
  use history <- decode.field("history", decode.list(action_decoder(found)))
  use approvals_issued <- decode.field("approvals_issued", decode.int)
  use phase <- decode.field("phase", phase_decoder(found))
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
  ))
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

fn identity_decoder() -> Decoder(Identity) {
  use name <- decode.field("name", decode.string)
  use version <- decode.field("version", decode.int)
  decode.success(Identity(name, version))
}

fn message_decoder() -> Decoder(Message) {
  use found <- tagged(model.UserMessage(""))
  case found {
    "user" -> Ok(string_field("text", model.UserMessage))
    "assistant" ->
      Ok({
        use text <- decode.field("text", decode.string)
        use calls <- decode.field("calls", decode.list(tool_call_decoder()))
        decode.success(model.AssistantMessage(text, calls))
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
  use state <- decode.field("state", action_state_decoder())
  use approvals <- decode.field("approvals", decode.list(approval_decoder()))
  use child <- since_2(found, "child", None, decode.optional(decode.string))
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

fn action_state_decoder() -> Decoder(ActionState) {
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
    "not_started" -> Ok(decode.success(run.NotStarted))
    "faulted" -> Ok(string_field("detail", run.Faulted))
    "delegated" -> Ok(decode.success(run.Delegated))
    "limit_reached" ->
      Ok(
        decode.field("budget", budget_decoder(), fn(budget) {
          decode.success(run.LimitReached(budget))
        }),
      )
    _ -> Error(Nil)
  }
}

fn budget_decoder() -> Decoder(run.Budget) {
  use found <- tagged(run.TurnLimit(0))
  let limit = fn(build) {
    decode.field("limit", decode.int, fn(limit) { decode.success(build(limit)) })
  }
  case found {
    "turn_limit" -> Ok(limit(run.TurnLimit))
    "token_limit" ->
      Ok({
        use limit <- decode.field("limit", decode.int)
        use used <- decode.field("used", decode.int)
        decode.success(run.TokenLimit(limit, used))
      })
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
            "host_fault" ->
              Ok(
                decode.field("failure", host_failure_decoder(), fn(failure) {
                  decode.success(controller.HostFault(failure))
                }),
              )
            _ -> Error(Nil)
          }
        })
        decode.success(controller.Stopping(turn, actions, reason))
      })
    "ended" ->
      Ok(
        decode.field("outcome", outcome_decoder(), fn(outcome) {
          decode.success(controller.Ended(outcome))
        }),
      )
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
  agent: Identity,
  registry: Registry(context),
) -> Result(State, List(Incompatibility)) {
  let identity = case state.agent == agent {
    True -> []
    False -> [run.OtherAgent(state.agent)]
  }
  let current = case state.phase {
    controller.Acting(_, actions) | controller.Stopping(_, actions, _) ->
      actions
    controller.AwaitingModel(_) | controller.Ended(_) -> []
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

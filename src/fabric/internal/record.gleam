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
//// Sums are objects with a `"tag"`; an absent optional value is `null`.
//// Decoding checks the format and version first: another version is
//// `UnsupportedVersion`, anything unreadable is `Corrupt`. Compatibility
//// with the agent that continues the run is a separate check.

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
import gleam/result
import gleam/string

pub const format = "fabric.run"

pub const version = 1

pub type DecodeError {
  UnsupportedVersion(found: Int)
  Corrupt(detail: String)
}

// --- encoding ------------------------------------------------------------------

pub fn encode(state: State) -> String {
  json.object([
    #("format", json.string(format)),
    #("version", json.int(version)),
    #("run", json.string(state.run)),
    #("agent", identity(state.agent)),
    #("incarnation", json.int(state.incarnation)),
    #(
      "limits",
      json.object([
        #("max_turns", json.int(state.limits.max_turns)),
        #("token_budget", json.nullable(state.limits.token_budget, json.int)),
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
    Ok(#(_, found)) if found != version -> Error(UnsupportedVersion(found))
    Ok(_) ->
      json.parse(text, state_decoder())
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

fn state_decoder() -> Decoder(State) {
  use run <- decode.field("run", decode.string)
  use agent <- decode.field("agent", identity_decoder())
  use incarnation <- decode.field("incarnation", decode.int)
  use limits <- decode.field("limits", {
    use max_turns <- decode.field("max_turns", decode.int)
    use token_budget <- decode.field(
      "token_budget",
      decode.optional(decode.int),
    )
    decode.success(controller.Limits(max_turns:, token_budget:))
  })
  use turns_used <- decode.field("turns_used", decode.int)
  use usage <- decode.field("usage", {
    use input <- decode.field("input_tokens", decode.int)
    use output <- decode.field("output_tokens", decode.int)
    use unreported <- decode.field("unreported_replies", decode.int)
    decode.success(run.TokenUsage(input, output, unreported))
  })
  use transcript <- decode.field("transcript", decode.list(message_decoder()))
  use history <- decode.field("history", decode.list(action_decoder()))
  use approvals_issued <- decode.field("approvals_issued", decode.int)
  use phase <- decode.field("phase", phase_decoder())
  decode.success(State(
    run:,
    agent:,
    incarnation:,
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

fn action_decoder() -> Decoder(ActionRecord) {
  use id <- decode.field("id", action_id_decoder())
  use call <- decode.field("call", tool_call_decoder())
  use state <- decode.field("state", action_state_decoder())
  use approvals <- decode.field("approvals", decode.list(approval_decoder()))
  decode.success(ActionRecord(id, call, state, approvals))
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
    _ -> Error(Nil)
  }
}

fn phase_decoder() -> Decoder(Phase) {
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
        use actions <- decode.field("actions", decode.list(action_decoder()))
        decode.success(controller.Acting(turn, actions))
      })
    "stopping" ->
      Ok({
        use turn <- decode.field("turn", decode.int)
        use actions <- decode.field("actions", decode.list(action_decoder()))
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
      case action.state {
        run.Queued | run.AwaitingApproval(..) ->
          case registry.admit(registry, name, action.call.arguments_json) {
            Ok(Nil) -> Error(Nil)
            Error(registry.NotRegistered) ->
              Ok(run.ToolNotRegistered(action.id, name))
            Error(registry.MalformedArguments(detail)) ->
              Ok(run.ArgumentsNotAccepted(action.id, name, detail))
          }
        _ -> Error(Nil)
      }
    })
  case list.append(identity, tools) {
    [] -> Ok(state)
    problems -> Error(problems)
  }
}

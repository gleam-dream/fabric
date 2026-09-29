//// Frozen v2 decoder from Git 570502e928496b0203909f164a5e8fd021b8ddc8.
//// See README.md in this directory; do not adapt to current domain decoder.

import fabric/support/v2/controller.{type Phase, type State, State}
import fabric/support/v2/model.{type Message, type ToolCall}
import fabric/support/v2/policy.{
  type ActionId, type Requirement, ActionId, Requirement,
}
import fabric/support/v2/run.{
  type ActionRecord, type ActionState, type Approval, type HostFailure,
  type Identity, type Outcome, ActionRecord, Identity,
}
import gleam/dynamic/decode.{type Decoder}
import gleam/json
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
      |> result.try(linked)
  }
}

/// A child run's id is its parent's id, `-`, and a positive sequence
/// number. A record whose parent or child links break that rule is
/// corrupt; ids then strictly grow down a family, so no link is cyclic.
fn linked(state: State) -> Result(State, DecodeError) {
  let parent = case state.parent {
    Some(parent) -> extends(state.run, parent.run)
    None -> True
  }
  let actions = case state.phase {
    controller.Acting(_, actions) | controller.Stopping(actions:, ..) ->
      list.append(state.history, actions)
    controller.AwaitingModel(_) | controller.Ended(_) -> state.history
  }
  let children =
    list.all(actions, fn(action) {
      case action.child {
        Some(child) -> extends(child, state.run)
        None -> True
      }
    })
  case parent, children {
    True, True -> Ok(state)
    False, _ ->
      Error(Corrupt(
        "the run " <> state.run <> " does not extend its parent's id",
      ))
    _, False ->
      Error(Corrupt(
        "a child of the run " <> state.run <> " does not extend its id",
      ))
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

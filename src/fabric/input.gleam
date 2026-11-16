//// Validated original input for one agent run. Imported history is context,
//// never a source of actions or approvals. Provider replay strings remain
//// opaque and are retained exactly as supplied.
////
//// Original input ends in one of two ways. `new` appends a current user
//// prompt to the history: the model answers that prompt. `continuation`
//// takes a history that already ends with the results of its last
//// assistant turn, such as a handed-over run's history with the decision
//// as the call's result (`fabric.handover_history`): the model continues
//// from those results, as it would have in the run that made the calls,
//// and no user message is invented. A continuation needs a store that
//// writes agent records of version 10 or later.

import fabric/model.{type Message}
import gleam/list
import gleam/result
import gleam/set

pub opaque type Input {
  Input(messages: List(Message))
}

pub type InputError {
  HistoryMustStartWithUser
  InvalidCallId
  DuplicateCallId(id: String)
  UnexpectedToolResult(id: String)
  UnresolvedCalls(ids: List(String))
  /// A continuation's history does not end with a tool result: its last
  /// message is a user prompt or an assistant turn, or it is empty. Use
  /// `new` to give the model a prompt instead.
  NotEndingInToolResults
}

/// Validate completed historical tool exchanges, then append the current
/// prompt exactly once. Adjacent user messages and repeated call ids in
/// different assistant turns are valid. Tool results may arrive in any order;
/// their supplied order is preserved. Provider-specific replay validity is
/// checked by the model adapter, not by this generic boundary.
pub fn new(
  history: List(Message),
  prompt: String,
) -> Result(Input, InputError) {
  use Nil <- result.try(case history {
    [] | [model.UserMessage(_), ..] -> Ok(Nil)
    _ -> Error(HistoryMustStartWithUser)
  })
  use Nil <- result.try(validate(history, []))
  Ok(Input(list.append(history, [model.UserMessage(prompt)])))
}

/// Validate a history that ends with the results of its last assistant
/// turn and take it as the complete original input, with no prompt
/// appended: the run's first model turn continues from those results.
/// The history must start with a user message, every call of every
/// assistant turn must have exactly one result, and the last message must
/// be a tool result (`NotEndingInToolResults` otherwise); a missing result
/// of the last turn is `UnresolvedCalls`.
///
/// Prefer it for a run that carries on a conversation whose calls are now
/// answered, such as a follow-on run after a handover. Use `new` instead
/// when the application has something new to say to the model: a
/// customer's next message, or an instruction the original run never had.
pub fn continuation(history: List(Message)) -> Result(Input, InputError) {
  use Nil <- result.try(case history {
    [model.UserMessage(_), ..] -> Ok(Nil)
    _ -> Error(HistoryMustStartWithUser)
  })
  use Nil <- result.try(validate(history, []))
  case list.last(history) {
    Ok(model.ToolResultMessage(..)) -> Ok(Input(history))
    _ -> Error(NotEndingInToolResults)
  }
}

/// The existing single-prompt input, with no imported history.
pub fn prompt(text: String) -> Input {
  Input([model.UserMessage(text)])
}

/// The complete original input, including its current prompt.
pub fn messages(input: Input) -> List(Message) {
  input.messages
}

fn validate(
  messages: List(Message),
  pending: List(String),
) -> Result(Nil, InputError) {
  case messages, pending {
    [], [] -> Ok(Nil)
    [], remaining -> Error(UnresolvedCalls(remaining))
    [model.ToolResultMessage(id, _), ..rest], pending ->
      case list.contains(pending, id) {
        False -> Error(UnexpectedToolResult(id))
        True -> validate(rest, list.filter(pending, fn(call) { call != id }))
      }
    [_, ..], [_, ..] -> Error(UnresolvedCalls(pending))
    [model.UserMessage(_), ..rest], [] -> validate(rest, [])
    [model.AssistantMessage(turn), ..rest], [] -> {
      use ids <- result.try(call_ids(turn.calls, set.new(), []))
      validate(rest, ids)
    }
  }
}

fn call_ids(
  calls: List(model.ToolCall),
  seen: set.Set(String),
  ids: List(String),
) -> Result(List(String), InputError) {
  case calls {
    [] -> Ok(list.reverse(ids))
    [call, ..rest] ->
      case call.id == "", set.contains(seen, call.id) {
        True, _ -> Error(InvalidCallId)
        _, True -> Error(DuplicateCallId(call.id))
        False, False ->
          call_ids(rest, set.insert(seen, call.id), [call.id, ..ids])
      }
  }
}

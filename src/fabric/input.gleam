//// Validated original input for one agent run. Imported history is context,
//// never a source of actions or approvals. Provider replay strings remain
//// opaque and are retained exactly as supplied.

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

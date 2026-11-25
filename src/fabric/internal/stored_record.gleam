//// A stored record decoded once, for the storage projections
//// (`fabric/store/retention`, `discovery`, `statistics` and `projection`):
//// each reads this value instead of decoding the record text again.

import fabric/internal/budget/record as budget_record
import fabric/internal/controller as agent
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record as graph_record
import fabric/internal/record as agent_record
import gleam/dynamic/decode
import gleam/json
import gleam/result

pub type Stored {
  AgentRun(agent.State)
  GraphRun(graph.State)
  FamilyBudget(budget_record.Record)
  /// Unknown, corrupt or unsupported: no projection is derived from it.
  Unreadable
}

/// Decodes `encoded` with the real decoders of the supported formats.
pub fn decode(encoded: String) -> Stored {
  case agent_record.decode(encoded) {
    Ok(state) -> AgentRun(state)
    Error(_) ->
      case graph_record.decode(encoded) {
        Ok(state) -> GraphRun(state)
        Error(_) ->
          case budget_record.decode(encoded) {
            Ok(record) -> FamilyBudget(record)
            Error(_) -> Unreadable
          }
      }
  }
}

/// The `phase.tag` the record's text `encoded` carries. For a run record
/// it comes from the decoded state, as the current encoders write it, so
/// the text is not parsed again; a budget record has none. Text that no
/// supported decoder reads is parsed for the tag alone.
pub fn phase_tag(stored: Stored, encoded: String) -> Result(String, Nil) {
  case stored {
    AgentRun(state) -> Ok(agent_record.phase_tag(state.phase))
    GraphRun(state) -> Ok(graph_record.phase_tag(state.phase))
    FamilyBudget(_) -> Error(Nil)
    Unreadable ->
      json.parse(encoded, decode.at(["phase", "tag"], decode.string))
      |> result.replace_error(Nil)
  }
}

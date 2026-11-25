//// A stored record decoded once, for the storage projections
//// (`fabric/store/retention`, `discovery`, `statistics` and `projection`):
//// each reads this value instead of decoding the record text again.

import fabric/internal/budget/record as budget_record
import fabric/internal/controller as agent
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record as graph_record
import fabric/internal/record as agent_record

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

/// The `phase.tag` the record's text carries, from the decoded state: what
/// the current encoders write for that phase. A budget record has none.
pub fn phase_tag(stored: Stored) -> Result(String, Nil) {
  case stored {
    AgentRun(state) -> Ok(agent_record.phase_tag(state.phase))
    GraphRun(state) -> Ok(graph_record.phase_tag(state.phase))
    FamilyBudget(_) | Unreadable -> Error(Nil)
  }
}

//// Checked execution topology for recovery discovery. This is independent of
//// deployed callbacks and accepts both open and ended family attachments.

import fabric/graph/child
import fabric/internal/controller as agent
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record as graph_record
import fabric/internal/record as agent_record
import fabric/retention
import fabric/run
import fabric/store
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub type Kind {
  Agent
  Graph
}

pub type Key {
  Key(kind: Kind, identity: run.Identity)
}

type State {
  AgentState(agent.State)
  GraphState(graph.State)
}

pub opaque type Record {
  Record(
    entry: store.Entry,
    state: State,
    metadata: retention.Metadata,
    key: Key,
    incarnation: Int,
  )
}

pub fn revision(record: Record) -> Int {
  record.entry.revision
}

pub fn load(runs: store.Store, id: String) -> Result(Record, Nil) {
  use entry <- result.try(store.get(runs, id) |> result.replace_error(Nil))
  use metadata <- result.try(retention.inspect(entry.record))
  use Nil <- result.try(case run.id_to_string(metadata.run) == id {
    True -> Ok(Nil)
    False -> Error(Nil)
  })
  case agent_record.decode(entry.record) {
    Ok(state) ->
      Ok(Record(
        entry,
        AgentState(state),
        metadata,
        Key(Agent, state.agent),
        state.incarnation,
      ))
    Error(_) -> {
      use state <- result.map(
        graph_record.decode(entry.record) |> result.replace_error(Nil),
      )
      Record(
        entry,
        GraphState(state),
        metadata,
        Key(Graph, state.definition.identity),
        state.incarnation,
      )
    }
  }
}

pub fn incarnation(record: Record) -> Int {
  record.incarnation
}

pub fn root(
  runs: store.Store,
  id: String,
  left: Int,
) -> Result(#(String, Key), Nil) {
  use record <- result.try(load(runs, id))
  ascend(runs, record, left)
}

fn ascend(runs, record: Record, left) {
  case record.metadata.parent {
    None -> Ok(#(run.id_to_string(record.metadata.run), record.key))
    Some(_) if left <= 0 -> Error(Nil)
    Some(link) -> {
      use above <- result.try(load(runs, run.id_to_string(link.run)))
      // Besides a valid child id, require the parent's matching reservation.
      use Nil <- result.try(
        case
          list.any(above.metadata.children, fn(child) {
            child.run == record.metadata.run && child.key == link.key
          })
        {
          True -> Ok(Nil)
          False -> Error(Nil)
        },
      )
      ascend(runs, above, left - 1)
    }
  }
}

fn terminal(record: Record) -> Bool {
  case record.state {
    AgentState(state) ->
      case state.phase {
        agent.Ended(_) | agent.NeverStarted -> True
        _ -> False
      }
    GraphState(state) ->
      case state.phase {
        graph.Ended(_) -> True
        _ -> False
      }
  }
}

fn awaits(record: Record, child: String) -> Bool {
  case record.state {
    AgentState(state) ->
      list.any(agent.active_children(state), fn(active) { active.2 == child })
    GraphState(state) ->
      case state.phase {
        graph.Joining(_, id)
        | graph.WaitingChild(_, id)
        | graph.ChildBlocked(_, id, _)
        | graph.StoppingChild(_, id) -> id == child
        graph.Ended(graph.Cancelled(a, graph.UnresolvedCancellation(_))) ->
          child.reserved_id(state.run, a.id) == child
        _ -> False
      }
  }
}

/// Ended candidates retain their retry cue until the parent has observed them.
/// The final CAS uses the observed revision and never takes a foreign lease.
pub fn release_acknowledged(runs: store.Store, record: Record) -> Bool {
  case terminal(record) {
    False -> False
    True -> {
      let id = run.id_to_string(record.metadata.run)
      let acknowledged = case record.metadata.parent {
        None -> True
        Some(link) ->
          case load(runs, run.id_to_string(link.run)) {
            Ok(above) -> !awaits(above, id)
            Error(_) -> False
          }
      }
      case acknowledged {
        False -> False
        True -> {
          let encoded = case record.state {
            AgentState(state) -> store.encode(runs, state)
            GraphState(state) ->
              graph_record.encode(state)
              |> result.replace_error(store.Unavailable("cannot encode graph"))
          }
          encoded
          |> result.try(fn(encoded) {
            store.commit(
              runs,
              id,
              record.entry.revision,
              encoded,
              store.Detached(False, False),
            )
          })
          |> result.is_ok
        }
      }
    }
  }
}

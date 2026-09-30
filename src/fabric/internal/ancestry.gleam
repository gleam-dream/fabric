//// Checked ownership above either runtime. A parent must still retain the
//// exact child reservation; an open but unrelated run cannot admit work.

import fabric/internal/controller as agent
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record as graph_record
import fabric/internal/record as agent_record
import fabric/run
import fabric/store
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Error {
  StoreFailed(store.StoreError)
  UnsupportedVersion(Int)
  Corrupt(String)
}

pub fn read(
  runs: store.Store,
  descendant: String,
  parent: Option(run.Parent),
  left: Int,
) -> Result(Bool, Error) {
  case parent {
    None -> Ok(True)
    Some(_) if left <= 0 ->
      Error(Corrupt("the chain of parent runs is too long"))
    Some(link) -> {
      let id = run.id_to_string(link.run)
      use entry <- result.try(
        store.get(runs, id) |> result.map_error(StoreFailed),
      )
      use #(stored_id, above, accepts) <- result.try(case link {
        run.AgentParent(_, action) -> {
          use state <- result.map(
            agent_record.decode(entry.record)
            |> result.map_error(fn(error) {
              case error {
                agent_record.UnsupportedVersion(v) -> UnsupportedVersion(v)
                agent_record.Corrupt(detail) -> Corrupt(detail)
              }
            }),
          )
          let accepts = case state.phase {
            agent.Acting(..) ->
              list.any(agent.active_children(state), fn(child) {
                child.0 == action && child.2 == descendant
              })
            _ -> False
          }
          #(state.run, state.parent, accepts)
        }
        run.GraphParent(_, activation) -> {
          use state <- result.map(
            graph_record.decode(entry.record)
            |> result.map_error(fn(error) {
              case error {
                graph_record.UnsupportedVersion(v) -> UnsupportedVersion(v)
                graph_record.Corrupt(detail) -> Corrupt(detail)
              }
            }),
          )
          let accepts = case state.phase {
            graph.Joining(a, child)
            | graph.WaitingChild(a, child)
            | graph.ChildBlocked(a, child, _) ->
              a.id == activation && child == descendant
            _ -> False
          }
          #(state.run, state.parent, accepts)
        }
      })
      case stored_id == id, accepts {
        False, _ -> Error(Corrupt("parent record belongs to a different run"))
        True, False -> Ok(False)
        True, True -> read(runs, id, above, left - 1)
      }
    }
  }
}

//// Storage-owned discovery of idle graph dependencies. This projection is a
//// scheduling hint, never permission to execute. Recovery must revalidate the
//// stored attachment and deployed definition through the registered root.

import fabric/graph/child
import fabric/graph/operation
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record
import fabric/retention
import fabric/run
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result

/// Bump when a record format or state changes discovery eligibility or keys.
/// Backends must refresh older projections before using them for scheduling.
pub const version = 2

/// `key` identifies one observation scope. It excludes run incarnation and
/// execution revision so recovering an unchanged wait cannot make it new work.
pub type Dependency {
  Dependency(run: run.RunId, dependency: run.RunId, key: String)
}

/// Inspect supported records without deployed code. Unknown/corrupt records
/// fail; readable records without an idle dependency return `None`.
pub fn inspect(encoded: String) -> Result(Option(Dependency), Nil) {
  classify(encoded) |> result.map(fn(entry) { entry.1 })
}

fn classify(encoded: String) -> Result(#(run.RunId, Option(Dependency)), Nil) {
  case record.decode(encoded) {
    Error(_) ->
      retention.inspect(encoded)
      |> result.map(fn(metadata) { #(metadata.run, None) })
    Ok(state) -> {
      let wait = case state.phase {
        graph.WaitingChild(activation, id)
        | graph.ChildBlocked(activation, id, _) ->
          Some(dependency(state, activation, id, "observe"))
        graph.Ended(graph.Cancelled(activation, graph.UnresolvedCancellation(_))) ->
          case activation.prepared.kind {
            operation.Agent | operation.Subgraph ->
              Some(dependency(
                state,
                activation,
                child.reserved_id(state.run, activation.id),
                "settle",
              ))
            _ -> None
          }
        _ -> None
      }
      Ok(#(run.issued(state.run), wait))
    }
  }
}

fn dependency(
  state: graph.State,
  activation: graph.Activation,
  id: String,
  mode: String,
) -> Dependency {
  let key =
    json.array(
      [
        json.string(mode),
        json.int(activation.id),
        json.int(activation.attempt),
        json.string(id),
      ],
      fn(value) { value },
    )
    |> json.to_string
  Dependency(run.issued(state.run), run.issued(id), key)
}

/// Metadata for a backend index. Check its version and source revision before
/// using it. Unknown or misfiled records retain only the projection version.
pub fn encode(stored_id: String, encoded: String) -> String {
  let fields = case classify(encoded) {
    Ok(#(id, wait)) ->
      case run.id_to_string(id) == stored_id {
        False -> []
        True -> [
          #(
            "wait",
            json.nullable(wait, fn(wait) {
              json.object([
                #("dependency", json.string(run.id_to_string(wait.dependency))),
                #("key", json.string(wait.key)),
              ])
            }),
          ),
        ]
      }
    Error(_) -> []
  }
  json.object([#("version", json.int(version)), ..fields]) |> json.to_string
}

//// Storage-owned discovery of idle dependencies, job reads and wait deadlines.
//// This projection is a
//// scheduling hint, never permission to execute. Recovery must revalidate the
//// stored attachment and deployed definition through the registered root.

import fabric/graph/child
import fabric/graph/job
import fabric/graph/operation
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record
import fabric/retention
import fabric/run
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// Bump when a record format or state changes discovery eligibility or keys.
/// Backends must refresh older projections before using them for scheduling.
pub const version = 7

pub type Trigger {
  Changed(dependency: run.RunId, deadline: Option(Int))
  Poll(every: Int, deadline: Option(Int))
  /// Absolute UTC Unix milliseconds; backend time alone judges eligibility.
  At(due: Int)
}

/// `key` identifies one observation scope. It excludes run incarnation and
/// execution revision so recovering an unchanged wait cannot make it new work.
pub type Wait {
  Wait(run: run.RunId, key: String, trigger: Trigger)
}

/// Inspect supported records without deployed code. Unknown/corrupt records
/// fail; readable records without an automatic wait return `None`.
pub fn inspect(encoded: String) -> Result(Option(Wait), Nil) {
  classify(encoded) |> result.map(fn(entry) { entry.1 })
}

fn classify(encoded: String) -> Result(#(run.RunId, Option(Wait)), Nil) {
  case record.decode(encoded) {
    Error(_) ->
      retention.inspect(encoded)
      |> result.map(fn(metadata) { #(metadata.run, None) })
    Ok(state) -> {
      let wait = case state.phase {
        graph.WaitingSignal(activation) ->
          case activation.deadline {
            None -> None
            Some(due) ->
              Some(Wait(
                run.issued(state.run),
                json.array(
                  [
                    json.string("signal_deadline"),
                    json.int(activation.id),
                    json.int(activation.attempt),
                    json.int(due),
                  ],
                  fn(value) { value },
                )
                  |> json.to_string,
                At(due),
              ))
          }
        graph.StoppingJob(_, job.RequestQueued, _)
        | graph.StoppingJob(_, job.RequestStarted, _) -> None
        graph.WaitingJob(activation) | graph.StoppingJob(activation, _, _) -> {
          let due = case state.phase {
            graph.WaitingJob(_) -> activation.deadline
            _ -> None
          }
          case activation.prepared.kind {
            operation.Job(job.Every(every))
            | operation.OwnedJob(job.Every(every)) ->
              Some(Wait(
                run.issued(state.run),
                json.array(
                  list.append(
                    [
                      json.string(case state.phase {
                        graph.StoppingJob(_, _, _) -> "stop_poll"
                        _ -> "poll"
                      }),
                      json.int(activation.id),
                      json.int(activation.attempt),
                      json.int(every),
                    ],
                    case due {
                      None -> []
                      Some(at) -> [json.int(at)]
                    },
                  ),
                  fn(value) { value },
                )
                  |> json.to_string,
                Poll(every, due),
              ))
            _ ->
              case due {
                None -> None
                Some(at) ->
                  Some(Wait(
                    run.issued(state.run),
                    json.array(
                      [
                        json.string("job_deadline"),
                        json.int(activation.id),
                        json.int(activation.attempt),
                        json.int(at),
                      ],
                      fn(value) { value },
                    )
                      |> json.to_string,
                    At(at),
                  ))
              }
          }
        }
        graph.WaitingChild(activation, id)
        | graph.ChildBlocked(activation, id, _) ->
          Some(dependency(state, activation, id, "observe", activation.deadline))
        graph.Blocked(a, graph.InvalidResult(_, _)) ->
          case a.prepared.kind, a.deadline {
            operation.Agent, Some(_) | operation.Subgraph, Some(_) ->
              Some(dependency(
                state,
                a,
                child.reserved_id(state.run, a.id),
                "observe",
                a.deadline,
              ))
            _, _ -> None
          }
        graph.Ended(graph.Cancelled(activation, graph.UnresolvedCancellation(_)))
        | graph.Ended(graph.Expired(activation, graph.UnresolvedCancellation(_))) ->
          case activation.prepared.kind {
            operation.Agent | operation.Subgraph ->
              Some(dependency(
                state,
                activation,
                child.reserved_id(state.run, activation.id),
                "settle",
                None,
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
  deadline: Option(Int),
) -> Wait {
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
  Wait(run.issued(state.run), key, Changed(run.issued(id), deadline))
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
              let trigger = case wait.trigger {
                Changed(id, due) -> [
                  #("dependency", json.string(run.id_to_string(id))),
                  ..deadline_fields(due)
                ]
                Poll(every, due) -> [
                  #("every", json.int(every)),
                  ..deadline_fields(due)
                ]
                At(due) -> [#("due", json.int(due))]
              }
              json.object([#("key", json.string(wait.key)), ..trigger])
            }),
          ),
        ]
      }
    Error(_) -> []
  }
  json.object([#("version", json.int(version)), ..fields]) |> json.to_string
}

fn deadline_fields(due: Option(Int)) -> List(#(String, json.Json)) {
  case due {
    None -> []
    Some(at) -> [#("due", json.int(at))]
  }
}

//// Serve an agent or graph run as a bounded request and response.
//// No transport is assumed: an HTTP handler, MCP handler or job can use
//// the same service. `agent` and `graph` bind execution; `request` holds
//// caller-owned input. Configuration is opaque and waits default to 25 s.
////
//// A key is scoped by service, runtime family and principal. Retries with
//// the same input reopen that run even when their correlation changes;
//// a changed input is `key_reused`. The first request's correlation stays
//// with the run. Use a stable authenticated principal in a shared service.
//// Without a key each request starts a fresh run; a deadline or the
//// supplied cancellation selector cancels work still in flight. Keyed
//// work outlives a disconnect, bounded by the agent or graph's limits.
//// Approval and reconciliation return immediately with the run id: the
//// application owns following them up, including unkeyed requests.
////
//// ```gleam
//// let service = invoke.agent("desk", runs, desk)
//// let request = invoke.request(context, "Help with order 42")
////   |> invoke.with_principal(subject)
////   |> invoke.with_key(Some(request_key))
////   |> invoke.with_cancelled(disconnected)
//// let response = invoke.call(service, request)
//// case invoke.answer(response) {
////   Some(answer) -> respond(answer)
////   None -> pending(invoke.id(response), invoke.describe_response(response))
//// }
//// ```
////
//// A cancellation failure is reported explicitly; it never claims the
//// run stopped. Read or recover such a run by id. An unknown effect needs
//// reconciliation, not a retry of the effect.
////
//// ## Serving through Relay
////
//// Copy `relay_serve` into the application; the consumer compiles this exact recipe.
//// See the README for composition and failure handling.
////
//// ```gleam
//// import fabric/invoke
//// import fabric/run
//// import gleam/option.{None, Some}
//// import gleam/result
//// import json/blueprint/value
//// import relay/content
//// import relay/tool
////
//// pub fn serve(
////   definition: tool.Definition(i, a),
////   service: invoke.Service(c, input, a),
////   start: fn(tool.Call(s), i) -> Result(invoke.Request(c, input), tool.ToolError),
//// ) -> Result(tool.Tool(s), invoke.ConfigError) {
////   use Nil <- result.map(invoke.check(service))
////   tool.handle_call(definition, fn(call, input) {
////     use request <- result.try(start(call, input))
////     let request =
////       request
////       |> invoke.with_key(tool.idempotency_key(call))
////       |> invoke.with_correlation(tool.correlation(call))
////       |> invoke.with_cancelled(tool.cancelled(call))
////     let response = invoke.call(service, request)
////     let meta = [
////       #(
////         "io.github.gleam-dream/run-id",
////         value.String(run.id_to_string(invoke.id(response))),
////       ),
////     ]
////     case invoke.answer(response) {
////       Some(answer) -> Ok(tool.complete_with_meta(answer, meta))
////       None ->
////         Error(tool.error_with(
////           [
////             content.text(invoke.describe_response(response))
////             |> content.with_meta(meta),
////           ],
////           Some(invoke.details(response)),
////         ))
////     }
////   })
//// }
//// ```
////
//// ## Reading a Relay run id
////
//// Copy `relay_run` into the application; the consumer compiles this exact recipe.
//// See the README for composition and failure handling.
////
//// ```gleam
//// import fabric/run
//// import gleam/option.{type Option, None, Some}
//// import json/blueprint/value
//// import relay/client
//// import relay/client/output
////
//// pub fn run_of(result: client.ToolResult(a)) -> Option(run.RunId) {
////   case output.meta(result, "io.github.gleam-dream/run-id") {
////     Some(value.String(id)) -> run.parse_id(id) |> option.from_result
////     _ -> None
////   }
//// }
//// ```

import fabric
import fabric/agent.{type Agent}
import fabric/graph
import fabric/model
import fabric/run.{type RunId}
import fabric/store.{type Store}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import json/blueprint/value.{type Value}
import sinal/correlation.{type Correlation}

/// Execution bound to a named request boundary. Names must be stable and
/// distinct for services sharing a store. A graph already owns its context.
pub opaque type Service(context, input, answer) {
  Service(
    name: String,
    family: String,
    wait: Duration,
    execute: fn(RunId, Request(context, input), Duration) -> Response(answer),
  )
}

/// Caller-owned input and identity. Context and cancellation are never stored.
pub opaque type Request(context, input) {
  Request(
    context: context,
    input: input,
    principal: String,
    key: Option(String),
    correlation: Option(Correlation),
    cancelled: process.Selector(Nil),
  )
}

/// A response always names the attempted run, including start failures.
/// `facts` is a portable JSON object for rendering structured failures;
/// native successful answers are available through `answer`.
pub opaque type Response(answer) {
  Response(
    id: RunId,
    answer: Option(answer),
    kind: Kind,
    code: String,
    description: String,
    facts: List(#(String, Value)),
  )
}

/// Stable next-action classification. Detailed machine codes may grow.
pub type Kind {
  Answered
  Working
  AwaitingApproval
  AwaitingInput
  OutcomeUnknown
  Unattended
  Ended
  Refused
}

/// A finite wait must fit the BEAM timer range. Invocation deliberately
/// requires a deadline; continuing keyed work has its own runtime bounds.
pub type ConfigError {
  InvalidWait(value: Int, minimum: Int, maximum: Int)
}

/// Build a request for one trusted anonymous caller. Shared services must
/// set the authenticated principal before accepting an idempotency key.
pub fn request(context: context, input: input) -> Request(context, input) {
  Request(
    context:,
    input:,
    principal: "anonymous",
    key: None,
    correlation: None,
    cancelled: process.new_selector(),
  )
}

pub fn with_principal(
  request: Request(c, i),
  principal: String,
) -> Request(c, i) {
  Request(..request, principal:)
}

pub fn with_key(request: Request(c, i), key: Option(String)) -> Request(c, i) {
  Request(..request, key:)
}

pub fn with_correlation(
  request: Request(c, i),
  correlation: Correlation,
) -> Request(c, i) {
  Request(..request, correlation: Some(correlation))
}

/// The caller supplies its disconnect or monitor selector. Consumed only
/// for an unkeyed request; keyed requests outlive the caller.
pub fn with_cancelled(
  request: Request(c, i),
  cancelled: process.Selector(Nil),
) -> Request(c, i) {
  Request(..request, cancelled:)
}

pub fn with_wait(
  service: Service(c, i, a),
  wait: Duration,
) -> Service(c, i, a) {
  Service(..service, wait:)
}

/// Validate configuration at application startup, before accepting calls.
pub fn check(service: Service(c, i, a)) -> Result(Nil, ConfigError) {
  let wait = duration.to_milliseconds(service.wait)
  case wait >= 1 && wait <= 4_294_967_295 {
    True -> Ok(Nil)
    False -> Error(InvalidWait(wait, 1, 4_294_967_295))
  }
}

pub fn describe_config_error(error: ConfigError) -> String {
  let InvalidWait(value, minimum, maximum) = error
  "fabric/invoke.with_wait (ms) is "
  <> int.to_string(value)
  <> ", outside "
  <> int.to_string(minimum)
  <> ".."
  <> int.to_string(maximum)
}

/// A collision-resistant, unambiguous identity for this service, principal
/// and key. JSON frames the parts before hashing; separators inside any
/// part cannot alias another request. This differs from the old MCP bridge
/// derivation; previously written runs remain accessible by their old id.
pub fn keyed_id(
  service: Service(c, i, a),
  principal: String,
  key: String,
) -> RunId {
  run.id_from_parts("invoke", [
    value.to_string(
      value.Array(list.map(
        [service.family, service.name, principal, key],
        value.String,
      )),
    ),
  ])
}

pub fn id(response: Response(a)) -> RunId {
  response.id
}

pub fn answer(response: Response(a)) -> Option(a) {
  response.answer
}

pub fn response_kind(response: Response(a)) -> Kind {
  response.kind
}

pub fn code(response: Response(a)) -> String {
  response.code
}

pub fn describe_response(response: Response(a)) -> String {
  response.description
}

/// A portable object with `error`, `run_id` and any approval or uncertain
/// effect evidence. Successful answers should be rendered from `answer`.
pub fn details(response: Response(a)) -> Value {
  value.Object([
    #("error", value.String(response.code)),
    #("run_id", value.String(run.id_to_string(response.id))),
    ..response.facts
  ])
}

/// Start or reopen, then wait once. Invalid configuration starts nothing.
pub fn call(service: Service(c, i, a), request: Request(c, i)) -> Response(a) {
  let id = case request.key {
    Some(key) -> keyed_id(service, request.principal, key)
    None -> run.new_id()
  }
  case check(service) {
    Error(error) ->
      response(id, Refused, "invalid_config", describe_config_error(error), [])
    Ok(Nil) -> service.execute(id, request, service.wait)
  }
}

/// Bind an agent; its prompt is the request input and its context is live.
pub fn agent(
  name: String,
  runs: Store,
  agent: Agent(c, a),
) -> Service(c, String, a) {
  Service(
    name:,
    family: "agent",
    wait: duration.seconds(25),
    execute: fn(id, request, wait) {
      let started =
        fabric.start(
          runs,
          agent,
          id:,
          context: request.context,
          prompt: request.input,
          correlation: request.correlation,
        )
      let opened = case started, request.key {
        Ok(handle), _ -> Ok(handle)
        Error(fabric.AlreadyStarted(..)), Some(_) -> {
          use handle <- result.try(
            fabric.open(runs, agent, request.context, id)
            |> result.map_error(fn(e) {
              unavailable(id, fabric.describe_error(e))
            }),
          )
          use snapshot <- result.try(
            fabric.snapshot(handle)
            |> result.map_error(fn(e) {
              unavailable(id, fabric.describe_error(e))
            }),
          )
          case snapshot.transcript {
            [model.UserMessage(prompt), ..] if prompt == request.input ->
              Ok(handle)
            _ -> Error(reused(id))
          }
        }
        Error(error), _ ->
          Error(
            response(
              id,
              Refused,
              "start_failed",
              fabric.describe_error(error),
              [],
            ),
          )
      }
      case opened {
        Error(response) -> response
        Ok(handle) -> {
          let cancel = fn() {
            fabric.cancel(handle)
            |> result.map(fn(status) {
              case status {
                run.Finished(_) -> True
                _ -> False
              }
            })
            |> result.map_error(AgentError)
          }
          case fabric.await_with(handle, within: wait, or: ending(request)) {
            Error(error) -> unavailable(id, fabric.describe_error(error))
            Ok(fabric.Interrupted(Nil)) ->
              stopped(id, "cancelled", "the call was cancelled", cancel())
            Ok(fabric.Reached(status)) ->
              case status {
                run.Finished(run.Completed(answer)) -> answered(id, answer)
                run.Working if request.key == None ->
                  stopped(
                    id,
                    "timed_out",
                    "no answer in time; the run was cancelled",
                    cancel(),
                  )
                run.Working -> working(id)
                run.Unattended ->
                  response(
                    id,
                    Unattended,
                    "unattended",
                    "the run has work in flight and no runner",
                    [],
                  )
                run.Suspended(_, [_, ..] as uncertain) ->
                  response(
                    id,
                    OutcomeUnknown,
                    "outcome_unknown",
                    "the run stopped on effects of unknown status; a person must reconcile them",
                    [
                      #(
                        "uncertain",
                        value.Array(
                          list.map(uncertain, fn(effect) {
                            value.Object([
                              #("tool", value.String(effect.tool)),
                              #("evidence", value.String(effect.evidence)),
                            ])
                          }),
                        ),
                      ),
                    ],
                  )
                run.Suspended(approvals, []) ->
                  response(
                    id,
                    AwaitingApproval,
                    "awaiting_approval",
                    "the run waits for an approval",
                    [
                      #(
                        "approvals",
                        value.Array(
                          list.map(approvals, fn(pending) {
                            value.Object([#("tool", value.String(pending.tool))])
                          }),
                        ),
                      ),
                    ],
                  )
                run.Finished(outcome) ->
                  response(
                    id,
                    Ended,
                    outcome_name(outcome),
                    run.describe_outcome(outcome),
                    [],
                  )
              }
          }
        }
      }
    },
  )
}

/// Bind a graph. Its runtime owns context; pass `Nil` as request context
/// and the native initial state as input. Retries compare the original
/// state, even after the graph has changed it.
pub fn graph(
  name: String,
  runtime: graph.Runtime(c, s, a),
) -> Service(Nil, s, a) {
  Service(
    name:,
    family: "graph",
    wait: duration.seconds(25),
    execute: fn(id, request, wait) {
      let opened = case
        graph.start(
          runtime,
          id:,
          initial: request.input,
          correlation: request.correlation,
        ),
        request.key
      {
        Ok(handle), _ -> Ok(handle)
        Error(graph.AlreadyStarted(..)), Some(_) -> {
          use handle <- result.try(
            graph.open(runtime, id)
            |> result.map_error(fn(e) {
              unavailable(id, graph.describe_error(e))
            }),
          )
          use same <- result.try(
            graph.matches_initial(handle, request.input)
            |> result.map_error(fn(e) {
              unavailable(id, graph.describe_error(e))
            }),
          )
          case same {
            True -> Ok(handle)
            False -> Error(reused(id))
          }
        }
        Error(error), _ ->
          Error(
            response(
              id,
              Refused,
              "start_failed",
              graph.describe_error(error),
              [],
            ),
          )
      }
      case opened {
        Error(response) -> response
        Ok(handle) ->
          wait_graph(
            handle,
            id,
            request.key == None,
            ending(request),
            now() + duration.to_milliseconds(wait),
          )
      }
    },
  )
}

fn wait_graph(
  handle: graph.Handle(c, s, a),
  id: RunId,
  owned: Bool,
  interrupt: process.Selector(Nil),
  deadline: Int,
) -> Response(a) {
  let left = int.max(0, deadline - now())
  case
    graph.await_with(handle, within: duration.milliseconds(left), or: interrupt)
  {
    Error(error) -> unavailable(id, graph.describe_error(error))
    Ok(graph.Interrupted(Nil)) ->
      stopped(
        id,
        "cancelled",
        "the call was cancelled",
        graph.cancel(handle)
          |> result.map(fn(status) { graph.status_kind(status) == graph.Ended })
          |> result.map_error(GraphError),
      )
    Ok(graph.Reached(status)) ->
      case status {
        graph.Completed(answer) -> answered(id, answer)
        _ ->
          case graph.status_kind(status) {
            graph.Active ->
              case deadline - now() > 0 {
                True ->
                  case
                    process.selector_receive(
                      interrupt,
                      int.min(100, int.max(0, deadline - now())),
                    )
                  {
                    Ok(Nil) ->
                      stopped(
                        id,
                        "cancelled",
                        "the call was cancelled",
                        graph.cancel(handle)
                          |> result.map(fn(status) {
                            graph.status_kind(status) == graph.Ended
                          })
                          |> result.map_error(GraphError),
                      )
                    Error(Nil) ->
                      wait_graph(handle, id, owned, interrupt, deadline)
                  }
                False ->
                  case owned {
                    True ->
                      stopped(
                        id,
                        "timed_out",
                        "no answer in time; cancellation was requested",
                        graph.cancel(handle)
                          |> result.map(fn(status) {
                            graph.status_kind(status) == graph.Ended
                          })
                          |> result.map_error(GraphError),
                      )
                    False -> working(id)
                  }
              }
            graph.NeedsRecovery ->
              response(
                id,
                Unattended,
                "unattended",
                graph.describe_status(status),
                [],
              )
            graph.NeedsInput ->
              case status {
                graph.AwaitingApproval(reference) ->
                  response(
                    id,
                    AwaitingApproval,
                    "awaiting_approval",
                    graph.describe_status(status),
                    [
                      #(
                        "approvals",
                        value.Array([
                          value.Object([
                            #(
                              "operation",
                              value.String(reference.requirement.name),
                            ),
                          ]),
                        ]),
                      ),
                    ],
                  )
                graph.Blocked(_, problem) ->
                  response(
                    id,
                    OutcomeUnknown,
                    "outcome_unknown",
                    graph.describe_status(status),
                    [
                      #(
                        "evidence",
                        value.String(case problem {
                          graph.EffectUncertain(evidence) -> evidence
                          graph.InvalidResult(_, reason) -> reason
                        }),
                      ),
                    ],
                  )
                _ ->
                  response(
                    id,
                    AwaitingInput,
                    "awaiting_input",
                    graph.describe_status(status),
                    [],
                  )
              }
            graph.Ended ->
              response(
                id,
                Ended,
                case status {
                  graph.Cancelled(_) -> "cancelled"
                  graph.Expired(..) -> "expired"
                  graph.Exhausted -> "budget_exhausted"
                  _ -> "failed"
                },
                graph.describe_status(status),
                [],
              )
          }
      }
  }
}

fn ending(request: Request(c, i)) -> process.Selector(Nil) {
  case request.key {
    None -> request.cancelled
    Some(_) -> process.new_selector()
  }
}

fn response(
  id: RunId,
  kind: Kind,
  code: String,
  description: String,
  facts: List(#(String, Value)),
) -> Response(a) {
  Response(id:, answer: None, kind:, code:, description:, facts:)
}

fn answered(id: RunId, answer: a) -> Response(a) {
  Response(
    id:,
    answer: Some(answer),
    kind: Answered,
    code: "answered",
    description: "the run answered",
    facts: [],
  )
}

fn working(id: RunId) -> Response(a) {
  response(
    id,
    Working,
    "working",
    "the run is still working; call again with the same idempotency key",
    [],
  )
}

fn reused(id: RunId) -> Response(a) {
  response(
    id,
    Refused,
    "key_reused",
    "the idempotency key names a run started with another request",
    [],
  )
}

fn unavailable(id: RunId, message: String) -> Response(a) {
  response(id, Refused, "unavailable", message, [])
}

fn stopped(
  id: RunId,
  code: String,
  message: String,
  cancelled: Result(Bool, CancellationError),
) -> Response(a) {
  case cancelled {
    Ok(True) -> response(id, Ended, code, message, [])
    Ok(False) ->
      response(
        id,
        Working,
        code,
        "cancellation requested; effects are still settling",
        [],
      )
    Error(error) ->
      response(
        id,
        OutcomeUnknown,
        "cancellation_failed",
        case error {
          AgentError(e) -> fabric.describe_error(e)
          GraphError(e) -> graph.describe_error(e)
        },
        [],
      )
  }
}

type CancellationError {
  AgentError(fabric.Error)
  GraphError(graph.Error)
}

fn outcome_name(outcome: run.Outcome(answer)) -> String {
  case outcome {
    run.Completed(_) -> "completed"
    run.AnswerInvalid(..) -> "answer_invalid"
    run.Refused(_) -> "refused"
    run.OutputLimited(_) -> "output_limited"
    run.BudgetExhausted(_) -> "budget_exhausted"
    run.BudgetUnverifiable(_) -> "budget_unverifiable"
    run.Cancelled -> "cancelled"
    run.Failed(_) -> "failed"
  }
}

@external(erlang, "fabric_ffi", "now_ms")
fn now() -> Int

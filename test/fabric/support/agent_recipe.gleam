//// Evaluation-only model-turn/tool-batch graph. Never a production API.
//// It reuses agent decisions but deliberately exposes the batch commit boundary.
//// Unsupported per-action lifecycles fail closed; lost batches never replay.

import fabric/agent
import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/internal/checked_agent
import fabric/internal/controller
import fabric/internal/invocation
import fabric/internal/model_port
import fabric/internal/record
import fabric/internal/registry
import fabric/internal/run_id
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/tool
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import json/blueprint/codec

pub fn initial(
  worker: agent.Agent(context, String),
  context: context,
  prompt: String,
) -> String {
  let config = checked_agent.admitted(worker)
  let #(state, _) =
    controller.start(
      env(config, context),
      "recipe-inner",
      config.identity,
      controller.Limits(
        config.max_turns,
        config.token_budget,
        config.max_children,
        config.max_depth,
      ),
      prompt,
      None,
      0,
    )
  record.encode(state)
}

pub fn runtime(
  runs: store.Store,
  worker: agent.Agent(context, String),
  context: fn(run.RunId) -> context,
) -> graph.Runtime(context, String, String) {
  let config = checked_agent.admitted(worker)
  let model_node =
    node("model", fn(context, raw) {
      use state <- result.try(load(raw, config))
      let env = env(config, context)
      case state.phase {
        controller.AwaitingModel(turn) -> {
          // No delegated tools are supported by this probe, so this declaration
          // set is the ordinary agent's set for the measured scenarios.
          use Nil <- result.try(require(
            !list.any(registry.declarations(env.registry), fn(tool) {
              registry.is_delegation(env.registry, tool.name)
            }),
            "recipe probe does not implement managed agent actions",
          ))
          let request =
            model.Request(
              run: run_id.from_string(state.run),
              turn:,
              correlation: state.correlation,
              system: env.system,
              messages: state.transcript,
              tools: registry.declarations(env.registry),
              answer: env.answer,
            )
          use reply <- result.try(
            model_port.call(config.model, request)
            |> result.map_error(fn(error) {
              tool.Uncertain(
                "recipe probe does not implement model retry/backoff: "
                <> model.describe_error(error),
              )
            }),
          )
          transition(env, state, controller.ModelReplied(turn, reply))
          |> result.map(record.encode)
        }
        _ -> Error(tool.Explain("model node received another phase"))
      }
    })
  let batch_node =
    node("batch", fn(context, raw) {
      use state <- result.try(load(raw, config))
      let env = env(config, context)
      case state.phase {
        controller.Acting(_, actions) -> {
          use Nil <- result.try(require(
            list.all(actions, fn(action) {
              case action.state {
                run.Queued ->
                  action.child == None
                  && registry.settles_within(env.registry, action.call.name)
                  == None
                _ -> controller.model_content(action.state) |> result.is_ok
              }
            }),
            "recipe probe requires per-action approval, reconciliation or settlement support",
          ))
          use state <- result.map(
            list.try_fold(actions, state, fn(state, action) {
              case action.state {
                run.Queued -> {
                  use state <- result.try(transition(
                    env,
                    state,
                    controller.ToolStarting(action.id),
                  ))
                  let outcome =
                    registry.invoke(
                      env.registry,
                      context,
                      tool.Call(
                        run: run_id.from_string(state.run),
                        action: action.id,
                        correlation: state.correlation,
                      ),
                      action.call.name,
                      action.call.arguments_json,
                      fn(_, _) { Error(tool.NotAwaited) },
                    )
                  case outcome {
                    invocation.EffectUncertain(reason) ->
                      Error(tool.Uncertain(reason))
                    _ ->
                      transition(
                        env,
                        state,
                        controller.ToolReported(action.id, outcome),
                      )
                  }
                }
                _ -> Ok(state)
              }
            }),
          )
          record.encode(state)
        }
        _ -> Error(tool.Explain("batch node received another phase"))
      }
    })
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("agent-recipe-evaluation", 1),
        entry: id("model"),
        nodes: [model_node, batch_node],
        state: codec.string(),
        answer: codec.string(),
      )
      |> definition.with_max_activations(config.max_turns * 2 + 1),
    )
  graph.new(spec, runs, context, fn(_, _) { Ok(policy.Allow) })
}

fn node(name, body) {
  let op =
    operation.new(
      run.DefinitionId(name, 1),
      codec.string(),
      codec.string(),
      fn(context, _, raw) { body(context, raw) },
      fn(error) { error },
    )
  definition.node(
    id(name),
    op,
    fn(state) { Ok(state) },
    fn(_, raw) {
      use state <- result.try(
        record.decode(raw) |> result.map_error(string.inspect),
      )
      case state.phase {
        controller.AwaitingModel(_) -> Ok(definition.Continue(raw, id("model")))
        controller.Acting(..) -> Ok(definition.Continue(raw, id("batch")))
        controller.Ended(_) -> Ok(definition.Finish(raw, raw))
        _ -> Error("recipe probe does not implement this agent lifecycle")
      }
    },
    [id("model"), id("batch")],
  )
}

fn env(
  config: checked_agent.Admitted(context),
  context: context,
) -> controller.Env(context) {
  controller.Env(
    config.registry,
    config.policy,
    context,
    config.system_prompt,
    approval_expiry: None,
    clock: fn() { 0 },
    answer: None,
    check_answer: fn(_) { Ok(Nil) },
  )
}

fn load(
  raw: String,
  config: checked_agent.Admitted(context),
) -> Result(controller.State, tool.Failure) {
  use state <- result.try(
    record.decode(raw)
    |> result.map_error(fn(error) { tool.Explain(string.inspect(error)) }),
  )
  record.check(state, config.identity, config.registry)
  |> result.map_error(fn(error) { tool.Explain(string.inspect(error)) })
}

fn transition(env, state, event) {
  controller.step(env, state, event)
  |> result.map(fn(next) { next.0 })
  |> result.map_error(fn(error) { tool.Uncertain(string.inspect(error)) })
}

fn require(condition: Bool, message: String) -> Result(Nil, tool.Failure) {
  case condition {
    True -> Ok(Nil)
    False -> Error(tool.Explain(message))
  }
}

fn id(name: String) -> definition.NodeId {
  let id = definition.node_id(name)
  id
}

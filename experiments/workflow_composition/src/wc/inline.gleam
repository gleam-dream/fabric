//// THROWAWAY (workflow composition experiment). A synchronous driver for the
//// same pure controller, with no store and no processes: used to run a
//// sub-agent inside a parent's `delegate` tool. It shows the controller is
//// not tied to the OTP runtime.

import gleam/list
import wc/agent
import wc/model.{type Model}
import wc/tool

pub fn run(
  model: Model,
  tools: tool.Registry,
  policy: agent.Policy,
  run: String,
  prompt: String,
  max_turns: Int,
) -> Result(String, agent.RunStatus) {
  let config = agent.Config(policy, tools)
  case agent.new(run, prompt, max_turns) {
    Error(reason) -> Error(agent.Finished(agent.HostFailed(reason)))
    Ok(#(state, effects)) -> drive(config, model, state, effects)
  }
}

fn drive(
  config: agent.Config,
  model: Model,
  state: agent.State,
  effects: List(agent.Effect),
) -> Result(String, agent.RunStatus) {
  case effects {
    [] ->
      case agent.status(state) {
        agent.Finished(agent.Answer(text)) -> Ok(text)
        // A child that needs a human must not be swallowed into a string
        // (BeamWeaver anti-oracle B1): surface it to the caller.
        other -> Error(other)
      }
    [effect, ..rest] -> {
      let #(state, more) = perform(config, model, state, effect)
      drive(config, model, state, list.append(rest, more))
    }
  }
}

fn perform(
  config: agent.Config,
  model: Model,
  state: agent.State,
  effect: agent.Effect,
) -> #(agent.State, List(agent.Effect)) {
  case effect {
    agent.CallModel(turn, transcript) -> {
      let event = case model(transcript) {
        Ok(reply) -> agent.ModelReplied(turn, reply)
        Error(reason) -> agent.ModelFailed(turn, reason)
      }
      apply(config, state, event)
    }
    agent.Dispatch(actions) ->
      list.fold(actions, #(state, []), fn(acc, action) {
        let #(id, call) = action
        let #(state, effects) = acc
        let #(state, started) = apply(config, state, agent.ToolStarting(id))
        let outcome = case tool.lookup(config.tools, call.name) {
          Ok(t) -> tool.invoke(t, call.arguments)
          Error(Nil) -> tool.BoundaryFailure("tool vanished")
        }
        let #(state, reported) =
          apply(config, state, agent.ToolReported(id, outcome))
        #(state, list.flatten([effects, started, reported]))
      })
    agent.StopTools -> apply(config, state, agent.ToolsStopped)
  }
}

fn apply(
  config: agent.Config,
  state: agent.State,
  event: agent.Event,
) -> #(agent.State, List(agent.Effect)) {
  case agent.step(config, state, event) {
    Ok(next) -> next
    Error(_) -> #(state, [])
  }
}

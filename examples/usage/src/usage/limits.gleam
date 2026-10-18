//// Bounds. Every attempt, call and wait has a finite default; a setter only
//// stores a bound, and `agent.build` reports every bound out of range at
//// once, each naming its setter.

import fabric/agent.{type Agent}
import fabric/policy
import fabric/run
import gleam/time/duration
import usage/support

/// An agent with its bounds changed on purpose: fewer model attempts, a
/// shorter model call, tool bodies without a time limit, and a token budget
/// (which has no default).
pub fn tuned() -> Result(Agent(Nil, String), List(agent.ConfigError)) {
  agent.new("tuned", support.answering("ok"), [], policy.always_allow())
  |> agent.with_max_turns(4)
  |> agent.with_model_timeout(run.After(duration.seconds(30)))
  |> agent.with_tool_timeout(run.Infinity)
  |> agent.with_token_budget(10_000)
  |> agent.build
}

/// What `build` says about two bounds that are out of range: one line that
/// names both setters.
pub fn rejected() -> String {
  let assert Error(errors) =
    agent.new("bad", support.answering("ok"), [], policy.always_allow())
    |> agent.with_max_turns(0)
    |> agent.with_max_concurrency(-1)
    |> agent.build
  agent.describe_config_errors(errors)
}

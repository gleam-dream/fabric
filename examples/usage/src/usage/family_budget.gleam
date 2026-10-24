//// A family budget bounds the whole family of runs one root run starts:
//// each model attempt, tool action and graph attempt spends one unit of
//// work. When it is spent the run ends with a typed outcome.

import fabric
import fabric/agent
import fabric/budget
import fabric/policy
import fabric/run
import fabric/store
import gleam/erlang/process
import gleam/option.{None}
import gleam/time/duration
import usage/support

/// Two units of work cannot pay for a model attempt, a tool action and a
/// second model attempt: the run ends `BudgetExhausted(FamilyLimit(..))`.
pub fn spent() -> run.Status(String) {
  let assert Ok(desk) =
    agent.new(
      "desk",
      support.calling_once("echo", "{\"text\":\"hi\"}", fn(_) { "done" }),
      [support.echo_tool()],
      policy.always_allow(),
    )
    |> agent.with_family_budget(budget.limits(work: 2))
    |> agent.build
  let runs = store.in_memory(process.new_name("usage-family-budget"))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(status) = fabric.await(handle, within: duration.seconds(5))
  let assert Ok(Nil) = store.stop(runs)
  status
}

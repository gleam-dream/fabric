//// The default bounds of an agent run: a model call, a tool body and a
//// tool result, each with its setter, and `await_with`, which waits for a
//// run or a caller's message in one receive.

import fabric
import fabric/agent
import fabric/budget
import fabric/model
import fabric/policy
import fabric/run.{After, Infinity}
import fabric/support
import fabric/support/codecs
import fabric/support/probe
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn start(desk: agent.Agent(Nil, String)) -> fabric.Run(Nil, String) {
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  handle
}

/// Every bound `build` refuses names its setter, and all of them are
/// reported at once.
pub fn build_reports_every_bound_with_its_setter_test() {
  let assert Error(errors) =
    agent.new(
      "bounded",
      scripted.model(fn(_) { model.FinalAnswer("done", None) }),
      [],
      policy.always_allow(),
    )
    |> agent.with_max_turns(0)
    |> agent.with_max_concurrency(0)
    |> agent.with_token_budget(0)
    |> agent.with_max_children(1000)
    |> agent.with_max_depth(17)
    |> agent.with_policy_timeout(duration.milliseconds(0))
    |> agent.with_model_retry_delay(duration.milliseconds(-1))
    |> agent.with_command_timeout(duration.milliseconds(0))
    |> agent.with_approval_expiry(After(duration.milliseconds(0)))
    |> agent.with_family_budget(
      budget.limits(work: 10) |> budget.with_depth(64),
    )
    |> agent.build
  list.map(errors, fn(error) {
    let assert agent.InvalidLimit(limit:, ..) = error
    limit
  })
  |> should.equal([
    agent.MaxTurns,
    agent.MaxConcurrency,
    agent.TokenBudget,
    agent.MaxChildren,
    agent.MaxDepth,
    agent.PolicyTimeout,
    agent.ModelRetryDelay,
    agent.CommandTimeout,
    agent.ApprovalExpiry,
    agent.FamilyDepth,
  ])
  let assert [first, ..] = errors
  agent.describe_config_error(first)
  |> should.equal("agent.with_max_turns is 0, outside 1..9007199254740991")
}

pub fn build_refuses_bounds_a_timer_cannot_hold_test() {
  let spec =
    agent.new(
      "bounded",
      scripted.model(fn(_) { model.FinalAnswer("done", None) }),
      [],
      policy.always_allow(),
    )
  let too_long = duration.milliseconds(4_294_967_296)
  spec
  |> agent.with_model_timeout(After(duration.milliseconds(0)))
  |> agent.with_tool_timeout(After(too_long))
  |> agent.with_max_result_bytes(0)
  |> agent.build
  |> should_fail_with([
    agent.InvalidLimit(agent.ModelTimeout, 0, 1, 4_294_967_295),
    agent.InvalidLimit(agent.ToolTimeout, 4_294_967_296, 1, 4_294_967_295),
    agent.InvalidLimit(agent.MaxResultBytes, 0, 1, 9_007_199_254_740_991),
  ])
  let lookup =
    tool.define(
      "lookup",
      "",
      codecs.one_field("x", codec.string()),
      codec.string(),
    )
    |> tool.bind(fn(_, _, x) { Ok(x) }, fn(_: Nil) { tool.Explain("no") })
    |> tool.with_timeout(After(duration.milliseconds(0)))
  agent.new(
    "bounded",
    scripted.model(fn(_) { model.FinalAnswer("done", None) }),
    [lookup],
    policy.always_allow(),
  )
  |> agent.build
  |> should_fail_with([
    agent.InvalidToolLimit("lookup", agent.ToolTimeout, 0, 1, 4_294_967_295),
  ])
  // Unbounded is explicit, and accepted.
  spec
  |> agent.with_model_timeout(Infinity)
  |> agent.with_tool_timeout(Infinity)
  |> agent.build
  |> should.be_ok
}

fn should_fail_with(
  built: Result(agent.Agent(c, String), List(agent.ConfigError)),
  errors: List(agent.ConfigError),
) -> Nil {
  case built {
    Error(found) -> found |> should.equal(errors)
    Ok(_) -> panic as "expected a configuration error"
  }
}

/// A model call still running at its timeout is stopped and counts as a
/// retryable failure, which spends a turn: the next attempt answers.
pub fn a_slow_model_call_times_out_and_is_retried_test() {
  let model =
    model.new(fn(request) {
      case request.turn {
        1 -> {
          process.sleep(2000)
          Ok(model.FinalAnswer("late", None))
        }
        _ -> Ok(model.FinalAnswer("on time", None))
      }
    })
  let desk =
    agent.new("slow-model", model, [], policy.always_allow())
    |> agent.with_model_timeout(After(duration.milliseconds(50)))
    |> agent.with_model_retry_delay(duration.milliseconds(0))
    |> support.agent
  let handle = start(desk)
  fabric.await(handle, within: duration.seconds(5))
  |> should.equal(Ok(run.Finished(run.Completed("on time"))))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  snapshot.turns_used |> should.equal(2)
}

/// A model call that times out on every turn ends the run on its turns,
/// with the timeout as the last failure.
pub fn a_model_that_never_answers_in_time_ends_on_its_turns_test() {
  let model =
    model.new(fn(_) {
      process.sleep(2000)
      Ok(model.FinalAnswer("late", None))
    })
  let desk =
    agent.new("stuck-model", model, [], policy.always_allow())
    |> agent.with_max_turns(2)
    |> agent.with_model_timeout(After(duration.milliseconds(30)))
    |> agent.with_model_retry_delay(duration.milliseconds(0))
    |> support.agent
  fabric.await(start(desk), within: duration.seconds(5))
  |> should.equal(Ok(run.Finished(run.BudgetExhausted(run.TurnLimit(2)))))
}

fn sleeping_tool(sleep: Int) -> tool.Tool(Nil) {
  tool.define(
    "slow",
    "Sleeps.",
    codecs.one_field("x", codec.string()),
    codec.string(),
  )
  |> tool.bind(
    fn(_context, _call, x: String) -> Result(String, Nil) {
      process.sleep(sleep)
      Ok(x)
    },
    fn(_) { tool.Explain("failed") },
  )
}

/// A tool body still running at its timeout is stopped; it may have acted,
/// so its action is an uncertain effect the run waits to have reconciled.
pub fn a_tool_body_past_its_timeout_is_an_uncertain_effect_test() {
  let desk =
    agent.new(
      "slow-tool",
      scripted.plan([scripted.slow("a", "a")]),
      [sleeping_tool(5000)],
      policy.always_allow(),
    )
    |> agent.with_tool_timeout(After(duration.milliseconds(50)))
    |> support.agent
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(start(desk), within: duration.seconds(5))
  uncertain.tool |> should.equal("slow")
  string.contains(uncertain.evidence, "50 ms timeout") |> should.be_true
}

/// `tool.with_timeout` overrides the agent's bound for one tool.
pub fn a_tools_own_timeout_overrides_the_agents_test() {
  let desk =
    agent.new(
      "own-timeout",
      scripted.plan([scripted.slow("a", "a")]),
      [sleeping_tool(150) |> tool.with_timeout(Infinity)],
      policy.always_allow(),
    )
    |> agent.with_tool_timeout(After(duration.milliseconds(50)))
    |> support.agent
  fabric.await(start(desk), within: duration.seconds(5))
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
}

/// A result larger than the run keeps stops the run and names the limit.
pub fn a_result_over_the_size_limit_stops_the_run_test() {
  let big =
    tool.define(
      "big",
      "Returns a lot.",
      codecs.one_field("x", codec.string()),
      codec.string(),
    )
    |> tool.bind(fn(_, _, _x) { Ok(string.repeat("a", 200)) }, fn(_: Nil) {
      tool.Explain("failed")
    })
  let desk =
    agent.new(
      "big-result",
      scripted.plan([scripted.call("b", "big", "{\"x\":\"a\"}")]),
      [big],
      policy.always_allow(),
    )
    |> agent.with_max_result_bytes(100)
    |> support.agent
  let assert Ok(run.Finished(run.Failed(run.OutputEncodingFailed(id, detail)))) =
    fabric.await(start(desk), within: duration.seconds(5))
  id |> should.equal(run.ActionId(1, "b"))
  string.contains(detail, "agent.with_max_result_bytes") |> should.be_true
}

/// The shape of tool_hub's Relay handler: it waits for its run and for its
/// caller's cancellation in one receive, cancels the run when the caller
/// goes away, and needs no waiter process.
pub fn await_with_returns_the_callers_message_first_test() {
  let probe = probe.new()
  let desk =
    agent.new(
      "interruptible",
      scripted.plan([scripted.slow("a", "a")]),
      [scripted.gated_tool(probe)],
      policy.always_allow(),
    )
    |> support.agent
  let handle = start(desk)
  let _arrival = probe.arrival(probe)
  // Relay's `tool.cancelled(call)` is a `Selector(Nil)`.
  let cancel = process.new_subject()
  let cancelled = process.new_selector() |> process.select(cancel)
  process.spawn(fn() {
    process.sleep(50)
    process.send(cancel, Nil)
  })
  fabric.await_with(handle, within: duration.seconds(5), or: cancelled)
  |> should.equal(Ok(fabric.Interrupted(Nil)))
  // The wait changed nothing; the handler cancels the run.
  let assert Ok(_) = fabric.cancel(handle)
  fabric.await(handle, within: duration.seconds(5))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  list.contains(probe.entries(probe), "end:a") |> should.be_false
}

/// With nothing on the selector it is `await`.
pub fn await_with_returns_the_status_when_the_run_settles_test() {
  let desk =
    agent.new(
      "settles",
      scripted.model(fn(_) { model.FinalAnswer("done", None) }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let never: process.Selector(Nil) =
    process.new_selector() |> process.select(process.new_subject())
  fabric.await_with(start(desk), within: duration.seconds(5), or: never)
  |> should.equal(Ok(fabric.Reached(run.Finished(run.Completed("done")))))
}

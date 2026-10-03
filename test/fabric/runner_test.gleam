//// The OTP runtime through the public API, with real processes. Tests wait
//// on barriers and committed statuses, never on sleeps.

import fabric
import fabric/agent
import fabric/internal/runner
import fabric/model.{AssistantMessage, ToolResultMessage, UserMessage}
import fabric/policy
import fabric/run.{ActionId}
import fabric/support
import fabric/support/apps
import fabric/support/flaky
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleeunit/should

fn states(run: fabric.Run(Nil)) -> List(run.ActionState) {
  let assert Ok(snapshot) = fabric.snapshot(run)
  list.map(snapshot.actions, fn(action) { action.state })
}

fn transfers_need_approval(
  _context: Nil,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  case action.tool {
    "transfer_funds" ->
      Ok(policy.RequireApproval(run.Requirement("transfer", 1)))
    _ -> Ok(policy.Allow)
  }
}

pub fn run_completes_with_two_typed_tools_test() {
  let calls = [
    scripted.call("c1", "lookup_weather", "{\"city\":\"Paris\"}"),
    scripted.call("c2", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}"),
  ]
  let agent =
    agent.new(
      "agent",
      scripted.plan(calls),
      [apps.weather_tool(), apps.transfer_tool()],
      policy.always_allow(),
    )
    |> support.agent
  let held = support.store()
  let assert Ok(run) =
    fabric.start(
      held,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "weather, then pay bob",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Completed(answer))) =
    fabric.await(run, within: duration.milliseconds(5000))
  answer
  |> should.equal("final: {\"summary\":\"sunny\"} | {\"receipt\":\"r-bob\"}")
  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.transcript
  |> should.equal([
    UserMessage("weather, then pay bob"),
    AssistantMessage(model.AssistantTurn("", calls, None)),
    ToolResultMessage("c1", "{\"summary\":\"sunny\"}"),
    ToolResultMessage("c2", "{\"receipt\":\"r-bob\"}"),
    AssistantMessage(model.AssistantTurn(answer, [], None)),
  ])
  snapshot.turns_used |> should.equal(2)
  snapshot.usage |> should.equal(run.TokenUsage(30, 10, 0))
  restart.runner(held, fabric.id(run)) |> should.equal(Error(Nil))
}

pub fn typed_failure_is_visible_to_the_model_test() {
  let agent =
    agent.new(
      "agent",
      scripted.plan([
        scripted.call("c1", "lookup_weather", "{\"city\":\"Oslo\"}"),
      ]),
      [apps.weather_tool()],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "weather in Oslo",
      correlation: None,
    )
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"error\":\"unknown city: Oslo\"}"))),
  )
  let assert [run.ToolFailed(_)] = states(run)
}

pub fn tool_concurrency_is_bounded_per_run_test() {
  let probe = probe.new()
  let agent =
    agent.new(
      "agent",
      scripted.plan([
        scripted.slow("a", "a"),
        scripted.slow("b", "b"),
        scripted.slow("c", "c"),
      ]),
      [scripted.gated_tool(probe)],
      policy.always_allow(),
    )
    |> agent.with_limits(
      agent.Limits(..agent.default_limits(), max_concurrency: 2),
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "three slow things",
      correlation: None,
    )
  let first = probe.arrival(probe)
  let second = probe.arrival(probe)
  // Two bodies are blocked; the third may only start after one ends.
  probe.release(first)
  let third = probe.arrival(probe)
  probe.release(second)
  probe.release(third)
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(run, within: duration.milliseconds(5000))
  probe.peak(probe) |> should.equal(2)
}

pub fn approval_suspends_the_run_as_data_test() {
  let agent =
    agent.new(
      "agent",
      scripted.plan([
        scripted.call("w", "lookup_weather", "{\"city\":\"Paris\"}"),
        scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}"),
      ]),
      [apps.weather_tool(), apps.transfer_tool()],
      transfers_need_approval,
    )
    |> support.agent
  let held = support.store()
  let assert Ok(run) =
    fabric.start(
      held,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "pay bob",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  pending.reference.id |> should.equal(ActionId(1, "t"))
  pending.reference.requirement
  |> should.equal(run.Requirement("transfer", 1))
  // No process holds the suspended run.
  restart.runner(held, fabric.id(run)) |> should.equal(Error(Nil))
  let assert [run.Succeeded(_), run.AwaitingApproval(_, 1)] = states(run)
  // Cancelling it is a transition on the stored record.
  fabric.cancel(run) |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert [run.Succeeded(_), run.NotStarted] = states(run)
  fabric.cancel(run) |> should.equal(Error(fabric.RunEnded))
}

pub fn cancel_kills_running_tools_and_records_them_uncertain_test() {
  let probe = probe.new()
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("a", "a"), scripted.slow("b", "b")]),
      [scripted.gated_tool(probe)],
      policy.always_allow(),
    )
    |> agent.with_limits(
      agent.Limits(..agent.default_limits(), max_concurrency: 1),
    )
    |> support.agent
  let held = support.store()
  let assert Ok(run) =
    fabric.start(
      held,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "two slow things",
      correlation: None,
    )
  let first = probe.arrival(probe)
  first.name |> should.equal("a")
  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert [run.Uncertain(_), run.NotStarted] = states(run)
  // The body started once, never finished, and was never retried.
  probe.entries(probe) |> should.equal(["start:a"])
  restart.runner(held, fabric.id(run)) |> should.equal(Error(Nil))
}

pub fn cancel_while_the_model_is_called_test() {
  let probe = probe.new()
  let blocking =
    model.new(fn(_request) {
      probe.gate(probe, "model")
      Ok(model.FinalAnswer("too late", option.None))
    })
  let agent =
    agent.new("agent", blocking, [], policy.always_allow())
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "think",
      correlation: None,
    )
  let _ = probe.arrival(probe)
  fabric.cancel(run) |> should.equal(Ok(run.Finished(run.Cancelled)))
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
}

pub fn uncertain_effect_blocks_until_reconciled_test() {
  let agent =
    agent.new(
      "agent",
      scripted.plan([
        scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":5000}"),
      ]),
      [apps.transfer_tool()],
      policy.always_allow(),
    )
    |> support.agent
  let held = support.store()
  let assert Ok(run) =
    fabric.start(
      held,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "pay bob a lot",
      correlation: None,
    )
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(run, within: duration.milliseconds(5000))
  uncertain
  |> should.equal(run.UncertainAction(
    run.ActionRef(fabric.id(run), ActionId(1, "t")),
    "transfer_funds",
    "gateway timed out after sending",
  ))
  restart.runner(held, fabric.id(run)) |> should.equal(Error(Nil))
  let assert Ok(run.Working) =
    fabric.reconcile(run, uncertain.reference, "{\"receipt\":\"confirmed\"}")
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"receipt\":\"confirmed\"}"))),
  )
  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.turns_used |> should.equal(2)
}

pub fn crash_after_the_fence_is_an_uncertain_effect_test() {
  let probe = probe.new()
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.call("x", "crash", "{\"x\":\"boom\"}")]),
      [scripted.crashing_tool(probe)],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "crash",
      correlation: None,
    )
  let assert Ok(run.Suspended([], [crashed])) =
    fabric.await(run, within: duration.milliseconds(5000))
  string.starts_with(crashed.evidence, "tool crashed") |> should.be_true
  probe.count(probe, "crash:boom") |> should.equal(1)
}

pub fn policy_failure_is_a_host_failure_test() {
  let failing = fn(_context: Nil, _action) { Error("policy service down") }
  let agent =
    agent.new(
      "agent",
      scripted.plan([
        scripted.call("w", "lookup_weather", "{\"city\":\"Paris\"}"),
      ]),
      [apps.weather_tool()],
      failing,
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "weather",
      correlation: None,
    )
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(
      run.Finished(
        run.Failed(run.PolicyFailed(ActionId(1, "w"), "policy service down")),
      ),
    ),
  )
}

pub fn crashing_policy_fails_closed_test() {
  let crashing = fn(_context: Nil, _action) -> Result(policy.Decision, String) {
    panic as "policy bug"
  }
  let agent =
    agent.new(
      "agent",
      scripted.plan([
        scripted.call("w", "lookup_weather", "{\"city\":\"Paris\"}"),
      ]),
      [apps.weather_tool()],
      crashing,
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "weather",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Failed(run.PolicyFailed(_, reason)))) =
    fabric.await(run, within: duration.milliseconds(5000))
  string.starts_with(reason, "policy crashed") |> should.be_true
}

/// Every problem is reported at once, and only a checked agent can start
/// a run.
pub fn invalid_configuration_is_rejected_before_starting_test() {
  let spec =
    agent.new(
      "agent",
      scripted.plan([]),
      [apps.weather_tool(), apps.weather_tool()],
      policy.always_allow(),
    )
    |> agent.with_limits(
      agent.Limits(
        ..agent.default_limits(),
        max_turns: 0,
        max_concurrency: -1,
        token_budget: Some(0),
      ),
    )
  let expected = [
    agent.DuplicateToolName("lookup_weather"),
    agent.MaxTurnsNotPositive(0),
    agent.MaxConcurrencyNotPositive(-1),
    agent.TokenBudgetNotPositive(0),
  ]
  agent.build(spec) |> should.equal(Error(expected))
}

pub fn handler_receives_the_run_context_test() {
  let greet =
    apps.weather_definition()
    |> tool_bind_context
  let agent =
    agent.new(
      "agent",
      scripted.plan([
        scripted.call("w", "lookup_weather", "{\"city\":\"Rome\"}"),
      ]),
      [greet],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: "alice",
      prompt: "hi",
      correlation: None,
    )
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"alice in Rome\"}"))),
  )
}

fn tool_bind_context(
  definition: tool.Definition(apps.City, apps.Forecast),
) -> tool.Tool(String) {
  tool.bind(
    definition,
    fn(context: String, _call, city: apps.City) -> Result(apps.Forecast, Nil) {
      Ok(apps.Forecast(context <> " in " <> city.name))
    },
    fn(_) { tool.Explain("failed") },
  )
}

pub fn concurrent_cancels_of_a_suspended_run_have_one_winner_test() {
  let agent =
    agent.new(
      "agent",
      scripted.plan([
        scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}"),
      ]),
      [apps.transfer_tool()],
      transfers_need_approval,
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "pay bob",
      correlation: None,
    )
  let assert Ok(run.Suspended([_], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  let results = process.new_subject()
  list.each(list.repeat(Nil, 8), fn(_) {
    process.spawn(fn() { process.send(results, fabric.cancel(run)) })
  })
  let outcomes =
    list.map(list.repeat(Nil, 8), fn(_) {
      let assert Ok(outcome) = process.receive(results, 5000)
      outcome
    })
  list.count(outcomes, fn(o) { o == Ok(run.Finished(run.Cancelled)) })
  |> should.equal(1)
  list.count(outcomes, fn(o) { o == Error(fabric.RunEnded) })
  |> should.equal(7)
}

pub fn a_policy_that_never_answers_fails_closed_at_its_deadline_test() {
  let stuck = fn(_context: Nil, _action) -> Result(policy.Decision, String) {
    let never: process.Subject(policy.Decision) = process.new_subject()
    Ok(process.receive_forever(never))
  }
  let agent =
    agent.new(
      "agent",
      scripted.plan([
        scripted.call("w", "lookup_weather", "{\"city\":\"Paris\"}"),
      ]),
      [apps.weather_tool()],
      stuck,
    )
    |> agent.with_limits(
      agent.Limits(
        ..agent.default_limits(),
        policy_timeout: duration.milliseconds(50),
      ),
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "weather",
      correlation: None,
    )
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(
      run.Finished(
        run.Failed(run.PolicyFailed(
          ActionId(1, "w"),
          "policy gave no decision within 50 ms",
        )),
      ),
    ),
  )
}

pub fn the_policy_timeout_must_be_positive_test() {
  agent.new("agent", scripted.plan([]), [], policy.always_allow())
  |> agent.with_limits(
    agent.Limits(
      ..agent.default_limits(),
      policy_timeout: duration.milliseconds(0),
    ),
  )
  |> agent.build
  |> should.equal(
    Error([agent.PolicyTimeoutNotPositive(duration.milliseconds(0))]),
  )
}

/// A timeout past the longest timer the runtime can set (2^32 - 1 ms) would
/// crash the process waiting on it, and a first retry delay past a 64th of
/// it would once doubled: each is refused up front, with its limit.
pub fn timer_fed_limits_must_fit_a_timer_test() {
  let longest = 4_294_967_295
  agent.new("agent", scripted.plan([]), [], policy.always_allow())
  |> agent.with_limits(
    agent.Limits(
      ..agent.default_limits(),
      policy_timeout: duration.milliseconds(longest + 1),
      command_timeout: duration.milliseconds(longest + 1),
      model_retry_delay: duration.milliseconds(longest / 64 + 1),
    ),
  )
  |> agent.build
  |> should.equal(
    Error([
      agent.PolicyTimeoutTooLarge(
        value: duration.milliseconds(longest + 1),
        limit: duration.milliseconds(longest),
      ),
      agent.CommandTimeoutTooLarge(
        value: duration.milliseconds(longest + 1),
        limit: duration.milliseconds(longest),
      ),
      agent.ModelRetryDelayTooLarge(
        value: duration.milliseconds(longest / 64 + 1),
        limit: duration.milliseconds(longest / 64),
      ),
    ]),
  )
  agent.new("agent", scripted.plan([]), [], policy.always_allow())
  |> agent.with_limits(
    agent.Limits(
      ..agent.default_limits(),
      policy_timeout: duration.milliseconds(longest),
      command_timeout: duration.milliseconds(longest),
      model_retry_delay: duration.milliseconds(longest / 64),
    ),
  )
  |> agent.build
  |> result.is_ok
  |> should.be_true
}

// --- model retries -------------------------------------------------------------

/// A retryable model failure is retried after a delay that doubles with
/// each consecutive failure.
pub fn model_retries_back_off_test() {
  let probe = probe.new()
  let flaky =
    model.new(fn(_request) {
      probe.record(probe, "call")
      case probe.count(probe, "call") {
        n if n <= 2 -> Error(model.ModelError("reset", retryable: True))
        _ -> Ok(model.FinalAnswer("ok", option.None))
      }
    })
  let agent =
    agent.new("agent", flaky, [], policy.always_allow())
    |> agent.with_limits(
      agent.Limits(
        ..agent.default_limits(),
        model_retry_delay: duration.milliseconds(40),
      ),
    )
    |> support.agent
  let started = now()
  let assert Ok(run) =
    fabric.start(
      support.store(),
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "hi",
      correlation: None,
    )
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("ok"))))
  // Two retries: 40 ms, then 80 ms.
  { now() - started >= 120 } |> should.be_true
  probe.count(probe, "call") |> should.equal(3)
}

pub fn the_model_retry_delay_must_not_be_negative_test() {
  agent.new("agent", scripted.plan([]), [], policy.always_allow())
  |> agent.with_limits(
    agent.Limits(
      ..agent.default_limits(),
      model_retry_delay: duration.milliseconds(-1),
    ),
  )
  |> agent.build
  |> should.equal(
    Error([agent.ModelRetryDelayNegative(duration.milliseconds(-1))]),
  )
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic(unit: Unit) -> Int

type Unit {
  Millisecond
}

fn now() -> Int {
  monotonic(Millisecond)
}

/// A transient `Unavailable` on the fence commit, or on any later commit,
/// is retried by the runner instead of stranding the run.
pub fn a_runner_retries_a_commit_the_store_could_not_make_test() {
  let flaky = flaky.new()
  let store = flaky.store(flaky)
  let agent =
    agent.new(
      "agent",
      scripted.plan([
        scripted.call("w", "lookup_weather", "{\"city\":\"Paris\"}"),
      ]),
      [apps.weather_tool()],
      policy.always_allow(),
    )
    |> support.agent
  // The insert passes; the commit of the reply, the fence, and the report
  // each fail once before the write happens.
  flaky.arm(flaky, [
    flaky.Pass,
    flaky.FailBefore,
    flaky.Pass,
    flaky.FailBefore,
    flaky.Pass,
    flaky.FailBefore,
  ])
  let assert Ok(run) =
    fabric.start(
      store,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "weather",
      correlation: None,
    )
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"sunny\"}"))),
  )
}

/// An exit signal from outside (a supervisor's shutdown) stops the runner
/// and its tools instead of being ignored; the run is then reported as
/// having no runner.
pub fn an_exit_signal_from_outside_stops_the_runner_test() {
  let probe = probe.new()
  let store = support.store()
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("a", "a")]),
      [scripted.gated_tool(probe)],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      store,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let _ = probe.arrival(probe)
  let assert Ok(runner) = restart.runner(store, fabric.id(run))
  let monitor = process.monitor(runner)
  process.send_abnormal_exit(runner, "shutdown")
  let assert Ok(Nil) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Unattended))
}

/// A string in another shape never becomes a run id, and a stored-run read
/// by such a string finds nothing without asking the backend.
pub fn a_run_id_that_fabric_never_issues_is_not_found_test() {
  run.parse_id("../escape") |> should.equal(Error(Nil))
  run.parse_id("") |> should.equal(Error(Nil))
  run.parse_id(string.repeat("a", 129)) |> should.equal(Error(Nil))
  let assert Ok(id) = run.parse_id("run-A_1")
  run.id_to_string(id) |> should.equal("run-A_1")

  let dir = restart.temp_dir()
  let store = support.directory(dir)
  runner.load(store, "../escape") |> should.equal(Error(runner.NotFound))
  runner.load(store, "") |> should.equal(Error(runner.NotFound))
  restart.remove_dir(dir)
}

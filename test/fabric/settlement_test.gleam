//// Late settlement: a tool bound with `tool.bind_settling` gets a handle
//// with which its result can be settled after its task was stopped. The
//// test holds the handle itself, so every settlement happens at a point
//// the test chooses. Tests wait on barriers and committed statuses, never
//// on sleeps.

import fabric
import fabric/agent
import fabric/policy
import fabric/run
import fabric/store
import fabric/support/apps.{type City, type Forecast, Forecast}
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process.{type Subject}
import gleam/string
import gleeunit/should

/// What the tool body does after handing its settlement to the test.
type Then {
  /// Wait until the test releases the body, then return `Paris`'s forecast.
  Wait
  /// Die without reporting, as a task killed from outside would.
  Die
}

type Handed {
  Handed(settlement: tool.Settlement(Forecast), release: Subject(Nil))
}

/// `lookup_weather`, settling within `within` ms after a stop. Its body
/// hands its settlement to `handed`, then does `then`.
fn settling_tool(
  handed: Subject(Handed),
  then: Then,
  within: Int,
) -> tool.Tool(Nil) {
  tool.bind_settling(
    apps.weather_definition(),
    fn(_, _city: City, settlement) {
      let release = process.new_subject()
      process.send(handed, Handed(settlement, release))
      case then {
        Wait -> {
          let assert Ok(Nil) = process.receive(release, 10_000)
          Ok(Forecast("sunny"))
        }
        Die -> {
          process.kill(process.self())
          Ok(Forecast("never"))
        }
      }
    },
    fn(_: Nil) { tool.Explain("failed") },
    within:,
  )
}

fn start(
  handed: Subject(Handed),
  then: Then,
  within: Int,
) -> #(fabric.Run(Nil), Handed) {
  let agent =
    agent.new(
      scripted.plan([
        scripted.call("w", "lookup_weather", "{\"city\":\"Paris\"}"),
      ]),
      [settling_tool(handed, then, within)],
      policy.always_allow(),
    )
  let assert Ok(run) = fabric.start(store.in_memory(), agent, Nil, "weather")
  let assert Ok(handed) = process.receive(handed, 5000)
  #(run, handed)
}

fn only_state(run: fabric.Run(Nil)) -> run.ActionState {
  let assert Ok(snapshot) = fabric.snapshot(run)
  let assert [action] = snapshot.actions
  action.state
}

/// Cancelling stops the tool's task, and the run waits for the tool's
/// settlement before it ends: a definite settlement is recorded as the
/// action's typed result, encoded by the tool's output codec.
pub fn a_stopped_tool_is_settled_definitely_before_the_run_ends_test() {
  let #(run, handed) = start(process.new_subject(), Wait, 5000)
  let assert Ok(run.Working) = fabric.cancel(run)
  tool.settle(handed.settlement, Ok(Forecast("cloudy")))
  |> should.equal(Ok(Nil))
  fabric.await(run, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
  only_state(run) |> should.equal(run.Succeeded("{\"summary\":\"cloudy\"}"))

  // Exactly once: the action no longer waits for a settlement.
  tool.settle(handed.settlement, Error(tool.Explain("again")))
  |> should.equal(Error(tool.NotAwaited))
}

/// A settlement that leaves the effect uncertain is recorded with its own
/// evidence.
pub fn a_stopped_tool_can_settle_as_uncertain_test() {
  let #(run, handed) = start(process.new_subject(), Wait, 5000)
  let assert Ok(_) = fabric.cancel(run)
  let assert Ok(Nil) =
    tool.settle(handed.settlement, Error(tool.Uncertain("undo failed")))
  fabric.await(run, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
  only_state(run) |> should.equal(run.Uncertain("undo failed"))
}

/// No settlement arrives within the tool's bound: the action is an
/// uncertain effect and the run ends. A settlement after that is refused
/// and changes nothing.
pub fn a_settlement_after_the_run_ended_is_refused_test() {
  let #(run, handed) = start(process.new_subject(), Wait, 20)
  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert run.Uncertain(evidence) = only_state(run)
  string.contains(evidence, "no settlement") |> should.be_true
  let assert Ok(before) = fabric.snapshot(run)

  tool.settle(handed.settlement, Ok(Forecast("cloudy")))
  |> should.equal(Error(tool.NotAwaited))
  fabric.snapshot(run) |> should.equal(Ok(before))
}

/// While the task runs, its own result is awaited, not a settlement; once
/// it has reported, the action is settled.
pub fn a_settlement_while_the_task_runs_is_refused_test() {
  let #(run, handed) = start(process.new_subject(), Wait, 5000)
  tool.settle(handed.settlement, Ok(Forecast("cloudy")))
  |> should.equal(Error(tool.NotAwaited))
  process.send(handed.release, Nil)
  fabric.await(run, 5000)
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"summary\":\"sunny\"}"))),
  )
  tool.settle(handed.settlement, Ok(Forecast("cloudy")))
  |> should.equal(Error(tool.NotAwaited))
}

/// A task that died without reporting leaves an uncertain effect, and the
/// run waits for it. A definite settlement records what happened, like a
/// reconciliation of exactly that action, and the run continues; an
/// uncertain one learns nothing new and is refused.
pub fn a_settlement_resolves_an_uncertain_effect_test() {
  let #(run, handed) = start(process.new_subject(), Die, 5000)
  let assert Ok(run.Suspended([], [_])) = fabric.await(run, 5000)
  tool.settle(handed.settlement, Error(tool.Uncertain("still unknown")))
  |> should.equal(Error(tool.NotAwaited))
  tool.settle(handed.settlement, Error(tool.Explain("no forecast today")))
  |> should.equal(Ok(Nil))
  fabric.await(run, 5000)
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"error\":\"no forecast today\"}"))),
  )
}

/// A human reconciliation that came first wins.
pub fn a_settlement_after_a_reconciliation_is_refused_test() {
  let #(run, handed) = start(process.new_subject(), Die, 5000)
  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(run, 5000)
  let assert Ok(_) = fabric.reconcile(run, uncertain.id, "{\"summary\":\"?\"}")
  tool.settle(handed.settlement, Ok(Forecast("cloudy")))
  |> should.equal(Error(tool.NotAwaited))
  fabric.await(run, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("final: {\"summary\":\"?\"}"))))
}

pub fn a_settlement_bound_must_be_positive_test() {
  agent.new(
    scripted.plan([]),
    [settling_tool(process.new_subject(), Wait, 0)],
    policy.always_allow(),
  )
  |> agent.validate
  |> should.equal(
    Error([agent.SettlementBoundNotPositive("lookup_weather", 0)]),
  )
}

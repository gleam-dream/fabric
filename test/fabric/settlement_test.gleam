//// Late settlement: a tool bound with `tool.bind_settling` gets a handle
//// with which its result can be settled after its task was stopped. The
//// test holds the handle itself, so every settlement happens at a point
//// the test chooses. Tests wait on barriers and committed statuses, never
//// on sleeps.

import fabric
import fabric/agent
import fabric/observation as o
import fabric/policy
import fabric/run
import fabric/store
import fabric/support/apps.{type City, type Forecast, Forecast}
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import sinal

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

// --- two stopped tools ----------------------------------------------------------

type Named {
  Named(name: String, settlement: tool.Settlement(Forecast))
}

/// A tool `name` whose body hands its settlement to `handed` and waits
/// until it is stopped.
fn named_settling(
  name: String,
  handed: Subject(Named),
  within: Int,
) -> tool.Tool(Nil) {
  tool.define(name, "weather", apps.city_codec(), apps.forecast_codec())
  |> tool.bind_settling(
    fn(_, _city: City, settlement) {
      process.send(handed, Named(name, settlement))
      let never = process.new_subject()
      let _ = process.receive_forever(never)
      Ok(Forecast("never"))
    },
    fn(_: Nil) { tool.Explain("failed") },
    within:,
  )
}

/// Runs `wa` (bound `a_within`) and `wb` (bound `b_within`) in one batch
/// and returns their settlements once both bodies run.
fn start_two(
  a_within: Int,
  b_within: Int,
) -> #(fabric.Run(Nil), tool.Settlement(Forecast), tool.Settlement(Forecast)) {
  let handed = process.new_subject()
  let agent =
    agent.new(
      scripted.plan([
        scripted.call("a", "wa", "{\"city\":\"Paris\"}"),
        scripted.call("b", "wb", "{\"city\":\"Paris\"}"),
      ]),
      [
        named_settling("wa", handed, a_within),
        named_settling("wb", handed, b_within),
      ],
      policy.always_allow(),
    )
  let assert Ok(run) = fabric.start(store.in_memory(), agent, Nil, "go")
  let assert Ok(first) = process.receive(handed, 5000)
  let assert Ok(second) = process.receive(handed, 5000)
  case first.name {
    "wa" -> #(run, first.settlement, second.settlement)
    _ -> #(run, second.settlement, first.settlement)
  }
}

fn states(run: fabric.Run(Nil)) -> List(run.ActionState) {
  let assert Ok(snapshot) = fabric.snapshot(run)
  list.map(snapshot.actions, fn(action) { action.state })
}

/// An action accepts one settlement: an uncertain one is recorded, and a
/// definite one offered afterwards is refused, while the other tool keeps
/// the run stopping.
pub fn a_settlement_is_accepted_once_per_action_test() {
  let #(run, a, b) = start_two(5000, 5000)
  let assert Ok(run.Working) = fabric.cancel(run)
  tool.settle(a, Error(tool.Uncertain("unknown"))) |> should.equal(Ok(Nil))
  tool.settle(a, Ok(Forecast("cloudy")))
  |> should.equal(Error(tool.NotAwaited))
  tool.settle(b, Ok(Forecast("rain"))) |> should.equal(Ok(Nil))
  fabric.await(run, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
  states(run)
  |> should.equal([
    run.Uncertain("unknown"),
    run.Succeeded("{\"summary\":\"rain\"}"),
  ])
}

/// Past its tool's bound the action is an uncertain effect; a settlement
/// that arrives afterwards, while the other tool keeps the run stopping, is
/// refused and changes nothing.
pub fn a_settlement_after_the_bound_is_refused_while_stopping_test() {
  let lapsed = process.new_subject()
  let assert Ok(id) =
    sinal.handler_id(
      "settlement-lapsed-" <> int.to_string(int.random(1_000_000)),
    )
  let assert Ok(attached) =
    sinal.observe(id, o.tool_settled(), fn(_, settled: o.ToolSettled) {
      case settled.action.tool, settled.disposition {
        "wa", o.EffectUncertain -> process.send(lapsed, Nil)
        _, _ -> Nil
      }
    })
  let #(run, a, b) = start_two(20, 5000)
  let assert Ok(run.Working) = fabric.cancel(run)
  let assert Ok(Nil) = process.receive(lapsed, 5000)
  let _ = sinal.detach(attached)

  tool.settle(a, Ok(Forecast("late"))) |> should.equal(Error(tool.NotAwaited))
  let assert [run.Uncertain(evidence), run.Running] = states(run)
  string.contains(evidence, "no settlement") |> should.be_true
  tool.settle(b, Ok(Forecast("rain"))) |> should.equal(Ok(Nil))
  fabric.await(run, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
}

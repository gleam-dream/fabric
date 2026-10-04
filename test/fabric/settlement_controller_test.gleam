//// The late-settlement rule of the pure controller: a stopped tool's
//// settlement is accepted once, only after the executor confirmed its task
//// no longer runs and before its bound passed.

import fabric/internal/controller.{type State}
import fabric/internal/invocation
import fabric/internal/registry
import fabric/model.{ToolRequest}
import fabric/policy
import fabric/run.{ActionId}
import fabric/support/apps.{Forecast}
import fabric/tool
import gleam/list
import gleam/option.{None}
import gleam/time/duration
import gleeunit/should

fn settling(name: String) -> tool.Tool(Nil) {
  tool.define(name, "weather", apps.city_codec(), apps.forecast_codec())
  |> tool.bind_settling(
    fn(_, _call, _, _) { Ok(Forecast("sunny")) },
    fn(_: Nil) { tool.Explain("failed") },
    settle_within: duration.milliseconds(50),
  )
}

fn env() -> controller.Env(Nil) {
  let assert Ok(tools) = registry.new([settling("wa"), settling("wb")])
  controller.Env(
    registry: tools,
    policy: policy.always_allow(),
    context: Nil,
    system: None,
    approval_expiry: None,
    clock: fn() { 0 },
    answer: None,
    check_answer: fn(_) { Ok(Nil) },
    answer_attempts: 1,
  )
}

fn step(state: State, event: controller.Event) -> State {
  let assert Ok(#(state, _)) = controller.step(env(), state, event)
  state
}

const a = ActionId(1, "a")

const b = ActionId(1, "b")

/// Both tools started, then the run was cancelled: stopping, tools not yet
/// confirmed stopped.
fn cancelled() -> State {
  let #(state, _) =
    controller.start(
      env(),
      "run-1",
      run.DefinitionId("agent", 1),
      controller.Limits(5, None, 0, 0),
      "go",
      None,
      0,
    )
  let city = "{\"city\":\"Paris\"}"
  state
  |> step(controller.ModelReplied(
    1,
    ToolRequest(
      model.AssistantTurn(
        "",
        [
          model.tool_call(id: "a", name: "wa", arguments_json: city),
          model.tool_call(id: "b", name: "wb", arguments_json: city),
        ],
        None,
      ),
      None,
    ),
  ))
  |> step(controller.ToolStarting(a))
  |> step(controller.ToolStarting(b))
  |> step(controller.Cancel)
}

fn settle(id: run.ActionId, content: String) -> controller.Event {
  controller.Settled(id, invocation.Returned(content))
}

fn states(state: State) -> List(run.ActionState) {
  controller.snapshot(state).actions |> list.map(fn(action) { action.state })
}

/// Before the executor confirmed the stop, the task may still run: its
/// settlement is early, and nothing changes.
pub fn a_settlement_before_the_tools_stopped_is_early_test() {
  controller.step(env(), cancelled(), settle(a, "x"))
  |> should.equal(Error(controller.SettlementEarly(a)))
}

/// After the stop, a settlement is accepted once: an uncertain one is
/// recorded, and a definite one offered afterwards is refused, even while
/// another tool keeps the run stopping.
pub fn a_settlement_is_accepted_once_test() {
  let state =
    cancelled()
    |> step(controller.ToolsStopped)
    |> step(controller.Settled(a, invocation.EffectUncertain("unknown")))
  states(state) |> should.equal([run.Uncertain("unknown"), run.Running])
  controller.step(env(), state, settle(a, "cloudy"))
  |> should.equal(Error(controller.SettlementNotAwaited(a)))
}

/// Past its bound, the action is an uncertain effect; a settlement that
/// arrives while another tool keeps the run stopping is refused.
pub fn a_settlement_after_the_bound_is_refused_test() {
  let state =
    cancelled()
    |> step(controller.ToolsStopped)
    |> step(controller.SettlementDue(a))
  controller.step(env(), state, settle(a, "late"))
  |> should.equal(Error(controller.SettlementNotAwaited(a)))
  let state = step(state, settle(b, "b"))
  controller.status(state) |> should.equal(run.Finished(run.Cancelled))
  states(state)
  |> should.equal([
    run.Uncertain(
      "stopped while running; no settlement arrived within the tool's bound",
    ),
    run.Succeeded("b"),
  ])
}

//// Delegations on the pure controller, event by event: the fence that
//// names a child before it exists, the children's ends in every phase,
//// and recovery of a run whose runner was starting a child.

import fabric/internal/controller.{
  type Effect, type State, CallModel, CancelChildren, ChildEnded, ChildFinished,
  ChildLost, ChildMissing, ChildStarted, StartChild, StopTools,
}
import fabric/internal/invocation
import fabric/internal/registry
import fabric/model.{ToolCall, ToolRequest}
import fabric/policy
import fabric/run.{ActionId}
import fabric/support
import fabric/support/scripted
import fabric/tool
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import json/blueprint/codec

fn ask() -> tool.Tool(Nil) {
  tool.delegation(
    tool.define("ask", "Ask a helper.", codec.string(), codec.string()),
    run.Identity("helper", 1),
    fn(question) { question },
    output: fn(text) {
      case text {
        "?" -> Error("no answer")
        _ -> Ok(text)
      }
    },
  )
}

fn env() -> controller.Env(Nil) {
  let assert Ok(tools) = registry.new([ask(), scripted_slow()])
  controller.Env(
    registry: tools,
    policy: policy.always_allow(),
    context: Nil,
    system: None,
  )
}

fn scripted_slow() -> tool.Tool(Nil) {
  tool.define("slow", "Slow.", codec.field("x", codec.string()), codec.string())
  |> tool.bind(fn(_, x) { Ok(x) }, fn(_: Nil) { tool.Explain("no") })
}

fn ask_call(id: String) -> model.ToolCall {
  ToolCall(id, "ask", "\"why?\"", None, None)
}

fn step(state: State, event: controller.Event) -> #(State, List(Effect)) {
  let assert Ok(next) = controller.step(env(), state, event)
  next
}

/// A run whose first reply asked for `calls`.
fn acting(
  calls: List(model.ToolCall),
  max_children: Int,
) -> #(State, List(Effect)) {
  let #(state, _) =
    controller.start(
      env(),
      "run-p",
      run.Identity("parent", 1),
      controller.Limits(
        max_turns: 4,
        token_budget: None,
        max_children:,
        max_depth: 1,
      ),
      "go",
      None,
      0,
    )
  step(
    state,
    controller.ModelReplied(
      1,
      ToolRequest(model.AssistantTurn("", calls, None), None),
    ),
  )
}

fn action(state: State, id: String) -> run.ActionRecord {
  let assert Ok(found) =
    controller.snapshot(state).actions
    |> list_find(fn(action) { action.id == ActionId(1, id) })
  found
}

fn list_find(items: List(a), matches: fn(a) -> Bool) -> Result(a, Nil) {
  case items {
    [] -> Error(Nil)
    [first, ..rest] ->
      case matches(first) {
        True -> Ok(first)
        False -> list_find(rest, matches)
      }
  }
}

pub fn an_allowed_delegation_names_its_child_before_the_child_exists_test() {
  let #(state, effects) = acting([ask_call("a"), ask_call("b")], 4)
  effects
  |> should.equal([
    StartChild(ActionId(1, "a"), "run-p-1", ask_call("a")),
    StartChild(ActionId(1, "b"), "run-p-2", ask_call("b")),
  ])
  action(state, "a")
  |> should.equal(run.ActionRecord(
    ActionId(1, "a"),
    ask_call("a"),
    run.Running,
    [],
    Some(support.id("run-p-1")),
  ))
  // Starting a child is work in flight; waiting on a started child is not.
  controller.needs_runner(state) |> should.be_true
  let assert #(state, []) = step(state, ChildStarted(ActionId(1, "a")))
  let assert #(state, []) = step(state, ChildStarted(ActionId(1, "b")))
  action(state, "a").state |> should.equal(run.Delegated)
  controller.needs_runner(state) |> should.be_false
  controller.step(env(), state, ChildStarted(ActionId(1, "a")))
  |> should.equal(Error(controller.ReportNotExpected(ActionId(1, "a"))))
}

pub fn a_child_end_is_mapped_by_the_delegation_test() {
  let #(state, _) = acting([ask_call("a")], 4)
  let #(state, _) = step(state, ChildStarted(ActionId(1, "a")))
  let #(state, effects) =
    step(
      state,
      ChildEnded(
        ActionId(1, "a"),
        ChildFinished(run.Completed("because"), False),
      ),
    )
  action(state, "a").state |> should.equal(run.Succeeded("\"because\""))
  action(state, "a").child |> should.equal(Some(support.id("run-p-1")))
  let assert [CallModel(2, _)] = effects
}

/// A completed answer the delegation cannot parse, and a child that ended
/// without an answer, are definite failures the model sees.
pub fn a_child_without_a_usable_answer_is_a_definite_failure_test() {
  let ended = fn(outcome) {
    let #(state, _) = acting([ask_call("a")], 4)
    let #(state, _) = step(state, ChildStarted(ActionId(1, "a")))
    let #(state, _) =
      step(state, ChildEnded(ActionId(1, "a"), ChildFinished(outcome, False)))
    action(state, "a").state
  }
  ended(run.Completed("?"))
  |> should.equal(run.ToolFailed("{\"error\":\"no answer\"}"))
  ended(run.Refused("nope"))
  |> should.equal(run.ToolFailed("{\"error\":\"the sub-agent refused: nope\"}"))
  ended(run.BudgetExhausted(run.TurnLimit(3)))
  |> should.equal(run.ToolFailed(
    "{\"error\":\"the sub-agent used its 3 model turns\"}",
  ))
  ended(run.Cancelled)
  |> should.equal(run.ToolFailed("{\"error\":\"the sub-agent was cancelled\"}"))
}

pub fn a_child_with_unknown_effects_makes_the_delegation_uncertain_test() {
  let #(state, _) = acting([ask_call("a")], 4)
  let #(state, _) =
    step(
      state,
      ChildEnded(ActionId(1, "a"), ChildFinished(run.Cancelled, True)),
    )
  let assert run.Uncertain(_) = action(state, "a").state
  let #(state, _) = acting([ask_call("a")], 4)
  let #(state, _) =
    step(state, ChildEnded(ActionId(1, "a"), ChildLost("corrupt")))
  let assert run.Uncertain(_) = action(state, "a").state
  // A missing child in a live batch is out of date: recovery starts it.
  let #(state, _) = acting([ask_call("a")], 4)
  controller.step(env(), state, ChildEnded(ActionId(1, "a"), ChildMissing))
  |> should.equal(Error(controller.ReportNotExpected(ActionId(1, "a"))))
}

/// Cancelling stops tools and cancels children; the run ends only when
/// both are done. A child that completed while the parent was stopping is
/// recorded as it completed, and the run still ends cancelled; an end
/// arriving after that is refused.
pub fn a_stopping_run_waits_for_its_children_and_ends_cancelled_test() {
  let calls = [ask_call("a"), ask_call("b"), scripted.slow("s", "s")]
  let #(state, _) = acting(calls, 4)
  let #(state, _) = step(state, controller.ToolStarting(ActionId(1, "s")))
  let #(state, _) = step(state, ChildStarted(ActionId(1, "a")))
  let #(state, effects) = step(state, controller.Cancel)
  effects
  |> should.equal([
    StopTools,
    CancelChildren([
      #(ActionId(1, "a"), "run-p-1"),
      #(ActionId(1, "b"), "run-p-2"),
    ]),
  ])
  let assert #(state, []) = step(state, controller.ToolsStopped)
  controller.status(state) |> should.equal(run.Working)
  let assert #(state, []) =
    step(
      state,
      ChildEnded(ActionId(1, "a"), ChildFinished(run.Completed("done"), False)),
    )
  let assert #(state, []) =
    step(state, ChildEnded(ActionId(1, "b"), ChildMissing))
  controller.status(state) |> should.equal(run.Finished(run.Cancelled))
  action(state, "a").state |> should.equal(run.Succeeded("\"done\""))
  action(state, "b").state |> should.equal(run.NotStarted)
  action(state, "s").state
  |> should.equal(run.Uncertain("stopped while running"))
  controller.step(
    env(),
    state,
    ChildEnded(ActionId(1, "a"), ChildFinished(run.Completed("again"), False)),
  )
  |> should.equal(Error(controller.RunEnded))
}

/// A runner lost while starting a child: the child is durable, so the
/// delegation waits on it (recovery starts or reattaches it) instead of
/// becoming uncertain. A stop that still waits on children asks to cancel
/// them again.
pub fn recovery_keeps_delegations_waiting_on_their_children_test() {
  let #(state, _) = acting([ask_call("a")], 4)
  let #(recovered, effects) = controller.recover(env(), state)
  action(recovered, "a").state |> should.equal(run.Delegated)
  effects |> should.equal([])

  let #(stopping, _) = step(state, controller.Cancel)
  let #(recovered, effects) = controller.recover(env(), stopping)
  controller.status(recovered) |> should.equal(run.Working)
  effects |> should.equal([CancelChildren([#(ActionId(1, "a"), "run-p-1")])])
}

/// Cancelling a run that is already stopping asks again to cancel the
/// children it still waits on, in case an earlier request was lost.
pub fn cancelling_a_stopping_run_cancels_its_children_again_test() {
  let #(state, _) = acting([ask_call("a"), ask_call("b")], 4)
  let #(state, _) = step(state, ChildStarted(ActionId(1, "a")))
  let #(state, _) = step(state, ChildStarted(ActionId(1, "b")))
  let #(stopping, _) = step(state, controller.Cancel)
  let assert #(stopping, []) =
    step(stopping, ChildEnded(ActionId(1, "b"), ChildMissing))
  let #(again, effects) = step(stopping, controller.Cancel)
  again |> should.equal(stopping)
  effects |> should.equal([CancelChildren([#(ActionId(1, "a"), "run-p-1")])])
}

/// The tools offered to the model with `limits` at `depth`.
fn offered(max_children: Int, max_depth: Int, depth: Int) -> List(String) {
  let assert #(_, [CallModel(_, request)]) =
    controller.start(
      env(),
      "run-p",
      run.Identity("parent", 1),
      controller.Limits(
        max_turns: 4,
        token_budget: None,
        max_children:,
        max_depth:,
      ),
      "go",
      None,
      depth,
    )
  list.map(request.tools, fn(spec) { spec.name })
}

/// A run that may start no sub-agent (no children allowed, as for a record
/// written before sub-agents, or no depth left) is not offered delegations
/// that would always be refused.
pub fn delegations_are_offered_only_when_a_child_may_start_test() {
  offered(4, 1, 0) |> should.equal(["ask", "slow"])
  offered(0, 1, 0) |> should.equal(["slow"])
  offered(4, 1, 1) |> should.equal(["slow"])
}

pub fn the_child_limit_counts_started_and_awaiting_children_test() {
  let #(state, effects) = acting([ask_call("a"), ask_call("b")], 1)
  action(state, "b").state
  |> should.equal(run.LimitReached(run.ChildLimit(1)))
  let assert [StartChild(..)] = effects
  controller.model_content(run.LimitReached(run.ChildLimit(1)))
  |> should.equal(
    Ok(invocation.error_detail_content(
      "limit_reached",
      "at most 1 sub-agent runs per run",
    )),
  )
}

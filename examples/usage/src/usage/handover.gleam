//// A call another system decides. The policy hands `refund_fee` over
//// (`policy.HandOver`): the run ends `run.HandedOver` at once, with no
//// further model turn and no approval that could expire, and the tool
//// never runs. The application files the call where it is decided, keyed
//// by the action's text form (`run.action_ref_to_string`), and once the
//// decision is recorded continues the conversation in a follow-on run:
//// its original input is the handed-over run's history with the decision
//// as the call's result (`input.continuation`), so the model continues
//// from that result with no invented prompt.
////
//// The follow-on run has the same agent and the same policy. Its context
//// says it is the follow-on (`Telling`), and the policy denies a second
//// refund there instead of handing it over again.

import fabric
import fabric/agent
import fabric/input
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/tool
import gleam/erlang/process
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/time/duration
import json/blueprint/codec
import usage/support

/// What the example shows: the call that was handed over, its action key,
/// how the handed-over run stays, and what the follow-on run answered.
pub type Shown {
  Shown(
    tool: String,
    arguments_json: String,
    key: String,
    first_run: run.Status(String),
    follow_on: run.Status(String),
  )
}

fn refund_definition() -> tool.Definition(Float, String) {
  tool.define(
    "refund_fee",
    "Refunds a fee, or part of one, to the customer.",
    support.one_field("amount", codec.float()),
    codec.string(),
  )
}

/// The agent's model: it asks for the refund, then answers from the
/// result it is given.
fn desk_model() -> model.Model {
  support.calling_once("refund_fee", "{\"amount\":80.0}", fn(results) {
    "Ana, " <> string.join(results, "; ")
  })
}

fn refund_tool() -> tool.Tool(Stage) {
  tool.bind(
    refund_definition(),
    fn(_context, _call, _amount: Float) -> Result(String, Nil) {
      panic as "a handed-over refund never runs here"
    },
    fn(_) { tool.Explain("refund failed") },
  )
}

pub fn shown() -> Shown {
  let assert Ok(desk) =
    agent.build(fn() {
      agent.new("desk", desk_model(), [refund_tool()], refund_policy)
    })
  let runs = store.in_memory(process.new_name("usage-handover"))
  let assert Ok(Nil) = store.start(runs)
  let first = run.new_id()
  let assert Ok(#(key, arguments_json)) = file_refund(runs, desk, first)

  // The decision arrives later, filed under `key`; the handed-over run
  // itself stays ended.
  let assert Ok(action) = run.parse_action_ref(key)
  let assert Ok(decided) =
    tool.reconciliation(refund_definition(), Ok("refunded 60.00"))
  let assert Ok(next) = tell(runs, desk, action.run, decided)
  let assert Ok(follow_on) = fabric.await(next, within: duration.seconds(5))
  let assert Ok(handle) = fabric.open(runs, desk, Deciding, first)
  let assert Ok(first_run) = fabric.await(handle, within: duration.seconds(0))
  let assert Ok(Nil) = store.stop(runs)
  Shown(tool: "refund_fee", arguments_json:, key:, first_run:, follow_on:)
}

// snips-start: handover
/// Which run the policy decides for: the one that proposes, or the
/// follow-on that tells the customer what was decided.
pub type Stage {
  Deciding
  Telling
}

/// Refunds are decided by finance, never by the agent's run. The follow-on
/// run has the same agent and policy: there a repeated refund call is
/// denied, or it would be handed over again.
fn refund_policy(stage: Stage, action: policy.Action) {
  case action.name, stage {
    "refund_fee", Deciding ->
      Ok(policy.HandOver("refunds are decided by finance"))
    "refund_fee", Telling -> Ok(policy.Deny("the refund is already decided"))
    _, _ -> Ok(policy.Allow)
  }
}

/// Runs the agent until it rests. A handover gives the application the
/// call to file, keyed by its action's text form.
fn file_refund(
  runs: store.Store,
  desk: agent.Agent(Stage, String),
  id: run.RunId,
) -> Result(#(String, String), String) {
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk,
      id:,
      context: Deciding,
      prompt: "Refund Ana's fee.",
      correlation: None,
    )
  case fabric.await(handle, within: duration.seconds(5)) {
    Ok(run.Finished(run.HandedOver(action:, arguments_json:, ..))) ->
      Ok(#(run.action_ref_to_string(action), arguments_json))
    other -> Error(string.inspect(other))
  }
}

/// Once the decision is recorded: a follow-on run continues the handed-over
/// conversation from the decision, given as the call's result.
fn tell(
  runs: store.Store,
  desk: agent.Agent(Stage, String),
  handed: run.RunId,
  decided: String,
) -> Result(fabric.Run(Stage, String), String) {
  use first <- result.try(
    fabric.open(runs, desk, Deciding, handed)
    |> result.map_error(string.inspect),
  )
  use snapshot <- result.try(
    fabric.snapshot(first) |> result.map_error(string.inspect),
  )
  use history <- result.try(
    fabric.handover_history(snapshot, result: decided)
    |> result.map_error(string.inspect),
  )
  use follow <- result.try(
    input.continuation(history) |> result.map_error(string.inspect),
  )
  fabric.start_with_input(
    runs,
    desk,
    id: run.new_id(),
    context: Telling,
    input: follow,
    correlation: None,
  )
  |> result.map_error(string.inspect)
}
// snips-end: handover

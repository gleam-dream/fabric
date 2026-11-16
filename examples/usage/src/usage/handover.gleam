//// A call another system decides. The policy hands `refund_fee` over
//// (`policy.HandOver`): the run ends `run.HandedOver` at once, with no
//// further model turn and no approval that could expire, and the tool
//// never runs. The application files the call where it is decided, keyed
//// by its run and action, and once the decision is recorded continues the
//// conversation in a follow-on run whose model reads the decision as the
//// call's result.

import fabric
import fabric/agent
import fabric/input
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/tool
import gleam/erlang/process
import gleam/int
import gleam/option.{None}
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

fn refund_tool() -> tool.Tool(Nil) {
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
    agent.new("desk", desk_model(), [refund_tool()], refund_policy)
    |> agent.build
  let runs = store.in_memory(process.new_name("usage-handover"))
  let assert Ok(Nil) = store.start(runs)
  let first = run.new_id()
  let assert Ok(#(action, arguments_json)) = file_refund(runs, desk, first)

  // The decision arrives later; the handed-over run itself stays ended.
  let assert Ok(handle) = fabric.open(runs, desk, Nil, first)
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert Ok(decided) =
    tool.reconciliation(refund_definition(), Ok("refunded 60.00"))
  let assert Ok(history) = fabric.handover_history(snapshot, result: decided)
  let assert Ok(follow) = input.new(history, "Finance decided. Tell Ana.")
  let assert Ok(next) =
    fabric.start_with_input(
      runs,
      desk,
      id: run.new_id(),
      context: Nil,
      input: follow,
      correlation: None,
    )
  let assert Ok(follow_on) = fabric.await(next, within: duration.seconds(5))
  let assert Ok(first_run) = fabric.await(handle, within: duration.seconds(0))
  let assert Ok(Nil) = store.stop(runs)
  Shown(
    tool: "refund_fee",
    arguments_json:,
    key: run.id_to_string(action.run)
      <> "/"
      <> int.to_string(action.id.turn)
      <> "."
      <> action.id.call_id,
    first_run:,
    follow_on:,
  )
}

// snips-start: handover
/// Refunds are decided by finance, never by the agent's run.
fn refund_policy(_context: Nil, action: policy.Action) {
  case action.name {
    "refund_fee" -> Ok(policy.HandOver("refunds are decided by finance"))
    _ -> Ok(policy.Allow)
  }
}

/// Runs the agent until it rests. A handover gives the application the
/// call to file, keyed by its run and action.
fn file_refund(
  runs: store.Store,
  desk: agent.Agent(Nil, String),
  id: run.RunId,
) -> Result(#(run.ActionRef, String), String) {
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk,
      id:,
      context: Nil,
      prompt: "Refund Ana's fee.",
      correlation: None,
    )
  case fabric.await(handle, within: duration.seconds(5)) {
    Ok(run.Finished(run.HandedOver(action:, arguments_json:, ..))) ->
      Ok(#(action, arguments_json))
    other -> Error(string.inspect(other))
  }
}
// snips-end: handover

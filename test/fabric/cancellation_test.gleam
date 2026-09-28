//// Cancellation does not depend on the run's runner cooperating: a runner
//// held by a synchronous observation handler has its cancellation
//// committed to its record, and once released it can commit nothing more,
//// so no tool body starts and no model turn is recorded after the
//// cancellation. Tests wait on barriers and on processes exiting, never
//// on sleeps.

import fabric
import fabric/agent.{type Agent}
import fabric/model
import fabric/observation as o
import fabric/policy
import fabric/run
import fabric/store
import fabric/support/apps
import fabric/support/probe.{type Probe}
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import sinal

// --- the application -----------------------------------------------------------

pub type Topic {
  Topic(topic: String)
}

pub type Summary {
  Summary(summary: String)
}

fn research() -> tool.Definition(Topic, Summary) {
  tool.define(
    "research",
    "Delegate research.",
    codec.field("topic", codec.string())
      |> codec.imap(Topic, fn(topic) { topic.topic }),
    codec.field("summary", codec.string())
      |> codec.imap(Summary, fn(summary) { summary.summary }),
  )
}

fn paying_tool(probe: Probe) -> tool.Tool(ctx) {
  tool.bind(
    apps.transfer_definition(),
    fn(_, transfer: apps.Transfer) -> Result(apps.Receipt, Nil) {
      probe.record(probe, "pay:" <> transfer.to)
      Ok(apps.Receipt("r-" <> transfer.to))
    },
    fn(_) { tool.Explain("failed") },
  )
}

/// Pays `one`, then `two`, then answers.
fn two_payments(probe: Probe, policy: policy.Policy(ctx)) -> Agent(ctx) {
  agent.new(
    scripted.model(fn(messages) {
      case scripted.results(messages) {
        [] -> model.ToolRequest("", [payment("t1", "one")], None)
        [_] -> model.ToolRequest("", [payment("t2", "two")], None)
        _ -> model.FinalAnswer("paid", None)
      }
    }),
    [paying_tool(probe)],
    policy,
  )
  |> agent.with_identity("payer", 1)
}

fn payment(id: String, to: String) -> model.ToolCall {
  scripted.call(id, "transfer_funds", "{\"to\":\"" <> to <> "\",\"amount\":1}")
}

fn delegating(child: Agent(ctx)) -> Agent(ctx) {
  agent.new(
    scripted.model(fn(messages) {
      case scripted.results(messages) {
        [] ->
          model.ToolRequest(
            "",
            [scripted.call("r", "research", "{\"topic\":\"x\"}")],
            None,
          )
        _ -> model.FinalAnswer("done", None)
      }
    }),
    [],
    policy.always_allow(),
  )
  |> agent.with_sub_agent(
    research(),
    to: child,
    prompt: fn(topic: Topic) { topic.topic },
    result: fn(outcome) {
      case outcome {
        run.Completed(text) -> Ok(Summary(text))
        _ -> Error(tool.Explain("no"))
      }
    },
  )
}

// --- a held runner -------------------------------------------------------------

/// A runner held by a handler of `t1`'s dispatch: its pid, and the subject
/// that releases it.
type Held {
  Held(runner: Pid, run: String, release: Subject(Nil))
}

/// Holds the runner of the first run that `matches` when it commits the
/// start of `t1`, until the test releases it.
fn hold_runner(
  matches: fn(String) -> Bool,
) -> #(Subject(Held), sinal.Attachment) {
  let held = process.new_subject()
  let assert Ok(id) =
    sinal.handler_id("held-runner-" <> int.to_string(int.random(1_000_000_000)))
  let assert Ok(attached) =
    sinal.observe(id, o.tool_dispatched(), fn(_, dispatched: o.ToolDispatched) {
      case matches(dispatched.action.run), dispatched.action.call_id {
        True, "t1" -> {
          let release = process.new_subject()
          process.send(
            held,
            Held(process.self(), dispatched.action.run, release),
          )
          let assert Ok(Nil) = process.receive(release, 10_000)
          Nil
        }
        _, _ -> Nil
      }
    })
  #(held, attached)
}

/// Releases the held runner and waits until it has exited: everything it
/// could still do is done.
fn release_and_wait(held: Held) -> Nil {
  let monitor = process.monitor(held.runner)
  process.send(held.release, Nil)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(5000)
  Nil
}

fn states(run: fabric.Run(ctx)) -> List(run.ActionState) {
  let assert Ok(snapshot) = fabric.snapshot(run)
  list.map(snapshot.actions, fn(action) { action.state })
}

/// A child whose runner a handler holds longer than the command timeout:
/// the parent's cancellation is committed to the child's record, both end
/// cancelled, and the released runner neither records the payment it had
/// started nor starts the second one.
pub fn a_held_child_is_cancelled_through_its_record_test() {
  let probe = probe.new()
  let #(holds, attached) = hold_runner(string.ends_with(_, "-1"))
  let child =
    two_payments(probe, policy.always_allow())
    |> agent.with_command_timeout(20)
  let assert Ok(run) =
    fabric.start(store.in_memory(), delegating(child), Nil, "go")
  let assert Ok(held) = process.receive(holds, 5000)
  let _ = sinal.detach(attached)

  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert Ok(child_run) = fabric.child(run, held.run)
  fabric.status(child_run) |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert [run.Uncertain(_)] = states(run)
  let assert Ok(before) = fabric.snapshot(child_run)
  let assert [run.Uncertain(_)] = states(child_run)

  release_and_wait(held)
  fabric.snapshot(child_run) |> should.equal(Ok(before))
  // The first payment's body started when its start was stored, before
  // the cancellation; the second never starts.
  probe.count(probe, "pay:two") |> should.equal(0)
}

/// `cancel` and `cancel_stored` of a run whose runner a handler holds do
/// not wait for it: each commits the cancellation to the record, and the
/// released runner commits nothing more.
pub fn a_held_run_is_cancelled_through_its_record_test() {
  let cancel_with = fn(
    cancel: fn(fabric.Run(Nil), store.Store) ->
      Result(run.Status, fabric.CommandError),
  ) {
    let probe = probe.new()
    let store = store.in_memory()
    let #(holds, attached) = hold_runner(fn(_) { True })
    let agent =
      two_payments(probe, policy.always_allow())
      |> agent.with_command_timeout(20)
    let assert Ok(run) = fabric.start(store, agent, Nil, "go")
    let assert Ok(held) = process.receive(holds, 5000)
    let _ = sinal.detach(attached)

    cancel(run, store) |> should.equal(Ok(run.Finished(run.Cancelled)))
    let assert Ok(before) = fabric.snapshot(run)
    release_and_wait(held)
    fabric.snapshot(run) |> should.equal(Ok(before))
    probe.count(probe, "pay:two") |> should.equal(0)
  }
  cancel_with(fn(run, _) { fabric.cancel(run) })
  cancel_with(fn(run, store) { fabric.cancel_stored(store, fabric.id(run)) })
}

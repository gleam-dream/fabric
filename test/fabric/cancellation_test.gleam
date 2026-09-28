//// Cancellation does not depend on the run's runner cooperating: a runner
//// held by a synchronous observation handler has its cancellation
//// committed to its record, and once released it can commit nothing more,
//// so no tool body starts and no model turn is recorded after the
//// cancellation. Tests wait on barriers and on processes exiting, never
//// on sleeps.

import fabric
import fabric/agent.{type Agent}
import fabric/internal/controller
import fabric/internal/record
import fabric/model
import fabric/observation as o
import fabric/policy.{ActionId}
import fabric/run
import fabric/store
import fabric/support/apps
import fabric/support/probe.{type Probe}
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
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

// --- nothing starts under a stopped ancestor --------------------------------------

fn limits(children: Int, depth: Int) -> controller.Limits {
  controller.Limits(
    max_turns: 8,
    token_budget: None,
    max_children: children,
    max_depth: depth,
  )
}

/// Stores a root run `id` that is stopping, waiting for its delegation
/// `r`'s child `id-1`.
fn store_stopping_root(store: store.Store, id: String) -> Nil {
  let call = scripted.call("r", "research", "{\"topic\":\"x\"}")
  let root =
    controller.State(
      run: id,
      agent: run.Identity("agent", 1),
      incarnation: 1,
      parent: None,
      depth: 0,
      limits: limits(4, 2),
      turns_used: 1,
      usage: run.TokenUsage(0, 0, 0),
      transcript: [model.UserMessage("go"), model.AssistantMessage("", [call])],
      history: [],
      approvals_issued: 0,
      phase: controller.Stopping(
        1,
        [
          run.ActionRecord(
            ActionId(1, "r"),
            call,
            run.Delegated,
            [],
            Some(id <> "-1"),
          ),
        ],
        controller.CancelRequested,
        True,
      ),
    )
  let assert Ok(1) = store.insert(store, id, record.encode(root), store.Keep)
  Nil
}

/// Stores the child `id-1` of the stopping root `id`, in `phase`, as a run
/// whose runner was lost.
fn store_orphaned_child(
  store: store.Store,
  id: String,
  agent: run.Identity,
  transcript: List(model.Message),
  phase: controller.Phase,
) -> String {
  let child = id <> "-1"
  let state =
    controller.State(
      run: child,
      agent:,
      incarnation: 1,
      parent: Some(run.Parent(id, ActionId(1, "r"))),
      depth: 1,
      limits: limits(1, 2),
      turns_used: 1,
      usage: run.TokenUsage(0, 0, 0),
      transcript:,
      history: [],
      approvals_issued: 0,
      phase:,
    )
  let assert Ok(1) =
    store.insert(store, child, record.encode(state), store.Keep)
  child
}

/// A child whose root is stopping is recovered with a queued payment: at
/// its fence it finds the root stopping, starts nothing, and cancels
/// itself.
pub fn a_tool_under_a_stopping_ancestor_never_starts_test() {
  let probe = probe.new()
  let store = store.in_memory()
  store_stopping_root(store, "run-ancestor")
  let t1 = payment("t1", "one")
  let child =
    store_orphaned_child(
      store,
      "run-ancestor",
      run.Identity("payer", 1),
      [model.UserMessage("x"), model.AssistantMessage("", [t1])],
      controller.Acting(1, [
        run.ActionRecord(ActionId(1, "t1"), t1, run.Queued, [], None),
      ]),
    )

  let assert Ok(recovered) =
    fabric.recover(
      store,
      two_payments(probe, policy.always_allow()),
      Nil,
      child,
    )
  fabric.await(recovered, 5000)
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  states(recovered) |> should.equal([run.NotStarted])
  probe.entries(probe) |> should.equal([])
}

/// A child whose root is stopping asks to start a sub-agent of its own:
/// the start finds the root stopping, stores no grandchild, and the child
/// cancels itself.
pub fn a_sub_agent_under_a_stopping_ancestor_never_starts_test() {
  let probe = probe.new()
  let store = store.in_memory()
  store_stopping_root(store, "run-elder")
  let child =
    store_orphaned_child(
      store,
      "run-elder",
      run.Identity("agent", 1),
      [model.UserMessage("x")],
      controller.AwaitingModel(1),
    )
  let delegating = delegating(two_payments(probe, policy.always_allow()))

  let assert Ok(recovered) = fabric.recover(store, delegating, Nil, child)
  fabric.await(recovered, 5000)
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  states(recovered) |> should.equal([run.NotStarted])
  probe.entries(probe) |> should.equal([])
  // The grandchild is a tombstone: cancelled before it ever started.
  let assert Ok(store.Entry(record: stored, ..)) =
    store.get(store, child <> "-1")
  let assert Ok(controller.State(phase: controller.NeverStarted, ..)) =
    record.decode(stored)
}

/// An answer to a child races its parent's cancellation: the answer's
/// policy recheck runs while the parent is cancelled. The answer may still
/// commit, but the payment it approved never starts.
pub fn an_answer_racing_the_parent_cancellation_starts_nothing_test() {
  list.repeat(Nil, 10)
  |> list.each(fn(_) {
    let probe = probe.new()
    let rechecks = process.new_subject()
    let child_policy = fn(context: String, _) {
      case context {
        "recheck" -> {
          let release = process.new_subject()
          process.send(rechecks, release)
          let _ = process.receive(release, 3000)
          Ok(policy.Allow)
        }
        _ -> Ok(policy.RequireApproval(policy.Requirement("t", 1)))
      }
    }
    let assert Ok(run) =
      fabric.start(
        store.in_memory(),
        delegating(two_payments(probe, child_policy)),
        "run",
        "go",
      )
    let assert Ok(run.Suspended([pending], _)) = fabric.await(run, 5000)
    let answered = process.new_subject()
    process.spawn(fn() {
      process.send(
        answered,
        fabric.answer(
          run,
          pending.reference,
          run.Approve,
          reviewer: None,
          context: "recheck",
        ),
      )
    })
    let assert Ok(release) = process.receive(rechecks, 5000)
    let assert Ok(_) = fabric.cancel(run)
    process.send(release, Nil)
    let assert Ok(_) = process.receive(answered, 5000)
    fabric.await(run, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
    let assert Ok(child) = fabric.child(run, pending.reference.run)
    fabric.await(child, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
    probe.entries(probe) |> should.equal([])
  })
}

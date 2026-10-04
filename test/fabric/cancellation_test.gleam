//// Cancellation does not depend on the run's runner cooperating: a runner
//// held by a synchronous observation handler has its cancellation
//// committed to its record and is killed with its work, so no tool body
//// runs on, no model is called, and nothing is recorded after the
//// cancellation. Tests wait on barriers and on processes exiting, never
//// on sleeps.

import fabric
import fabric/agent.{type Agent}
import fabric/internal/controller
import fabric/internal/record
import fabric/internal/store as store_core
import fabric/model
import fabric/policy
import fabric/run.{type RunId, ActionId}
import fabric/store
import fabric/store/backend
import fabric/support
import fabric/support/apps
import fabric/support/flaky
import fabric/support/probe.{type Probe}
import fabric/support/scripted
import fabric/telemetry as o
import fabric/tool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import sinal
import sinal/correlation

// --- the application -----------------------------------------------------------

pub type Topic {
  Topic(topic: String)
}

pub type Summary {
  Summary(summary: String)
}

/// The summary is the researcher's plain answer.
fn research() -> tool.Definition(Topic, String) {
  tool.define(
    "research",
    "Delegate research.",
    {
      use topic <- codec.field("topic", codec.string(), get: fn(topic) {
        topic.topic
      })
      codec.success(Topic(topic))
    },
    {
      use summary <- codec.field("summary", codec.string(), get: fn(summary) {
        summary
      })
      codec.success(summary)
    },
  )
}

fn paying_tool(probe: Probe) -> tool.Tool(ctx) {
  tool.bind(
    apps.transfer_definition(),
    fn(_, _call, transfer: apps.Transfer) -> Result(apps.Receipt, Nil) {
      probe.record(probe, "pay:" <> transfer.to)
      Ok(apps.Receipt("r-" <> transfer.to))
    },
    fn(_) { tool.Explain("failed") },
  )
}

/// Pays `one`, then `two`, then answers.
fn two_payments_spec(
  probe: Probe,
  policy: policy.Policy(ctx),
) -> agent.Spec(ctx, String) {
  agent.new(
    "payer",
    scripted.model(fn(messages) {
      case scripted.results(messages) {
        [] ->
          model.ToolRequest(
            model.AssistantTurn("", [payment("t1", "one")], None),
            None,
          )
        [_] ->
          model.ToolRequest(
            model.AssistantTurn("", [payment("t2", "two")], None),
            None,
          )
        _ -> model.FinalAnswer("paid", None)
      }
    }),
    [paying_tool(probe)],
    policy,
  )
}

fn two_payments(
  probe: Probe,
  policy: policy.Policy(ctx),
) -> Agent(ctx, String) {
  support.agent(two_payments_spec(probe, policy))
}

fn payment(id: String, to: String) -> model.ToolCall {
  scripted.call(id, "transfer_funds", "{\"to\":\"" <> to <> "\",\"amount\":1}")
}

fn delegating(child: Agent(ctx, String)) -> Agent(ctx, String) {
  agent.new(
    "agent",
    scripted.model(fn(messages) {
      case scripted.results(messages) {
        [] ->
          model.ToolRequest(
            model.AssistantTurn(
              "",
              [scripted.call("r", "research", "{\"topic\":\"x\"}")],
              None,
            ),
            None,
          )
        _ -> model.FinalAnswer("done", None)
      }
    }),
    [],
    policy.always_allow(),
  )
  |> agent.with_sub_agent(research(), to: child, prompt: fn(topic: Topic) {
    topic.topic
  })
  |> support.agent
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
  let attached =
    sinal.observe(o.tool_dispatched(), fn(_, dispatched: o.ToolDispatched) {
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
    |> process.selector_receive(30_000)
  Nil
}

fn states(run: fabric.Run(ctx, String)) -> List(run.ActionState) {
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
    two_payments_spec(probe, policy.always_allow())
    |> agent.with_command_timeout(duration.milliseconds(20))
    |> support.agent
  let assert Ok(run) =
    fabric.start(
      support.store(),
      delegating(child),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(held) = process.receive(holds, 30_000)
  let _ = sinal.detach(attached)

  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert Ok(child_run) = fabric.child(run, support.id(held.run))
  fabric.await(child_run, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
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
    cancel: fn(fabric.Run(Nil, String), store.Store) ->
      Result(run.Status(String), fabric.Error),
  ) {
    let probe = probe.new()
    let store = support.store()
    let #(holds, attached) = hold_runner(fn(_) { True })
    let agent =
      two_payments_spec(probe, policy.always_allow())
      |> agent.with_command_timeout(duration.milliseconds(20))
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
    let assert Ok(held) = process.receive(holds, 30_000)
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

/// A runner held by a handler of the commit that settles `t1` (and asks
/// for the next model turn), until the test releases it.
fn hold_on_settled() -> #(Subject(Held), sinal.Attachment) {
  let held = process.new_subject()
  let attached =
    sinal.observe(o.tool_settled(), fn(_, settled: o.ToolSettled) {
      case settled.action.call_id {
        "t1" -> {
          let release = process.new_subject()
          process.send(held, Held(process.self(), settled.action.run, release))
          let assert Ok(Nil) = process.receive(release, 10_000)
          Nil
        }
        _ -> Nil
      }
    })
  #(held, attached)
}

/// Pays `one` (and, when `slow`, runs the gated `slow` tool beside it),
/// then answers; every model call is recorded as `model`.
fn counted_payer(probe: Probe, slow: Bool) -> Agent(Nil, String) {
  let first = case slow {
    True -> [payment("t1", "one"), scripted.slow("s", "x")]
    False -> [payment("t1", "one")]
  }
  agent.new(
    "payer",
    model.new(fn(request: model.Request) {
      probe.record(probe, "model")
      Ok(case scripted.results(request.messages) {
        [] -> model.ToolRequest(model.AssistantTurn("", first, None), None)
        _ -> model.FinalAnswer("paid", None)
      })
    }),
    [paying_tool(probe), scripted.gated_tool(probe)],
    policy.always_allow(),
  )
  |> agent.with_command_timeout(duration.milliseconds(20))
  |> support.agent
}

/// The held runner had committed the settlement of `t1`, which asks for
/// the next model turn, when the cancellation was committed to its record:
/// the runner is stopped, so the model is never called again.
pub fn a_held_runner_calls_no_model_after_its_cancellation_test() {
  let probe = probe.new()
  let #(holds, attached) = hold_on_settled()
  let assert Ok(run) =
    fabric.start(
      support.store(),
      counted_payer(probe, False),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(held) = process.receive(holds, 30_000)
  let _ = sinal.detach(attached)
  probe.count(probe, "model") |> should.equal(1)

  fabric.cancel(run) |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert Ok(before) = fabric.snapshot(run)
  release_and_wait(held)
  fabric.snapshot(run) |> should.equal(Ok(before))
  probe.count(probe, "model") |> should.equal(1)
}

/// A tool body still running when its held runner's cancellation is
/// committed to the record dies with the runner: nothing of the abandoned
/// work outlives it.
pub fn a_held_runners_running_body_dies_with_it_test() {
  let probe = probe.new()
  let #(holds, attached) = hold_on_settled()
  let assert Ok(run) =
    fabric.start(
      support.store(),
      counted_payer(probe, True),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let arrival = probe.arrival(probe)
  let assert Ok(held) = process.receive(holds, 30_000)
  let _ = sinal.detach(attached)
  let assert Ok(body) = process.subject_owner(arrival.release)
  let body_exit = process.monitor(body)

  fabric.cancel(run) |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(body_exit, fn(down) { down })
    |> process.selector_receive(30_000)
  release_and_wait(held)
  probe.count(probe, "end:x") |> should.equal(0)
  probe.count(probe, "model") |> should.equal(1)
}

/// A handler cancels its own run from inside the runner, on the commit
/// that asks for the next model turn: the runner cannot be stopped from
/// its own process, and it calls no model once its record moved on.
pub fn a_runner_whose_handler_cancelled_its_run_calls_no_model_test() {
  let probe = probe.new()
  let memory = support.store()
  let runners = process.new_subject()
  let attached =
    sinal.observe(o.tool_settled(), fn(_, settled: o.ToolSettled) {
      let cancelled =
        fabric.cancel_stored(memory, support.id(settled.action.run))
      process.send(runners, #(process.self(), cancelled))
    })
  let assert Ok(run) =
    fabric.start(
      memory,
      counted_payer(probe, False),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(#(runner, cancelled)) = process.receive(runners, 30_000)
  let runner_exit = process.monitor(runner)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(runner_exit, fn(down) { down })
    |> process.selector_receive(30_000)
  let _ = sinal.detach(attached)

  cancelled |> should.equal(Ok(run.Finished(run.Cancelled)))
  fabric.await(run, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  probe.count(probe, "model") |> should.equal(1)
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
      agent: run.DefinitionId("agent", 1),
      incarnation: 1,
      parent: None,
      depth: 0,
      limits: limits(4, 2),
      turns_used: 1,
      usage: run.TokenUsage(0, 0, 0),
      transcript: [
        model.UserMessage("go"),
        model.AssistantMessage(model.AssistantTurn("", [call], None)),
      ],
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
            Some(support.id(id <> "-1")),
            0,
          ),
        ],
        controller.CancelRequested,
        True,
      ),
      family_budget: None,
      correlation: correlation.from_key(id),
      root: id,
      root_exact: True,
    )
  let assert Ok(1) =
    store_core.insert(store, id, record.encode(root), store_core.Keep)
  Nil
}

/// Stores the child `id-1` of the stopping root `id`, in `phase`, as a run
/// whose runner was lost.
fn store_orphaned_child(
  store: store.Store,
  id: String,
  agent: run.DefinitionId,
  transcript: List(model.Message),
  phase: controller.Phase,
) -> RunId {
  let child = id <> "-1"
  let state =
    controller.State(
      run: child,
      agent:,
      incarnation: 1,
      parent: Some(run.AgentParent(support.id(id), ActionId(1, "r"))),
      depth: 1,
      limits: limits(1, 2),
      turns_used: 1,
      usage: run.TokenUsage(0, 0, 0),
      transcript:,
      history: [],
      approvals_issued: 0,
      phase:,
      family_budget: None,
      correlation: correlation.from_key(child),
      root: id,
      root_exact: True,
    )
  let assert Ok(1) =
    store_core.insert(store, child, record.encode(state), store_core.Keep)
  support.id(child)
}

/// A child whose root is stopping is recovered with a queued payment: at
/// its fence it finds the root stopping, starts nothing, and cancels
/// itself.
pub fn a_tool_under_a_stopping_ancestor_never_starts_test() {
  let probe = probe.new()
  let store = support.store()
  store_stopping_root(store, "run-ancestor")
  let t1 = payment("t1", "one")
  let child =
    store_orphaned_child(
      store,
      "run-ancestor",
      run.DefinitionId("payer", 1),
      [
        model.UserMessage("x"),
        model.AssistantMessage(model.AssistantTurn("", [t1], None)),
      ],
      controller.Acting(1, [
        run.ActionRecord(ActionId(1, "t1"), t1, run.Queued, [], None, 0),
      ]),
    )

  let assert Ok(recovered) =
    fabric.recover(
      store,
      two_payments(probe, policy.always_allow()),
      Nil,
      child,
    )
  fabric.await(recovered, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  states(recovered) |> should.equal([run.NotStarted])
  probe.entries(probe) |> should.equal([])
}

/// A recovered child sees its stopping root before calling the model. No
/// new delegation is requested or reserved, and the child cancels itself.
pub fn a_model_under_a_stopping_ancestor_never_starts_test() {
  let probe = probe.new()
  let store = support.store()
  store_stopping_root(store, "run-elder")
  let child =
    store_orphaned_child(
      store,
      "run-elder",
      run.DefinitionId("agent", 1),
      [model.UserMessage("x")],
      controller.AwaitingModel(1),
    )
  let delegating = delegating(two_payments(probe, policy.always_allow()))

  let assert Ok(recovered) = fabric.recover(store, delegating, Nil, child)
  fabric.await(recovered, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  states(recovered) |> should.equal([])
  probe.entries(probe) |> should.equal([])
  // Cancellation precedes the model request, so no delegation is reserved.
  store_core.get(store, support.text(child) <> "-1")
  |> should.equal(Error(backend.NotFound))
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
        _ -> Ok(policy.RequireApproval(run.Requirement("t", 1)))
      }
    }
    let assert Ok(run) =
      fabric.start(
        support.store(),
        delegating(two_payments(probe, child_policy)),
        id: run.new_id(),
        context: "run",
        prompt: "go",
        correlation: None,
      )
    let assert Ok(run.Suspended([pending], _)) =
      fabric.await(run, within: duration.milliseconds(5000))
    let answered = process.new_subject()
    process.spawn(fn() {
      process.send(
        answered,
        fabric.approve(
          run,
          pending.reference,
          reviewer: support.reviewer("reviewer"),
          context: "recheck",
        ),
      )
    })
    let assert Ok(release) = process.receive(rechecks, 30_000)
    let assert Ok(_) = fabric.cancel(run)
    process.send(release, Nil)
    let assert Ok(_) = process.receive(answered, 30_000)
    fabric.await(run, within: duration.milliseconds(5000))
    |> should.equal(Ok(run.Finished(run.Cancelled)))
    let assert Ok(child) = fabric.child(run, pending.reference.run)
    fabric.await(child, within: duration.milliseconds(5000))
    |> should.equal(Ok(run.Finished(run.Cancelled)))
    probe.entries(probe) |> should.equal([])
  })
}

/// A child's fence reads its ancestors open, and the root's cancellation
/// commits while the child is storing the tool's start: the child reads its
/// ancestors again once the start is stored, so the body never runs.
pub fn a_start_racing_an_ancestor_cancellation_never_runs_test() {
  let probe = probe.new()
  let backend = flaky.new()
  let starts = process.new_subject()
  let attached =
    sinal.observe(o.model_turn(), fn(_, turn: o.ModelTurn) {
      case string.ends_with(turn.run, "-1"), turn.turn {
        // The child's first turn queued `t1`: its next write stores the
        // start of `t1`. The test holds that write before the runner goes
        // on.
        True, 1 -> {
          let armed = process.new_subject()
          process.send(starts, #(turn.run, armed))
          let assert Ok(Nil) = process.receive(armed, 30_000)
          Nil
        }
        _, _ -> Nil
      }
    })
  let assert Ok(run) =
    fabric.start(
      flaky.store(backend),
      delegating(two_payments(probe, policy.always_allow())),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(#(child, armed)) = process.receive(starts, 30_000)
  let held = flaky.hold(backend, fn(run) { run == child })
  // A read through the backend: the hold is in place before the runner
  // writes again.
  let _ = store_core.get(flaky.store(backend), child)
  process.send(armed, Nil)
  let assert Ok(_) = process.receive(held, 30_000)
  let _ = sinal.detach(attached)

  let assert Ok(_) = fabric.cancel(run)
  flaky.release_held(backend)
  fabric.await(run, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert Ok(child) = fabric.child(run, support.id(child))
  fabric.await(child, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  probe.entries(probe) |> should.equal([])
}

/// A child whose root is stopping is recovered with a delegation whose
/// grandchild was never stored: reattaching it finds the root stopping,
/// stores no grandchild, and the child cancels itself.
pub fn a_reattached_sub_agent_under_a_stopping_ancestor_never_starts_test() {
  let probe = probe.new()
  let store = support.store()
  store_stopping_root(store, "run-elders")
  let r = scripted.call("r", "research", "{\"topic\":\"x\"}")
  let child =
    store_orphaned_child(
      store,
      "run-elders",
      run.DefinitionId("agent", 1),
      [
        model.UserMessage("x"),
        model.AssistantMessage(model.AssistantTurn("", [r], None)),
      ],
      controller.Acting(1, [
        run.ActionRecord(
          ActionId(1, "r"),
          r,
          run.Delegated,
          [],
          Some(support.id("run-elders-1-1")),
          0,
        ),
      ]),
    )
  let delegating = delegating(two_payments(probe, policy.always_allow()))

  let assert Ok(recovered) = fabric.recover(store, delegating, Nil, child)
  fabric.await(recovered, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  probe.entries(probe) |> should.equal([])
  // The grandchild is a tombstone: cancelled before it ever started.
  let assert Ok(store_core.Entry(record: stored, ..)) =
    store_core.get(store, support.text(child) <> "-1")
  let assert Ok(controller.State(phase: controller.NeverStarted, ..)) =
    record.decode(stored)
}

// --- a settling child -----------------------------------------------------------

/// A child whose tool hands its settlement to `handed` and waits.
fn settling_child(
  handed: Subject(tool.Settlement(apps.Forecast)),
) -> Agent(Nil, String) {
  agent.new(
    "forecaster",
    scripted.plan([scripted.call("w", "lookup_weather", "{\"city\":\"Paris\"}")]),
    [
      tool.bind_settling(
        apps.weather_definition(),
        fn(_, _call, _, settlement) {
          process.send(handed, settlement)
          let never = process.new_subject()
          let _ = process.receive_forever(never)
          Ok(apps.Forecast("never"))
        },
        fn(_: Nil) { tool.Explain("failed") },
        settle_within: duration.milliseconds(5000),
      ),
    ],
    policy.always_allow(),
  )
  |> support.agent
}

/// `cancel_stored` of a parent whose child waits for a stopped tool's
/// settlement: the parent ends at once, recording that the child is still
/// stopping (not that it was lost), and the child then ends with its
/// settlement.
pub fn cancel_stored_of_a_parent_with_a_settling_child_test() {
  let store = support.store()
  let handed = process.new_subject()
  let assert Ok(run) =
    fabric.start(
      store,
      delegating(settling_child(handed)),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(settlement) = process.receive(handed, 30_000)

  fabric.cancel_stored(store, fabric.id(run))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert [run.Uncertain(evidence)] = states(run)
  string.contains(evidence, "still stopping") |> should.be_true
  string.contains(evidence, "cannot be continued") |> should.be_false

  let assert Ok(child) = fabric.child(run, support.child_id(fabric.id(run), 1))
  tool.settle(settlement, Ok(apps.Forecast("cloudy")), summary: "")
  |> should.equal(Ok(Nil))
  fabric.await(child, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  states(child) |> should.equal([run.Succeeded("{\"summary\":\"cloudy\"}")])
}

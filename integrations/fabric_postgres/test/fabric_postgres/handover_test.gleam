//// A handover (`policy.HandOver`) on the PostgreSQL store: a node killed
//// around the handover leaves a run that recovery brings to the same
//// ending, without running the handed-over tool or a body twice.

import fabric
import fabric/agent.{type Agent}
import fabric/approvers
import fabric/model
import fabric/policy
import fabric/reviewer
import fabric/run.{ActionId, ActionRef, Requirement}
import fabric/store
import fabric/sweeper
import fabric/testing
import fabric/tool
import fabric_postgres
import fabric_postgres/agents
import fabric_postgres/support
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import pog

/// What the agents of these tests tell the test process.
type Signal {
  /// The model was called.
  Model
  /// The model waits, at its first attempt of its second turn, until
  /// released.
  Held(release: Subject(Nil))
  /// A body of `refund_fee` ran (a handover never runs it).
  Refund
  /// The body of `slow` started and waits until released.
  SlowStarted(release: Subject(Nil))
}

const reason = "refunds are decided by finance"

const refund_arguments = "{\"amount\":80}"

fn one_field(name: String, inner: codec.Codec(a)) -> codec.Codec(a) {
  use value <- codec.field(name, inner, get: fn(value) { value })
  codec.success(value)
}

fn results(messages: List(model.Message)) -> Int {
  list.count(messages, fn(message) {
    case message {
      model.ToolResultMessage(..) -> True
      _ -> False
    }
  })
}

fn ask(calls: List(model.ToolCall)) -> model.Reply {
  model.ToolRequest(model.AssistantTurn("", calls, None), None)
}

fn refund_fee(signals: Subject(Signal)) -> tool.Tool(context) {
  tool.define(
    "refund_fee",
    "Refunds a fee.",
    one_field("amount", codec.int()),
    codec.string(),
  )
  |> tool.bind(
    fn(_, _, _amount: Int) -> Result(String, Nil) {
      process.send(signals, Refund)
      Ok("refunded")
    },
    fn(_) { tool.Explain("failed") },
  )
}

/// The issue's support agent: it reads the fee history, then calls
/// `refund_fee`, which the policy hands over. With `hold`, its second
/// turn waits for the test first.
fn support_agent(signals: Subject(Signal), hold: Bool) -> Agent(Nil, String) {
  let assert Ok(desk) =
    agent.build_with(fn() {
      agent.new(
        "support",
        model.new(fn(request: model.Request) {
          process.send(signals, Model)
          Ok(case results(request.messages) {
            0 ->
              ask([
                model.tool_call(
                  id: "c1",
                  name: "fee_history",
                  arguments_json: "{\"customer\":\"ana\"}",
                ),
              ])
            1 -> {
              case hold {
                True -> {
                  let release = process.new_subject()
                  process.send(signals, Held(release))
                  let _ = process.receive(release, 60_000)
                  Nil
                }
                False -> Nil
              }
              ask([
                model.tool_call(
                  id: "c2",
                  name: "refund_fee",
                  arguments_json: refund_arguments,
                ),
              ])
            }
            _ -> model.FinalAnswer("Pronto, Ana: estornei os 80.00.", None)
          })
        }),
        [
          tool.define(
            "fee_history",
            "The fees charged to a customer.",
            one_field("customer", codec.string()),
            codec.string(),
          )
            |> tool.bind(
              fn(_, _, customer: String) -> Result(String, Nil) {
                Ok("late fee 80.00 charged to " <> customer)
              },
              fn(_) { tool.Explain("unreadable") },
            ),
          refund_fee(signals),
        ],
        fn(_, action: policy.Action) {
          case action.name {
            "refund_fee" -> Ok(policy.HandOver(reason))
            _ -> Ok(policy.Allow)
          }
        },
      )
      |> agent.with_approvers(testing.trusting_approvers())
    })
  desk
}

/// One reply calls `slow` (allowed; it settles late, so a stopped run
/// waits up to a minute for its settlement) and `refund_fee`, which waits
/// for an approval; answered under the context "hand over", the policy
/// hands the refund over instead.
fn deciding_agent(signals: Subject(Signal)) -> Agent(String, String) {
  let assert Ok(desk) =
    agent.build_with(fn() {
      agent.new(
        "deciding",
        model.new(fn(request: model.Request) {
          process.send(signals, Model)
          Ok(case results(request.messages) {
            0 ->
              ask([
                model.tool_call(
                  id: "s",
                  name: "slow",
                  arguments_json: "{\"x\":\"s\"}",
                ),
                model.tool_call(
                  id: "r",
                  name: "refund_fee",
                  arguments_json: refund_arguments,
                ),
              ])
            _ -> model.FinalAnswer("done", None)
          })
        }),
        [
          tool.define(
            "slow",
            "Waits for the test.",
            one_field("x", codec.string()),
            codec.string(),
          )
            |> tool.bind_settling(
              fn(_, _, x: String, _settlement) -> Result(String, Nil) {
                let release = process.new_subject()
                process.send(signals, SlowStarted(release))
                let _ = process.receive(release, 60_000)
                Ok(x)
              },
              fn(_) { tool.Explain("failed") },
              settle_within: duration.seconds(60),
            ),
          refund_fee(signals),
        ],
        fn(context: String, action: policy.Action) {
          case action.name, context {
            "refund_fee", "hand over" -> Ok(policy.HandOver(reason))
            "refund_fee", _ ->
              Ok(policy.RequireApproval(Requirement("finance", 1)))
            _, _ -> Ok(policy.Allow)
          }
        },
      )
      |> agent.with_approvers(testing.trusting_approvers())
    })
  desk
}

/// Every signal sent so far, in order.
fn drain(signals: Subject(Signal)) -> List(Signal) {
  case process.receive(signals, 0) {
    Ok(signal) -> [signal, ..drain(signals)]
    Error(Nil) -> []
  }
}

fn count(signals: List(Signal), wanted: fn(Signal) -> Bool) -> Int {
  list.count(signals, wanted)
}

fn is_model(signal: Signal) -> Bool {
  signal == Model
}

fn is_refund(signal: Signal) -> Bool {
  signal == Refund
}

/// The node is killed while the model computes the reply that holds the
/// handover: nothing of it was stored. Another store over the same table
/// recovers the run, the model is asked again, and the run ends at the
/// handover; the record reads back the same after a further restart.
pub fn a_node_killed_before_the_handover_is_recorded_test() {
  support.using_pool(8, a_node_killed_before_the_handover_is_recorded)
}

fn a_node_killed_before_the_handover_is_recorded(
  connection: pog.Connection,
) -> Nil {
  let signals = process.new_subject()
  let schema = support.schema()
  let name = process.new_name("handover_before")
  let settings = support.migrated(connection, "a", schema)
  let id = run.new_id()
  let #(owner, Nil) =
    agents.owned(fn() {
      let assert Ok(runs) = fabric_postgres.store(name, settings)
      let assert Ok(Nil) = store.start(runs)
      let assert Ok(_) =
        fabric.start(
          runs,
          support_agent(signals, True),
          id:,
          context: Nil,
          prompt: "Handle this complaint from ana.",
          correlation: None,
        )
      Nil
    })
  let assert Ok(Model) = process.receive(signals, 30_000)
  let assert Ok(Model) = process.receive(signals, 30_000)
  let assert Ok(Held(_)) = process.receive(signals, 30_000)
  agents.kill(owner)

  let desk = support_agent(signals, False)
  let assert Ok(runs) = fabric_postgres.store(name, settings)
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(recovered) = fabric.recover(runs, desk, Nil, id)
  let expected =
    run.Finished(run.HandedOver(
      action: ActionRef(id, ActionId(3, "c2")),
      tool: "refund_fee",
      arguments_json: refund_arguments,
      reason:,
    ))
  fabric.await(recovered, within: duration.seconds(30))
  |> should.equal(Ok(expected))
  let seen = drain(signals)
  count(seen, is_model) |> should.equal(1)
  count(seen, is_refund) |> should.equal(0)

  // A later store over the same table reads the same ending.
  let assert Ok(Nil) = store.stop(runs)
  let assert Ok(again) =
    fabric_postgres.store(process.new_name("handover_reread"), settings)
  let assert Ok(Nil) = store.start(again)
  let assert Ok(opened) = fabric.open(again, desk, Nil, id)
  fabric.await(opened, within: duration.milliseconds(0))
  |> should.equal(Ok(expected))
  let assert Ok(snapshot) = fabric.snapshot(opened)
  let assert Ok(last) = list.last(snapshot.actions)
  last.state |> should.equal(run.Handover(reason))
  drain(signals) |> should.equal([])
  let assert Ok(Nil) = store.stop(again)
  Nil
}

/// The handover is stored while a sibling's body was stopped and its late
/// settlement is awaited; the node is killed then. Another store recovers
/// the run into the same ending: the sibling is an uncertain effect, its
/// body ran once, and the handed-over tool never ran.
pub fn a_node_killed_after_the_handover_is_recorded_test() {
  support.using_pool(8, a_node_killed_after_the_handover_is_recorded)
}

fn a_node_killed_after_the_handover_is_recorded(
  connection: pog.Connection,
) -> Nil {
  let signals = process.new_subject()
  let schema = support.schema()
  let name = process.new_name("handover_after")
  let settings = support.migrated(connection, "a", schema)
  let id = run.new_id()
  let #(owner, handle) =
    agents.owned(fn() {
      let assert Ok(runs) = fabric_postgres.store(name, settings)
      let assert Ok(Nil) = store.start(runs)
      let assert Ok(handle) =
        fabric.start(
          runs,
          deciding_agent(signals),
          id:,
          context: "ask",
          prompt: "go",
          correlation: None,
        )
      handle
    })
  let assert Ok(Model) = process.receive(signals, 30_000)
  let assert Ok(SlowStarted(_)) = process.receive(signals, 30_000)
  let assert Ok([pending]) = fabric.pending(handle)
  let assert Ok(proof) =
    approvers.check(
      testing.trusting_approvers(),
      as_reviewer("bia"),
      pending.reference,
    )
  let assert Ok(run.Working) =
    fabric.approve(handle, pending.reference, proof:, context: "hand over")
  // The handover is stored; the stopped sibling awaits its settlement.
  let assert Ok(snapshot) = fabric.snapshot(handle)
  snapshot.status |> should.equal(run.Working)
  let assert [_, handed] = snapshot.actions
  handed.state |> should.equal(run.Handover(reason))
  agents.kill(owner)

  let assert Ok(runs) = fabric_postgres.store(name, settings)
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(recovered) =
    fabric.recover(runs, deciding_agent(signals), "ask", id)
  let assert Ok(run.Finished(run.HandedOver(action:, tool:, ..))) =
    fabric.await(recovered, within: duration.seconds(30))
  action |> should.equal(ActionRef(id, ActionId(1, "r")))
  tool |> should.equal("refund_fee")
  let assert Ok(snapshot) = fabric.snapshot(recovered)
  let assert [sibling, handed] = snapshot.actions
  let assert run.Uncertain(_) = sibling.state
  handed.state |> should.equal(run.Handover(reason))
  let seen = drain(signals)
  count(seen, is_model) |> should.equal(0)
  count(seen, is_refund) |> should.equal(0)
  count(seen, fn(signal) {
    case signal {
      SlowStarted(_) -> True
      _ -> False
    }
  })
  |> should.equal(0)
  let assert Ok(Nil) = store.stop(runs)
  Nil
}

fn as_reviewer(subject: String) -> reviewer.Reviewer {
  let assert Ok(reviewer) = reviewer.new(subject)
  reviewer
}

/// Node `a`, with a short lease, stores a handover while a sibling's late
/// settlement is awaited, and is killed. Node `b` runs a sweeper, which
/// recovers the run once `a`'s lease expires: the run ends `HandedOver`,
/// the sibling is an uncertain effect, and no body runs again.
pub fn a_sweeper_completes_a_handover_after_its_node_died_test() {
  support.using_pool(8, a_sweeper_completes_a_handover_after_its_node_died)
}

fn a_sweeper_completes_a_handover_after_its_node_died(
  connection: pog.Connection,
) -> Nil {
  let signals = process.new_subject()
  let schema = support.schema()
  let lease = 500
  let first =
    support.migrated(connection, "a", schema)
    |> fabric_postgres.with_lease(duration.milliseconds(lease))
  let id = run.new_id()
  let #(owner, handle) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("handover_swept_a"), first)
      let assert Ok(Nil) = store.start(runs)
      let assert Ok(handle) =
        fabric.start(
          runs,
          deciding_agent(signals),
          id:,
          context: "ask",
          prompt: "go",
          correlation: None,
        )
      handle
    })
  let assert Ok(Model) = process.receive(signals, 30_000)
  let assert Ok(SlowStarted(_)) = process.receive(signals, 30_000)
  let assert Ok([pending]) = fabric.pending(handle)
  let assert Ok(proof) =
    approvers.check(
      testing.trusting_approvers(),
      as_reviewer("bia"),
      pending.reference,
    )
  let assert Ok(run.Working) =
    fabric.approve(handle, pending.reference, proof:, context: "hand over")
  agents.kill(owner)

  let second = support.migrated(connection, "b", schema)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("handover_swept_b"), second)
  let assert Ok(subtree) =
    sweeper.supervised(
      runs,
      [sweeper.agent(deciding_agent(signals), fn(_) { "ask" })],
      every: duration.milliseconds(25),
    )
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(subtree)
    |> static_supervisor.start
  let assert Ok(seen) = fabric.open(runs, deciding_agent(signals), "ask", id)
  let assert run.Finished(run.HandedOver(action:, ..)) = ended(seen, 300)
  action |> should.equal(ActionRef(id, ActionId(1, "r")))
  let assert Ok(snapshot) = fabric.snapshot(seen)
  let assert [sibling, handed] = snapshot.actions
  let assert run.Uncertain(_) = sibling.state
  handed.state |> should.equal(run.Handover(reason))
  let seen_signals = drain(signals)
  count(seen_signals, is_model) |> should.equal(0)
  count(seen_signals, is_refund) |> should.equal(0)
  count(seen_signals, fn(signal) {
    case signal {
      SlowStarted(_) -> True
      _ -> False
    }
  })
  |> should.equal(0)
  process.unlink(supervisor.pid)
  agents.kill(supervisor.pid)
}

/// The status once the run has ended; `await` can see the expired lease
/// before a sweep has claimed it.
fn ended(handle: fabric.Run(c, a), tries: Int) -> run.Status(a) {
  let assert Ok(status) =
    fabric.await(handle, within: duration.milliseconds(100))
  case status {
    run.Finished(_) -> status
    _ if tries > 0 -> {
      process.sleep(10)
      ended(handle, tries - 1)
    }
    other -> panic as { "the run did not end: " <> string.inspect(other) }
  }
}

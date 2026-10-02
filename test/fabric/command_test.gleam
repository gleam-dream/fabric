//// Commands applied with no runner: the caller commits, starts any runner
//// the commit needs, and emits the commit's events itself. Tests wait on
//// barriers, never on sleeps.

import fabric
import fabric/agent
import fabric/observation as o
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/apps
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import gleeunit/should
import sinal

/// A transfer that tells `started` when its body runs.
fn announcing_transfer(started: Subject(Nil)) -> tool.Tool(Nil) {
  tool.bind(
    apps.transfer_definition(),
    fn(_, _: apps.Transfer) -> Result(apps.Receipt, Nil) {
      process.send(started, Nil)
      Ok(apps.Receipt("r-1"))
    },
    fn(_) { tool.Explain("failed") },
  )
}

/// An answer to a suspended run is committed by its caller, which starts
/// the runner for the approved transfer and emits the answer's events. The
/// runner is already working while those events' handlers run: a handler
/// that waits for the transfer's body sees it start.
pub fn a_runner_started_by_a_command_works_while_its_handlers_run_test() {
  let started = process.new_subject()
  let agent =
    agent.new(
      "agent",
      scripted.plan([
        scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":1}"),
      ]),
      [announcing_transfer(started)],
      fn(_, _) { Ok(policy.RequireApproval(run.Requirement("t", 1))) },
    )
    |> support.agent
  let assert Ok(run) = fabric.start(support.store(), agent, Nil, "pay")
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)

  let seen = process.new_subject()
  let attached =
    sinal.observe(o.approval_answered(), fn(_, answered) {
      case answered.action.run == support.text(fabric.id(run)) {
        // Runs in the caller of `answer`, which owns `started`.
        True -> process.send(seen, process.receive(started, 2000))
        False -> Nil
      }
    })
  let answered =
    fabric.approve(run, pending.reference, reviewer: None, context: Nil)
  let _ = sinal.detach(attached)
  let assert Ok(_) = answered
  process.receive(seen, 0) |> should.equal(Ok(Ok(Nil)))
}

fn approval_agent() -> agent.Agent(Nil) {
  agent.new(
    "agent",
    scripted.plan([
      scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":1}"),
    ]),
    [apps.transfer_tool()],
    fn(_, _) { Ok(policy.RequireApproval(run.Requirement("t", 1))) },
  )
  |> support.agent
}

/// A cancellation of a suspended run is committed by its caller, which
/// emits the commit's events itself before `cancel` returns: the handler
/// runs in the caller.
pub fn a_command_with_no_runner_emits_its_events_in_the_caller_test() {
  let assert Ok(run) =
    fabric.start(support.store(), approval_agent(), Nil, "pay")
  let assert Ok(run.Suspended(_, _)) = fabric.await(run, 5000)
  let ran_in = process.new_subject()
  let attached =
    sinal.observe(o.run_cancelled(), fn(_, cancelled: o.RunCancelled) {
      case cancelled.run == support.text(fabric.id(run)) {
        True -> process.send(ran_in, process.self())
        False -> Nil
      }
    })
  let cancelled = fabric.cancel(run)
  let _ = sinal.detach(attached)
  cancelled |> should.equal(Ok(run.Finished(run.Cancelled)))
  process.receive(ran_in, 0) |> should.equal(Ok(process.self()))
}

/// A handler in the caller of an answer cancels the run the answer just
/// started a runner for, while the approved transfer's body still runs:
/// that runner is already serving, so the cancellation is applied, not
/// refused as busy.
pub fn a_handler_in_a_commands_caller_can_command_the_run_test() {
  let memory = support.store()
  let agent =
    agent.new(
      "agent",
      scripted.plan([
        scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":1}"),
      ]),
      [
        tool.bind(
          apps.transfer_definition(),
          fn(_, _: apps.Transfer) -> Result(apps.Receipt, Nil) {
            let never = process.new_subject()
            let _ = process.receive_forever(never)
            Ok(apps.Receipt("never"))
          },
          fn(_) { tool.Explain("failed") },
        ),
      ],
      fn(_, _) { Ok(policy.RequireApproval(run.Requirement("t", 1))) },
    )
    |> agent.with_limits(
      agent.Limits(..agent.default_limits(), command_timeout: 300),
    )
    |> support.agent
  let assert Ok(run) = fabric.start(memory, agent, Nil, "pay")
  let assert Ok(run.Suspended([pending], _)) = fabric.await(run, 5000)
  let outcome = process.new_subject()
  let attached =
    sinal.observe(o.approval_answered(), fn(_, answered) {
      case answered.action.run == support.text(fabric.id(run)) {
        True ->
          process.send(outcome, fabric.cancel_stored(memory, fabric.id(run)))
        False -> Nil
      }
    })
  let assert Ok(_) =
    fabric.approve(run, pending.reference, reviewer: None, context: Nil)
  let _ = sinal.detach(attached)
  let assert Ok(Ok(_)) = process.receive(outcome, 0)
  fabric.await(run, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
}

/// A run whose transfer timed out after sending: an uncertain effect.
fn uncertain_transfer() -> agent.Agent(Nil) {
  agent.new(
    "agent",
    scripted.plan([
      scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":5000}"),
    ]),
    [apps.transfer_tool()],
    policy.always_allow(),
  )
  |> support.agent
}

/// A reconciliation names its effect by run and action, and only runs of
/// the handle's family are reconciled through it: another run's effect,
/// or a run that does not exist, is refused and stays uncertain.
pub fn a_foreign_effect_is_not_reconciled_test() {
  let runs = support.store()
  let assert Ok(own) = fabric.start(runs, uncertain_transfer(), Nil, "pay")
  let assert Ok(other) = fabric.start(runs, uncertain_transfer(), Nil, "pay")
  let assert Ok(run.Suspended([], [mine])) = fabric.await(own, 5000)
  let assert Ok(run.Suspended([], [theirs])) = fabric.await(other, 5000)
  mine.reference
  |> should.equal(run.ActionRef(fabric.id(own), run.ActionId(1, "t")))

  fabric.reconcile(own, theirs.reference, "{\"receipt\":\"r\"}")
  |> should.equal(Error(fabric.WrongReference))
  fabric.reconcile(
    own,
    run.ActionRef(..mine.reference, run: support.id("run-nobody")),
    "{\"receipt\":\"r\"}",
  )
  |> should.equal(Error(fabric.WrongReference))
  fabric.reconcile(
    own,
    run.ActionRef(..mine.reference, id: run.ActionId(1, "nope")),
    "{\"receipt\":\"r\"}",
  )
  |> should.equal(Error(fabric.WrongReference))
  fabric.await(other, 0) |> should.equal(Ok(run.Suspended([], [theirs])))

  let assert Ok(_) =
    fabric.reconcile(own, mine.reference, "{\"receipt\":\"r\"}")
  fabric.await(own, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("final: {\"receipt\":\"r\"}"))))
}

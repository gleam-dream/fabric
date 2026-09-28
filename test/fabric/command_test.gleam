//// Commands applied with no runner: the caller commits, starts any runner
//// the commit needs, and emits the commit's events itself. Tests wait on
//// barriers, never on sleeps.

import fabric
import fabric/agent
import fabric/observation as o
import fabric/policy
import fabric/run
import fabric/store
import fabric/support/apps
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process.{type Subject}
import gleam/int
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
      scripted.plan([
        scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":1}"),
      ]),
      [announcing_transfer(started)],
      fn(_, _) { Ok(policy.RequireApproval(policy.Requirement("t", 1))) },
    )
  let assert Ok(run) = fabric.start(store.in_memory(), agent, Nil, "pay")
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)

  let seen = process.new_subject()
  let assert Ok(id) =
    sinal.handler_id("command-path-" <> int.to_string(int.random(1_000_000)))
  let assert Ok(attached) =
    sinal.observe(id, o.approval_answered(), fn(_, answered) {
      case answered.action.run == fabric.id(run) {
        // Runs in the caller of `answer`, which owns `started`.
        True -> process.send(seen, process.receive(started, 2000))
        False -> Nil
      }
    })
  let answered =
    fabric.answer(
      run,
      pending.reference,
      run.Approve,
      reviewer: None,
      context: Nil,
    )
  let _ = sinal.detach(attached)
  let assert Ok(_) = answered
  process.receive(seen, 0) |> should.equal(Ok(Ok(Nil)))
}

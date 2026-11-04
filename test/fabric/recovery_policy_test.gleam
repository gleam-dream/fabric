//// Recovery re-runs the policy for queued work. A queued action that never
//// started passes the policy again, with the recovering context, before
//// its body can run: a denial ends it as a fresh denial would, and an
//// approval requirement asks for an approval again. The record store is
//// trusted like the database it lives in, so this recheck is what keeps a
//// record edited to queue an action from running it unchecked.

import fabric
import fabric/agent.{type Agent}
import fabric/internal/controller
import fabric/internal/record
import fabric/internal/store as store_core
import fabric/model
import fabric/policy
import fabric/run.{Requirement}
import fabric/store.{type Store}
import fabric/support
import fabric/support/apps
import fabric/support/probe.{type Probe}
import fabric/support/restart
import fabric/support/scripted
import fabric/tool
import gleam/list
import gleam/option.{None}
import gleam/string
import gleam/time/duration
import gleeunit/should

fn paying_tool(probe: Probe) -> tool.Tool(String) {
  tool.bind(
    apps.transfer_definition(),
    fn(_, _call, transfer: apps.Transfer) -> Result(apps.Receipt, Nil) {
      probe.record(probe, "pay:" <> transfer.to)
      Ok(apps.Receipt("r-" <> transfer.to))
    },
    fn(_) { tool.Explain("failed") },
  )
}

fn transfer_call() -> model.ToolCall {
  scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}")
}

/// Transfers need an approval.
fn reviewed(
  _: String,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  case action.name {
    "transfer_funds" -> Ok(policy.RequireApproval(Requirement("transfer", 1)))
    _ -> Ok(policy.Allow)
  }
}

/// Transfers are denied to anyone but `alice`.
fn alice_only(
  who: String,
  _: policy.Action,
) -> Result(policy.Decision, String) {
  case who {
    "alice" -> Ok(policy.Allow)
    _ -> Ok(policy.Deny("only alice may pay"))
  }
}

fn payer(
  probe: Probe,
  policy: fn(String, policy.Action) -> Result(policy.Decision, String),
) -> Agent(String, String) {
  agent.new(
    "payer",
    scripted.model(fn(messages) {
      case scripted.results(messages) {
        [] ->
          model.ToolRequest(
            model.AssistantTurn("", [transfer_call()], None),
            None,
          )
        seen -> model.FinalAnswer("final: " <> string.join(seen, " | "), None)
      }
    }),
    [paying_tool(probe)],
    policy,
  )
  |> support.agent
}

/// A run whose transfer awaits an approval, stored in `dir` by an owner
/// that then crashed; its record is then edited so that the transfer reads
/// queued, as an allowed action whose runner was lost does.
fn queued_after_a_crash(dir: String, probe: Probe) -> #(Store, run.RunId) {
  let #(owner, #(runs, run)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let assert Ok(run) =
        fabric.start(
          runs,
          payer(probe, reviewed),
          id: run.new_id(),
          context: "mallory",
          prompt: "pay bob",
          correlation: None,
        )
      #(runs, run)
    })
  let assert Ok(run.Suspended([_], [])) =
    fabric.await(run, within: duration.milliseconds(5000))
  restart.crash(owner, runs)
  let runs = support.directory(dir)
  let id = support.text(fabric.id(run))
  let assert Ok(entry) = store_core.get(runs, id)
  let assert Ok(state) = record.decode(entry.record)
  let assert controller.Acting(turn, actions) = state.phase
  let queued =
    list.map(actions, fn(action) {
      run.ActionRecord(..action, state: run.Queued)
    })
  let edited =
    record.encode(
      controller.State(..state, phase: controller.Acting(turn, queued)),
    )
  let assert Ok(_) =
    store_core.commit(
      runs,
      id,
      entry.revision,
      edited,
      store_core.Detached(in_flight: True, seize: True),
    )
  #(runs, fabric.id(run))
}

/// A queued transfer that the current policy denies does not run on
/// recovery, and the run ends as a run whose transfer was denied when the
/// model asked for it.
pub fn recovery_denies_a_queued_action_the_policy_now_denies_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let #(runs, id) = queued_after_a_crash(dir, probe)

  let assert Ok(recovered) =
    fabric.recover(runs, payer(probe, alice_only), "mallory", id)
  let outcome = fabric.await(recovered, within: duration.milliseconds(5000))
  probe.count(probe, "pay:bob") |> should.equal(0)

  let assert Ok(fresh) =
    fabric.start(
      support.store(),
      payer(probe, alice_only),
      id: run.new_id(),
      context: "mallory",
      prompt: "pay bob",
      correlation: None,
    )
  outcome
  |> should.equal(fabric.await(fresh, within: duration.milliseconds(5000)))
  let assert Ok(run.Finished(run.Completed(answer))) = outcome
  string.contains(answer, "only alice may pay") |> should.be_true
  probe.count(probe, "pay:bob") |> should.equal(0)
  restart.remove_dir(dir)
}

/// A queued transfer that the policy still holds for approval asks for one
/// again on recovery instead of running.
pub fn recovery_asks_again_for_a_queued_action_that_needs_approval_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let #(runs, id) = queued_after_a_crash(dir, probe)

  let assert Ok(recovered) =
    fabric.recover(runs, payer(probe, reviewed), "mallory", id)
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(recovered, within: duration.milliseconds(5000))
  pending.reference.requirement |> should.equal(Requirement("transfer", 1))
  probe.count(probe, "pay:bob") |> should.equal(0)
  restart.remove_dir(dir)
}

/// A queued transfer that the policy still allows runs once on recovery,
/// with no new approval requirement.
pub fn recovery_runs_a_queued_action_the_policy_still_allows_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let #(runs, id) = queued_after_a_crash(dir, probe)

  let assert Ok(recovered) =
    fabric.recover(runs, payer(probe, alice_only), "alice", id)
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(recovered, within: duration.milliseconds(5000))
  probe.count(probe, "pay:bob") |> should.equal(1)
  restart.remove_dir(dir)
}

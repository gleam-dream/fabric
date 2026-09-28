//// Answering approvals and cancelling paused runs through the public API,
//// with no process holding the run, including after a restart. Includes
//// the BeamWeaver anti-oracle rows B2, B3, and B4: Fabric asserts the
//// opposite of what BeamWeaver does.

import fabric
import fabric/agent.{type Agent}
import fabric/model
import fabric/policy
import fabric/run.{ActionId, Requirement}
import fabric/store
import fabric/support
import fabric/support/apps
import fabric/support/flaky
import fabric/support/probe.{type Probe}
import fabric/support/restart
import fabric/support/scripted
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

/// The application's current facts, loaded when an answer arrives.
type Desk {
  Desk(frozen: Bool, requirement_version: Int)
}

fn open_desk() -> Desk {
  Desk(frozen: False, requirement_version: 1)
}

fn desk_policy(
  desk: Desk,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  case action.tool, desk {
    "transfer_funds", Desk(frozen: True, ..) ->
      Ok(policy.Deny("account frozen"))
    "transfer_funds", Desk(requirement_version: version, ..) ->
      Ok(policy.RequireApproval(Requirement("transfer", version)))
    _, _ -> Ok(policy.Allow)
  }
}

/// A transfer tool that records each effect in the ledger.
fn paying_tool(probe: Probe) -> tool.Tool(Desk) {
  tool.bind(
    apps.transfer_definition(),
    fn(_desk, transfer: apps.Transfer) -> Result(apps.Receipt, Nil) {
      probe.record(probe, "pay:" <> transfer.to)
      Ok(apps.Receipt("r-" <> transfer.to))
    },
    fn(_) { tool.Explain("failed") },
  )
}

fn transfer_call() -> model.ToolCall {
  scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}")
}

fn paying_agent(probe: Probe) -> Agent(Desk) {
  agent.new(
    "agent",
    scripted.plan([transfer_call()]),
    [paying_tool(probe)],
    desk_policy,
  )
  |> support.agent
}

fn suspended(probe: Probe) -> #(fabric.Run(Desk), run.PendingApproval) {
  let assert Ok(run) =
    fabric.start(store.in_memory(), paying_agent(probe), open_desk(), "pay")
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)
  #(run, pending)
}

fn approve(
  run: fabric.Run(Desk),
  reference: run.ApprovalRef,
) -> Result(run.Status, fabric.CommandError) {
  fabric.approve(run, reference, reviewer: None, context: open_desk())
}

// --- answering -----------------------------------------------------------------

pub fn an_approved_tool_runs_once_after_a_restart_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let #(owner, #(old, id)) =
    restart.owned(fn() {
      let assert Ok(store) = store.directory(dir)
      let assert Ok(run) =
        fabric.start(store, paying_agent(probe), open_desk(), "pay")
      let assert Ok(run.Suspended([_], [])) = fabric.await(run, 5000)
      #(store, fabric.id(run))
    })
  restart.kill(owner)
  restart.gone(store.pid(old))

  let assert Ok(store) = store.directory(dir)
  let assert Ok(run) =
    fabric.recover(store, paying_agent(probe), open_desk(), id)
  let assert Ok([pending]) = fabric.pending(run)
  let assert Ok(_) =
    fabric.approve(
      run,
      pending.reference,
      reviewer: Some("alice"),
      context: open_desk(),
    )
  fabric.await(run, 5000)
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"receipt\":\"r-bob\"}"))),
  )
  probe.count(probe, "pay:bob") |> should.equal(1)
  let assert Ok(snapshot) = fabric.snapshot(run)
  let assert [action] = snapshot.actions
  action.approvals
  |> should.equal([
    run.Approval(
      pending.reference.requirement,
      pending.reference.revision,
      run.Approve,
      Some("alice"),
    ),
  ])
  snapshot.incarnation |> should.equal(1)
  restart.remove_dir(dir)
}

pub fn a_rejected_tool_never_runs_and_the_model_sees_the_reason_test() {
  let probe = probe.new()
  let #(run, pending) = suspended(probe)
  let assert Ok(_) =
    fabric.reject(
      run,
      pending.reference,
      reason: "not today",
      reviewer: Some("bob"),
    )
  fabric.await(run, 5000)
  |> should.equal(
    Ok(
      run.Finished(run.Completed(
        "final: {\"error\":\"rejected\",\"detail\":\"not today\"}",
      )),
    ),
  )
  probe.count(probe, "pay:bob") |> should.equal(0)
}

/// A rejection is not checked again: it takes no context, never runs the
/// policy (here one that would now fail), and the rejected tool never runs.
pub fn a_rejection_never_runs_the_policy_test() {
  let probe = probe.new()
  let calls = process.new_subject()
  let once = fn(desk, action: policy.Action) {
    process.send(calls, action.id)
    case action.id {
      ActionId(1, "t") -> desk_policy(desk, action)
      _ -> Error("the policy runs only for the admission")
    }
  }
  let agent =
    agent.new(
      "agent",
      scripted.plan([transfer_call()]),
      [paying_tool(probe)],
      once,
    )
    |> support.agent
  let assert Ok(run) =
    fabric.start(store.in_memory(), agent, open_desk(), "pay")
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)
  process.receive(calls, 0) |> should.equal(Ok(ActionId(1, "t")))

  let assert Ok(_) =
    fabric.reject(
      run,
      pending.reference,
      reason: "not today",
      reviewer: Some("bob"),
    )
  fabric.await(run, 5000)
  |> should.equal(
    Ok(
      run.Finished(run.Completed(
        "final: {\"error\":\"rejected\",\"detail\":\"not today\"}",
      )),
    ),
  )
  process.receive(calls, 0) |> should.equal(Error(Nil))
  probe.count(probe, "pay:bob") |> should.equal(0)
}

/// Anti-oracle B2 and B4: BeamWeaver accepts stale, duplicate, and
/// unknown-thread resumes, and an invalid resume consumes the pause.
/// Fabric refuses each with a distinct error and the pause stays intact.
pub fn refused_answers_are_distinct_and_keep_the_pause_test() {
  let probe = probe.new()
  let #(run, pending) = suspended(probe)
  let reference = pending.reference

  approve(run, run.ApprovalRef(..reference, run: support.id("run-other")))
  |> should.equal(Error(fabric.WrongReference))
  approve(run, run.ApprovalRef(..reference, id: ActionId(1, "nope")))
  |> should.equal(Error(fabric.WrongReference))
  approve(run, run.ApprovalRef(..reference, revision: reference.revision + 1))
  |> should.equal(Error(fabric.StaleReference))
  approve(
    run,
    run.ApprovalRef(..reference, requirement: Requirement("transfer", 7)),
  )
  |> should.equal(Error(fabric.StaleReference))
  fabric.pending(run) |> should.equal(Ok([pending]))
  probe.count(probe, "pay:bob") |> should.equal(0)

  let assert Ok(_) = approve(run, reference)
  let assert Ok(run.Finished(run.Completed(_))) = fabric.await(run, 5000)
  approve(run, reference) |> should.equal(Error(fabric.AlreadyAnswered))
  probe.count(probe, "pay:bob") |> should.equal(1)
}

/// Anti-oracle B3: a concurrent double resume runs BeamWeaver's tool
/// twice. In Fabric exactly one answer wins and the tool runs once.
pub fn concurrent_answers_have_one_winner_and_the_tool_runs_once_test() {
  let probe = probe.new()
  let #(run, pending) = suspended(probe)
  let results = process.new_subject()
  list.each(list.repeat(Nil, 8), fn(_) {
    process.spawn(fn() {
      process.send(results, approve(run, pending.reference))
    })
  })
  let outcomes =
    list.map(list.repeat(Nil, 8), fn(_) {
      let assert Ok(outcome) = process.receive(results, 5000)
      outcome
    })
  list.count(outcomes, fn(outcome) {
    case outcome {
      Ok(_) -> True
      Error(_) -> False
    }
  })
  |> should.equal(1)
  list.count(outcomes, fn(outcome) { outcome == Error(fabric.AlreadyAnswered) })
  |> should.equal(7)
  let assert Ok(run.Finished(run.Completed(_))) = fabric.await(run, 5000)
  probe.count(probe, "pay:bob") |> should.equal(1)
}

/// The account was frozen after the request was issued: the policy checked
/// at answer time denies the transfer although it was approved.
pub fn the_policy_at_answer_time_wins_over_an_approval_test() {
  let probe = probe.new()
  let #(run, pending) = suspended(probe)
  let assert Ok(_) =
    fabric.approve(
      run,
      pending.reference,
      reviewer: Some("alice"),
      context: Desk(..open_desk(), frozen: True),
    )
  fabric.await(run, 5000)
  |> should.equal(
    Ok(
      run.Finished(run.Completed(
        "final: {\"error\":\"denied\",\"detail\":\"account frozen\"}",
      )),
    ),
  )
  probe.count(probe, "pay:bob") |> should.equal(0)
}

/// The requirement changed between the request and the answer (here across
/// a recovery under a new policy version): the old approval is not applied
/// and a new request is issued.
pub fn a_changed_requirement_issues_a_new_request_test() {
  let probe = probe.new()
  let #(run, pending) = suspended(probe)
  let stricter = Desk(..open_desk(), requirement_version: 2)
  let assert Error(fabric.RequirementChanged(renewed)) =
    fabric.approve(run, pending.reference, None, stricter)
  renewed.reference.requirement |> should.equal(Requirement("transfer", 2))
  fabric.pending(run) |> should.equal(Ok([renewed]))
  probe.count(probe, "pay:bob") |> should.equal(0)

  let assert Ok(_) =
    fabric.approve(run, renewed.reference, Some("carol"), stricter)
  let assert Ok(run.Finished(run.Completed(_))) = fabric.await(run, 5000)
  probe.count(probe, "pay:bob") |> should.equal(1)
}

// --- cancellation --------------------------------------------------------------

/// A paused run has no process; cancelling it voids its approval requests.
pub fn cancelling_a_paused_run_voids_its_approvals_test() {
  let probe = probe.new()
  let #(run, pending) = suspended(probe)
  fabric.cancel(run) |> should.equal(Ok(run.Finished(run.Cancelled)))
  approve(run, pending.reference) |> should.equal(Error(fabric.RunEnded))
  fabric.pending(run) |> should.equal(Ok([]))
  let assert Ok(snapshot) = fabric.snapshot(run)
  list.map(snapshot.actions, fn(action) { action.state })
  |> should.equal([run.NotStarted])
  probe.count(probe, "pay:bob") |> should.equal(0)
}

/// An answer and a cancel race. Either the cancel commits first (the
/// answer gets `RunEnded`, the tool never runs), or the answer commits
/// first and the cancel stops the run after it (the tool ran at most once
/// and is recorded). Every interleaving ends `Cancelled`.
pub fn an_answer_racing_a_cancel_has_a_defined_outcome_test() {
  list.each(list.repeat(Nil, 20), fn(_) {
    let probe = probe.new()
    // After the tool result, the model never answers: the cancel always
    // finds the run still open.
    let model =
      scripted.model(fn(messages) {
        case scripted.results(messages) {
          [] -> model.ToolRequest("", [transfer_call()], None)
          _ -> {
            process.sleep_forever()
            model.FinalAnswer("never", None)
          }
        }
      })
    let assert Ok(run) =
      fabric.start(
        store.in_memory(),
        agent.new("agent", model, [paying_tool(probe)], desk_policy)
          |> support.agent,
        open_desk(),
        "pay",
      )
    let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)
    let answered = process.new_subject()
    let cancelled = process.new_subject()
    process.spawn(fn() {
      process.send(answered, approve(run, pending.reference))
    })
    process.spawn(fn() { process.send(cancelled, fabric.cancel(run)) })
    let assert Ok(answer) = process.receive(answered, 5000)
    let assert Ok(Ok(_)) = process.receive(cancelled, 5000)
    fabric.await(run, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
    let assert Ok(snapshot) = fabric.snapshot(run)
    let assert [action] = snapshot.actions
    case answer {
      Error(fabric.RunEnded) -> {
        probe.count(probe, "pay:bob") |> should.equal(0)
        action.state |> should.equal(run.NotStarted)
      }
      Ok(_) -> {
        let paid = probe.count(probe, "pay:bob")
        { paid <= 1 } |> should.be_true
        case action.state {
          run.NotStarted -> paid |> should.equal(0)
          run.Succeeded(_) -> paid |> should.equal(1)
          run.Uncertain(_) -> Nil
          other -> panic as { "unexpected state " <> string.inspect(other) }
        }
      }
      Error(other) -> panic as { "unexpected answer " <> string.inspect(other) }
    }
  })
}

pub fn cancelling_a_paused_run_after_a_restart_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let #(owner, #(old, id)) =
    restart.owned(fn() {
      let assert Ok(store) = store.directory(dir)
      let assert Ok(run) =
        fabric.start(store, paying_agent(probe), open_desk(), "pay")
      let assert Ok(run.Suspended([_], [])) = fabric.await(run, 5000)
      #(store, fabric.id(run))
    })
  restart.kill(owner)
  restart.gone(store.pid(old))

  let assert Ok(store) = store.directory(dir)
  let assert Ok(run) =
    fabric.recover(store, paying_agent(probe), open_desk(), id)
  let assert Ok([pending]) = fabric.pending(run)
  fabric.cancel(run) |> should.equal(Ok(run.Finished(run.Cancelled)))
  approve(run, pending.reference) |> should.equal(Error(fabric.RunEnded))
  probe.count(probe, "pay:bob") |> should.equal(0)
  restart.remove_dir(dir)
}

// --- identical writes -------------------------------------------------------------

/// Two stores apply the same answer to the same revision, so they write
/// byte-identical records. One lands; the other's write is lost and
/// reported unavailable. Reading back must not mistake the first writer's
/// record for its own: only one of them performs the answer's effects.
pub fn an_identical_record_by_another_writer_does_not_confirm_a_lost_write_test() {
  let probe = probe.new()
  let backend = flaky.new()
  let agent =
    agent.new(
      "agent",
      model.new(fn(request: model.Request) {
        case scripted.results(request.messages) {
          [] ->
            Ok(model.ToolRequest(
              "",
              [
                scripted.call(
                  "t",
                  "transfer_funds",
                  "{\"to\":\"bob\",\"amount\":10}",
                ),
              ],
              None,
            ))
          _ -> {
            probe.gate(probe, "model")
            Ok(model.FinalAnswer("done", None))
          }
        }
      }),
      [apps.transfer_tool()],
      fn(_, action: policy.Action) {
        case action.tool {
          "transfer_funds" ->
            Ok(policy.RequireApproval(Requirement("transfer", 1)))
          _ -> Ok(policy.Allow)
        }
      },
    )
    |> support.agent
  let first = flaky.store(backend)
  let assert Ok(run) = fabric.start(first, agent, Nil, "pay")
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)
  let id = fabric.id(run)
  let reason = "not today"

  // The second writer reads the record, and its write is held.
  let held = flaky.hold(backend, fn(written) { written == support.text(id) })
  let second = process.new_subject()
  let second_store = flaky.store(backend)
  process.spawn(fn() {
    let assert Ok(handle) = fabric.recover(second_store, agent, Nil, id)
    process.send(
      second,
      fabric.reject(handle, pending.reference, reason:, reviewer: None),
    )
  })
  let assert Ok(_) = process.receive(held, 5000)
  // The first writer's identical answer lands, and its model call waits.
  let assert Ok(run.Working) =
    fabric.reject(run, pending.reference, reason:, reviewer: None)
  let calling = probe.arrival(probe)
  // The held write is lost.
  flaky.drop_held(backend)
  let assert Ok(outcome) = process.receive(second, 5000)
  probe.release(calling)
  fabric.await(run, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("done"))))

  let assert Error(fabric.Unreadable(fabric.StoreUnavailable(_))) = outcome
  process.receive(probe.arrivals, 0) |> should.equal(Error(Nil))
}

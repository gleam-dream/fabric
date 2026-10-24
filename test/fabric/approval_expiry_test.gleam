//// Approval requests expire: 7 days by default, set with
//// `agent.with_approval_expiry`. An expired request rejects its action, the
//// model sees the rejection, and a late answer is `ApprovalExpired`. The
//// deadline is stored with the request; a request stored without one never
//// expires. Whoever touches the run next rejects it: `await`, an answer,
//// `recover`, or a leased store's sweeper.

import fabric
import fabric/agent
import fabric/internal/clock
import fabric/policy
import fabric/run.{After, Infinity, Requirement}
import fabric/store/conformance
import fabric/support
import fabric/support/apps
import fabric/support/nodes
import fabric/support/probe.{type Probe}
import fabric/support/scripted
import fabric/sweeper
import fabric/telemetry as o
import fabric/tool
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import sinal

fn paying_tool(probe: Probe) -> tool.Tool(Nil) {
  tool.bind(
    apps.transfer_definition(),
    fn(_, _call, transfer: apps.Transfer) -> Result(apps.Receipt, Nil) {
      probe.record(probe, "pay:" <> transfer.to)
      Ok(apps.Receipt("r-" <> transfer.to))
    },
    fn(_) { tool.Explain("failed") },
  )
}

fn spec(probe: Probe) -> agent.Spec(Nil, String) {
  agent.new(
    "expiring",
    scripted.plan([
      scripted.call("t", "transfer_funds", "{\"to\":\"bob\",\"amount\":10}"),
    ]),
    [paying_tool(probe)],
    fn(_, action: policy.Action) {
      case action.name {
        "transfer_funds" ->
          Ok(policy.RequireApproval(Requirement("transfer", 1)))
        _ -> Ok(policy.Allow)
      }
    },
  )
}

/// An agent whose approval requests expire after `milliseconds`.
fn expiring(probe: Probe, milliseconds: Int) -> agent.Agent(Nil, String) {
  spec(probe)
  |> agent.with_approval_expiry(After(duration.milliseconds(milliseconds)))
  |> support.agent
}

fn start(
  runs,
  desk: agent.Agent(Nil, String),
) -> #(fabric.Run(Nil, String), run.PendingApproval) {
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "pay",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(handle, within: duration.seconds(5))
  #(handle, pending)
}

/// Blocks until the UTC clock that judges deadlines has passed `pending`'s.
fn after_deadline(pending: run.PendingApproval) -> Nil {
  let assert Some(at) = pending.expires
  let left = clock.to_milliseconds(at) - clock.now()
  case left >= 0 {
    True -> process.sleep(left + 1)
    False -> Nil
  }
}

/// The run ended without paying: the model saw the expiry.
fn ended_unpaid(handle: fabric.Run(Nil, String), probe: Probe) -> Nil {
  let assert Ok(run.Finished(run.Completed(answer))) =
    fabric.await(handle, within: duration.seconds(5))
  string.contains(answer, "expired") |> should.be_true
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [
    run.ActionRecord(
      state: run.Rejected(_),
      approvals: [run.Approval(answer: run.Expired, reviewer: None, ..)],
      ..,
    ),
  ] = snapshot.actions
  probe.entries(probe) |> should.equal([])
}

pub fn requests_expire_after_seven_days_by_default_test() {
  let before = clock.now()
  let #(_, pending) = start(support.store(), support.agent(spec(probe.new())))
  let assert Some(at) = pending.expires
  let week = 7 * 24 * 60 * 60 * 1000
  let deadline = clock.to_milliseconds(at)
  { deadline >= before + week && deadline <= clock.now() + week }
  |> should.be_true
}

pub fn an_infinite_expiry_stores_no_deadline_test() {
  let desk =
    spec(probe.new())
    |> agent.with_approval_expiry(Infinity)
    |> support.agent
  let #(_, pending) = start(support.store(), desk)
  pending.expires |> should.equal(None)
}

/// `await` rejects a request whose deadline passed, and the run goes on to
/// its next model turn without the action.
pub fn await_rejects_an_expired_request_and_the_model_sees_it_test() {
  let probe = probe.new()
  let #(handle, pending) = start(support.store(), expiring(probe, 30))
  after_deadline(pending)
  ended_unpaid(handle, probe)
}

/// A late answer is refused, and the request expires instead.
pub fn a_late_answer_is_approval_expired_test() {
  let probe = probe.new()
  let #(handle, pending) = start(support.store(), expiring(probe, 30))
  after_deadline(pending)
  fabric.approve(
    handle,
    pending.reference,
    proof: support.proof(
      pending.reference.requirement,
      support.reviewer("alice"),
    ),
    context: Nil,
  )
  |> should.equal(Error(fabric.ApprovalExpired))
  fabric.error_kind(fabric.ApprovalExpired) |> should.equal(fabric.Refused)
  // Answering again names the expiry, not a generic answered request.
  fabric.reject(
    handle,
    pending.reference,
    proof: support.proof(
      pending.reference.requirement,
      support.reviewer("alice"),
    ),
    reason: "too late",
  )
  |> should.equal(Error(fabric.ApprovalExpired))
  ended_unpaid(handle, probe)
}

/// An answer before the deadline runs the action as always.
pub fn an_answer_in_time_is_applied_test() {
  let probe = probe.new()
  let #(handle, pending) = start(support.store(), expiring(probe, 60_000))
  let assert Ok(_) =
    fabric.approve(
      handle,
      pending.reference,
      proof: support.proof(
        pending.reference.requirement,
        support.reviewer("alice"),
      ),
      context: Nil,
    )
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(handle, within: duration.seconds(5))
  probe.entries(probe) |> should.equal(["pay:bob"])
}

/// `recover` rejects an expired request of a suspended run.
pub fn recover_rejects_an_expired_request_test() {
  let probe = probe.new()
  let desk = expiring(probe, 30)
  let runs = support.store()
  let #(handle, pending) = start(runs, desk)
  after_deadline(pending)
  let assert Ok(_) = fabric.recover(runs, desk, Nil, fabric.id(handle))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [run.ActionRecord(state: run.Rejected(_), ..)] = snapshot.actions
  ended_unpaid(handle, probe)
}

/// On a leased store the sweeper finds a request when it is due and
/// rejects it, with no caller awaiting the run.
pub fn the_sweeper_rejects_a_due_request_test() {
  let memory = conformance.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let probe = probe.new()
  let desk = expiring(probe, 30)
  let #(handle, pending) = start(a, desk)
  let answers = process.new_subject()
  let attachment =
    sinal.observe(o.approval_answered(), fn(_, answered) {
      // Only this run's answers: other tests' runs answer too.
      case answered.action.run == run.id_to_string(fabric.id(handle)) {
        True -> process.send(answers, answered.answer)
        False -> Nil
      }
    })
  after_deadline(pending)
  let assert Ok(sweeper) =
    sweeper.start(
      a,
      [sweeper.agent(desk, fn(_) { Nil })],
      every: duration.milliseconds(10),
    )
  process.receive(answers, 10_000) |> should.equal(Ok(o.Expired))
  let _ = sinal.detach(attachment)
  process.unlink(sweeper)
  process.kill(sweeper)
  ended_unpaid(handle, probe)
}

/// A pending approval reports its deadline as a timestamp.
pub fn the_deadline_is_a_timestamp_test() {
  let #(_, pending) = start(support.store(), expiring(probe.new(), 60_000))
  let assert Some(at) = pending.expires
  timestamp.compare(at, timestamp.system_time()) |> should.equal(order.Gt)
}

/// Deadlines are set and judged by the store's clock (`store.now`), not
/// by the clock of the node that checks them: over a backend whose clock
/// runs a day ahead, a request issued for an hour expires once the
/// backend's clock passes its deadline, though this node's has not.
pub fn deadlines_follow_the_store_clock_test() {
  let probe = probe.new()
  let hour = 60 * 60 * 1000
  let memory = conformance.leased_memory()
  memory.advance(24 * hour)
  let runs = nodes.node(memory.backend, "clock-node", nodes.long)
  let #(handle, pending) = start(runs, expiring(probe, hour))
  let assert Some(at) = pending.expires
  { clock.to_milliseconds(at) >= clock.now() + 24 * hour }
  |> should.be_true
  memory.advance(2 * hour)
  fabric.approve(
    handle,
    pending.reference,
    proof: support.proof(
      pending.reference.requirement,
      support.reviewer("alice"),
    ),
    context: Nil,
  )
  |> should.equal(Error(fabric.ApprovalExpired))
  ended_unpaid(handle, probe)
}

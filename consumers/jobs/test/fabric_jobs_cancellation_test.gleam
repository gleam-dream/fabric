//// Explicit cancellation crosses the real remote service boundary.

import fabric/approvers
import fabric/graph
import fabric/graph/job
import fabric/graph/operation
import fabric/policy
import fabric/reviewer
import fabric/run
import fabric/store
import fabric/testing as fabric_testing
import fabric_jobs_demo as demo
import fabric_jobs_demo/client
import fabric_jobs_demo/support
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import sinal/correlation

fn id(name) {
  let assert Ok(id) = run.parse_id(name)
  id
}

fn memory() {
  let runs = store.in_memory(process.new_name("stop-example"))
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn submit(name, delay) {
  let assert Ok(receipt) =
    client.submit(
      support.url(),
      operation.Invocation(id(name), 1, 1, correlation.from_key(name)),
      client.Request("retained cancellation", delay),
    )
  receipt
}

fn request(_, receipt) {
  client.request_cancel(support.url(), receipt)
}

fn runtime(runs, request, recovery) {
  demo.cancellation_runtime(
    runs,
    request,
    support.url(),
    recovery,
    fn(_, _) { Ok(policy.Allow) },
    fabric_testing.trusting_approvers(),
  )
}

fn poll(handle, reference, left) {
  let assert Ok(_) = graph.poll_job(handle, reference)
  let assert Ok(snapshot) = graph.snapshot(handle)
  case snapshot.status, left {
    graph.Completed(_), _ -> snapshot
    graph.AwaitingJob(_), n if n > 0 -> {
      process.sleep(20)
      poll(handle, reference, n - 1)
    }
    _, _ -> panic as "cancellation outcome did not settle"
  }
}

pub fn cancellation_requires_approval_and_acknowledgment_is_not_confirmation_test() {
  let receipt = submit("gated-remote-stop", 5000)
  let runtime =
    demo.cancellation_runtime(
      memory(),
      request,
      support.url(),
      operation.ReplayInterrupted(3),
      fn(_, action) {
        case action.target {
          policy.RunOperation(kind: policy.Activity, ..) ->
            Ok(policy.RequireApproval(run.Requirement("stop-remote-job", 1)))
          _ -> Ok(policy.Allow)
        }
      },
      fabric_testing.trusting_approvers(),
    )
  let assert Ok(handle) =
    graph.start(runtime, id("gated-stop-flow"), receipt, correlation: None)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingApproval(approval) = waiting
  client.read(support.url(), receipt) |> should.equal(Ok(client.Queued))
  let assert Ok(_) =
    graph.approve(
      handle,
      approval,
      proof: proof_for(approval.requirement, as_reviewer("reviewer")),
      context: Nil,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert [ack] = waiting.receipts
  codec.decode_json(client.cancel_reply_codec(), ack.output_json)
  |> should.equal(Ok(client.StopRequested))
  // Even if the service has since stopped, the saved acknowledgment alone
  // leaves Fabric waiting for a separately observed terminal fact.
  let done = poll(handle, reference, 1500)
  done.status |> should.equal(graph.Completed(client.Stopped))
  list.length(done.receipts) |> should.equal(2)
  client.artifact(support.url(), receipt) |> should.be_error
  let denied_receipt = submit("denied-remote-stop", 5000)
  let denied =
    demo.cancellation_runtime(
      memory(),
      fn(_, _) { panic as "denied stop must not execute" },
      support.url(),
      operation.ReplayInterrupted(3),
      fn(_, _) { Ok(policy.Deny("not owned")) },
      fabric_testing.trusting_approvers(),
    )
  let assert Ok(handle) =
    graph.start(
      denied,
      id("denied-stop-flow"),
      denied_receipt,
      correlation: None,
    )
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done |> should.equal(graph.Failed(graph.Denied("not owned")))
  client.read(support.url(), denied_receipt) |> should.equal(Ok(client.Queued))
}

pub fn a_saved_cancellation_request_reconnects_without_requesting_again_test() {
  let receipt = submit("saved-remote-stop", 5000)
  let directory = support.temp_dir()
  let #(owner, runs) = support.owned(fn() { support.directory(directory) })
  let assert Ok(handle) =
    graph.start(
      runtime(runs, request, operation.ReplayInterrupted(3)),
      id("saved-stop-flow"),
      receipt,
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting
  support.crash(owner, runs)
  let handle =
    open_graph(
      runtime(
        support.directory(directory),
        fn(_, _) { panic as "saved stop request must not repeat" },
        operation.ReplayInterrupted(3),
      ),
      id("saved-stop-flow"),
    )
  let assert Ok(recovered) = graph.recover(handle)
  recovered |> should.equal(waiting)
  let done = poll(handle, reference, 1500)
  done.status |> should.equal(graph.Completed(client.Stopped))
  graph.poll_job(handle, reference) |> should.equal(Ok(done.status))
  support.remove_dir(directory)
}

fn interrupted(name, recovery) {
  let receipt = submit(name <> "-remote", 5000)
  let accepted = process.new_subject()
  let directory = support.temp_dir()
  let #(owner, runs) = support.owned(fn() { support.directory(directory) })
  let request = fn(_, receipt) {
    let assert Ok(reply) = client.request_cancel(support.url(), receipt)
    process.send(accepted, reply)
    let never: process.Subject(Nil) = process.new_subject()
    process.receive_forever(never)
    Ok(reply)
  }
  let assert Ok(_) =
    graph.start(
      runtime(runs, request, recovery),
      id(name),
      receipt,
      correlation: None,
    )
  process.receive(accepted, 5000) |> should.equal(Ok(client.StopRequested))
  support.crash(owner, runs)
  #(directory, receipt)
}

pub fn lost_stop_acknowledgment_replays_only_under_the_service_idempotency_contract_test() {
  let #(directory, receipt) =
    interrupted("replayed-stop", operation.ReplayInterrupted(3))
  let handle =
    open_graph(
      runtime(
        support.directory(directory),
        request,
        operation.ReplayInterrupted(3),
      ),
      id("replayed-stop"),
    )
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert [ack] = waiting.receipts
  ack.attempt |> should.equal(2)
  poll(handle, reference, 100).status
  |> should.equal(graph.Completed(client.Stopped))
  client.request_cancel(support.url(), receipt)
  |> should.equal(Ok(client.StopRequested))
  client.artifact(support.url(), receipt) |> should.be_error
  support.remove_dir(directory)
}

pub fn an_unrepeatable_stop_request_remains_uncertain_until_reconciled_test() {
  let #(directory, _receipt) =
    interrupted("unrepeatable-stop", operation.RequireReconciliation)
  let handle =
    open_graph(
      runtime(
        support.directory(directory),
        fn(_, _) { panic as "unrepeatable stop must not execute" },
        operation.RequireReconciliation,
      ),
      id("unrepeatable-stop"),
    )
  let assert Ok(blocked) = graph.recover(handle)
  let assert graph.Blocked(reference, graph.EffectUncertain(_)) = blocked
  let assert Ok(encoded) =
    codec.encode_json(client.cancel_reply_codec(), client.StopRequested)
  let assert Ok(_) = graph.reconcile(handle, reference, encoded)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting
  poll(handle, reference, 100).status
  |> should.equal(graph.Completed(client.Stopped))
  support.remove_dir(directory)
}

pub fn a_returned_transport_error_never_claims_cancellation_or_automatic_replay_test() {
  let receipt = submit("returned-stop-error", 5000)
  let runs = memory()
  let request = fn(_, receipt) {
    let assert Ok(client.StopRequested) =
      client.request_cancel(support.url(), receipt)
    Error(client.Uncertain("response could not be confirmed"))
  }
  let assert Ok(handle) =
    graph.start(
      runtime(runs, request, operation.ReplayInterrupted(3)),
      id("uncertain-stop-flow"),
      receipt,
      correlation: None,
    )
  let assert Ok(blocked) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Blocked(reference, graph.EffectUncertain(_)) = blocked
  let handle =
    open_graph(
      runtime(
        runs,
        fn(_, _) {
          panic as "a returned uncertain result is not interrupted replay"
        },
        operation.ReplayInterrupted(3),
      ),
      id("uncertain-stop-flow"),
    )
  let assert Ok(recovered) = graph.recover(handle)
  recovered |> should.equal(blocked)
  let assert Ok(encoded) =
    codec.encode_json(client.cancel_reply_codec(), client.StopRequested)
  let assert Ok(_) = graph.reconcile(handle, reference, encoded)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting
  poll(handle, reference, 100).status
  |> should.equal(graph.Completed(client.Stopped))
}

fn completed(receipt, left) {
  let assert Ok(progress) = client.read(support.url(), receipt)
  case progress, left {
    client.Complete(digest), _ -> digest
    _, n if n > 0 -> {
      process.sleep(20)
      completed(receipt, n - 1)
    }
    _, _ -> panic as "remote completion did not arrive"
  }
}

pub fn completion_that_won_before_stop_is_returned_without_erasing_the_artifact_test() {
  let receipt = submit("completed-before-stop", 0)
  let digest = completed(receipt, 1500)
  let assert Ok(handle) =
    graph.start(
      runtime(memory(), request, operation.ReplayInterrupted(3)),
      id("late-stop-flow"),
      receipt,
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Completed(client.Finished(digest)))
  list.length(done.receipts) |> should.equal(1)
  client.artifact(support.url(), receipt)
  |> should.equal(Ok("RETAINED CANCELLATION"))
}

fn submit_owned(invocation, request) {
  client.submit(support.url(), invocation, request)
}

fn request_owned(_, receipt) {
  client.request_cancel(support.url(), receipt) |> result.replace(Nil)
}

fn poll_owned(handle, reference, left) {
  let assert Ok(_) = graph.poll_job(handle, reference)
  let assert Ok(snapshot) = graph.snapshot(handle)
  case snapshot.status, left {
    graph.Cancelled(_), _ -> snapshot
    graph.CancellingJob(..), n if n > 0 -> {
      process.sleep(20)
      poll_owned(handle, reference, n - 1)
    }
    _, _ -> panic as "owned cancellation did not settle"
  }
}

pub fn owned_cancellation_reconnects_to_the_real_terminal_outcome_after_restart_test() {
  let directory = support.temp_dir()
  let #(owner, runs) = support.owned(fn() { support.directory(directory) })
  let assert Ok(handle) =
    graph.start(
      demo.owned_runtime(runs, submit_owned, request_owned, support.url()),
      id("owned-real-stop"),
      demo.Submitting(client.Request("never published", 5000)),
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert demo.Accepted(receipt) = waiting.value
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(pending) =
    graph.await(handle, within: duration.milliseconds(5000))
  pending
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.CancellationRequested,
  ))
  support.crash(owner, runs)
  let rt =
    demo.owned_runtime(
      support.directory(directory),
      fn(_, _) { panic as "submission retained" },
      fn(_, _) { panic as "request retained" },
      support.url(),
    )
  let handle = open_graph(rt, id("owned-real-stop"))
  let assert Ok(recovered) = graph.recover(handle)
  recovered |> should.equal(pending)
  poll_owned(handle, reference, 100).status
  |> should.equal(graph.Cancelled(graph.JobStopped(reference)))
  client.read(support.url(), receipt) |> should.equal(Ok(client.Cancelled))
  client.artifact(support.url(), receipt) |> should.be_error
  support.remove_dir(directory)
}

pub fn an_interrupted_owned_request_is_resolved_by_real_observation_without_replay_test() {
  let directory = support.temp_dir()
  let #(owner, runs) = support.owned(fn() { support.directory(directory) })
  let accepted = process.new_subject()
  let request = fn(invocation, receipt) {
    let assert Ok(Nil) = request_owned(invocation, receipt)
    process.send(accepted, Nil)
    let never: process.Subject(Nil) = process.new_subject()
    process.receive_forever(never)
    Ok(Nil)
  }
  let assert Ok(handle) =
    graph.start(
      demo.owned_runtime(runs, submit_owned, request, support.url()),
      id("owned-lost-stop"),
      demo.Submitting(client.Request("lost stop ack", 5000)),
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting
  let assert Ok(_) = graph.cancel(handle)
  process.receive(accepted, 5000) |> should.equal(Ok(Nil))
  support.crash(owner, runs)
  let rt =
    demo.owned_runtime(
      support.directory(directory),
      fn(_, _) { panic },
      fn(_, _) { panic as "uncertain stop must not replay" },
      support.url(),
    )
  let handle = open_graph(rt, id("owned-lost-stop"))
  let assert Ok(recovered) = graph.recover(handle)
  let assert graph.CancellingJob(
    _,
    job.RequestUncertain(_),
    operation.CancellationRequested,
  ) = recovered
  poll_owned(handle, reference, 100).status
  |> should.equal(graph.Cancelled(graph.JobStopped(reference)))
  support.remove_dir(directory)
}

pub fn a_completed_owned_job_keeps_its_artifact_when_local_cancellation_wins_test() {
  let assert Ok(handle) =
    graph.start(
      demo.owned_runtime(memory(), submit_owned, request_owned, support.url()),
      id("owned-completed-stop"),
      demo.Submitting(client.Request("already published", 0)),
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert demo.Accepted(receipt) = waiting.value
  let digest = completed(receipt, 1500)
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let done = poll_owned(handle, reference, 1500)
  done.status |> should.equal(graph.Cancelled(graph.AfterResult))
  let assert [_, outcome] = done.receipts
  codec.decode_json(codec.string(), outcome.output_json)
  |> should.equal(Ok(digest))
  outcome.route |> should.equal(graph.Stopped)
  client.artifact(support.url(), receipt)
  |> should.equal(Ok("ALREADY PUBLISHED"))
}

fn open_graph(
  runtime: graph.Runtime(context, state, answer),
  id: run.RunId,
) -> graph.Handle(context, state, answer) {
  let assert Ok(handle) = graph.open(runtime, id)
  handle
}

fn as_reviewer(subject: String) -> reviewer.Reviewer {
  let assert Ok(reviewer) = reviewer.new(subject)
  reviewer
}

/// A proof that `reviewer` answers a request waiting for `requirement`,
/// from the trusting approvers the test's agents and runtimes are given.
fn proof_for(
  requirement: run.Requirement,
  reviewer: reviewer.Reviewer,
) -> approvers.Proof {
  let assert Ok(proof) =
    approvers.check(fabric_testing.trusting_approvers(), reviewer, requirement)
  proof
}

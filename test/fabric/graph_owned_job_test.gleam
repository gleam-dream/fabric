//// J18–J21: ownership retains cancellation until authoritative settlement.

import fabric/budget
import fabric/graph
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/job
import fabric/graph/operation
import fabric/policy
import fabric/retention
import fabric/run
import fabric/store
import fabric/support
import fabric/support/flaky
import fabric/support/probe
import fabric/support/restart
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit/should
import json/blueprint/codec

fn runtime(runs, read, request) {
  runtime_with(runs, read, request, fn(_, action) {
    action.kind |> should.equal(operation.OwnedJob(job.Manual))
    Ok(policy.Allow)
  })
}

fn runtime_with(runs, read, request, policy) {
  runtime_version(runs, read, request, policy, 1)
}

fn runtime_version(runs, read, request, policy, version) {
  let observer =
    job.observe(
      run.Identity("owned-job", 1),
      codec.string(),
      codec.int(),
      fn(_, receipt) { read(receipt) },
    )
  let op =
    operation.own_job(
      observer,
      fn(_, invocation, receipt) { request(invocation, receipt) },
      fn(error) { error },
    )
  let assert Ok(id) = definition.node_id("job")
  let node =
    definition.node(
      id,
      op,
      fn(receipt) { Ok(receipt) },
      fn(_, _) { panic as "canceled job must never route" },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("owned-flow", version),
      id,
      [node],
      codec.string(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, policy)
}

pub fn refusals_uncertainty_and_read_failures_remain_pending_until_terminal_evidence_test() {
  list.each(
    [
      #(
        operation.DefiniteFailure("stop refused"),
        job.RequestRefused("stop refused"),
      ),
      #(operation.UncertainEffect("ack lost"), job.RequestUncertain("ack lost")),
    ],
    fn(pair) {
      let runs = support.store()
      let calls = probe.new()
      let request = fn(_, _) {
        probe.record(calls, "request")
        Error(pair.0)
      }
      let assert Ok(handle) =
        graph.start(
          runtime(runs, fn(_) { Error("offline") }, request),
          support.id("refused-stop"),
          "receipt",
        )
      let assert Ok(waiting) = graph.await(handle, 5000)
      let assert graph.AwaitingJob(reference) = waiting.status
      graph.cancel(handle) |> should.equal(Ok(Nil))
      let assert Ok(pending) = graph.await(handle, 5000)
      pending.status
      |> should.equal(graph.CancellingJob(
        reference,
        pair.1,
        operation.CancellationRequested,
      ))
      graph.poll_job(handle, reference) |> should.be_error
      graph.read(handle) |> should.equal(Ok(pending))
      graph.cancel(handle) |> should.equal(Ok(Nil))
      let assert Ok(_) = graph.recover(handle)
      probe.entries(calls) |> should.equal(["request"])
      let handle =
        graph.attach(
          runtime(runs, fn(_) { Ok(job.Failed("remote failed")) }, fn(_, _) {
            panic
          }),
          support.id("refused-stop"),
        )
      let assert Ok(done) = graph.poll_job(handle, reference)
      done.status
      |> should.equal(
        graph.Cancelled(
          graph.AfterFailure(graph.OperationFailed("remote failed")),
        ),
      )
      graph.poll_job(handle, reference) |> should.equal(Ok(done))
    },
  )
}

pub fn cancellation_before_owned_admission_never_requests_a_remote_stop_test() {
  let rt =
    runtime_with(support.store(), fn(_) { panic }, fn(_, _) { panic }, fn(_, _) {
      Ok(policy.RequireApproval(run.Requirement("own-job", 1)))
    })
  let assert Ok(handle) =
    graph.start(rt, support.id("unadmitted-stop"), "receipt")
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingApproval(approval) = waiting.status
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(done) = graph.read(handle)
  done.status |> should.equal(graph.Cancelled(graph.BeforeStart))
  graph.approve(handle, approval) |> should.be_error
}

pub fn a_failed_start_fence_releases_no_stop_and_queued_recovery_can_request_test() {
  let backend = flaky.new()
  let calls = probe.new()
  let rt =
    runtime(flaky.store(backend), fn(_) { Ok(job.Cancelled) }, fn(_, _) {
      probe.record(calls, "request")
      Ok(Nil)
    })
  let assert Ok(handle) = graph.start(rt, support.id("fenced-stop"), "receipt")
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingJob(reference) = waiting.status
  flaky.arm(backend, [flaky.Pass, flaky.FailBefore])
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(unattended) = graph.await(handle, 5000)
  unattended.status |> should.equal(graph.Unattended)
  probe.entries(calls) |> should.equal([])
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(pending) = graph.await(handle, 5000)
  pending.status
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.CancellationRequested,
  ))
  probe.entries(calls) |> should.equal(["request"])
  let assert Ok(done) = graph.poll_job(handle, reference)
  done.status |> should.equal(graph.Cancelled(graph.JobStopped(reference)))
}

pub fn owned_cleanup_continues_under_a_cancelled_parent_with_no_unused_work_budget_test() {
  let runs = support.store()
  let rt = runtime(runs, fn(_) { Ok(job.Cancelled) }, fn(_, _) { Ok(Nil) })
  let assert Ok(id) = definition.node_id("child")
  let node =
    definition.node(
      id,
      graph.as_subgraph(rt),
      fn(receipt) { Ok(receipt) },
      fn(_, _) { panic as "cancelled parent must never route" },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("owned-parent", 1),
      id,
      [node],
      codec.string(),
      codec.int(),
      1,
    ))
  let parent =
    graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) =
    graph.start_with_budget(
      parent,
      support.id("owned-parent"),
      "receipt",
      budget.Limits(2, 1, 1),
    )
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.Child(child_ref, child.Job(_)) = waiting.status
  let assert Ok(child_handle) = graph.child(handle, child_ref.activation, rt)
  let assert Ok(child_waiting) = graph.read(child_handle)
  let assert graph.AwaitingJob(reference) = child_waiting.status
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(pending) = graph.await(handle, 5000)
  let assert graph.Cancelled(graph.ChildUnresolved(_, _)) = pending.status
  let assert Ok(child_pending) = graph.read(child_handle)
  child_pending.status
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.CancellationRequested,
  ))
  let assert Ok(done) = graph.poll_job(child_handle, reference)
  done.status |> should.equal(graph.Cancelled(graph.JobStopped(reference)))
  let assert Ok(settled) = graph.recover(handle)
  settled.status |> should.equal(graph.Cancelled(graph.ChildSettled(child_ref)))
}

pub fn incompatible_code_can_record_intent_but_cannot_dispatch_owned_cleanup_test() {
  let runs = support.store()
  let calls = probe.new()
  let correct =
    runtime(runs, fn(_) { Ok(job.Cancelled) }, fn(_, _) {
      probe.record(calls, "request")
      Ok(Nil)
    })
  let assert Ok(handle) =
    graph.start(correct, support.id("changed-owned"), "receipt")
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingJob(reference) = waiting.status
  let changed =
    runtime_version(
      runs,
      fn(_) { panic },
      fn(_, _) { panic as "incompatible cleanup must not execute" },
      fn(_, _) { Ok(policy.Allow) },
      2,
    )
  graph.cancel(graph.attach(changed, support.id("changed-owned")))
  |> should.equal(Ok(Nil))
  let assert Ok(unattended) = graph.await(handle, 5000)
  unattended.status |> should.equal(graph.Unattended)
  probe.entries(calls) |> should.equal([])
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(pending) = graph.await(handle, 5000)
  pending.status
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.CancellationRequested,
  ))
  let assert Ok(done) = graph.poll_job(handle, reference)
  done.status |> should.equal(graph.Cancelled(graph.JobStopped(reference)))
  probe.entries(calls) |> should.equal(["request"])
}

pub fn accepted_cancellation_survives_restart_until_confirmed_test() {
  let directory = restart.temp_dir()
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(directory)
      let assert Ok(handle) =
        graph.start(
          runtime(runs, fn(_) { Ok(job.Pending) }, fn(_, receipt) {
            receipt |> should.equal("receipt")
            Ok(Nil)
          }),
          support.id("owned-stop"),
          "receipt",
        )
      #(runs, handle)
    })
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingJob(reference) = waiting.status
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(pending) = graph.await(handle, 5000)
  pending.status
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.CancellationRequested,
  ))
  let assert Ok(entry) = store.get(runs, "owned-stop")
  entry.live |> should.equal(None)
  let assert Ok(metadata) = retention.inspect(entry.record)
  metadata.settled |> should.equal(False)
  graph.cancel(handle) |> should.equal(Ok(Nil))
  restart.crash(owner, runs)
  let runs = support.directory(directory)
  let handle =
    graph.attach(
      runtime(runs, fn(_) { Ok(job.Cancelled) }, fn(_, _) {
        panic as "saved request cannot repeat"
      }),
      support.id("owned-stop"),
    )
  let assert Ok(recovered) = graph.recover(handle)
  recovered.status |> should.equal(pending.status)
  let assert Ok(done) = graph.poll_job(handle, reference)
  done.status |> should.equal(graph.Cancelled(graph.JobStopped(reference)))
  let assert Ok(entry) = store.get(runs, "owned-stop")
  let assert Ok(metadata) = retention.inspect(entry.record)
  metadata.settled |> should.equal(True)
  restart.remove_dir(directory)
}

pub fn an_interrupted_stop_is_not_replayed_and_completion_settles_without_routing_test() {
  let directory = restart.temp_dir()
  let called = process.new_subject()
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(directory)
      let assert Ok(handle) =
        graph.start(
          runtime(runs, fn(_) { Ok(job.Pending) }, fn(_, _) {
            process.send(called, Nil)
            let never: process.Subject(Nil) = process.new_subject()
            process.receive_forever(never)
            Ok(Nil)
          }),
          support.id("lost-stop"),
          "receipt",
        )
      #(runs, handle)
    })
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingJob(reference) = waiting.status
  graph.cancel(handle) |> should.equal(Ok(Nil))
  process.receive(called, 5000) |> should.equal(Ok(Nil))
  restart.crash(owner, runs)
  let handle =
    graph.attach(
      runtime(
        support.directory(directory),
        fn(_) { Ok(job.Completed(42)) },
        fn(_, _) { panic as "uncertain stop cannot repeat" },
      ),
      support.id("lost-stop"),
    )
  let assert Ok(recovered) = graph.recover(handle)
  let assert graph.CancellingJob(
    _,
    job.RequestUncertain(_),
    operation.CancellationRequested,
  ) = recovered.status
  let assert Ok(done) = graph.poll_job(handle, reference)
  done.status |> should.equal(graph.Cancelled(graph.AfterResult))
  let assert [receipt] = done.receipts
  receipt.output_json |> should.equal("42")
  receipt.route |> should.equal(graph.Canceled)
  graph.poll_job(handle, reference) |> should.equal(Ok(done))
  restart.remove_dir(directory)
}

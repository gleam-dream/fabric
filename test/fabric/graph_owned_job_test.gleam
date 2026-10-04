//// J18–J21: ownership retains cancellation until authoritative settlement.

import fabric/budget
import fabric/graph
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/job
import fabric/graph/operation
import fabric/internal/store as store_core
import fabric/policy
import fabric/run
import fabric/store/retention
import fabric/support
import fabric/support/flaky
import fabric/support/probe
import fabric/support/restart
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn runtime(runs, read, request) {
  runtime_with(runs, read, request, fn(_, action) {
    support.kind(action) |> should.equal(policy.OwnedJob)
    Ok(policy.Allow)
  })
}

fn runtime_with(runs, read, request, policy) {
  runtime_version(runs, read, request, policy, 1)
}

fn runtime_version(runs, read, request, policy, version) {
  let observer =
    job.observe(
      run.DefinitionId("owned-job", 1),
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
  let id = definition.node_id("job")
  let node =
    definition.node(
      id,
      op,
      fn(receipt) { Ok(receipt) },
      fn(_, _) { panic as "canceled job must never route" },
      [],
    )
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("owned-flow", version),
        entry: id,
        nodes: [node],
        state: codec.string(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(1),
    )
  graph.new(spec, runs, fn(_) { Nil }, policy)
}

pub fn refusals_uncertainty_and_read_failures_remain_pending_until_terminal_evidence_test() {
  list.each(
    [
      #(tool.Explain("stop refused"), job.RequestRefused("stop refused")),
      #(tool.Uncertain("ack lost"), job.RequestUncertain("ack lost")),
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
          correlation: None,
        )
      let assert Ok(waiting) =
        graph.await(handle, within: duration.milliseconds(5000))
      let assert graph.AwaitingJob(reference) = waiting
      let assert Ok(_) = graph.cancel(handle)
      let assert Ok(_) =
        graph.await(handle, within: duration.milliseconds(5000))
      let assert Ok(pending) = graph.snapshot(handle)
      pending.status
      |> should.equal(graph.CancellingJob(
        reference,
        pair.1,
        operation.CancellationRequested,
      ))
      graph.poll_job(handle, reference) |> should.be_error
      graph.snapshot(handle) |> should.equal(Ok(pending))
      let assert Ok(_) = graph.cancel(handle)
      let assert Ok(_) = graph.recover(handle)
      probe.entries(calls) |> should.equal(["request"])
      let handle =
        support.open_graph(
          runtime(runs, fn(_) { Ok(job.Failed("remote failed")) }, fn(_, _) {
            panic
          }),
          support.id("refused-stop"),
        )
      let assert Ok(_) = graph.poll_job(handle, reference)
      let assert Ok(done) = graph.snapshot(handle)
      done.status
      |> should.equal(
        graph.Cancelled(
          graph.AfterFailure(graph.OperationFailed("remote failed")),
        ),
      )
      graph.poll_job(handle, reference) |> should.equal(Ok(done.status))
    },
  )
}

pub fn cancellation_before_owned_admission_never_requests_a_remote_stop_test() {
  let rt =
    runtime_with(support.store(), fn(_) { panic }, fn(_, _) { panic }, fn(_, _) {
      Ok(policy.RequireApproval(run.Requirement("own-job", 1)))
    })
  let assert Ok(handle) =
    graph.start(rt, support.id("unadmitted-stop"), "receipt", correlation: None)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingApproval(approval) = waiting
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Cancelled(graph.BeforeStart))
  graph.approve(
    handle,
    approval,
    reviewer: support.reviewer("reviewer"),
    context: Nil,
  )
  |> should.be_error
}

pub fn a_failed_start_fence_releases_no_stop_and_queued_recovery_can_request_test() {
  let backend = flaky.new()
  let calls = probe.new()
  let rt =
    runtime(flaky.store(backend), fn(_) { Ok(job.Cancelled) }, fn(_, _) {
      probe.record(calls, "request")
      Ok(Nil)
    })
  let assert Ok(handle) =
    graph.start(rt, support.id("fenced-stop"), "receipt", correlation: None)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting
  flaky.arm(backend, [flaky.Pass, flaky.FailBefore])
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(unattended) =
    graph.await(handle, within: duration.milliseconds(5000))
  unattended |> should.equal(graph.Unattended)
  probe.entries(calls) |> should.equal([])
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(pending) =
    graph.await(handle, within: duration.milliseconds(5000))
  pending
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.CancellationRequested,
  ))
  probe.entries(calls) |> should.equal(["request"])
  let assert Ok(done) = graph.poll_job(handle, reference)
  done |> should.equal(graph.Cancelled(graph.JobStopped(reference)))
}

pub fn owned_cleanup_continues_under_a_cancelled_parent_with_no_unused_work_budget_test() {
  let runs = support.store()
  let rt = runtime(runs, fn(_) { Ok(job.Cancelled) }, fn(_, _) { Ok(Nil) })
  let id = definition.node_id("child")
  let node =
    definition.node(
      id,
      graph.as_subgraph(rt),
      fn(receipt) { Ok(receipt) },
      fn(_, _) { panic as "cancelled parent must never route" },
      [],
    )
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("owned-parent", 1),
        entry: id,
        nodes: [node],
        state: codec.string(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(1),
    )
  let parent =
    graph.new(spec, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) =
    graph.start(
      graph.with_family_budget(
        parent,
        budget.limits(work: 2)
          |> budget.with_children(1)
          |> budget.with_depth(1),
      ),
      support.id("owned-parent"),
      "receipt",
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(child_ref, child.Job(_)) = waiting
  let assert Ok(child_handle) = graph.child(handle, child_ref.activation, rt)
  let assert Ok(child_waiting) = graph.snapshot(child_handle)
  let assert graph.AwaitingJob(reference) = child_waiting.status
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(pending) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Cancelled(graph.ChildUnresolved(_, _)) = pending
  let assert Ok(child_pending) = graph.snapshot(child_handle)
  child_pending.status
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.CancellationRequested,
  ))
  let assert Ok(done) = graph.poll_job(child_handle, reference)
  done |> should.equal(graph.Cancelled(graph.JobStopped(reference)))
  let assert Ok(settled) = graph.recover(handle)
  settled |> should.equal(graph.Cancelled(graph.ChildSettled(child_ref)))
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
    graph.start(
      correct,
      support.id("changed-owned"),
      "receipt",
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting
  let changed =
    runtime_version(
      runs,
      fn(_) { panic },
      fn(_, _) { panic as "incompatible cleanup must not execute" },
      fn(_, _) { Ok(policy.Allow) },
      2,
    )
  let assert Error(graph.IncompatibleDefinition(_)) =
    graph.open(changed, support.id("changed-owned"))
  graph.cancel_stored(runs, support.id("changed-owned"))
  |> should.equal(Ok(Nil))
  let assert Ok(unattended) =
    graph.await(handle, within: duration.milliseconds(5000))
  unattended |> should.equal(graph.Unattended)
  probe.entries(calls) |> should.equal([])
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(pending) =
    graph.await(handle, within: duration.milliseconds(5000))
  pending
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.CancellationRequested,
  ))
  let assert Ok(done) = graph.poll_job(handle, reference)
  done |> should.equal(graph.Cancelled(graph.JobStopped(reference)))
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
          correlation: None,
        )
      #(runs, handle)
    })
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(pending) =
    graph.await(handle, within: duration.milliseconds(5000))
  pending
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.CancellationRequested,
  ))
  let assert Ok(entry) = store_core.get(runs, "owned-stop")
  entry.live |> should.equal(None)
  let assert Ok(metadata) = retention.inspect(entry.record)
  metadata.settled |> should.equal(False)
  let assert Ok(_) = graph.cancel(handle)
  restart.crash(owner, runs)
  let runs = support.directory(directory)
  let handle =
    support.open_graph(
      runtime(runs, fn(_) { Ok(job.Cancelled) }, fn(_, _) {
        panic as "saved request cannot repeat"
      }),
      support.id("owned-stop"),
    )
  let assert Ok(recovered) = graph.recover(handle)
  recovered |> should.equal(pending)
  let assert Ok(done) = graph.poll_job(handle, reference)
  done |> should.equal(graph.Cancelled(graph.JobStopped(reference)))
  let assert Ok(entry) = store_core.get(runs, "owned-stop")
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
          correlation: None,
        )
      #(runs, handle)
    })
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting
  let assert Ok(_) = graph.cancel(handle)
  process.receive(called, 30_000) |> should.equal(Ok(Nil))
  restart.crash(owner, runs)
  let handle =
    support.open_graph(
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
  ) = recovered
  let assert Ok(_) = graph.poll_job(handle, reference)
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Cancelled(graph.AfterResult))
  let assert [receipt] = done.receipts
  receipt.output_json |> should.equal("42")
  receipt.route |> should.equal(graph.Stopped)
  graph.poll_job(handle, reference) |> should.equal(Ok(done.status))
  restart.remove_dir(directory)
}

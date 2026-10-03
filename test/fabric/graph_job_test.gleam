//// J6–J10: retained job observations have no executor and never own remote work.

import fabric/budget
import fabric/graph
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/job
import fabric/graph/operation
import fabric/internal/store as store_core
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/flaky
import fabric/support/probe
import fabric/support/restart
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn runtime(runs, read) {
  runtime_with(runs, read, fn(_, _) { Ok(policy.Allow) }, fn(receipt, output) {
    Ok(definition.Finish(receipt, output))
  })
}

fn runtime_with(runs, read, gate, accept) {
  let output = codec.integer_between(0, 100)
  let observer =
    job.observe(
      run.DefinitionId("external-job", 1),
      codec.string(),
      output,
      fn(_, receipt) { read(receipt) },
    )
  let assert Ok(id) = definition.node_id("result")
  let node =
    definition.node(
      id,
      operation.await_job(observer),
      fn(receipt) { Ok(receipt) },
      accept,
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId("job-observer", 1),
      id,
      [node],
      codec.string(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, gate)
}

pub fn a_job_wait_survives_restart_and_commits_completion_once_test() {
  let directory = restart.temp_dir()
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(directory)
      let assert Ok(handle) =
        graph.start(
          runtime(runs, fn(_) { Ok(job.Pending) }),
          support.id("job-restart"),
          "receipt-17",
        )
      #(runs, handle)
    })
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Ok(entry) = store_core.get(runs, "job-restart")
  entry.live |> should.equal(None)
  graph.poll_job(handle, reference) |> should.equal(Ok(waiting))
  restart.crash(owner, runs)
  let calls = probe.new()
  let restored =
    runtime(support.directory(directory), fn(receipt) {
      receipt |> should.equal("receipt-17")
      probe.record(calls, "observe")
      Ok(job.Completed(42))
    })
  let handle = graph.attach(restored, support.id("job-restart"))
  let assert Ok(recovered) = graph.recover(handle)
  recovered.status |> should.equal(waiting.status)
  let assert Ok(done) = graph.poll_job(handle, reference)
  done.status |> should.equal(graph.Completed(42))
  graph.poll_job(handle, reference) |> should.equal(Ok(done))
  probe.entries(calls) |> should.equal(["observe"])
  restart.remove_dir(directory)
}

pub fn job_observation_requires_admission_and_a_current_reference_test() {
  let calls = probe.new()
  let read = fn(_) {
    probe.record(calls, "read")
    Ok(job.Completed(42))
  }
  let runtime =
    runtime_with(
      support.store(),
      read,
      fn(_, action) {
        action.kind |> should.equal(operation.Job(job.Manual))
        Ok(policy.RequireApproval(run.Requirement("observe", 1)))
      },
      fn(receipt, output) { Ok(definition.Finish(receipt, output)) },
    )
  let id = support.id("job-approval")
  let assert Ok(handle) = graph.start(runtime, id, "receipt")
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingApproval(approval) = waiting.status
  let guess = job.Reference(id, 1, 1, run.DefinitionId("external-job", 1))
  graph.poll_job(handle, guess) |> should.be_error
  probe.entries(calls) |> should.equal([])
  let assert Ok(approved) = graph.approve(handle, approval)
  let assert graph.AwaitingJob(reference) = approved.status
  graph.poll_job(handle, job.Reference(..reference, activation: 2))
  |> should.be_error
  graph.poll_job(
    handle,
    job.Reference(..reference, run: support.id("wrong-run")),
  )
  |> should.be_error
  graph.poll_job(
    handle,
    job.Reference(..reference, operation: run.DefinitionId("external-job", 2)),
  )
  |> should.be_error
  probe.entries(calls) |> should.equal([])
  let assert Ok(done) = graph.poll_job(handle, reference)
  done.status |> should.equal(graph.Completed(42))
}

pub fn observation_errors_and_invalid_outputs_leave_the_wait_unconsumed_test() {
  let runs = support.store()
  let id = support.id("job-observation-error")
  let assert Ok(handle) =
    graph.start(
      runtime(runs, fn(_) { Error("transport unavailable") }),
      id,
      "receipt",
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting.status
  graph.poll_job(handle, reference) |> should.be_error
  graph.read(handle) |> should.equal(Ok(waiting))
  let invalid =
    graph.attach(runtime(runs, fn(_) { Ok(job.Completed(101)) }), id)
  graph.poll_job(invalid, reference) |> should.be_error
  graph.read(invalid) |> should.equal(Ok(waiting))
  let refused =
    graph.attach(
      runtime_with(
        runs,
        fn(_) { Ok(job.Completed(42)) },
        fn(_, _) { Ok(policy.Allow) },
        fn(_, _) { Error("route rejected") },
      ),
      id,
    )
  graph.poll_job(refused, reference) |> should.be_error
  graph.read(refused) |> should.equal(Ok(waiting))
  let corrected =
    graph.attach(runtime(runs, fn(_) { Ok(job.Completed(42)) }), id)
  let assert Ok(done) = graph.poll_job(corrected, reference)
  done.status |> should.equal(graph.Completed(42))
}

pub fn an_observer_timeout_preserves_the_wait_and_reuses_its_work_grant_test() {
  let runs = support.store()
  let id = support.id("job-timeout")
  let started = process.new_subject()
  let assert Ok(slow) =
    runtime(runs, fn(_) {
      process.send(started, process.self())
      process.sleep_forever()
      Ok(job.Pending)
    })
    |> graph.with_timeouts(
      callbacks: duration.milliseconds(50),
      operations: duration.milliseconds(1000),
      commands: duration.milliseconds(1000),
    )
  let assert Ok(handle) =
    graph.start_with_budget(
      slow,
      id,
      "receipt",
      budget.limits(work: 1) |> budget.with_children(1) |> budget.with_depth(1),
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting.status
  graph.poll_job(handle, reference) |> should.be_error
  let assert Ok(observer) = process.receive(started, 1000)
  restart.gone(observer)
  graph.read(handle) |> should.equal(Ok(waiting))
  let pending = graph.attach(runtime(runs, fn(_) { Ok(job.Pending) }), id)
  graph.poll_job(pending, reference) |> should.equal(Ok(waiting))
  graph.poll_job(pending, reference) |> should.equal(Ok(waiting))
  let restored =
    graph.attach(runtime(runs, fn(_) { Ok(job.Completed(42)) }), id)
  let assert Ok(done) = graph.poll_job(restored, reference)
  done.status |> should.equal(graph.Completed(42))
}

pub fn definite_remote_failure_does_not_run_the_success_route_test() {
  let runtime =
    runtime_with(
      support.store(),
      fn(_) { Ok(job.Failed("remote job failed")) },
      fn(_, _) { Ok(policy.Allow) },
      fn(_, _) { panic as "a failed job has no success route" },
    )
  let assert Ok(handle) =
    graph.start(runtime, support.id("failed-job"), "receipt")
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Ok(done) = graph.poll_job(handle, reference)
  done.status
  |> should.equal(graph.Failed(graph.OperationFailed("remote job failed")))
  done.receipts |> should.equal([])
}

pub fn cancellation_wins_over_an_inflight_observation_without_remote_cancellation_test() {
  let calls = probe.new()
  let runtime =
    with_successor(
      support.store(),
      fn(_) {
        probe.record(calls, "observe")
        probe.gate(calls, "observation")
        Ok(job.Completed(42))
      },
      calls,
    )
  let assert Ok(handle) =
    graph.start(runtime, support.id("cancel-job"), "receipt")
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting.status
  let reply = process.new_subject()
  process.spawn(fn() { process.send(reply, graph.poll_job(handle, reference)) })
  let held = probe.arrival(calls)
  graph.cancel(handle) |> should.equal(Ok(Nil))
  probe.release(held)
  let assert Ok(Error(_)) = process.receive(reply, 5000)
  let assert Ok(cancelled) = graph.read(handle)
  cancelled.status
  |> should.equal(graph.Cancelled(graph.JobDetached(reference)))
  cancelled.receipts |> should.equal([])
  graph.poll_job(handle, reference) |> should.be_error
  probe.entries(calls) |> should.equal(["observe"])
}

pub fn competing_observations_commit_only_one_result_test() {
  let calls = probe.new()
  let assert Ok(handle) =
    graph.start(
      runtime(support.store(), fn(_) {
        probe.gate(calls, "observation")
        Ok(job.Completed(42))
      }),
      support.id("competing-job"),
      "receipt",
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting.status
  let replies = process.new_subject()
  list.each([1, 2], fn(_) {
    process.spawn(fn() {
      process.send(replies, graph.poll_job(handle, reference))
    })
  })
  let first = probe.arrival(calls)
  let second = probe.arrival(calls)
  probe.release(first)
  probe.release(second)
  let assert Ok(Ok(one)) = process.receive(replies, 5000)
  let assert Ok(Ok(two)) = process.receive(replies, 5000)
  one |> should.equal(two)
  one.status |> should.equal(graph.Completed(42))
  list.length(one.receipts) |> should.equal(1)
}

pub fn failed_and_lost_completion_commits_preserve_the_receipt_test() {
  let backend = flaky.new()
  let assert Ok(handle) =
    graph.start(
      runtime(flaky.store(backend), fn(_) { Ok(job.Completed(42)) }),
      support.id("job-commit"),
      "receipt",
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting.status
  flaky.arm(backend, [flaky.FailBefore])
  graph.poll_job(handle, reference) |> should.be_error
  graph.read(handle) |> should.equal(Ok(waiting))
  flaky.arm(backend, [flaky.FailAfter])
  let assert Ok(done) = graph.poll_job(handle, reference)
  done.status |> should.equal(graph.Completed(42))
  graph.poll_job(handle, reference) |> should.equal(Ok(done))
}

pub fn managed_parents_park_while_their_child_observes_a_job_test() {
  let runs = support.store()
  let child_runtime = runtime(runs, fn(_) { Ok(job.Completed(42)) })
  let assert Ok(id) = definition.node_id("child")
  let node =
    definition.node(
      id,
      graph.as_subgraph(child_runtime),
      fn(receipt) { Ok(receipt) },
      fn(receipt, output) { Ok(definition.Finish(receipt, output)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId("job-parent", 1),
      id,
      [node],
      codec.string(),
      codec.int(),
      1,
    ))
  let parent =
    graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) =
    graph.start(parent, support.id("nested-job"), "receipt")
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(child_ref, child.Job(_)) = waiting.status
  let assert Ok(child) =
    graph.child(handle, child_ref.activation, child_runtime)
  let assert Ok(waiting_child) = graph.read(child)
  let assert graph.AwaitingJob(reference) = waiting_child.status
  let assert Ok(_) = graph.poll_job(child, reference)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(42))
}

fn with_successor(runs, read, calls) {
  let assert Ok(wait) = definition.node_id("wait")
  let assert Ok(next) = definition.node_id("next")
  let observer =
    job.observe(
      run.DefinitionId("external-job", 1),
      codec.string(),
      codec.int(),
      fn(_, receipt) { read(receipt) },
    )
  let waiting =
    definition.node(
      wait,
      operation.await_job(observer),
      fn(receipt) { Ok(receipt) },
      fn(receipt, _) { Ok(definition.Continue(receipt, next)) },
      [next],
    )
  let effect =
    operation.new(
      run.DefinitionId("successor", 1),
      codec.string(),
      codec.int(),
      fn(_, _, _) {
        probe.record(calls, "successor")
        Ok(99)
      },
      fn(_: Nil) { operation.DefiniteFailure("cannot fail") },
    )
  let successor =
    definition.node(
      next,
      effect,
      fn(receipt) { Ok(receipt) },
      fn(receipt, output) { Ok(definition.Finish(receipt, output)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId("job-with-successor", 1),
      wait,
      [waiting, successor],
      codec.string(),
      codec.int(),
      2,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

//// D9–D13: expiration closes routing and preserves owned cleanup.

import fabric
import fabric/budget
import fabric/graph
import fabric/graph/definition
import fabric/graph/job
import fabric/graph/operation
import fabric/observation
import fabric/policy
import fabric/retention
import fabric/run
import fabric/store
import fabric/support
import fabric/support/nodes
import fabric/support/probe
import fabric/support/restart
import fabric/testing
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should
import json/blueprint/codec
import sinal

fn runtime(runs, owned, read, request, accept) {
  runtime_with(runs, owned, job.Manual, read, request, accept)
}

fn runtime_with(runs, owned, polling, read, request, accept) {
  let observer =
    job.observe(
      run.Identity("deadline-job", 1),
      codec.string(),
      codec.int(),
      fn(_, receipt) { read(receipt) },
    )
  let observer = case polling {
    job.Manual -> observer
    job.Every(every) -> {
      let assert Ok(observer) = job.with_poll_interval(observer, every)
      observer
    }
  }
  let op = case owned {
    True ->
      operation.own_job(
        observer,
        fn(_, invocation, receipt) { request(invocation, receipt) },
        fn(error) { error },
      )
    False -> operation.await_job(observer)
  }
  let assert Ok(op) = operation.with_deadline(op, 60_000)
  let assert Ok(node) = definition.node_id("job")
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("job-deadline", 1),
      node,
      [definition.node(node, op, fn(receipt) { Ok(receipt) }, accept, [])],
      codec.string(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

pub fn ownership_can_be_cancelled_even_when_arming_cannot_read_the_clock_test() {
  let memory = testing.leased_memory()
  let backend =
    store.LeasedBackend(..memory.backend, now: fn() {
      Error(store.Unavailable("clock offline"))
    })
  let runs = nodes.node(backend, "unarmed-owner", nodes.long)
  let calls = probe.new()
  let spec =
    runtime(
      runs,
      True,
      fn(_) { Ok(job.Completed(42)) },
      fn(_, _) {
        probe.record(calls, "stop")
        Ok(Nil)
      },
      fn(_, _) { panic as "cancelled wait cannot route" },
    )
  let assert Ok(handle) =
    graph.start(spec, support.id("unarmed-owner"), "receipt")
  let assert Ok(unattended) = graph.await(handle, 5000)
  unattended.status |> should.equal(graph.Unattended)
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(pending) = graph.await(handle, 5000)
  let assert graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.CancellationRequested,
  ) = pending.status
  pending.deadline |> should.equal(None)
  let assert Ok(done) = graph.poll_job(handle, reference)
  done.status |> should.equal(graph.Cancelled(graph.AfterResult))
  probe.entries(calls) |> should.equal(["stop"])
}

pub fn a_terminal_result_observed_after_the_deadline_is_retained_without_routing_or_a_stop_test() {
  let memory = testing.leased_memory()
  let runs = nodes.node(memory.backend, "late-result", nodes.long)
  let spec =
    runtime(
      runs,
      True,
      fn(_) {
        memory.advance(60_001)
        Ok(job.Completed(42))
      },
      fn(_, _) { panic as "authoritative terminal work needs no stop" },
      fn(_, _) { panic as "late result cannot route" },
    )
  let assert Ok(handle) =
    graph.start(spec, support.id("late-job-result"), "receipt")
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  let assert Ok(done) = graph.poll_job(handle, reference)
  done.status |> should.equal(graph.Expired(due, graph.AfterResult))
  let assert [receipt] = done.receipts
  receipt.output_json |> should.equal("42")
  receipt.route |> should.equal(graph.Canceled)
}

pub fn a_failed_read_cannot_extend_a_deadline_and_cleanup_ignores_clock_failure_test() {
  let memory = testing.leased_memory()
  let calls = probe.new()
  let backend =
    store.LeasedBackend(..memory.backend, now: fn() {
      case probe.count(calls, "stop") {
        0 -> memory.backend.now()
        _ -> Error(store.Unavailable("clock offline"))
      }
    })
  let runs = nodes.node(backend, "failed-read", nodes.long)
  let spec =
    runtime(
      runs,
      True,
      fn(_) {
        case probe.count(calls, "stop") {
          0 -> {
            memory.advance(60_001)
            Error("remote offline")
          }
          _ -> Ok(job.Cancelled)
        }
      },
      fn(_, _) {
        probe.record(calls, "stop")
        Ok(Nil)
      },
      fn(_, _) { panic },
    )
  let assert Ok(handle) =
    graph.start(spec, support.id("failed-job-read"), "receipt")
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  let assert Ok(_) = graph.poll_job(handle, reference)
  let assert Ok(pending) = graph.await(handle, 5000)
  pending.status
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.DeadlineReached(due),
  ))
  let assert Ok(done) = graph.poll_job(handle, reference)
  done.status |> should.equal(graph.Expired(due, graph.JobStopped(reference)))
}

fn scan(runs, build) {
  let events = process.new_subject()
  let attached =
    sinal.observe(observation.sweep(), fn(summary, _) {
      process.send(events, summary)
    })
  let assert Ok(spec) =
    fabric.sweeper(
      runs,
      [graph.recovery(run.Identity("job-deadline", 1), build)],
      every: 60_000,
    )
  let assert Ok(started) = spec.start()
  let assert Ok(summary) = process.receive(events, 5000)
  process.unlink(started.pid)
  restart.kill(started.pid)
  let _ = sinal.detach(attached)
  summary
}

pub fn the_deadline_preempts_polling_but_does_not_spin_cleanup_observations_test() {
  let memory = testing.leased_memory()
  let runs = nodes.node(memory.backend, "scheduled-deadline", nodes.long)
  let calls = probe.new()
  let build = fn(runs) {
    runtime_with(
      runs,
      True,
      job.Every(120_000),
      fn(_) {
        probe.record(calls, "read")
        case probe.count(calls, "finish") {
          0 -> Ok(job.Pending)
          _ -> Ok(job.Cancelled)
        }
      },
      fn(_, _) {
        probe.record(calls, "stop")
        Ok(Nil)
      },
      fn(_, _) { panic },
    )
  }
  let assert Ok(handle) =
    graph.start(build(runs), support.id("scheduled-deadline"), "receipt")
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  scan(runs, build).claimed |> should.equal(1)
  probe.count(calls, "read") |> should.equal(1)
  scan(runs, build).claimed |> should.equal(0)
  memory.advance(60_001)
  scan(runs, build).claimed |> should.equal(1)
  let assert Ok(pending) = graph.await(handle, 5000)
  pending.status
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.DeadlineReached(due),
  ))
  probe.count(calls, "read") |> should.equal(1)
  scan(runs, build).claimed |> should.equal(1)
  probe.count(calls, "read") |> should.equal(2)
  scan(runs, build).claimed |> should.equal(0)
  memory.advance(120_001)
  probe.record(calls, "finish")
  scan(runs, build).claimed |> should.equal(1)
  let assert Ok(done) = graph.read(handle)
  done.status |> should.equal(graph.Expired(due, graph.JobStopped(reference)))
  probe.count(calls, "stop") |> should.equal(1)
}

pub fn read_only_expiration_detaches_without_observation_or_a_stop_request_test() {
  let memory = testing.leased_memory()
  let runs = nodes.node(memory.backend, "readonly", nodes.long)
  let spec =
    runtime(
      runs,
      False,
      fn(_) { panic as "expired wait must not read" },
      fn(_, _) { panic as "not owned" },
      fn(_, _) { panic as "no route" },
    )
  let assert Ok(handle) =
    graph.start(spec, support.id("readonly-deadline"), "receipt")
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  memory.advance(60_001)
  let assert Ok(expired) = graph.poll_job(handle, reference)
  expired.status
  |> should.equal(graph.Expired(due, graph.JobDetached(reference)))
  expired.receipts |> should.equal([])
  graph.poll_job(handle, reference) |> should.equal(Ok(expired))
}

pub fn owned_expiration_keeps_its_cause_and_cleanup_across_restart_test() {
  let memory = testing.leased_memory()
  let calls = probe.new()
  let #(owner, runs) =
    restart.owned(fn() { nodes.node(memory.backend, "owned", nodes.long) })
  let build = fn(runs, read) {
    runtime(
      runs,
      True,
      read,
      fn(_, _) {
        probe.record(calls, "stop")
        Ok(Nil)
      },
      fn(_, _) { panic as "expired job cannot route" },
    )
  }
  let assert Ok(handle) =
    graph.start_with_budget(
      build(runs, fn(_) { Ok(job.Pending) }),
      support.id("owned-deadline"),
      "receipt",
      budget.Limits(1, 1, 1),
    )
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  memory.advance(60_001)
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(pending) = graph.await(handle, 5000)
  pending.status
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.DeadlineReached(due),
  ))
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(row) = store.get(runs, "owned-deadline")
  let assert Ok(metadata) = retention.inspect(row.record)
  metadata.settled |> should.equal(False)
  row.live |> should.equal(None)
  restart.crash(owner, runs)
  let restored = nodes.node(memory.backend, "owned", nodes.long)
  let handle =
    graph.attach(
      build(restored, fn(_) { Ok(job.Completed(42)) }),
      support.id("owned-deadline"),
    )
  let assert Ok(done) = graph.poll_job(handle, reference)
  done.status |> should.equal(graph.Expired(due, graph.AfterResult))
  let assert [receipt] = done.receipts
  receipt.output_json |> should.equal("42")
  receipt.route |> should.equal(graph.Canceled)
  probe.entries(calls) |> should.equal(["stop"])
}

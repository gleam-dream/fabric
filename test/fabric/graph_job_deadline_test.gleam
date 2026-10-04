//// D9–D13: expiration closes routing and preserves owned cleanup.

import fabric/budget
import fabric/graph
import fabric/graph/definition
import fabric/graph/job
import fabric/graph/operation
import fabric/internal/store as store_core
import fabric/policy
import fabric/run
import fabric/store/backend
import fabric/store/conformance
import fabric/store/retention
import fabric/support
import fabric/support/nodes
import fabric/support/probe
import fabric/support/restart
import fabric/sweeper
import fabric/telemetry
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import sinal

fn runtime(runs, owned, read, request, accept) {
  runtime_with(runs, owned, job.Manual, read, request, accept)
}

fn runtime_with(runs, owned, polling, read, request, accept) {
  let observer =
    job.observe(
      run.DefinitionId("deadline-job", 1),
      codec.string(),
      codec.int(),
      fn(_, receipt) { read(receipt) },
    )
  let observer = case polling {
    job.Manual -> observer
    job.Every(every) -> {
      let observer =
        job.with_poll_interval(observer, duration.milliseconds(every))
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
  let op = operation.with_deadline(op, run.After(duration.milliseconds(60_000)))
  let node = definition.node_id("job")
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("job-deadline", 1),
        entry: node,
        nodes: [
          definition.node(node, op, fn(receipt) { Ok(receipt) }, accept, []),
        ],
        state: codec.string(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(1),
    )
  graph.new(spec, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
  |> graph.build
  |> should.be_ok
}

pub fn ownership_can_be_cancelled_even_when_arming_cannot_read_the_clock_test() {
  let memory = conformance.leased_memory()
  let backend =
    backend.LeasedBackend(..memory.backend, now: fn() {
      Error(backend.Unavailable("clock offline"))
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
    graph.start(spec, support.id("unarmed-owner"), "receipt", correlation: None)
  let assert Ok(unattended) =
    graph.await(handle, within: duration.milliseconds(5000))
  unattended |> should.equal(graph.Unattended)
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(pending) = graph.snapshot(handle)
  let assert graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.CancellationRequested,
  ) = pending.status
  pending.deadline |> should.equal(None)
  let assert Ok(done) = graph.poll_job(handle, reference)
  done |> should.equal(graph.Cancelled(graph.AfterResult))
  probe.entries(calls) |> should.equal(["stop"])
}

pub fn a_terminal_result_observed_after_the_deadline_is_retained_without_routing_or_a_stop_test() {
  let memory = conformance.leased_memory()
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
    graph.start(
      spec,
      support.id("late-job-result"),
      "receipt",
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  let assert Ok(_) = graph.poll_job(handle, reference)
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Expired(due, graph.AfterResult))
  let assert [receipt] = done.receipts
  receipt.output_json |> should.equal("42")
  receipt.route |> should.equal(graph.Stopped)
}

pub fn a_failed_read_cannot_extend_a_deadline_and_cleanup_ignores_clock_failure_test() {
  let memory = conformance.leased_memory()
  let calls = probe.new()
  let backend =
    backend.LeasedBackend(..memory.backend, now: fn() {
      case probe.count(calls, "stop") {
        0 -> memory.backend.now()
        _ -> Error(backend.Unavailable("clock offline"))
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
    graph.start(
      spec,
      support.id("failed-job-read"),
      "receipt",
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  let assert Ok(_) = graph.poll_job(handle, reference)
  let assert Ok(pending) =
    graph.await(handle, within: duration.milliseconds(5000))
  pending
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.DeadlineReached(due),
  ))
  let assert Ok(done) = graph.poll_job(handle, reference)
  done |> should.equal(graph.Expired(due, graph.JobStopped(reference)))
}

fn scan(runs, build) {
  let events = process.new_subject()
  let attached =
    sinal.observe(telemetry.sweep(), fn(summary, _) {
      process.send(events, summary)
    })
  let assert Ok(started) =
    sweeper.start(
      runs,
      [sweeper.graph(run.DefinitionId("job-deadline", 1), build)],
      every: duration.milliseconds(60_000),
    )
  let assert Ok(summary) = process.receive(events, 30_000)
  process.unlink(started)
  restart.kill(started)
  let _ = sinal.detach(attached)
  summary
}

pub fn the_deadline_preempts_polling_but_does_not_spin_cleanup_observations_test() {
  let memory = conformance.leased_memory()
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
    graph.start(
      build(runs),
      support.id("scheduled-deadline"),
      "receipt",
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  scan(runs, build).claimed |> should.equal(1)
  probe.count(calls, "read") |> should.equal(1)
  scan(runs, build).claimed |> should.equal(0)
  memory.advance(60_001)
  scan(runs, build).claimed |> should.equal(1)
  let assert Ok(pending) =
    graph.await(handle, within: duration.milliseconds(5000))
  pending
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
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Expired(due, graph.JobStopped(reference)))
  probe.count(calls, "stop") |> should.equal(1)
}

pub fn read_only_expiration_detaches_without_observation_or_a_stop_request_test() {
  let memory = conformance.leased_memory()
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
    graph.start(
      spec,
      support.id("readonly-deadline"),
      "receipt",
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  memory.advance(60_001)
  let assert Ok(_) = graph.poll_job(handle, reference)
  let assert Ok(expired) = graph.snapshot(handle)
  expired.status
  |> should.equal(graph.Expired(due, graph.JobDetached(reference)))
  expired.receipts |> should.equal([])
  graph.poll_job(handle, reference) |> should.equal(Ok(expired.status))
}

pub fn owned_expiration_keeps_its_cause_and_cleanup_across_restart_test() {
  let memory = conformance.leased_memory()
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
    graph.start(
      support.budgeted(
        build(runs, fn(_) { Ok(job.Pending) }),
        budget.limits(work: 1)
          |> budget.with_children(1)
          |> budget.with_depth(1),
      ),
      support.id("owned-deadline"),
      "receipt",
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  memory.advance(60_001)
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(pending) =
    graph.await(handle, within: duration.milliseconds(5000))
  pending
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.DeadlineReached(due),
  ))
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(row) = store_core.get(runs, "owned-deadline")
  let assert Ok(metadata) = retention.inspect(row.record)
  metadata.settled |> should.equal(False)
  row.live |> should.equal(None)
  restart.crash(owner, runs)
  let restored = nodes.node(memory.backend, "owned", nodes.long)
  let handle =
    support.open_graph(
      build(restored, fn(_) { Ok(job.Completed(42)) }),
      support.id("owned-deadline"),
    )
  let assert Ok(_) = graph.poll_job(handle, reference)
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Expired(due, graph.AfterResult))
  let assert [receipt] = done.receipts
  receipt.output_json |> should.equal("42")
  receipt.route |> should.equal(graph.Stopped)
  probe.entries(calls) |> should.equal(["stop"])
}

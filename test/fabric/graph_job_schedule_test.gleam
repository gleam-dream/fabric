//// J11–J13: storage owns due observation; claims survive process loss.

import fabric
import fabric/budget
import fabric/graph
import fabric/graph/definition
import fabric/graph/job
import fabric/graph/operation
import fabric/policy
import fabric/run
import fabric/store/backend
import fabric/store/conformance
import fabric/support
import fabric/support/nodes
import fabric/support/probe
import fabric/support/restart
import fabric/telemetry as o
import gleam/erlang/process
import gleam/result
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import sinal

fn runtime(runs, every, read) {
  let observer =
    job.observe(
      run.DefinitionId("scheduled-job", 1),
      codec.string(),
      codec.int(),
      fn(_, receipt) { read(receipt) },
    )
  let assert Ok(observer) =
    job.with_poll_interval(observer, duration.milliseconds(every))
  let assert Ok(id) = definition.node_id("result")
  let node =
    definition.node(
      id,
      operation.await_job(observer),
      fn(receipt) { Ok(receipt) },
      fn(receipt, output) { Ok(definition.Finish(receipt, output)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId("scheduled-flow", 1),
      id,
      [node],
      codec.string(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn scan(runs, build) {
  let events = process.new_subject()
  let attachment =
    sinal.observe(o.sweep(), fn(summary, _) { process.send(events, summary) })
  let assert Ok(spec) =
    fabric.sweeper(
      runs,
      [graph.recovery(run.DefinitionId("scheduled-flow", 1), build)],
      every: duration.milliseconds(60_000),
    )
  let assert Ok(started) = spec.start()
  let assert Ok(summary) = process.receive(events, 5000)
  process.unlink(started.pid)
  restart.kill(started.pid)
  let _ = sinal.detach(attachment)
  summary
}

pub fn scheduled_observation_reuses_one_work_grant_and_waits_for_backend_time_test() {
  let memory = conformance.leased_memory()
  let runs = nodes.node(memory.backend, "schedule", nodes.long)
  let calls = probe.new()
  let build = fn(runs) {
    runtime(runs, 60_000, fn(receipt) {
      receipt |> should.equal("job-receipt")
      probe.record(calls, "observe")
      case probe.count(calls, "observe") {
        1 -> Ok(job.Pending)
        _ -> Ok(job.Completed(42))
      }
    })
  }
  let id = support.id("scheduled-job")
  let assert Ok(handle) =
    graph.start_with_budget(
      build(runs),
      id,
      "job-receipt",
      budget.Limits(1, 1, 1),
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(_) = waiting.status
  scan(runs, build).recovered |> should.equal(1)
  probe.entries(calls) |> should.equal(["observe"])
  nodes.holder(memory.backend, id) |> should.equal(backend.Free)
  scan(runs, build).claimed |> should.equal(0)
  probe.entries(calls) |> should.equal(["observe"])
  memory.advance(60_000)
  scan(runs, build).recovered |> should.equal(1)
  let assert Ok(done) = graph.read(handle)
  done.status |> should.equal(graph.Completed(42))
  scan(runs, build).claimed |> should.equal(0)
  probe.entries(calls) |> should.equal(["observe", "observe"])
}

pub fn polling_intervals_are_bounded_and_part_of_definition_compatibility_test() {
  let observer =
    job.observe(
      run.DefinitionId("job", 1),
      codec.string(),
      codec.int(),
      fn(_, _) { Ok(job.Completed(42)) },
    )
  job.with_poll_interval(observer, duration.milliseconds(0)) |> should.be_error
  job.with_poll_interval(observer, duration.milliseconds(-1)) |> should.be_error
  job.with_poll_interval(observer, duration.milliseconds(4_294_967_296))
  |> should.be_error
  job.with_poll_interval(observer, duration.milliseconds(4_294_967_295))
  |> should.be_ok
  let runs = support.store()
  let id = support.id("changed-poll")
  let assert Ok(handle) =
    graph.start(runtime(runs, 1000, fn(_) { Ok(job.Pending) }), id, "receipt")
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting.status
  let changed =
    graph.attach(
      runtime(runs, 2000, fn(_) { panic as "changed contract must not observe" }),
      id,
    )
  graph.poll_job(changed, reference) |> should.be_error
  graph.recover(changed) |> should.be_error
}

pub fn a_failed_observer_keeps_a_retry_claim_until_expiry_and_recovers_after_store_loss_test() {
  let memory = conformance.leased_memory()
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = nodes.node(memory.backend, "old-job-owner", nodes.long)
      let assert Ok(handle) =
        graph.start(
          runtime(runs, 1000, fn(_) { Error("service unavailable") }),
          support.id("retry-job"),
          "receipt",
        )
      #(runs, handle)
    })
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting.status
  scan(runs, fn(runs) {
    runtime(runs, 1000, fn(_) { Error("service unavailable") })
  }).failed
  |> should.equal(1)
  let assert backend.Held(_, True) = nodes.holder(memory.backend, reference.run)
  restart.crash(owner, runs)
  let restored = nodes.node(memory.backend, "new-job-owner", nodes.long)
  let build = fn(runs) { runtime(runs, 1000, fn(_) { Ok(job.Completed(42)) }) }
  scan(restored, build).claimed |> should.equal(0)
  memory.advance(nodes.long)
  scan(restored, build).recovered |> should.equal(1)
  let handle = graph.attach(build(restored), reference.run)
  let assert Ok(done) = graph.read(handle)
  done.status |> should.equal(graph.Completed(42))
}

pub fn discovery_of_a_parent_does_not_poll_an_unclaimed_job_early_test() {
  let memory = conformance.leased_memory()
  let runs = nodes.node(memory.backend, "nested-job", nodes.long)
  let calls = probe.new()
  let build_child = fn(runs) {
    runtime(runs, 60_000, fn(_) {
      probe.record(calls, "observe")
      case probe.count(calls, "observe") {
        1 -> Ok(job.Pending)
        _ -> Ok(job.Completed(42))
      }
    })
  }
  let build = fn(runs) {
    let assert Ok(id) = definition.node_id("child")
    let op = graph.as_subgraph(build_child(runs))
    let node =
      definition.node(
        id,
        op,
        fn(receipt) { Ok(receipt) },
        fn(receipt, n) { Ok(definition.Finish(receipt, n)) },
        [],
      )
    let assert Ok(spec) =
      definition.build(definition.Spec(
        run.DefinitionId("scheduled-flow", 1),
        id,
        [node],
        codec.string(),
        codec.int(),
        1,
      ))
    graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  }
  let id = support.id("nested-job-root")
  let assert Ok(handle) = graph.start(build(runs), id, "receipt")
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let _ = scan(runs, build)
  probe.entries(calls) |> should.equal(["observe"])
  // The child revision changed when the first poll released its claim. A
  // subsequent parent scan must inspect it without issuing another job read.
  let _ = scan(runs, build)
  let _ = scan(runs, build)
  probe.entries(calls) |> should.equal(["observe"])
  memory.advance(60_000)
  let _ = scan(runs, build)
  let _ = scan(runs, build)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(42))
  probe.entries(calls) |> should.equal(["observe", "observe"])
}

pub fn each_new_visit_is_eligible_without_waiting_for_the_previous_interval_test() {
  let memory = conformance.leased_memory()
  let runs = nodes.node(memory.backend, "poll-cycle", nodes.long)
  let build = fn(runs) {
    let observer =
      job.observe(
        run.DefinitionId("cycle-job", 1),
        codec.int(),
        codec.int(),
        fn(_, n) { Ok(job.Completed(n + 1)) },
      )
    let assert Ok(observer) =
      job.with_poll_interval(observer, duration.milliseconds(60_000))
    let assert Ok(id) = definition.node_id("observe")
    let node =
      definition.node(
        id,
        operation.await_job(observer),
        fn(n) { Ok(n) },
        fn(_, n) {
          case n < 2 {
            True -> Ok(definition.Continue(n, id))
            False -> Ok(definition.Finish(n, n))
          }
        },
        [id],
      )
    let assert Ok(spec) =
      definition.build(definition.Spec(
        run.DefinitionId("scheduled-flow", 1),
        id,
        [node],
        codec.int(),
        codec.int(),
        2,
      ))
    graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  }
  let assert Ok(handle) = graph.start(build(runs), support.id("poll-cycle"), 0)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  scan(runs, build) |> should.equal(o.Sweep(1, 1, 0, 0))
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(reference) = waiting.status
  reference.activation |> should.equal(2)
  scan(runs, build).claimed |> should.equal(1)
  let assert Ok(done) = graph.read(handle)
  done.status |> should.equal(graph.Completed(2))
}

pub fn discovery_rechecks_a_claim_released_after_its_initial_read_test() {
  let memory = conformance.leased_memory()
  let id = support.id("released-job-claim")
  let race = probe.new()
  let calls = probe.new()
  let backend =
    backend.LeasedBackend(..memory.backend, get: fn(key) {
      use current <- result.map(memory.backend.get(key))
      case
        key == run.id_to_string(id),
        current.holder,
        probe.count(race, "armed"),
        probe.count(race, "released")
      {
        True, backend.Held(_, True), armed, 0 if armed > 0 -> {
          // A real competing write releases the lease immediately after the
          // first discovery read. Its returned snapshot is now stale.
          let assert Ok(Nil) =
            memory.backend.compare_and_set(
              key,
              current.revision,
              current.record,
              backend.Release,
            )
          probe.record(race, "released")
        }
        _, _, _, _ -> Nil
      }
      current
    })
  let runs = nodes.node(backend, "released-job", nodes.long)
  let build = fn(runs) {
    runtime(runs, 60_000, fn(_) {
      probe.record(calls, "observe")
      Ok(job.Completed(42))
    })
  }
  let assert Ok(handle) = graph.start(build(runs), id, "receipt")
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(_) = waiting.status
  scan(runs, fn(runs) {
    probe.record(race, "armed")
    build(runs)
  }).failed
  |> should.equal(0)
  probe.count(race, "released") |> should.equal(1)
  probe.entries(calls) |> should.equal([])
  scan(runs, build).claimed |> should.equal(0)
  memory.advance(60_000)
  scan(runs, build).recovered |> should.equal(1)
  let assert Ok(done) = graph.read(handle)
  done.status |> should.equal(graph.Completed(42))
  probe.entries(calls) |> should.equal(["observe"])
}

pub fn losing_a_scan_releases_its_local_observation_without_releasing_the_claim_test() {
  let memory = conformance.leased_memory()
  let runs = nodes.node(memory.backend, "lost-job-scan", nodes.long)
  let calls = probe.new()
  let build = fn(runs) {
    runtime(runs, 60_000, fn(_) {
      probe.gate(calls, "observing")
      Ok(job.Pending)
    })
  }
  let id = support.id("lost-job-scan")
  let assert Ok(handle) = graph.start(build(runs), id, "receipt")
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingJob(_) = waiting.status
  let assert Ok(spec) =
    fabric.sweeper(
      runs,
      [graph.recovery(run.DefinitionId("scheduled-flow", 1), build)],
      every: duration.milliseconds(60_000),
    )
  let assert Ok(started) = spec.start()
  let _ = probe.arrival(calls)
  process.unlink(started.pid)
  restart.kill(started.pid)
  let assert backend.Held(_, True) = nodes.holder(memory.backend, id)
  let finish = fn(runs) {
    runtime(runs, 60_000, fn(_) { Ok(job.Completed(42)) })
  }
  scan(runs, finish).claimed |> should.equal(0)
  memory.advance(nodes.long)
  scan(runs, finish).recovered |> should.equal(1)
  let assert Ok(done) = graph.read(handle)
  done.status |> should.equal(graph.Completed(42))
}

//// Database time determines job deadlines and cleanup poll intervals.

import fabric/budget
import fabric/graph
import fabric/graph/definition
import fabric/graph/job
import fabric/graph/operation
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/backend
import fabric/sweeper
import fabric_postgres
import fabric_postgres/agents
import fabric_postgres/support
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import pog

fn runtime(runs, read, request) {
  let observer =
    job.observe(
      run.DefinitionId("pg-expiring-job", 1),
      codec.string(),
      codec.int(),
      fn(_, _) { read() },
    )
    |> job.with_poll_interval(duration.milliseconds(20_000))
  let op =
    operation.own_job(observer, fn(_, _, _) { request() }, fn(error) { error })
    |> operation.with_deadline(run.After(duration.milliseconds(5000)))
  let node = definition.node_id("job")
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("pg-job-deadline", 1),
        entry: node,
        nodes: [
          definition.node(
            node,
            op,
            fn(receipt) { Ok(receipt) },
            fn(_, _) { panic as "expired job cannot route" },
            [],
          ),
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

fn store(settings) {
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("pg-job-deadline"), settings)
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn sweep(runs, build) {
  let assert Ok(started) =
    sweeper.start(
      runs,
      [sweeper.graph(run.DefinitionId("pg-job-deadline", 1), build)],
      every: duration.milliseconds(20),
    )
  started
}

fn released(backend: backend.LeasedBackend, left: Int) {
  let assert Ok(row) = backend.get("pg-job-deadline")
  case row.holder, left {
    backend.Free, _ -> Nil
    _, n if n > 0 -> {
      process.sleep(10)
      released(backend, n - 1)
    }
    _, _ -> panic as "job wait retained its lease"
  }
}

fn expired(handle, left) {
  let assert Ok(snapshot) = graph.snapshot(handle)
  case snapshot.status, left {
    graph.Expired(..), _ -> snapshot
    _, n if n > 0 -> {
      process.sleep(20)
      expired(handle, n - 1)
    }
    _, _ -> panic as "deadline cleanup did not settle"
  }
}

pub fn the_database_expires_before_the_next_poll_and_retains_cleanup_across_restart_test() {
  let connection = support.pool(4)
  let settings = support.migrated(connection, "job-deadline", support.schema())
  let backend = fabric_postgres.backend(settings)
  let observed = process.new_subject()
  let requested = process.new_subject()
  let assert Ok(id) = run.parse_id("pg-job-deadline")
  let pending = fn() {
    process.send(observed, Nil)
    Ok(job.Pending)
  }
  let #(owner, waiting) =
    agents.owned(fn() {
      let runs = store(settings)
      let build = fn(runs) {
        runtime(runs, pending, fn() { panic as "wait not due yet" })
      }
      let assert Ok(handle) =
        graph.start(
          support.budgeted(
            build(runs),
            budget.limits(work: 1)
              |> budget.with_children(1)
              |> budget.with_depth(1),
          ),
          id,
          "receipt",
          correlation: None,
        )
      let assert Ok(_) = graph.await(handle, within: duration.seconds(30))
      let assert Ok(waiting) = graph.snapshot(handle)
      let _ = sweep(runs, build)
      waiting
    })
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  process.receive(observed, 30_000) |> should.equal(Ok(Nil))
  released(backend, 3000)
  backend.claim_ready("early", 60_000, 10) |> should.equal(Ok([]))
  agents.kill(owner)
  let assert Ok(_) =
    pog.query(
      "SELECT true FROM pg_sleep(GREATEST(0, ($1::bigint - floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint)::double precision / 1000.0) + 0.02)",
    )
    |> pog.parameter(pog.int(due))
    |> pog.timeout(30_000)
    |> pog.execute(connection)
  let #(owner, handle) =
    agents.owned(fn() {
      let runs = store(settings)
      let build = fn(runs) {
        runtime(runs, pending, fn() {
          process.send(requested, Nil)
          Ok(Nil)
        })
      }
      let _ = sweep(runs, build)
      open_graph(build(runs), id)
    })
  process.receive(requested, 30_000) |> should.equal(Ok(Nil))
  process.receive(observed, 30_000) |> should.equal(Ok(Nil))
  released(backend, 3000)
  let assert Ok(cleanup) = graph.snapshot(handle)
  cleanup.status
  |> should.equal(graph.CancellingJob(
    reference,
    job.RequestAccepted,
    operation.DeadlineReached(due),
  ))
  fabric_postgres.prune(
    settings,
    ended_for: duration.milliseconds(0),
    limit: 10,
  )
  |> should.equal(Ok(0))
  backend.claim_ready("too-soon", 60_000, 10) |> should.equal(Ok([]))
  agents.kill(owner)
  let runs = store(settings)
  let build = fn(runs) {
    runtime(runs, fn() { Ok(job.Cancelled) }, fn() {
      panic as "saved stop must not repeat"
    })
  }
  let started = sweep(runs, build)
  let done = expired(open_graph(build(runs), id), 3000)
  done.status |> should.equal(graph.Expired(due, graph.JobStopped(reference)))
  process.receive(requested, 0) |> should.equal(Error(Nil))
  process.unlink(started)
  agents.kill(started)
  released(backend, 3000)
  fabric_postgres.prune(
    settings,
    ended_for: duration.milliseconds(0),
    limit: 10,
  )
  |> should.equal(Ok(2))
}

fn open_graph(
  runtime: graph.Runtime(context, state, answer),
  id: run.RunId,
) -> graph.Handle(context, state, answer) {
  let assert Ok(handle) = graph.open(runtime, id)
  handle
}

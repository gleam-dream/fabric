//// D9–D13: a real service retains the effects of deadline-triggered cleanup.

import fabric/budget
import fabric/graph
import fabric/graph/job
import fabric/graph/operation
import fabric/run
import fabric/store
import fabric/store/conformance
import fabric/sweeper
import fabric_jobs_demo as demo
import fabric_jobs_demo/client
import fabric_jobs_demo/support
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration
import gleeunit/should

fn id(name) {
  let assert Ok(id) = run.parse_id(name)
  id
}

fn leased(backend) {
  let assert Ok(runs) =
    store.leased(
      process.new_name("deadline-job"),
      node: "deadline",
      lease: duration.milliseconds(1000),
      backend:,
    )
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn submit(invocation, request) {
  client.submit(support.url(), invocation, request)
}

fn stop(_, receipt) {
  client.request_cancel(support.url(), receipt) |> result.replace(Nil)
}

fn settle(runs, build, id) {
  let assert Ok(started) =
    sweeper.start(
      runs,
      [sweeper.graph(run.DefinitionId("artifact-submit-and-wait", 1), build)],
      every: duration.milliseconds(20),
    )
  let done = await_expired(open_graph(build(runs), id), 1500)
  process.unlink(started)
  process.kill(started)
  done
}

fn await_expired(handle, remaining) {
  let assert Ok(snapshot) = graph.snapshot(handle)
  case snapshot.status, remaining {
    graph.Expired(..), _ -> snapshot
    _, n if n > 0 -> {
      process.sleep(20)
      await_expired(handle, n - 1)
    }
    _, _ -> panic as "real job expiration did not settle"
  }
}

pub fn a_restarted_sweeper_expires_and_stops_a_real_owned_job_test() {
  let storage = conformance.leased_memory()
  let #(owner, runs) = support.owned(fn() { leased(storage.backend) })
  let assert Ok(handle) =
    graph.start(
      graph.with_family_budget(
        demo.deadline_runtime(runs, submit, stop, support.url(), 60_000),
        budget.limits(work: 2)
          |> budget.with_children(1)
          |> budget.with_depth(1),
      ),
      id("deadline-real-job"),
      demo.Submitting(client.Request("never published after expiry", 5000)),
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  let assert demo.Accepted(receipt) = waiting.value
  client.read(support.url(), receipt) |> should.equal(Ok(client.Queued))
  support.crash(owner, runs)
  storage.advance(60_001)
  let runs = leased(storage.backend)
  let build = fn(runs) {
    demo.deadline_runtime(
      runs,
      fn(_, _) { panic as "retained submission must not repeat" },
      stop,
      support.url(),
      60_000,
    )
  }
  let done = settle(runs, build, id("deadline-real-job"))
  done.status |> should.equal(graph.Expired(due, graph.JobStopped(reference)))
  list.length(done.receipts) |> should.equal(1)
  client.read(support.url(), receipt) |> should.equal(Ok(client.Cancelled))
  client.artifact(support.url(), receipt) |> should.be_error
}

pub fn a_lost_deadline_stop_acknowledgment_is_observed_without_repeating_the_request_test() {
  let storage = conformance.leased_memory()
  let #(owner, runs) = support.owned(fn() { leased(storage.backend) })
  let accepted = process.new_subject()
  let request = fn(invocation, receipt) {
    let assert Ok(Nil) = stop(invocation, receipt)
    process.send(accepted, Nil)
    let never: process.Subject(Nil) = process.new_subject()
    process.receive_forever(never)
    Ok(Nil)
  }
  let assert Ok(handle) =
    graph.start(
      demo.deadline_runtime(runs, submit, request, support.url(), 60_000),
      id("deadline-lost-stop"),
      demo.Submitting(client.Request("expired lost acknowledgment", 5000)),
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  storage.advance(60_001)
  let assert Ok(_) = graph.recover(handle)
  process.receive(accepted, 5000) |> should.equal(Ok(Nil))
  support.crash(owner, runs)
  storage.advance(1001)
  let runs = leased(storage.backend)
  let build = fn(runs) {
    demo.deadline_runtime(
      runs,
      fn(_, _) { panic },
      fn(_, _) { panic as "uncertain deadline stop must not replay" },
      support.url(),
      60_000,
    )
  }
  let handle = open_graph(build(runs), id("deadline-lost-stop"))
  let assert Ok(recovered) = graph.recover(handle)
  let assert graph.CancellingJob(
    _,
    job.RequestUncertain(_),
    operation.DeadlineReached(saved_due),
  ) = recovered
  saved_due |> should.equal(due)
  settle(runs, build, id("deadline-lost-stop")).status
  |> should.equal(graph.Expired(due, graph.JobStopped(reference)))
}

fn open_graph(
  runtime: graph.Runtime(context, state, answer),
  id: run.RunId,
) -> graph.Handle(context, state, answer) {
  let assert Ok(handle) = graph.open(runtime, id)
  handle
}

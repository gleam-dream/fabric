//// J1–J5: public Fabric APIs against a separate durable HTTP job service.

import fabric/graph
import fabric/graph/operation
import fabric/run
import fabric/store
import fabric_jobs_demo as demo
import fabric_jobs_demo/client
import fabric_jobs_demo/support
import gleam/erlang/process
import gleam/list
import gleeunit
import gleeunit/should
import json/blueprint/codec

pub fn main() -> Nil {
  gleeunit.main()
}

fn id(name) {
  let assert Ok(id) = run.parse_id(name)
  id
}

fn runtime(runs, send) {
  demo.runtime(runs, send, operation.ReplayInterrupted(3))
}

fn memory() {
  let runs = store.in_memory(process.new_name("job-example"))
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn send(invocation, request) {
  client.submit(support.url(), invocation, request)
}

fn await_job(receipt, tries) {
  let assert Ok(status) = client.read(support.url(), receipt)
  case status {
    client.Complete(_) -> status
    client.Queued if tries > 0 -> {
      process.sleep(20)
      await_job(receipt, tries - 1)
    }
    client.Queued -> panic as "external job did not finish"
  }
}

pub fn an_acceptance_receipt_does_not_claim_business_completion_test() {
  let assert Ok(handle) =
    graph.start(
      runtime(memory(), send),
      id("receipt-before-work"),
      client.Request("Fabric composes jobs", 2000),
    )
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Completed(receipt) = done.status
  client.read(support.url(), receipt) |> should.equal(Ok(client.Queued))
  let assert client.Complete(digest) = await_job(receipt, 200)
  client.artifact(support.url(), receipt)
  |> should.equal(Ok("FABRIC COMPOSES JOBS"))
  digest |> should.equal(support.sha256("FABRIC COMPOSES JOBS"))
  // The receipt remains the graph answer after the service completes its work.
  graph.read(handle) |> should.equal(Ok(done))
}

pub fn lost_acceptance_acknowledgement_replays_the_same_logical_submission_test() {
  let directory = support.temp_dir()
  let accepted = process.new_subject()
  let #(owner, runs) = support.owned(fn() { support.directory(directory) })
  let submit = fn(invocation, request) {
    let assert Ok(receipt) = send(invocation, request)
    process.send(accepted, receipt)
    let never: process.Subject(Nil) = process.new_subject()
    process.receive_forever(never)
    Ok(receipt)
  }
  let assert Ok(handle) =
    graph.start(
      runtime(runs, submit),
      id("lost-acceptance"),
      client.Request("survives Fabric", 1000),
    )
  let assert Ok(receipt) = process.receive(accepted, 5000)
  let assert Ok(before) = graph.read(handle)
  before.receipts |> should.equal([])
  client.read(support.url(), receipt) |> should.equal(Ok(client.Queued))
  support.crash(owner, runs)
  let runs = support.directory(directory)
  let handle = graph.attach(runtime(runs, send), id("lost-acceptance"))
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(done) = graph.await(handle, 5000)
  done.status |> should.equal(graph.Completed(receipt))
  let assert [saved] = done.receipts
  saved.activation |> should.equal(1)
  saved.attempt |> should.equal(2)
  await_job(receipt, 100)
  |> should.equal(client.Complete(support.sha256("SURVIVES FABRIC")))
  client.artifact(support.url(), receipt) |> should.equal(Ok("SURVIVES FABRIC"))
  support.remove_dir(directory)
}

pub fn a_saved_receipt_survives_restart_without_another_submission_test() {
  let directory = support.temp_dir()
  let #(owner, #(runs, handle)) =
    support.owned(fn() {
      let runs = support.directory(directory)
      let assert Ok(handle) =
        graph.start(
          runtime(runs, send),
          id("saved-receipt"),
          client.Request("saved", 0),
        )
      #(runs, handle)
    })
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Completed(receipt) = done.status
  support.crash(owner, runs)
  let runs = support.directory(directory)
  let restored =
    runtime(runs, fn(_, _) { panic as "saved acceptance must not submit again" })
  let handle = graph.attach(restored, id("saved-receipt"))
  let assert Ok(recovered) = graph.recover(handle)
  recovered.status |> should.equal(graph.Completed(receipt))
  recovered.receipts |> should.equal(done.receipts)
  support.remove_dir(directory)
}

pub fn an_unrepeatable_submission_stays_uncertain_until_receipt_reconciliation_test() {
  let directory = support.temp_dir()
  let accepted = process.new_subject()
  let #(owner, runs) = support.owned(fn() { support.directory(directory) })
  let submit = fn(invocation, request) {
    let assert Ok(receipt) = send(invocation, request)
    process.send(accepted, receipt)
    let never: process.Subject(Nil) = process.new_subject()
    process.receive_forever(never)
    Ok(receipt)
  }
  let runtime = demo.runtime(runs, submit, operation.RequireReconciliation)
  let assert Ok(_) =
    graph.start(
      runtime,
      id("uncertain-submission"),
      client.Request("uncertain", 0),
    )
  let assert Ok(receipt) = process.receive(accepted, 5000)
  support.crash(owner, runs)
  let runtime =
    demo.runtime(
      support.directory(directory),
      fn(_, _) { panic as "unsafe submission must not repeat" },
      operation.RequireReconciliation,
    )
  let handle = graph.attach(runtime, id("uncertain-submission"))
  let assert Ok(blocked) = graph.recover(handle)
  let assert graph.Blocked(reference, graph.EffectUncertain(_)) = blocked.status
  let assert Ok(encoded) = codec.encode_json(client.receipt_codec(), receipt)
  let assert Ok(done) = graph.reconcile(handle, reference, encoded)
  done.status |> should.equal(graph.Completed(receipt))
  support.remove_dir(directory)
}

pub fn concurrent_submissions_share_one_receipt_and_reject_different_input_test() {
  let invocation = operation.Invocation(id("concurrent-submission"), 1, 1)
  let request = client.Request("one artifact", 0)
  let assert Ok(before) = client.count(support.url())
  let replies = process.new_subject()
  list.each([1, 2, 3, 4, 5, 6, 7, 8], fn(attempt) {
    process.spawn(fn() {
      process.send(
        replies,
        send(operation.Invocation(..invocation, attempt: attempt), request),
      )
    })
  })
  let receipts =
    list.map([1, 2, 3, 4, 5, 6, 7, 8], fn(_) {
      let assert Ok(Ok(receipt)) = process.receive(replies, 5000)
      receipt
    })
  list.unique(receipts) |> list.length |> should.equal(1)
  client.count(support.url()) |> should.equal(Ok(before + 1))
  let assert Error(client.Rejected(409, _)) =
    send(invocation, client.Request("different artifact", 0))
  client.count(support.url()) |> should.equal(Ok(before + 1))
  let assert Ok(next_visit) =
    send(operation.Invocation(..invocation, activation: 2), request)
  list.contains(receipts, next_visit) |> should.be_false
  client.count(support.url()) |> should.equal(Ok(before + 2))
}

fn poll_attachment(handle, reference, tries) {
  let assert Ok(snapshot) = graph.poll_job(handle, reference)
  case snapshot.status {
    graph.Completed(_) -> snapshot
    graph.AwaitingJob(_) if tries > 0 -> {
      process.sleep(20)
      poll_attachment(handle, reference, tries - 1)
    }
    _ -> panic as "job attachment did not complete"
  }
}

pub fn a_retained_job_attachment_survives_restart_without_resubmitting_test() {
  let directory = support.temp_dir()
  let #(owner, #(runs, handle)) =
    support.owned(fn() {
      let runs = support.directory(directory)
      let assert Ok(handle) =
        graph.start(
          demo.waiting_runtime(runs, send, support.url()),
          id("attached-job"),
          demo.Submitting(client.Request("attached output", 1000)),
        )
      #(runs, handle)
    })
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert demo.Accepted(receipt) = waiting.value
  client.read(support.url(), receipt) |> should.equal(Ok(client.Queued))
  list.length(waiting.receipts) |> should.equal(1)
  support.crash(owner, runs)
  let restored =
    demo.waiting_runtime(
      support.directory(directory),
      fn(_, _) { panic as "attachment must reuse accepted receipt" },
      support.url(),
    )
  let handle = graph.attach(restored, id("attached-job"))
  let assert Ok(recovered) = graph.recover(handle)
  recovered.status |> should.equal(waiting.status)
  let done = poll_attachment(handle, reference, 150)
  done.status
  |> should.equal(graph.Completed(support.sha256("ATTACHED OUTPUT")))
  list.length(done.receipts) |> should.equal(2)
  graph.poll_job(handle, reference) |> should.equal(Ok(done))
  support.remove_dir(directory)
}

pub fn canceling_a_read_only_attachment_leaves_the_real_remote_job_running_test() {
  let assert Ok(handle) =
    graph.start(
      demo.waiting_runtime(memory(), send, support.url()),
      id("detached-job"),
      demo.Submitting(client.Request("still external", 1000)),
    )
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingJob(reference) = waiting.status
  let assert demo.Accepted(receipt) = waiting.value
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(cancelled) = graph.read(handle)
  cancelled.status
  |> should.equal(graph.Cancelled(graph.JobDetached(reference)))
  list.length(cancelled.receipts) |> should.equal(1)
  graph.poll_job(handle, reference) |> should.be_error
  await_job(receipt, 150)
  |> should.equal(client.Complete(support.sha256("STILL EXTERNAL")))
  client.artifact(support.url(), receipt) |> should.equal(Ok("STILL EXTERNAL"))
  graph.read(handle) |> should.equal(Ok(cancelled))
}

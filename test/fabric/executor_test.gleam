//// The common executor contract through actual process/effect boundaries.

import fabric/internal/executor
import fabric/support/probe
import fabric/support/restart
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import gleeunit/should

type Visit {
  Visit(node: String, ordinal: Int)
}

type Decision {
  Score(Int)
}

pub fn graph_identity_and_typed_result_use_the_shared_executor_test() {
  let reports = process.new_subject()
  let executor =
    executor.start(
      executor.Hooks(
        max_in_flight: 1,
        fence: fn(_: Visit) { True },
        report: fn(report) { process.send(reports, report) },
      ),
    )
  let visit = Visit("review", 3)
  executor.submit(executor, [executor.Job(visit, fn() { Score(4) }, None)])
  process.receive(reports, 1000)
  |> should.equal(Ok(executor.Reported(visit, Score(4))))
  executor.stop(executor)
  process.receive(reports, 1000) |> should.equal(Ok(executor.Stopped))
}

pub fn refused_fence_never_performs_its_effect_test() {
  let reports = process.new_subject()
  let inspected = process.new_subject()
  let ledger = probe.new()
  let executor =
    executor.start(
      executor.Hooks(
        max_in_flight: 1,
        fence: fn(visit: Visit) {
          process.send(inspected, visit)
          False
        },
        report: fn(report) { process.send(reports, report) },
      ),
    )
  let visit = Visit("publish", 4)
  executor.submit(executor, [
    executor.Job(visit, fn() { probe.record(ledger, "published") }, None),
  ])
  process.receive(inspected, 1000) |> should.equal(Ok(visit))
  executor.stop(executor)
  process.receive(reports, 1000) |> should.equal(Ok(executor.Stopped))
  probe.entries(ledger) |> should.equal([])
}

pub fn crash_stays_distinct_from_a_returned_result_test() {
  let reports = process.new_subject()
  let executor =
    executor.start(
      executor.Hooks(
        max_in_flight: 1,
        fence: fn(_: Visit) { True },
        report: fn(report) { process.send(reports, report) },
      ),
    )
  let crashing = Visit("request", 7)
  let succeeding = Visit("review", 8)
  executor.submit(executor, [
    executor.Job(crashing, fn() { panic as "body failed" }, None),
    executor.Job(succeeding, fn() { Score(2) }, None),
  ])
  let assert Ok(executor.Crashed(found, evidence)) =
    process.receive(reports, 1000)
  found |> should.equal(crashing)
  string.contains(evidence, "body failed") |> should.be_true
  process.receive(reports, 1000)
  |> should.equal(Ok(executor.Reported(succeeding, Score(2))))
  executor.stop(executor)
  process.receive(reports, 1000) |> should.equal(Ok(executor.Stopped))
}

pub fn stop_settles_running_tasks_without_starting_queued_work_test() {
  let reports = process.new_subject()
  let ledger = probe.new()
  let executor =
    executor.start(
      executor.Hooks(
        max_in_flight: 1,
        fence: fn(_: Visit) { True },
        report: fn(report) { process.send(reports, report) },
      ),
    )
  executor.submit(executor, [
    executor.Job(
      Visit("request", 1),
      fn() {
        probe.record(ledger, "started")
        probe.gate(ledger, "held")
      },
      None,
    ),
    executor.Job(
      Visit("request", 2),
      fn() { probe.record(ledger, "must not start") },
      None,
    ),
  ])
  let _ = probe.arrival(ledger)
  executor.stop(executor)
  process.receive(reports, 1000) |> should.equal(Ok(executor.Stopped))
  probe.entries(ledger) |> should.equal(["started"])
}

pub fn losing_the_owner_kills_the_body_test() {
  let worker = process.new_subject()
  let #(owner, _) =
    restart.owned(fn() {
      let executor =
        executor.start(
          executor.Hooks(
            max_in_flight: 1,
            fence: fn(_: Visit) { True },
            report: fn(_) { Nil },
          ),
        )
      executor.submit(executor, [
        executor.Job(
          Visit("held", 1),
          fn() {
            let hold: process.Subject(Nil) = process.new_subject()
            process.send(worker, process.self())
            process.receive_forever(hold)
          },
          None,
        ),
      ])
    })
  let assert Ok(body) = process.receive(worker, 1000)
  restart.kill(owner)
  restart.gone(body)
}

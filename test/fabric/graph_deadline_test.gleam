//// D4–D8: deadlines belong to admitted activations and survive store loss.

import fabric
import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/graph/signal
import fabric/observation
import fabric/policy
import fabric/run
import fabric/store
import fabric/support/nodes
import fabric/support/probe
import fabric/support/restart
import fabric/testing
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleeunit/should
import json/blueprint/codec
import sinal

fn id(name) {
  let assert Ok(id) = run.parse_id(name)
  id
}

fn answer() {
  signal.new(run.Identity("deadline-answer", 1), codec.bool())
}

fn runtime(runs, inspect) {
  runtime_with(runs, inspect, 60_000, fn(n, done, node) {
    case done {
      True -> Ok(definition.Finish(n, n))
      False -> Ok(definition.Continue(n + 1, node))
    }
  })
}

fn runtime_with(runs, inspect, within, accept) {
  let assert Ok(node) = definition.node_id("wait")
  let assert Ok(wait) =
    operation.await_signal(codec.int(), answer())
    |> operation.with_deadline(within)
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("deadline-loop", 1),
      node,
      [
        definition.node(
          node,
          wait,
          fn(n) { Ok(n) },
          fn(n, done) { accept(n, done, node) },
          [node],
        ),
      ],
      codec.int(),
      codec.int(),
      3,
    ))
  graph.new(spec, runs, fn() { Nil }, inspect)
}

pub fn deadline_configuration_is_bounded_and_part_of_definition_compatibility_test() {
  let wait = operation.await_signal(codec.int(), answer())
  operation.with_deadline(wait, 0) |> should.be_error
  operation.with_deadline(wait, -1) |> should.be_error
  operation.with_deadline(wait, 4_294_967_296) |> should.be_error
  operation.with_deadline(wait, 4_294_967_295) |> should.be_ok
  let activity =
    operation.new(
      run.Identity("body", 1),
      codec.int(),
      codec.int(),
      fn(_, _, n) { Ok(n) },
      fn(_error: Nil) { operation.DefiniteFailure("none") },
    )
  operation.with_deadline(activity, 1000)
  |> should.equal(Error(operation.DeadlineRequiresSignal))
  let memory = testing.leased_memory()
  let runs = nodes.node(memory.backend, "definition", nodes.long)
  let assert Ok(handle) =
    graph.start(
      runtime(runs, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-contract"),
      1,
    )
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let changed =
    graph.attach(
      runtime_with(runs, fn(_, _) { Ok(policy.Allow) }, 120_000, fn(n, _, _) {
        Ok(definition.Finish(n, n))
      }),
      id("deadline-contract"),
    )
  graph.recover(changed) |> should.be_error
  graph.deliver(changed, reference, answer(), True) |> should.be_error
}

pub fn interrupted_arming_recovers_once_without_repeating_policy_test() {
  let memory = testing.leased_memory()
  let calls = probe.new()
  let backend =
    store.LeasedBackend(..memory.backend, now: fn() {
      probe.record(calls, "clock")
      case probe.count(calls, "clock") {
        1 -> Error(store.Unavailable("clock offline"))
        _ -> memory.backend.now()
      }
    })
  let runs = nodes.node(backend, "arming", nodes.long)
  let assert Ok(handle) =
    graph.start(
      runtime(runs, fn(_, _) {
        probe.record(calls, "policy")
        Ok(policy.Allow)
      }),
      id("deadline-arming"),
      1,
    )
  let assert Ok(interrupted) = graph.await(handle, 5000)
  interrupted.status |> should.equal(graph.Unattended)
  interrupted.deadline |> should.equal(None)
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingSignal(_) = waiting.status
  let assert Some(_) = waiting.deadline
  probe.count(calls, "policy") |> should.equal(1)
  let assert Ok(unchanged) = graph.recover(handle)
  unchanged.deadline |> should.equal(waiting.deadline)
  unchanged.revision |> should.equal(waiting.revision)
}

pub fn a_clock_failure_refuses_delivery_but_allows_explicit_cancellation_test() {
  let memory = testing.leased_memory()
  let calls = probe.new()
  let backend =
    store.LeasedBackend(..memory.backend, now: fn() {
      case probe.count(calls, "offline") {
        0 -> memory.backend.now()
        _ -> Error(store.Unavailable("clock offline"))
      }
    })
  let runs = nodes.node(backend, "clock-failure", nodes.long)
  let assert Ok(handle) =
    graph.start(
      runtime(runs, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-clock-failure"),
      1,
    )
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingSignal(reference) = waiting.status
  probe.record(calls, "offline")
  graph.deliver(handle, reference, answer(), True)
  |> should.equal(Error(graph.StoreFailed(store.Unavailable("clock offline"))))
  let assert Ok(unchanged) = graph.read(handle)
  unchanged.revision |> should.equal(waiting.revision)
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(cancelled) = graph.read(handle)
  cancelled.status |> should.equal(graph.Cancelled(graph.BeforeStart))
}

pub fn a_delivery_that_crosses_the_deadline_during_acceptance_cannot_route_test() {
  let memory = testing.leased_memory()
  let runs = nodes.node(memory.backend, "slow-route", nodes.long)
  let spec =
    runtime_with(runs, fn(_, _) { Ok(policy.Allow) }, 60_000, fn(n, _, _) {
      memory.advance(60_001)
      Ok(definition.Finish(n, n))
    })
  let assert Ok(handle) = graph.start(spec, id("deadline-slow-route"), 1)
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  let assert Ok(expired) = graph.deliver(handle, reference, answer(), True)
  expired.status |> should.equal(graph.Failed(graph.DeadlineExpired(due)))
  expired.receipts |> should.equal([])
}

fn scan(runs) {
  let events = process.new_subject()
  let assert Ok(handler) =
    sinal.handler_id(
      "deadline-scan-" <> int.to_string(int.random(1_000_000_000)),
    )
  let assert Ok(attached) =
    sinal.observe(handler, observation.sweep(), fn(summary, _) {
      process.send(events, summary)
    })
  let assert Ok(spec) =
    fabric.sweeper(
      runs,
      [
        graph.recovery(run.Identity("deadline-loop", 1), fn(runs) {
          runtime(runs, fn(_, _) { Ok(policy.Allow) })
        }),
      ],
      every: 60_000,
    )
  let assert Ok(started) = spec.start()
  let assert Ok(summary) = process.receive(events, 5000)
  process.unlink(started.pid)
  restart.kill(started.pid)
  let _ = sinal.detach(attached)
  summary
}

pub fn due_discovery_expires_a_wait_after_store_loss_without_manual_delivery_test() {
  let memory = testing.leased_memory()
  let #(owner, runs) =
    restart.owned(fn() {
      nodes.node(memory.backend, "old-deadline", nodes.long)
    })
  let assert Ok(handle) =
    graph.start(
      runtime(runs, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-scan"),
      1,
    )
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert Some(due) = waiting.deadline
  scan(runs).claimed |> should.equal(0)
  memory.advance(60_001)
  restart.crash(owner, runs)
  let restored = nodes.node(memory.backend, "new-deadline", nodes.long)
  scan(restored).claimed |> should.equal(1)
  let handle =
    graph.attach(
      runtime(restored, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-scan"),
    )
  let assert Ok(expired) = graph.read(handle)
  expired.status |> should.equal(graph.Failed(graph.DeadlineExpired(due)))
  nodes.holder(memory.backend, id("deadline-scan")) |> should.equal(store.Free)
  scan(restored).claimed |> should.equal(0)
}

pub fn a_clock_correction_releases_the_claim_without_resetting_the_due_time_test() {
  let memory = testing.leased_memory()
  let runs = nodes.node(memory.backend, "corrected-clock", nodes.long)
  let assert Ok(handle) =
    graph.start(
      runtime(runs, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-correction"),
      1,
    )
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert Some(due) = waiting.deadline
  memory.advance(60_001)
  store.claim_ready(runs, 1) |> should.equal(Ok(["deadline-correction"]))
  memory.advance(-120_000)
  let assert Ok(early) = graph.recover(handle)
  early.status |> should.equal(waiting.status)
  early.deadline |> should.equal(waiting.deadline)
  nodes.holder(memory.backend, id("deadline-correction"))
  |> should.equal(store.Free)
  store.claim_ready(runs, 1) |> should.equal(Ok([]))
  memory.advance(120_001)
  store.claim_ready(runs, 1) |> should.equal(Ok(["deadline-correction"]))
  let assert Ok(expired) = graph.recover(handle)
  expired.status |> should.equal(graph.Failed(graph.DeadlineExpired(due)))
}

pub fn an_expiration_commit_wins_against_an_in_progress_delivery_test() {
  let memory = testing.leased_memory()
  let runs = nodes.node(memory.backend, "deadline-race", nodes.long)
  let route = probe.new()
  let spec =
    runtime_with(runs, fn(_, _) { Ok(policy.Allow) }, 60_000, fn(n, _, _) {
      probe.gate(route, "route")
      Ok(definition.Finish(n, n))
    })
  let assert Ok(handle) = graph.start(spec, id("deadline-race"), 1)
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  let reply = process.new_subject()
  process.spawn(fn() {
    process.send(reply, graph.deliver(handle, reference, answer(), True))
  })
  let held = probe.arrival(route)
  memory.advance(60_001)
  let assert Ok(expired) = graph.recover(handle)
  expired.status |> should.equal(graph.Failed(graph.DeadlineExpired(due)))
  probe.release(held)
  let assert Ok(Error(graph.CommandRefused(_))) = process.receive(reply, 5000)
  let assert Ok(unchanged) = graph.read(handle)
  unchanged.revision |> should.equal(expired.revision)
  unchanged.receipts |> should.equal([])
}

pub fn overdue_waits_expire_after_restart_without_a_signal_or_runner_test() {
  let memory = testing.leased_memory()
  let #(owner, runs) =
    restart.owned(fn() { nodes.node(memory.backend, "deadline", nodes.long) })
  let spec = runtime(runs, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) = graph.start(spec, id("deadline-restart"), 7)
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  let assert Ok(row) = store.get(runs, "deadline-restart")
  row.live |> should.equal(None)
  memory.advance(60_001)
  restart.crash(owner, runs)
  let restored = nodes.node(memory.backend, "deadline", nodes.long)
  let handle =
    graph.attach(
      runtime(restored, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-restart"),
    )
  let assert Ok(expired) = graph.recover(handle)
  expired.status |> should.equal(graph.Failed(graph.DeadlineExpired(due)))
  expired.receipts |> should.equal([])
  let assert Error(graph.CommandRefused(_)) =
    graph.deliver(handle, reference, answer(), True)
}

pub fn approval_does_not_start_the_clock_and_revisits_get_new_deadlines_test() {
  let memory = testing.leased_memory()
  let runs = nodes.node(memory.backend, "deadline", nodes.long)
  let spec =
    runtime(runs, fn(_, _) {
      Ok(policy.RequireApproval(run.Requirement("publish", 1)))
    })
  let assert Ok(handle) = graph.start(spec, id("deadline-approval"), 0)
  let assert Ok(pending) = graph.await(handle, 5000)
  let assert graph.AwaitingApproval(approval) = pending.status
  pending.deadline |> should.equal(None)
  memory.advance(120_000)
  let assert Ok(approved) = graph.approve(handle, approval)
  let assert Ok(first) = graph.await(handle, 5000)
  let assert graph.AwaitingSignal(reference) = first.status
  let assert Some(due) = first.deadline
  let assert Ok(now) = store.now(runs)
  should.be_true(due > now + 50_000)
  let _ = approved
  memory.advance(10_000)
  let assert Ok(_) = graph.deliver(handle, reference, answer(), False)
  let assert Ok(pending) = graph.await(handle, 5000)
  let assert graph.AwaitingApproval(approval) = pending.status
  let assert Ok(_) = graph.approve(handle, approval)
  let assert Ok(second) = graph.await(handle, 5000)
  let assert Some(next_due) = second.deadline
  should.be_true(next_due >= due + 10_000)
  let assert Ok(duplicate) = graph.deliver(handle, reference, answer(), False)
  duplicate.revision |> should.equal(second.revision)
  duplicate.deadline |> should.equal(second.deadline)
}

pub fn late_delivery_commits_expiration_without_accepting_the_result_test() {
  let memory = testing.leased_memory()
  let runs = nodes.node(memory.backend, "deadline", nodes.long)
  let assert Ok(handle) =
    graph.start(
      runtime(runs, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-delivery"),
      1,
    )
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  memory.advance(60_001)
  let assert Ok(expired) = graph.deliver(handle, reference, answer(), True)
  expired.status |> should.equal(graph.Failed(graph.DeadlineExpired(due)))
  expired.receipts |> should.equal([])
}

//// D4–D8: deadlines belong to admitted activations and survive store loss.

import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/graph/signal
import fabric/internal/store as store_core
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/backend
import fabric/store/conformance
import fabric/support
import fabric/support/nodes
import fabric/support/probe
import fabric/support/restart
import fabric/sweeper
import fabric/telemetry
import fabric/tool
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import sinal

fn id(name) {
  let assert Ok(id) = run.parse_id(name)
  id
}

fn answer() {
  signal.new(run.DefinitionId("deadline-answer", 1), codec.bool())
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
  let node = definition.node_id("wait")
  let wait =
    operation.await_signal(codec.int(), answer())
    |> operation.with_deadline(run.After(duration.milliseconds(within)))
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("deadline-loop", 1),
        entry: node,
        nodes: [
          definition.node(
            node,
            wait,
            fn(n) { Ok(n) },
            fn(n, done) { accept(n, done, node) },
            [node],
          ),
        ],
        state: codec.int(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(3),
    )
  graph.new(spec, runs, fn(_) { Nil }, inspect) |> graph.build |> should.be_ok
}

pub fn deadline_configuration_is_bounded_and_part_of_definition_compatibility_test() {
  let wait = operation.await_signal(codec.int(), answer())
  operation.with_deadline(wait, run.After(duration.milliseconds(0)))
  |> support.operation_problems
  |> should.not_equal([])
  operation.with_deadline(wait, run.After(duration.milliseconds(-1)))
  |> support.operation_problems
  |> should.not_equal([])
  operation.with_deadline(wait, run.After(duration.milliseconds(4_294_967_296)))
  |> support.operation_problems
  |> should.not_equal([])
  operation.with_deadline(wait, run.After(duration.milliseconds(4_294_967_295)))
  |> support.operation_problems
  |> should.equal([])
  let activity =
    operation.new(
      run.DefinitionId("body", 1),
      codec.int(),
      codec.int(),
      fn(_, _, n) { Ok(n) },
      fn(_error: Nil) { tool.Explain("none") },
    )
  operation.with_deadline(activity, run.After(duration.milliseconds(1000)))
  |> support.operation_problems
  |> should.equal([operation.DeadlineRequiresWait])
  let memory = conformance.leased_memory()
  let runs = nodes.node(memory.backend, "definition", nodes.long)
  let assert Ok(handle) =
    graph.start(
      runtime(runs, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-contract"),
      1,
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingSignal(reference) = waiting
  // Another deadline is another stored contract: the run does not open
  // under it, and the wait is unchanged.
  let changed =
    runtime_with(runs, fn(_, _) { Ok(policy.Allow) }, 120_000, fn(n, _, _) {
      Ok(definition.Finish(n, n))
    })
  let assert Error(graph.IncompatibleDefinition(_)) =
    graph.open(changed, id("deadline-contract"))
  let assert Ok(unchanged) = graph.snapshot(handle)
  unchanged.status |> should.equal(graph.AwaitingSignal(reference))
}

pub fn interrupted_arming_recovers_once_without_repeating_policy_test() {
  let memory = conformance.leased_memory()
  let calls = probe.new()
  let backend =
    backend.LeasedBackend(..memory.backend, now: fn() {
      probe.record(calls, "clock")
      case probe.count(calls, "clock") {
        1 -> Error(backend.Unavailable("clock offline"))
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
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(interrupted) = graph.snapshot(handle)
  interrupted.status |> should.equal(graph.Unattended)
  interrupted.deadline |> should.equal(None)
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(_) = waiting.status
  let assert Some(_) = waiting.deadline
  probe.count(calls, "policy") |> should.equal(1)
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(unchanged) = graph.snapshot(handle)
  unchanged.deadline |> should.equal(waiting.deadline)
  unchanged.revision |> should.equal(waiting.revision)
}

pub fn a_clock_failure_refuses_delivery_but_allows_explicit_cancellation_test() {
  let memory = conformance.leased_memory()
  let calls = probe.new()
  let backend =
    backend.LeasedBackend(..memory.backend, now: fn() {
      case probe.count(calls, "offline") {
        0 -> memory.backend.now()
        _ -> Error(backend.Unavailable("clock offline"))
      }
    })
  let runs = nodes.node(backend, "clock-failure", nodes.long)
  let assert Ok(handle) =
    graph.start(
      runtime(runs, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-clock-failure"),
      1,
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(reference) = waiting.status
  probe.record(calls, "offline")
  graph.deliver(handle, reference, answer(), True)
  |> should.equal(Error(graph.StoreUnavailable("clock offline")))
  let assert Ok(unchanged) = graph.snapshot(handle)
  unchanged.revision |> should.equal(waiting.revision)
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(cancelled) = graph.snapshot(handle)
  cancelled.status |> should.equal(graph.Cancelled(graph.BeforeStart))
}

pub fn a_delivery_that_crosses_the_deadline_during_acceptance_cannot_route_test() {
  let memory = conformance.leased_memory()
  let runs = nodes.node(memory.backend, "slow-route", nodes.long)
  let spec =
    runtime_with(runs, fn(_, _) { Ok(policy.Allow) }, 60_000, fn(n, _, _) {
      memory.advance(60_001)
      Ok(definition.Finish(n, n))
    })
  let assert Ok(handle) =
    graph.start(spec, id("deadline-slow-route"), 1, correlation: None)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  let assert Ok(_) = graph.deliver(handle, reference, answer(), True)
  let assert Ok(expired) = graph.snapshot(handle)
  expired.status |> should.equal(graph.Failed(graph.DeadlineExpired(due)))
  expired.receipts |> should.equal([])
}

fn scan(runs) {
  let events = process.new_subject()
  let attached =
    sinal.observe(telemetry.sweep(), fn(summary, _) {
      process.send(events, summary)
    })
  let assert Ok(started) =
    sweeper.start(
      runs,
      [
        sweeper.graph(run.DefinitionId("deadline-loop", 1), fn(runs) {
          runtime(runs, fn(_, _) { Ok(policy.Allow) })
        }),
      ],
      every: duration.milliseconds(60_000),
    )
  let assert Ok(summary) = process.receive(events, 30_000)
  process.unlink(started)
  restart.kill(started)
  let _ = sinal.detach(attached)
  summary
}

pub fn due_discovery_expires_a_wait_after_store_loss_without_manual_delivery_test() {
  let memory = conformance.leased_memory()
  let #(owner, runs) =
    restart.owned(fn() {
      nodes.node(memory.backend, "old-deadline", nodes.long)
    })
  let assert Ok(handle) =
    graph.start(
      runtime(runs, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-scan"),
      1,
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert Some(due) = waiting.deadline
  scan(runs).claimed |> should.equal(0)
  memory.advance(60_001)
  restart.crash(owner, runs)
  let restored = nodes.node(memory.backend, "new-deadline", nodes.long)
  scan(restored).claimed |> should.equal(1)
  let handle =
    support.open_graph(
      runtime(restored, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-scan"),
    )
  let assert Ok(expired) = graph.snapshot(handle)
  expired.status |> should.equal(graph.Failed(graph.DeadlineExpired(due)))
  nodes.holder(memory.backend, id("deadline-scan"))
  |> should.equal(backend.Free)
  scan(restored).claimed |> should.equal(0)
}

pub fn a_clock_correction_releases_the_claim_without_resetting_the_due_time_test() {
  let memory = conformance.leased_memory()
  let runs = nodes.node(memory.backend, "corrected-clock", nodes.long)
  let assert Ok(handle) =
    graph.start(
      runtime(runs, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-correction"),
      1,
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert Some(due) = waiting.deadline
  memory.advance(60_001)
  store_core.claim_ready(runs, 1) |> should.equal(Ok(["deadline-correction"]))
  memory.advance(-120_000)
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(early) = graph.snapshot(handle)
  early.status |> should.equal(waiting.status)
  early.deadline |> should.equal(waiting.deadline)
  nodes.holder(memory.backend, id("deadline-correction"))
  |> should.equal(backend.Free)
  store_core.claim_ready(runs, 1) |> should.equal(Ok([]))
  memory.advance(120_001)
  store_core.claim_ready(runs, 1) |> should.equal(Ok(["deadline-correction"]))
  let assert Ok(expired) = graph.recover(handle)
  expired |> should.equal(graph.Failed(graph.DeadlineExpired(due)))
}

pub fn an_expiration_commit_wins_against_an_in_progress_delivery_test() {
  let memory = conformance.leased_memory()
  let runs = nodes.node(memory.backend, "deadline-race", nodes.long)
  let route = probe.new()
  let spec =
    runtime_with(runs, fn(_, _) { Ok(policy.Allow) }, 60_000, fn(n, _, _) {
      probe.gate(route, "route")
      Ok(definition.Finish(n, n))
    })
  let assert Ok(handle) =
    graph.start(spec, id("deadline-race"), 1, correlation: None)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  let reply = process.new_subject()
  process.spawn(fn() {
    process.send(reply, graph.deliver(handle, reference, answer(), True))
  })
  let held = probe.arrival(route)
  memory.advance(60_001)
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(expired) = graph.snapshot(handle)
  expired.status |> should.equal(graph.Failed(graph.DeadlineExpired(due)))
  probe.release(held)
  let assert Ok(Error(graph.RunEnded)) = process.receive(reply, 30_000)
  let assert Ok(unchanged) = graph.snapshot(handle)
  unchanged.revision |> should.equal(expired.revision)
  unchanged.receipts |> should.equal([])
}

pub fn overdue_waits_expire_after_restart_without_a_signal_or_runner_test() {
  let memory = conformance.leased_memory()
  let #(owner, runs) =
    restart.owned(fn() { nodes.node(memory.backend, "deadline", nodes.long) })
  let spec = runtime(runs, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(handle) =
    graph.start(spec, id("deadline-restart"), 7, correlation: None)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  let assert Ok(row) = store_core.get(runs, "deadline-restart")
  row.live |> should.equal(None)
  memory.advance(60_001)
  restart.crash(owner, runs)
  let restored = nodes.node(memory.backend, "deadline", nodes.long)
  let handle =
    support.open_graph(
      runtime(restored, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-restart"),
    )
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(expired) = graph.snapshot(handle)
  expired.status |> should.equal(graph.Failed(graph.DeadlineExpired(due)))
  expired.receipts |> should.equal([])
  let assert Error(graph.RunEnded) =
    graph.deliver(handle, reference, answer(), True)
}

pub fn approval_does_not_start_the_clock_and_revisits_get_new_deadlines_test() {
  let memory = conformance.leased_memory()
  let runs = nodes.node(memory.backend, "deadline", nodes.long)
  let spec =
    runtime(runs, fn(_, _) {
      Ok(policy.RequireApproval(run.Requirement("publish", 1)))
    })
  let assert Ok(handle) =
    graph.start(spec, id("deadline-approval"), 0, correlation: None)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(pending) = graph.snapshot(handle)
  let assert graph.AwaitingApproval(approval) = pending.status
  // The approval request's own deadline (7 days); the wait's clock has not
  // started.
  let assert Some(expires) = pending.deadline
  let assert Ok(now) = store.now(runs)
  { expires > now + 6 * 24 * 60 * 60 * 1000 } |> should.be_true
  memory.advance(120_000)
  let assert Ok(_) =
    graph.approve(
      handle,
      approval,
      reviewer: support.reviewer("reviewer"),
      context: Nil,
    )
  let assert Ok(approved) = graph.snapshot(handle)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(first) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(reference) = first.status
  let assert Some(due) = first.deadline
  let assert Ok(now) = store.now(runs)
  should.be_true(due > now + 50_000)
  let _ = approved
  memory.advance(10_000)
  let assert Ok(_) = graph.deliver(handle, reference, answer(), False)
  let assert Ok(pending) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingApproval(approval) = pending
  let assert Ok(_) =
    graph.approve(
      handle,
      approval,
      reviewer: support.reviewer("reviewer"),
      context: Nil,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(second) = graph.snapshot(handle)
  let assert Some(next_due) = second.deadline
  should.be_true(next_due >= due + 10_000)
  let assert Ok(_) = graph.deliver(handle, reference, answer(), False)
  let assert Ok(duplicate) = graph.snapshot(handle)
  duplicate.revision |> should.equal(second.revision)
  duplicate.deadline |> should.equal(second.deadline)
}

pub fn late_delivery_commits_expiration_without_accepting_the_result_test() {
  let memory = conformance.leased_memory()
  let runs = nodes.node(memory.backend, "deadline", nodes.long)
  let assert Ok(handle) =
    graph.start(
      runtime(runs, fn(_, _) { Ok(policy.Allow) }),
      id("deadline-delivery"),
      1,
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Some(due) = waiting.deadline
  memory.advance(60_001)
  let assert Ok(_) = graph.deliver(handle, reference, answer(), True)
  let assert Ok(expired) = graph.snapshot(handle)
  expired.status |> should.equal(graph.Failed(graph.DeadlineExpired(due)))
  expired.receipts |> should.equal([])
}

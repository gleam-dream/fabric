import fabric
import fabric/agent
import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/model
import fabric/observation as o
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import fabric/testing
import gleam/erlang/process
import gleam/option.{None}
import gleeunit/should
import json/blueprint/codec
import sinal

pub fn shutdown_reports_a_confirmed_handoff_and_runner_exit_test() {
  let name = process.new_name("drain-summary")
  let runs = store.in_memory(name)
  let #(events, attached) = capture(name)
  let ledger = probe.new()
  let agent = slow(ledger)
  let application = restart.application(runs)
  let assert Ok(_) = fabric.start(runs, agent, Nil, "go")
  let held = probe.arrival(ledger)
  restart.begin_stop(application)
  restart.draining(runs)
  probe.release(held)
  restart.stopped(application)
  let assert Ok(summary) = process.receive(events, 1000)
  summary |> should.equal(o.Drain(1, 1, 0, 0, 0, 1, 0, summary.elapsed_ms))
  { summary.elapsed_ms >= 0 } |> should.be_true
  let _ = sinal.detach(attached)
}

@external(erlang, "erlang", "atom_to_binary")
fn name_text(name: process.Name(a)) -> String

fn slow(ledger: probe.Probe) -> agent.Agent(Nil) {
  agent.new(
    "agent",
    scripted.plan([scripted.slow("a", "a")]),
    [scripted.gated_tool(ledger)],
    policy.always_allow(),
  )
  |> support.agent
}

fn capture(
  name: process.Name(store.Message),
) -> #(process.Subject(o.Drain), sinal.Attachment) {
  let events = process.new_subject()
  let attached =
    sinal.observe(o.drain(), fn(summary, store_name) {
      case store_name == name_text(name) {
        True -> process.send(events, summary)
        False -> Nil
      }
    })
  #(events, attached)
}

fn reported(events: process.Subject(o.Drain), expected: o.Drain) -> o.Drain {
  let assert Ok(summary) = process.receive(events, 1000)
  summary |> should.equal(o.Drain(..expected, elapsed_ms: summary.elapsed_ms))
  should.be_true(summary.elapsed_ms >= 0)
  summary
}

fn leased(
  name: process.Name(store.Message),
  backend: store.LeasedBackend,
  milliseconds: Int,
) -> store.Store {
  let assert Ok(runs) = store.leased(name, "summary", 60_000, backend)
  let assert Ok(runs) = store.with_drain(runs, milliseconds)
  runs
}

pub fn a_lost_handoff_acknowledgment_is_confirmed_by_readback_test() {
  let name = process.new_name("drain-readback")
  let memory = testing.leased_memory()
  let backend =
    store.LeasedBackend(
      ..memory.backend,
      compare_and_set: fn(id, revision, encoded, lease) {
        let result =
          memory.backend.compare_and_set(id, revision, encoded, lease)
        case lease, result {
          store.Claim(_, 0), Ok(_) ->
            Error(store.Unavailable("lost acknowledgment"))
          _, _ -> result
        }
      },
    )
  let runs = leased(name, backend, 1000)
  let #(events, attached) = capture(name)
  let ledger = probe.new()
  let application = restart.application(runs)
  let assert Ok(_) = fabric.start(runs, slow(ledger), Nil, "go")
  let held = probe.arrival(ledger)
  restart.begin_stop(application)
  restart.draining(runs)
  probe.release(held)
  restart.stopped(application)
  let _ = reported(events, o.Drain(1, 1, 0, 0, 0, 1, 0, 0))
  let _ = sinal.detach(attached)
}

pub fn an_unconfirmed_handoff_is_reported_as_failed_test() {
  let name = process.new_name("drain-failed")
  let memory = testing.leased_memory()
  let backend =
    store.LeasedBackend(
      ..memory.backend,
      compare_and_set: fn(id, revision, encoded, lease) {
        case lease {
          store.Claim(_, 0) -> Error(store.Unavailable("offline"))
          _ -> memory.backend.compare_and_set(id, revision, encoded, lease)
        }
      },
    )
  let runs = leased(name, backend, 1000)
  let #(events, attached) = capture(name)
  let ledger = probe.new()
  let application = restart.application(runs)
  let assert Ok(_) = fabric.start(runs, slow(ledger), Nil, "go")
  let held = probe.arrival(ledger)
  restart.begin_stop(application)
  restart.draining(runs)
  probe.release(held)
  restart.stopped(application)
  let _ = reported(events, o.Drain(1, 0, 1, 0, 0, 1, 0, 0))
  let _ = sinal.detach(attached)
}

pub fn the_supervisor_deadline_is_counted_as_a_forced_exit_test() {
  let name = process.new_name("drain-killed")
  let assert Ok(runs) = store.with_drain(store.in_memory(name), 50)
  let #(events, attached) = capture(name)
  let ledger = probe.new()
  let application = restart.application(runs)
  let assert Ok(_) = fabric.start(runs, slow(ledger), Nil, "go")
  let _ = probe.arrival(ledger)
  restart.stop(application)
  let summary = reported(events, o.Drain(1, 0, 0, 0, 1, 0, 0, 0))
  should.be_true(summary.elapsed_ms >= 50)
  let _ = sinal.detach(attached)
}

pub fn a_commit_still_pending_after_the_deadline_is_not_reported_as_success_or_failure_test() {
  let name = process.new_name("drain-pending")
  let memory = testing.leased_memory()
  let writes = probe.new()
  let backend =
    store.LeasedBackend(
      ..memory.backend,
      compare_and_set: fn(id, revision, encoded, lease) {
        case lease {
          store.Claim(_, 0) -> probe.gate(writes, "handoff")
          _ -> Nil
        }
        memory.backend.compare_and_set(id, revision, encoded, lease)
      },
    )
  let runs = leased(name, backend, 100)
  let #(events, attached) = capture(name)
  let ledger = probe.new()
  let application = restart.application(runs)
  let assert Ok(_) = fabric.start(runs, slow(ledger), Nil, "go")
  let held = probe.arrival(ledger)
  restart.begin_stop(application)
  restart.draining(runs)
  probe.release(held)
  let writing = probe.arrival(writes)
  restart.stopped_within(application, 3000) |> should.be_true
  let summary = reported(events, o.Drain(1, 0, 0, 1, 1, 0, 0, 0))
  should.be_true(summary.elapsed_ms >= 1000)
  let assert Ok(writer) = process.subject_owner(writing.release)
  restart.gone(writer)
  let _ = sinal.detach(attached)
}

pub fn a_handoff_can_be_confirmed_even_if_its_runner_is_then_killed_test() {
  let name = process.new_name("drain-confirmed-kill")
  let assert Ok(runs) = store.with_drain(store.in_memory(name), 100)
  let #(events, attached) = capture(name)
  let ledger = probe.new()
  let observations = probe.new()
  let application = restart.application(runs)
  let assert Ok(handle) = fabric.start(runs, slow(ledger), Nil, "go")
  let held = probe.arrival(ledger)
  let blocked =
    sinal.observe(o.run_handed_off(), fn(_, meta) {
      case meta.run == support.text(fabric.id(handle)) {
        True -> probe.gate(observations, "handoff observer")
        False -> Nil
      }
    })
  restart.begin_stop(application)
  restart.draining(runs)
  probe.release(held)
  let _ = probe.arrival(observations)
  restart.stopped(application)
  let _ = reported(events, o.Drain(1, 1, 0, 0, 1, 0, 0, 0))
  let _ = sinal.detach(blocked)
  let _ = sinal.detach(attached)
}

pub fn a_blocked_summary_observer_does_not_hold_shutdown_test() {
  let name = process.new_name("drain-observer")
  let observations = probe.new()
  let attached =
    sinal.observe(o.drain(), fn(_, meta) {
      case meta == name_text(name) {
        True -> probe.gate(observations, "summary observer")
        False -> Nil
      }
    })
  let application = restart.application(store.in_memory(name))
  restart.begin_stop(application)
  let observing = probe.arrival(observations)
  restart.stopped_within(application, 2000) |> should.be_true
  let assert Ok(observer) = process.subject_owner(observing.release)
  restart.gone(observer)
  let _ = sinal.detach(attached)
}

pub fn idle_shutdown_excludes_completed_and_suspended_runs_test() {
  let name = process.new_name("drain-idle")
  let runs = store.in_memory(name)
  let #(events, attached) = capture(name)
  let application = restart.application(runs)
  let complete =
    agent.new(
      "complete",
      scripted.model(fn(_) { model.FinalAnswer("done", None) }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(completed) = fabric.start(runs, complete, Nil, "go")
  let assert Ok(run.Finished(_)) = fabric.await(completed, 1000)
  let waiting =
    agent.new(
      "waiting",
      scripted.plan([scripted.slow("a", "a")]),
      [scripted.gated_tool(probe.new())],
      fn(_, _) { Ok(policy.RequireApproval(run.Requirement("review", 1))) },
    )
    |> support.agent
  let assert Ok(suspended) = fabric.start(runs, waiting, Nil, "go")
  let assert Ok(run.Suspended(_, _)) = fabric.await(suspended, 1000)
  // Reading readiness is a round trip after both runners' final writes.
  let assert Ok(store.Readiness(runners: 0, ..)) = store.readiness(runs)
  restart.stop(application)
  let _ = reported(events, o.Drain(0, 0, 0, 0, 0, 0, 0, 0))
  let _ = sinal.detach(attached)
}

pub fn graph_runners_are_included_in_the_same_summary_test() {
  let name = process.new_name("graph-drain-summary")
  let runs = store.in_memory(name)
  let #(events, attached) = capture(name)
  let ledger = probe.new()
  let assert Ok(node) = definition.node_id("work")
  let work =
    operation.new(
      run.Identity("work", 1),
      codec.int(),
      codec.int(),
      fn(_, _, n) {
        probe.gate(ledger, "work")
        Ok(n + 1)
      },
      fn(_error: Nil) { operation.DefiniteFailure("cannot fail") },
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("graph-drain-summary", 1),
      node,
      [
        definition.node(
          node,
          work,
          fn(n) { Ok(n) },
          fn(_, n) { Ok(definition.Continue(n, node)) },
          [node],
        ),
      ],
      codec.int(),
      codec.int(),
      3,
    ))
  let application = restart.application(runs)
  let runtime =
    graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(id) = run.parse_id("graph-drain-summary")
  let assert Ok(_) = graph.start(runtime, id, 0)
  let held = probe.arrival(ledger)
  restart.begin_stop(application)
  restart.draining(runs)
  probe.release(held)
  restart.stopped(application)
  let _ = reported(events, o.Drain(1, 1, 0, 0, 0, 1, 0, 0))
  let _ = sinal.detach(attached)
}

pub fn a_runner_admitted_before_drain_is_counted_while_its_first_write_is_pending_test() {
  let name = process.new_name("drain-starting")
  let memory = testing.leased_memory()
  let writes = probe.new()
  let backend =
    store.LeasedBackend(..memory.backend, insert: fn(id, encoded, lease) {
      probe.gate(writes, "insert")
      memory.backend.insert(id, encoded, lease)
    })
  let runs = leased(name, backend, 1000)
  let #(events, attached) = capture(name)
  let ledger = probe.new()
  let application = restart.application(runs)
  let started = process.new_subject()
  process.spawn(fn() {
    process.send(started, fabric.start(runs, slow(ledger), Nil, "go"))
  })
  let writing = probe.arrival(writes)
  restart.begin_stop(application)
  restart.draining(runs)
  probe.release(writing)
  let assert Ok(Ok(_)) = process.receive(started, 1000)
  restart.stopped_within(application, 3000) |> should.be_true
  let _ = reported(events, o.Drain(1, 1, 0, 0, 0, 1, 0, 0))
  probe.count(ledger, "start:a") |> should.equal(0)
  let _ = sinal.detach(attached)
}

pub fn store_loss_during_drain_reports_unavailable_accounting_test() {
  let name = process.new_name("drain-store-loss")
  let assert Ok(runs) = store.with_drain(store.in_memory(name), 100)
  let unavailable = process.new_subject()
  let attached =
    sinal.observe(o.drain_unavailable(), fn(_, meta) {
      case meta == name_text(name) {
        True -> process.send(unavailable, Nil)
        False -> Nil
      }
    })
  let #(events, capture) = capture(name)
  let ledger = probe.new()
  let application = restart.application(runs)
  let assert Ok(_) = fabric.start(runs, slow(ledger), Nil, "go")
  let _ = probe.arrival(ledger)
  restart.begin_stop(application)
  restart.draining(runs)
  let assert Ok(pid) = store.pid(runs)
  restart.kill(pid)
  restart.stopped_within(application, 3000) |> should.be_true
  process.receive(unavailable, 1000) |> should.equal(Ok(Nil))
  process.receive(events, 0) |> should.equal(Error(Nil))
  let _ = sinal.detach(attached)
  let _ = sinal.detach(capture)
}

pub fn a_runner_that_finishes_during_drain_needs_no_handoff_test() {
  let name = process.new_name("drain-finished")
  let runs = store.in_memory(name)
  let #(events, attached) = capture(name)
  let replies = probe.new()
  let final =
    agent.new(
      "final",
      scripted.model(fn(_) {
        probe.gate(replies, "model")
        model.FinalAnswer("done", None)
      }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let application = restart.application(runs)
  let assert Ok(_) = fabric.start(runs, final, Nil, "go")
  let replying = probe.arrival(replies)
  restart.begin_stop(application)
  restart.draining(runs)
  probe.release(replying)
  restart.stopped(application)
  let _ = reported(events, o.Drain(1, 0, 0, 0, 0, 1, 0, 0))
  let _ = sinal.detach(attached)
}

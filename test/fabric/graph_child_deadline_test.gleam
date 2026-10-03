//// D14–D18: managed deadlines preserve child identity and terminal evidence.

import fabric
import fabric/agent
import fabric/graph
import fabric/graph/agent as agent_node
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/job
import fabric/graph/operation
import fabric/graph/signal
import fabric/model
import fabric/policy
import fabric/retention
import fabric/run
import fabric/store
import fabric/support
import fabric/support/nodes
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import fabric/testing
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn runtime(runs, identity, op, accept) {
  let assert Ok(id) = definition.node_id("work")
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity(identity, 1),
      id,
      [definition.node(id, op, fn(n) { Ok(n) }, accept, [])],
      codec.int(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn parent(runs, op, accept) {
  let assert Ok(op) = operation.with_deadline(op, duration.milliseconds(60_000))
  runtime(runs, "child-deadline", op, accept)
}

fn finish(_, n) {
  Ok(definition.Finish(n, n))
}

fn waiting_child(runs) {
  runtime(
    runs,
    "signal-child",
    operation.await_signal(
      codec.int(),
      signal.new(run.Identity("answer", 1), codec.int()),
    ),
    finish,
  )
}

pub fn expiration_after_restart_cancels_the_same_signal_child_test() {
  let memory = testing.leased_memory()
  let #(owner, runs) =
    restart.owned(fn() { nodes.node(memory.backend, "before", 300_000) })
  let leaf = waiting_child(runs)
  let assert Ok(handle) =
    graph.start(
      parent(runs, graph.as_subgraph(leaf), finish),
      support.id("expiring-child"),
      41,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(reference, child.Signal(_)) = waiting.status
  let assert Some(due) = waiting.deadline
  parked(runs, graph.id(handle), 300)
  restart.crash(owner, runs)
  memory.advance(60_001)
  let runs = nodes.node(memory.backend, "after", 300_000)
  let leaf = waiting_child(runs)
  let handle =
    graph.attach(
      parent(runs, graph.as_subgraph(leaf), fn(_, _) {
        panic as "expired child cannot route"
      }),
      support.id("expiring-child"),
    )
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Expired(due, graph.ChildSettled(reference)))
  done.receipts |> should.equal([])
  let assert Ok(child_handle) = graph.child(handle, reference.activation, leaf)
  let assert Ok(stopped) = graph.read(child_handle)
  stopped.status |> should.equal(graph.Cancelled(graph.BeforeStart))
  let assert Ok(row) = store.get(runs, "expiring-child")
  let assert Ok(metadata) = retention.inspect(row.record)
  metadata.settled |> should.be_true
  let assert [link] = metadata.children
  link.run |> should.equal(reference.child)
}

pub fn result_mapping_cannot_cross_the_child_deadline_test() {
  let memory = testing.leased_memory()
  let runs = nodes.node(memory.backend, "mapping", 300_000)
  let leaf =
    runtime(
      runs,
      "answer-child",
      operation.new(
        run.Identity("answer", 1),
        codec.int(),
        codec.int(),
        fn(_, _, n) { Ok(n + 1) },
        fn(_: Nil) { operation.DefiniteFailure("impossible") },
      ),
      finish,
    )
  let assert Ok(handle) =
    graph.start(
      parent(runs, graph.as_subgraph(leaf), fn(_, n) {
        memory.advance(60_001)
        Ok(definition.Finish(n, n))
      }),
      support.id("late-child-mapping"),
      41,
    )
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Expired(_, graph.ChildSettled(reference)) = done.status
  done.value |> should.equal(41)
  done.receipts |> should.equal([])
  let assert Ok(child_handle) = graph.child(handle, reference.activation, leaf)
  let assert Ok(answer) = graph.read(child_handle)
  answer.status |> should.equal(graph.Completed(42))
}

pub fn an_expired_agent_keeps_uncertain_effects_until_the_child_is_reconciled_test() {
  let memory = testing.leased_memory()
  let runs = nodes.node(memory.backend, "agent-deadline", 300_000)
  let effects = probe.new()
  let worker =
    agent.new(
      "worker",
      scripted.model(fn(_) {
        model.ToolRequest(
          model.AssistantTurn(
            "",
            [scripted.call("effect", "crash", "{\"x\":\"charge\"}")],
            None,
          ),
          None,
        )
      }),
      [scripted.crashing_tool(effects)],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(child_runtime) =
    agent_node.new(
      agent_node.Definition(
        run.Identity("deadline-agent", 1),
        worker,
        codec.int(),
        codec.int(),
        fn(_) { "run the operation" },
        fn(_) { Ok(42) },
      ),
      runs,
      fn() { Nil },
    )
  let assert Ok(handle) =
    graph.start(
      parent(runs, agent_node.as_operation(child_runtime), finish),
      support.id("expired-agent-effect"),
      41,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(reference, child.AgentInput([], [uncertain])) =
    waiting.status
  let assert Some(due) = waiting.deadline
  parked(runs, graph.id(handle), 300)
  memory.advance(60_001)
  let assert Ok(_) = graph.recover(handle)
  let expired = expired(handle, 300)
  let assert graph.Expired(saved_due, graph.ChildUnresolved(saved_ref, _)) =
    expired.status
  saved_due |> should.equal(due)
  saved_ref |> should.equal(reference)
  let assert Ok(row) = store.get(runs, "expired-agent-effect")
  let assert Ok(metadata) = retention.inspect(row.record)
  metadata.settled |> should.be_false
  let assert Ok(_) =
    fabric.reconcile_stored(runs, uncertain.reference, "charge confirmed")
  let assert Ok(settled) = graph.recover(handle)
  settled.status
  |> should.equal(graph.Expired(due, graph.ChildSettled(reference)))
  probe.entries(effects) |> should.equal(["crash:charge"])
  settled.receipts |> should.equal([])
}

fn expired(handle, remaining) {
  let assert Ok(snapshot) = graph.read(handle)
  case snapshot.status, remaining {
    graph.Expired(..), _ -> snapshot
    _, n if n > 0 -> {
      process.sleep(10)
      expired(handle, n - 1)
    }
    _, _ -> panic as "child deadline did not settle"
  }
}

pub fn a_clock_failure_before_arming_starts_no_child_test() {
  let memory = testing.leased_memory()
  let backend =
    store.LeasedBackend(..memory.backend, now: fn() {
      Error(store.Unavailable("clock offline"))
    })
  let runs = nodes.node(backend, "unarmed-child", 300_000)
  let leaf = waiting_child(runs)
  let assert Ok(handle) =
    graph.start(
      parent(runs, graph.as_subgraph(leaf), finish),
      support.id("unarmed-child"),
      41,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  waiting.status |> should.equal(graph.Unattended)
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(done) = graph.read(handle)
  done.status |> should.equal(graph.Cancelled(graph.BeforeStart))
  store.get(runs, child.reserved_id("unarmed-child", 1))
  |> should.equal(Error(store.NotFound))
}

pub fn expiration_before_child_creation_records_a_never_started_child_test() {
  let memory = testing.leased_memory()
  let backend =
    store.LeasedBackend(..memory.backend, now: fn() {
      memory.advance(60_001)
      memory.backend.now()
    })
  let runs = nodes.node(backend, "before-child", 300_000)
  let leaf =
    runtime(
      runs,
      "never-started",
      operation.new(
        run.Identity("effect", 1),
        codec.int(),
        codec.int(),
        fn(_, _, _) { panic as "expired child must not start" },
        fn(_: Nil) { operation.DefiniteFailure("impossible") },
      ),
      finish,
    )
  let assert Ok(handle) =
    graph.start(
      parent(runs, graph.as_subgraph(leaf), finish),
      support.id("before-child"),
      41,
    )
  let done = expired(handle, 300)
  let assert graph.Expired(_, graph.ChildSettled(reference)) = done.status
  let assert Ok(child_handle) = graph.child(handle, reference.activation, leaf)
  let assert Ok(stopped) = graph.read(child_handle)
  stopped.status |> should.equal(graph.Cancelled(graph.BeforeStart))
  stopped.receipts |> should.equal([])
}

pub fn expired_reconciliation_keeps_the_child_result_without_calling_parent_mapping_test() {
  let memory = testing.leased_memory()
  let runs = nodes.node(memory.backend, "blocked-mapping", 300_000)
  let leaf =
    runtime(
      runs,
      "answer-child",
      operation.new(
        run.Identity("answer", 1),
        codec.int(),
        codec.int(),
        fn(_, _, n) { Ok(n + 1) },
        fn(_: Nil) { operation.DefiniteFailure("impossible") },
      ),
      finish,
    )
  let build = fn(accept) { parent(runs, graph.as_subgraph(leaf), accept) }
  let assert Ok(handle) =
    graph.start(
      build(fn(_, _) { Error("mapping unavailable") }),
      support.id("expired-mapping"),
      41,
    )
  let assert Ok(blocked) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Blocked(reference, graph.InvalidResult(_, _)) =
    blocked.status
  let assert Some(due) = blocked.deadline
  memory.advance(60_001)
  let handle =
    graph.attach(
      build(fn(_, _) { panic as "deadline must precede reconciliation callback" }),
      support.id("expired-mapping"),
    )
  let assert Ok(_) = graph.reconcile(handle, reference, "42")
  let done = expired(handle, 300)
  let assert graph.Expired(saved_due, graph.ChildSettled(child_ref)) =
    done.status
  saved_due |> should.equal(due)
  done.receipts |> should.equal([])
  let assert Ok(child_handle) = graph.child(handle, child_ref.activation, leaf)
  let assert Ok(answer) = graph.read(child_handle)
  answer.status |> should.equal(graph.Completed(42))
}

pub fn a_sweeper_settles_nested_cleanup_after_expiration_without_a_working_clock_test() {
  let memory = testing.leased_memory()
  let clock = probe.new()
  let backend =
    store.LeasedBackend(..memory.backend, now: fn() {
      case probe.entries(clock) {
        [] -> memory.backend.now()
        _ -> Error(store.Unavailable("clock offline during cleanup"))
      }
    })
  let runs = nodes.node(backend, "nested-deadline", 300_000)
  let terminal = probe.new()
  let build = fn(runs) {
    let observer =
      job.observe(
        run.Identity("nested-job", 1),
        codec.int(),
        codec.int(),
        fn(_, _) {
          case probe.entries(terminal) {
            [] -> Ok(job.Pending)
            _ -> Ok(job.Completed(42))
          }
        },
      )
    let assert Ok(observer) =
      job.with_poll_interval(observer, duration.milliseconds(100))
    let job_child =
      runtime(
        runs,
        "nested-job-child",
        operation.own_job(
          observer,
          fn(_, _, _) { Ok(Nil) },
          fn(error: operation.Failure) { error },
        ),
        finish,
      )
    let middle =
      runtime(runs, "nested-middle", graph.as_subgraph(job_child), finish)
    parent(runs, graph.as_subgraph(middle), finish)
  }
  let assert Ok(handle) =
    graph.start(build(runs), support.id("nested-deadline"), 41)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(reference, child.Job(_)) = waiting.status
  let assert Some(due) = waiting.deadline
  parked(runs, graph.id(handle), 300)
  memory.advance(60_001)
  let assert Ok(_) = graph.recover(handle)
  let before = expired(handle, 300)
  let assert graph.Expired(_, graph.ChildUnresolved(_, _)) = before.status
  probe.record(clock, "offline")
  probe.record(terminal, "completed")
  let assert Ok(spec) =
    fabric.sweeper(
      runs,
      [graph.recovery(run.Identity("child-deadline", 1), build)],
      every: duration.milliseconds(10),
    )
  let assert Ok(started) = spec.start()
  let done = settled(handle, 300)
  process.unlink(started.pid)
  restart.kill(started.pid)
  done.status |> should.equal(graph.Expired(due, graph.ChildSettled(reference)))
  done.receipts |> should.equal([])
}

fn settled(handle, remaining) {
  let assert Ok(snapshot) = graph.read(handle)
  case snapshot.status, remaining {
    graph.Expired(_, graph.ChildSettled(_)), _ -> snapshot
    _, n if n > 0 -> {
      process.sleep(10)
      settled(handle, n - 1)
    }
    _, _ -> panic as "nested deadline cleanup did not settle"
  }
}

pub fn an_overdue_retained_wait_cannot_replace_a_missing_child_with_a_tombstone_test() {
  let memory = testing.leased_memory()
  let #(owner, runs) =
    restart.owned(fn() {
      nodes.node(memory.backend, "lost-child-before", 300_000)
    })
  let root = "missing-deadline-child"
  let build = fn(runs) {
    parent(runs, graph.as_subgraph(waiting_child(runs)), finish)
  }
  let assert Ok(handle) = graph.start(build(runs), support.id(root), 41)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Child(reference, child.Signal(_)) = waiting.status
  parked(runs, graph.id(handle), 300)
  restart.crash(owner, runs)
  memory.advance(60_001)
  let assert Ok(before) = memory.backend.get(root)
  let missing = run.id_to_string(reference.child)
  let backend =
    store.LeasedBackend(..memory.backend, get: fn(id) {
      case id == missing {
        True -> Error(store.NotFound)
        False -> memory.backend.get(id)
      }
    })
  let runs = nodes.node(backend, "lost-child-after", 300_000)
  let handle = graph.attach(build(runs), support.id(root))
  graph.recover(handle)
  |> should.equal(Error(graph.StoreFailed(store.NotFound)))
  let assert Ok(after) = memory.backend.get(root)
  after.record |> should.equal(before.record)
}

fn parked(runs, id, remaining) {
  let assert Ok(row) = store.get(runs, run.id_to_string(id))
  case row.live, remaining {
    None, _ -> Nil
    _, n if n > 0 -> {
      process.sleep(10)
      parked(runs, id, n - 1)
    }
    _, _ -> panic as "parent did not save its idle wait"
  }
}

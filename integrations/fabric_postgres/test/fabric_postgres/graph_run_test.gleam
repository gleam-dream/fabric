//// An external package uses only public graph APIs on the real PostgreSQL
//// backend. Approval survives store loss and completion releases its lease.

import fabric
import fabric/budget
import fabric/graph
import fabric/graph/agent as agent_node
import fabric/graph/child
import fabric/graph/definition
import fabric/graph/job
import fabric/graph/operation
import fabric/graph/signal
import fabric/policy
import fabric/run
import fabric/store
import fabric_postgres
import fabric_postgres/agents
import fabric_postgres/support
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/option.{None}
import gleeunit/should
import json/blueprint/codec

pub fn a_graph_survives_store_restart_and_completes_on_postgres_test() {
  let effects = process.new_subject()
  let assert Ok(node_id) = definition.node_id("increment")
  let op =
    operation.new(
      run.Identity("increment", 1),
      codec.int(),
      codec.int(),
      fn(_, invocation, n) {
        process.send(effects, invocation.activation)
        Ok(n + 1)
      },
      fn(_error: Nil) { operation.DefiniteFailure("cannot fail") },
    )
  let node =
    definition.node(
      node_id,
      op,
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("postgres-graph", 1),
      node_id,
      [node],
      codec.int(),
      codec.int(),
      1,
    ))
  let settings = support.migrated(support.pool(4), "graph", support.schema())
  let assert Ok(id) = run.parse_id("postgres-graph-run")
  let #(owner, approval) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("graph-original"), settings)
      let assert Ok(Nil) = store.start(runs)
      let runtime =
        graph.new(spec, runs, fn() { Nil }, fn(_, _) {
          Ok(policy.RequireApproval(run.Requirement("increment", 1)))
        })
      let assert Ok(handle) = graph.start(runtime, id, 41)
      let assert Ok(waiting) = graph.await(handle, 5000)
      let assert graph.AwaitingApproval(approval) = waiting.status
      approval
    })
  agents.kill(owner)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("graph-restored"), settings)
  let assert Ok(Nil) = store.start(runs)
  let runtime =
    graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
  let handle = graph.attach(runtime, id)
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(_) = graph.approve(handle, approval)
  let assert Ok(done) = graph.await(handle, 5000)
  done.value |> should.equal(42)
  done.status |> should.equal(graph.Completed(42))
  process.receive(effects, 1000) |> should.equal(Ok(1))
  process.receive(effects, 0) |> should.equal(Error(Nil))
  let assert Ok(row) =
    fabric_postgres.backend(settings).get(run.id_to_string(id))
  row.holder |> should.equal(store.Free)
  json.parse(row.record, decode.field("format", decode.string, decode.success))
  |> should.equal(Ok("fabric.graph"))
}

pub fn a_signal_wait_releases_its_lease_and_another_store_consumes_it_once_test() {
  let response = signal.new(run.Identity("human-review", 1), codec.bool())
  let assert Ok(node_id) = definition.node_id("review")
  let node =
    definition.node(
      node_id,
      operation.await_signal(codec.int(), response),
      fn(n) { Ok(n) },
      fn(n, approved) { Ok(definition.Finish(n, approved)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("postgres-signal", 1),
      node_id,
      [node],
      codec.int(),
      codec.bool(),
      1,
    ))
  let settings =
    support.migrated(support.pool(4), "graph-signal", support.schema())
  let assert Ok(id) = run.parse_id("postgres-signal-run")
  let #(owner, reference) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("signal-original"), settings)
      let assert Ok(Nil) = store.start(runs)
      let runtime =
        graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
      let assert Ok(handle) = graph.start(runtime, id, 41)
      let assert Ok(waiting) = graph.await(handle, 5000)
      let assert graph.AwaitingSignal(reference) = waiting.status
      let assert Ok(entry) = store.get(runs, run.id_to_string(id))
      entry.live |> should.equal(None)
      reference
    })
  let assert Ok(row) =
    fabric_postgres.backend(settings).get(run.id_to_string(id))
  row.holder |> should.equal(store.Free)
  agents.kill(owner)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("signal-restored"), settings)
  let assert Ok(Nil) = store.start(runs)
  let handle =
    graph.attach(
      graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) }),
      id,
    )
  let assert Ok(done) = graph.deliver(handle, reference, response, True)
  done.status |> should.equal(graph.Completed(True))
  let assert Ok(duplicate) = graph.deliver(handle, reference, response, True)
  duplicate.revision |> should.equal(done.revision)
}

pub fn a_job_wait_survives_store_loss_without_holding_a_lease_test() {
  let observer =
    job.observe(
      run.Identity("postgres-job", 1),
      codec.string(),
      codec.int(),
      fn(_, receipt) {
        receipt |> should.equal("accepted-job")
        Ok(job.Completed(42))
      },
    )
  let assert Ok(node_id) = definition.node_id("observe")
  let node =
    definition.node(
      node_id,
      operation.await_job(observer),
      fn(receipt) { Ok(receipt) },
      fn(receipt, output) { Ok(definition.Finish(receipt, output)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("postgres-job-flow", 1),
      node_id,
      [node],
      codec.string(),
      codec.int(),
      1,
    ))
  let settings =
    support.migrated(support.pool(4), "graph-job", support.schema())
  let assert Ok(id) = run.parse_id("postgres-job-run")
  let #(owner, reference) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("job-original"), settings)
      let assert Ok(Nil) = store.start(runs)
      let runtime =
        graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
      let assert Ok(handle) = graph.start(runtime, id, "accepted-job")
      let assert Ok(waiting) = graph.await(handle, 5000)
      let assert graph.AwaitingJob(reference) = waiting.status
      reference
    })
  let backend = fabric_postgres.backend(settings)
  let assert Ok(row) = backend.get(run.id_to_string(id))
  row.holder |> should.equal(store.Free)
  fabric_postgres.prune(settings, ended_for: 0, limit: 10)
  |> should.equal(Ok(0))
  agents.kill(owner)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("job-restored"), settings)
  let assert Ok(Nil) = store.start(runs)
  let handle =
    graph.attach(
      graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) }),
      id,
    )
  let assert Ok(waiting) = graph.recover(handle)
  waiting.status |> should.equal(graph.AwaitingJob(reference))
  let assert Ok(done) = graph.poll_job(handle, reference)
  done.status |> should.equal(graph.Completed(42))
  graph.poll_job(handle, reference) |> should.equal(Ok(done))
  let assert Ok(row) = backend.get(run.id_to_string(id))
  row.holder |> should.equal(store.Free)
  fabric_postgres.prune(settings, ended_for: 0, limit: 10)
  |> should.equal(Ok(1))
}

pub fn scheduled_job(runs, every, read) {
  let observer =
    job.observe(
      run.Identity("pg-scheduled-observer", 1),
      codec.string(),
      codec.int(),
      fn(_, receipt) { read(receipt) },
    )
  let assert Ok(observer) = job.with_poll_interval(observer, every)
  let assert Ok(id) = definition.node_id("observe")
  let node =
    definition.node(
      id,
      operation.await_job(observer),
      fn(receipt) { Ok(receipt) },
      fn(receipt, n) { Ok(definition.Finish(receipt, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("pg-scheduled-job", 1),
      id,
      [node],
      codec.string(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn owned_job(runs, read, request) {
  let observer =
    job.observe(
      run.Identity("pg-owned-observer", 1),
      codec.string(),
      codec.int(),
      fn(_, receipt) { read(receipt) },
    )
  let assert Ok(observer) = job.with_poll_interval(observer, 100)
  let assert Ok(id) = definition.node_id("observe")
  let op =
    operation.own_job(
      observer,
      fn(_, _, receipt) { request(receipt) },
      fn(error) { error },
    )
  let node =
    definition.node(
      id,
      op,
      fn(receipt) { Ok(receipt) },
      fn(_, _) { panic as "owned cancellation must not route" },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("pg-owned-job", 1),
      id,
      [node],
      codec.string(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

pub fn owned_job_cancellation_survives_postgres_restart_and_sweeps_before_pruning_test() {
  let settings =
    support.migrated(support.pool(4), "owned-job", support.schema())
  let assert Ok(id) = run.parse_id("pg-owned-stop")
  let #(owner, reference) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("owned-original"), settings)
      let assert Ok(Nil) = store.start(runs)
      let assert Ok(handle) =
        graph.start_with_budget(
          owned_job(runs, fn(_) { Ok(job.Pending) }, fn(receipt) {
            receipt |> should.equal("accepted")
            Ok(Nil)
          }),
          id,
          "accepted",
          budget.Limits(1, 1, 1),
        )
      let assert Ok(waiting) = graph.await(handle, 5000)
      let assert graph.AwaitingJob(reference) = waiting.status
      graph.cancel(handle) |> should.equal(Ok(Nil))
      let assert Ok(pending) = graph.await(handle, 5000)
      pending.status
      |> should.equal(graph.CancellingJob(reference, job.RequestAccepted))
      reference
    })
  released(settings, id, 200) |> should.be_true
  fabric_postgres.prune(settings, ended_for: 0, limit: 10)
  |> should.equal(Ok(0))
  agents.kill(owner)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("owned-restored"), settings)
  let assert Ok(Nil) = store.start(runs)
  let build = fn(runs) {
    owned_job(runs, fn(_) { Ok(job.Cancelled) }, fn(_) {
      panic as "saved request must not repeat"
    })
  }
  let handle = graph.attach(build(runs), id)
  let assert Ok(pending) = graph.read(handle)
  pending.status
  |> should.equal(graph.CancellingJob(reference, job.RequestAccepted))
  let assert Ok(spec) =
    fabric.sweeper(
      runs,
      [graph.recovery(run.Identity("pg-owned-job", 1), build)],
      every: 20,
    )
  let assert Ok(sweeper) = spec.start()
  let done = await_owned_settlement(handle, 300)
  done.status |> should.equal(graph.Cancelled(graph.JobStopped(reference)))
  released(settings, id, 200) |> should.be_true
  process.unlink(sweeper.pid)
  agents.kill(sweeper.pid)
  // The root and its shared-capacity ledger settle and prune together.
  fabric_postgres.prune(settings, ended_for: 0, limit: 10)
  |> should.equal(Ok(2))
}

fn await_owned_settlement(handle, left) {
  let assert Ok(snapshot) = graph.read(handle)
  case snapshot.status, left {
    graph.Cancelled(_), _ -> snapshot
    _, n if n > 0 -> {
      process.sleep(20)
      await_owned_settlement(handle, n - 1)
    }
    _, _ -> panic as "owned cancellation did not settle"
  }
}

pub fn a_postgres_sweeper_retains_the_next_poll_across_store_loss_test() {
  let settings =
    support.migrated(support.pool(4), "scheduled-job", support.schema())
  let observed = process.new_subject()
  let assert Ok(id) = run.parse_id("pg-scheduled")
  let #(owner, #(_runs, reference)) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(
          process.new_name("job-schedule-original"),
          settings,
        )
      let assert Ok(Nil) = store.start(runs)
      let build = fn(runs) {
        scheduled_job(runs, 1000, fn(_) {
          process.send(observed, Nil)
          Ok(job.Pending)
        })
      }
      let assert Ok(handle) =
        graph.start_with_budget(
          build(runs),
          id,
          "receipt",
          budget.Limits(1, 1, 1),
        )
      let assert Ok(waiting) = graph.await(handle, 5000)
      let assert graph.AwaitingJob(reference) = waiting.status
      let assert Ok(spec) =
        fabric.sweeper(
          runs,
          [graph.recovery(run.Identity("pg-scheduled-job", 1), build)],
          every: 20,
        )
      let assert Ok(_) = spec.start()
      #(runs, reference)
    })
  process.receive(observed, 5000) |> should.equal(Ok(Nil))
  released(settings, id, 200) |> should.be_true
  agents.kill(owner)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("job-schedule-restored"), settings)
  let assert Ok(Nil) = store.start(runs)
  let build = fn(runs) {
    scheduled_job(runs, 1000, fn(receipt) {
      receipt |> should.equal("receipt")
      Ok(job.Completed(42))
    })
  }
  let handle = graph.attach(build(runs), id)
  let assert Ok(waiting) = graph.read(handle)
  waiting.status |> should.equal(graph.AwaitingJob(reference))
  let assert Ok(spec) =
    fabric.sweeper(
      runs,
      [graph.recovery(run.Identity("pg-scheduled-job", 1), build)],
      every: 20,
    )
  let assert Ok(sweeper) = spec.start()
  let done = await_idle_completion(handle, 300)
  done.status |> should.equal(graph.Completed(42))
  released(settings, id, 200) |> should.be_true
  process.unlink(sweeper.pid)
  agents.kill(sweeper.pid)
}

pub fn managed_pair(
  runs: store.Store,
) -> #(graph.Runtime(Nil, Int, Int), graph.Runtime(Nil, Int, Int)) {
  managed_pair_with(runs, fn(_, _, n) { Ok(n + 1) }, fn(_, _) {
    Ok(policy.RequireApproval(run.Requirement("child-increment", 1)))
  })
}

pub fn an_idle_parent_discovers_a_completed_child_after_losing_its_wakeup_test() {
  let settings =
    support.migrated(support.pool(4), "idle-discovery", support.schema())
  let assert Ok(id) = run.parse_id("postgres-idle-parent")
  let #(owner, #(reference, approval)) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("idle-original"), settings)
      let assert Ok(Nil) = store.start(runs)
      let #(parent, runtime) = managed_pair(runs)
      let assert Ok(handle) = graph.start(parent, id, 41)
      let assert Ok(waiting) = graph.await(handle, 5000)
      let assert graph.Child(reference, child.Approval(_)) = waiting.status
      let assert Ok(child_handle) =
        graph.child(handle, reference.activation, runtime)
      let assert Ok(snapshot) = graph.read(child_handle)
      let assert graph.AwaitingApproval(approval) = snapshot.status
      released(settings, id, 200) |> should.be_true
      released(settings, reference.child, 200) |> should.be_true
      #(reference, approval)
    })
  agents.kill(owner)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("idle-restored"), settings)
  let assert Ok(Nil) = store.start(runs)
  let #(parent, child) = managed_pair(runs)
  let handle = graph.attach(parent, id)
  let assert Ok(child) = graph.child(handle, reference.activation, child)
  let assert Ok(_) = graph.approve(child, approval)
  let assert Ok(done) = graph.await(child, 5000)
  done.status |> should.equal(graph.Completed(42))
  released(settings, id, 200) |> should.be_true
  released(settings, reference.child, 200) |> should.be_true
  let assert Ok(spec) =
    fabric.sweeper(
      runs,
      [
        graph.recovery(run.Identity("pg-parent", 1), fn(pinned) {
          managed_pair(pinned).0
        }),
      ],
      every: 20,
    )
  let assert Ok(sweeper) = spec.start()
  await_idle_completion(handle, 150).status |> should.equal(graph.Completed(42))
  process.unlink(sweeper.pid)
  agents.kill(sweeper.pid)
}

fn await_idle_completion(handle, tries) {
  let assert Ok(snapshot) = graph.await(handle, 25)
  case snapshot.status {
    graph.Completed(_) -> snapshot
    _ if tries > 0 -> {
      process.sleep(10)
      await_idle_completion(handle, tries - 1)
    }
    _ -> panic as "free parent never discovered its completed child"
  }
}

fn managed_pair_with(
  runs: store.Store,
  perform: fn(Nil, operation.Invocation, Int) -> Result(Int, Nil),
  policy: graph.Policy(Nil),
) -> #(graph.Runtime(Nil, Int, Int), graph.Runtime(Nil, Int, Int)) {
  let assert Ok(node_id) = definition.node_id("increment")
  let op =
    operation.new(
      run.Identity("increment", 1),
      codec.int(),
      codec.int(),
      perform,
      fn(_error: Nil) { operation.DefiniteFailure("cannot fail") },
    )
  let node =
    definition.node(
      node_id,
      op,
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("pg-child", 1),
      node_id,
      [node],
      codec.int(),
      codec.int(),
      1,
    ))
  let child = graph.new(spec, runs, fn() { Nil }, policy)
  let node =
    definition.node(
      node_id,
      graph.as_subgraph(child),
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("pg-parent", 1),
      node_id,
      [node],
      codec.int(),
      codec.int(),
      1,
    ))
  #(graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) }), child)
}

pub fn a_managed_subgraph_adopts_its_approved_child_after_postgres_restart_test() {
  let settings =
    support.migrated(support.pool(4), "managed-graph", support.schema())
    |> fabric_postgres.with_lease(600)
  let assert Ok(id) = run.parse_id("postgres-managed-graph")
  let #(owner, #(reference, approval)) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("managed-original"), settings)
      let assert Ok(Nil) = store.start(runs)
      let #(parent, child) = managed_pair(runs)
      let assert Ok(handle) = graph.start(parent, id, 41)
      let assert Ok(waiting) = graph.await(handle, 5000)
      let assert graph.Child(reference, child.Approval(_)) = waiting.status
      let assert Ok(child_handle) =
        graph.child(handle, reference.activation, child)
      let assert Ok(waiting) = graph.read(child_handle)
      let assert graph.AwaitingApproval(approval) = waiting.status
      released(settings, id, 200) |> should.be_true
      released(settings, reference.child, 200) |> should.be_true
      #(reference, approval)
    })
  agents.kill(owner)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("managed-restored"), settings)
  let assert Ok(Nil) = store.start(runs)
  let #(parent, child) = managed_pair(runs)
  let handle = graph.attach(parent, id)
  // An idle parent has already released its lease before the store dies.
  released(settings, id, 200) |> should.be_true
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(child_handle) = graph.child(handle, reference.activation, child)
  graph.id(child_handle) |> should.equal(reference.child)
  let assert Ok(_) = graph.approve(child_handle, approval)
  let assert Ok(done) = graph.await(handle, 5000)
  done.status |> should.equal(graph.Completed(42))
  let assert Ok(parent_row) =
    fabric_postgres.backend(settings).get(run.id_to_string(id))
  let assert Ok(child_row) =
    fabric_postgres.backend(settings).get(run.id_to_string(reference.child))
  parent_row.holder |> should.equal(store.Free)
  child_row.holder |> should.equal(store.Free)
}

pub fn child_cancellation_settlement_survives_postgres_restart_test() {
  let settings =
    support.migrated(support.pool(4), "cancel-settle", support.schema())
  let effects = process.new_subject()
  let perform = fn(_, _, _) {
    process.send(effects, Nil)
    panic as "external effect has no saved result"
  }
  let #(owner, runs) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("cancel-original"), settings)
      let assert Ok(Nil) = store.start(runs)
      runs
    })
  let #(parent, child) =
    managed_pair_with(runs, perform, fn(_, _) { Ok(policy.Allow) })
  let assert Ok(id) = run.parse_id("postgres-cancel-settlement")
  let assert Ok(handle) = graph.start(parent, id, 41)
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.Child(reference, child.Uncertain(_)) = waiting.status
  graph.cancel(handle) |> should.equal(Ok(Nil))
  let assert Ok(cancelled) = graph.await(handle, 5000)
  let assert graph.Cancelled(graph.ChildUnresolved(_, _)) = cancelled.status
  let assert Ok(child_handle) = graph.child(handle, reference.activation, child)
  let assert Ok(child_cancelled) = graph.read(child_handle)
  let assert graph.Cancelled(graph.Unresolved(reconciliation, _)) =
    child_cancelled.status
  agents.kill(owner)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("cancel-restored"), settings)
  let assert Ok(Nil) = store.start(runs)
  let #(parent, child) =
    managed_pair_with(runs, perform, fn(_, _) {
      panic as "settlement must not admit work"
    })
  let handle = graph.attach(parent, id)
  let assert Ok(child_handle) = graph.child(handle, reference.activation, child)
  let assert Ok(_) = graph.reconcile(child_handle, reconciliation, "42")
  let assert Ok(spec) =
    fabric.sweeper(
      runs,
      [
        graph.recovery(run.Identity("pg-parent", 1), fn(pinned) {
          managed_pair_with(pinned, perform, fn(_, _) {
            panic as "settlement must not admit work"
          }).0
        }),
      ],
      every: 20,
    )
  let assert Ok(sweeper) = spec.start()
  let settled = await_settlement(handle, 150)
  process.unlink(sweeper.pid)
  agents.kill(sweeper.pid)
  settled.status |> should.equal(graph.Cancelled(graph.ChildSettled(reference)))
  settled.value |> should.equal(41)
  settled.receipts |> should.equal([])
  graph.recover(handle) |> should.equal(Ok(settled))
  let assert Ok(parent_row) =
    fabric_postgres.backend(settings).get(run.id_to_string(id))
  let assert Ok(child_row) =
    fabric_postgres.backend(settings).get(run.id_to_string(reference.child))
  parent_row.holder |> should.equal(store.Free)
  child_row.holder |> should.equal(store.Free)
  process.receive(effects, 1000) |> should.equal(Ok(Nil))
  process.receive(effects, 0) |> should.equal(Error(Nil))
  fabric_postgres.prune(settings, ended_for: 0, limit: 1) |> should.equal(Ok(2))
}

fn await_settlement(handle, tries) {
  let assert Ok(snapshot) = graph.read(handle)
  case snapshot.status {
    graph.Cancelled(graph.ChildSettled(_)) -> snapshot
    _ if tries > 0 -> {
      process.sleep(10)
      await_settlement(handle, tries - 1)
    }
    _ -> panic as "canceled parent did not discover child settlement"
  }
}

fn released(
  settings: fabric_postgres.Settings,
  id: run.RunId,
  tries: Int,
) -> Bool {
  let assert Ok(row) =
    fabric_postgres.backend(settings).get(run.id_to_string(id))
  case row.holder {
    store.Free -> True
    store.Held(_, _) if tries > 0 -> {
      process.sleep(10)
      released(settings, id, tries - 1)
    }
    _ -> False
  }
}

fn managed_agent(runs: store.Store, gate: agents.Gate) {
  let assert Ok(agent) =
    agent_node.new(
      agent_node.Definition(
        run.Identity("pg-agent-node", 1),
        agents.agent(gate, 120),
        codec.int(),
        codec.string(),
        int.to_string,
        Ok,
      ),
      runs,
      fn() { Nil },
    )
  let assert Ok(id) = definition.node_id("agent")
  let node =
    definition.node(
      id,
      agent_node.as_operation(agent),
      fn(n) { Ok(n) },
      fn(n, answer) { Ok(definition.Finish(n, answer)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("pg-agent-graph", 1),
      id,
      [node],
      codec.int(),
      codec.string(),
      1,
    ))
  #(graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) }), agent)
}

pub fn a_managed_agent_keeps_its_approval_and_identity_after_postgres_restart_test() {
  let settings =
    support.migrated(support.pool(4), "graph-agent", support.schema())
    |> fabric_postgres.with_lease(600)
  let gate = agents.gate()
  let assert Ok(id) = run.parse_id("postgres-managed-agent")
  let #(owner, #(reference, approval)) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("agent-original"), settings)
      let assert Ok(Nil) = store.start(runs)
      let #(parent, _) = managed_agent(runs, gate)
      let assert Ok(handle) =
        graph.start_with_budget(parent, id, 41, budget.Limits(4, 1, 1))
      let assert Ok(waiting) = graph.await(handle, 5000)
      let assert graph.Child(reference, child.AgentInput([approval], [])) =
        waiting.status
      released(settings, id, 200) |> should.be_true
      released(settings, reference.child, 200) |> should.be_true
      #(reference, approval)
    })
  agents.kill(owner)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("agent-restored"), settings)
  let assert Ok(Nil) = store.start(runs)
  let #(parent, agent) = managed_agent(runs, gate)
  let handle = graph.attach(parent, id)
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(agent) = agent_node.child(handle, reference.activation, agent)
  fabric.id(agent) |> should.equal(reference.child)
  let assert Ok(_) = fabric.approve(agent, approval.reference, None, Nil)
  let arrival = agents.arrival(gate)
  arrival.amount |> should.equal(120)
  agents.release(arrival)
  let assert Ok(done) = graph.await(handle, 5000)
  done.status |> should.equal(graph.Completed("done: {\"done\":120}"))
  agents.another(gate, 0) |> should.be_false
  released(settings, id, 200) |> should.be_true
  released(settings, reference.child, 200) |> should.be_true
  // Root, agent and shared budget ledger form one settled retention family.
  fabric_postgres.prune(settings, ended_for: 0, limit: 1) |> should.equal(Ok(3))
  fabric_postgres.backend(settings).get(run.id_to_string(reference.child))
  |> should.equal(Error(store.NotFound))
}

pub fn a_restarted_managed_agent_cannot_reset_its_family_work_budget_test() {
  let settings =
    support.migrated(support.pool(4), "agent-budget", support.schema())
    |> fabric_postgres.with_lease(600)
  let gate = agents.gate()
  let assert Ok(id) = run.parse_id("postgres-agent-budget")
  let #(owner, #(reference, approval)) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("budget-original"), settings)
      let assert Ok(Nil) = store.start(runs)
      let #(parent, _) = managed_agent(runs, gate)
      // The graph activation and initial model attempt consume both units.
      let assert Ok(handle) =
        graph.start_with_budget(parent, id, 41, budget.Limits(2, 1, 1))
      let assert Ok(waiting) = graph.await(handle, 5000)
      let assert graph.Child(reference, child.AgentInput([approval], [])) =
        waiting.status
      released(settings, id, 200) |> should.be_true
      released(settings, reference.child, 200) |> should.be_true
      #(reference, approval)
    })
  agents.kill(owner)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("budget-restored"), settings)
  let assert Ok(Nil) = store.start(runs)
  let #(parent, worker) = managed_agent(runs, gate)
  let handle = graph.attach(parent, id)
  graph.recover(handle) |> should.be_ok
  let assert Ok(worker) = agent_node.child(handle, reference.activation, worker)
  fabric.approve(worker, approval.reference, None, Nil) |> should.be_ok
  fabric.await(worker, 5000)
  |> should.equal(
    Ok(run.Finished(run.BudgetExhausted(run.FamilyLimit(budget.WorkLimit(2))))),
  )
  let assert Ok(snapshot) = fabric.snapshot(worker)
  let assert [action] = snapshot.actions
  action.state |> should.equal(run.NotStarted)
  graph.await(handle, 5000) |> should.be_ok
  agents.another(gate, 0) |> should.be_false
  released(settings, id, 200) |> should.be_true
  released(settings, reference.child, 200) |> should.be_true
  fabric_postgres.prune(settings, ended_for: 0, limit: 1) |> should.equal(Ok(3))
}

pub fn a_registered_graph_recovers_its_agent_after_postgres_store_loss_test() {
  let settings =
    support.migrated(support.pool(4), "graph-sweep", support.schema())
    |> fabric_postgres.with_lease(600)
  let gate = agents.gate()
  let assert Ok(id) = run.parse_id("postgres-swept-graph")
  let #(owner, #(handle, worker, approval)) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("sweep-original"), settings)
      let assert Ok(Nil) = store.start(runs)
      let #(runtime, worker) = managed_agent(runs, gate)
      let assert Ok(handle) =
        graph.start_with_budget(runtime, id, 41, budget.Limits(4, 1, 1))
      let assert Ok(waiting) = graph.await(handle, 5000)
      let assert graph.Child(reference, child.AgentInput([approval], [])) =
        waiting.status
      let assert Ok(worker) =
        agent_node.child(handle, reference.activation, worker)
      #(handle, worker, approval)
    })
  fabric.approve(worker, approval.reference, None, Nil) |> should.be_ok
  let _started = agents.arrival(gate)
  agents.kill(owner)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("sweep-restored"), settings)
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(spec) =
    fabric.sweeper(
      runs,
      [
        graph.recovery(run.Identity("pg-agent-graph", 1), fn(pinned) {
          managed_agent(pinned, gate).0
        }),
      ],
      every: 20,
    )
  let assert Ok(sweeper) = spec.start()
  let #(runtime, worker) = managed_agent(runs, gate)
  let handle = graph.attach(runtime, graph.id(handle))
  let effect = swept_uncertainty(handle, 150)
  let assert Ok(worker) = agent_node.child(handle, 1, worker)
  fabric.reconcile(worker, effect.reference, "effect confirmed") |> should.be_ok
  let assert Ok(done) = graph.await(handle, 5000)
  done.status |> should.equal(graph.Completed("done: effect confirmed"))
  agents.another(gate, 0) |> should.be_false
  process.unlink(sweeper.pid)
  agents.kill(sweeper.pid)
}

fn swept_uncertainty(handle, tries) {
  let assert Ok(snapshot) = graph.await(handle, 25)
  case snapshot.status {
    graph.Child(_, child.AgentInput([], [effect])) -> effect
    _ if tries > 0 -> {
      process.sleep(10)
      swept_uncertainty(handle, tries - 1)
    }
    _ -> panic as "automatic graph recovery did not expose the interrupted tool"
  }
}

pub fn canceled_agent_evidence_settles_after_postgres_restart_test() {
  let settings =
    support.migrated(support.pool(4), "agent-settlement", support.schema())
    |> fabric_postgres.with_lease(600)
  let gate = agents.gate()
  let assert Ok(id) = run.parse_id("postgres-canceled-agent")
  let #(owner, #(handle, worker)) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("cancel-original"), settings)
      let assert Ok(Nil) = store.start(runs)
      let #(parent, worker) = managed_agent(runs, gate)
      let assert Ok(handle) = graph.start(parent, id, 41)
      #(handle, worker)
    })
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.Child(reference, child.AgentInput([approval], [])) =
    waiting.status
  let assert Ok(worker) = agent_node.child(handle, reference.activation, worker)
  let assert Ok(_) = fabric.approve(worker, approval.reference, None, Nil)
  let _started = agents.arrival(gate)
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(done) = graph.await(handle, 5000)
  let assert graph.Cancelled(graph.ChildUnresolved(_, _)) = done.status
  let assert Ok(before) = fabric.snapshot(worker)
  let assert [action] = before.actions
  let effect = run.ActionRef(reference.child, action.id)
  released(settings, id, 200) |> should.be_true
  released(settings, reference.child, 200) |> should.be_true
  agents.kill(owner)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("cancel-restored"), settings)
  let assert Ok(Nil) = store.start(runs)
  fabric_postgres.prune(settings, ended_for: 0, limit: 1) |> should.equal(Ok(0))
  let assert Ok(settled) =
    fabric.reconcile_stored(runs, effect, "effect confirmed")
  settled.status |> should.equal(run.Finished(run.Cancelled))
  fabric.settle_stored(runs, reference.child) |> should.be_ok
  let #(parent, worker) = managed_agent(runs, gate)
  let handle = graph.attach(parent, id)
  let assert Ok(done) = graph.recover(handle)
  done.status |> should.equal(graph.Cancelled(graph.ChildSettled(reference)))
  done.receipts |> should.equal([])
  let assert Ok(worker) = agent_node.child(handle, reference.activation, worker)
  let assert Ok(after) = fabric.snapshot(worker)
  after.status |> should.equal(before.status)
  after.transcript |> should.equal(before.transcript)
  after.turns_used |> should.equal(before.turns_used)
  after.usage |> should.equal(before.usage)
  agents.another(gate, 0) |> should.be_false
  released(settings, id, 200) |> should.be_true
  released(settings, reference.child, 200) |> should.be_true
  fabric_postgres.prune(settings, ended_for: 0, limit: 1) |> should.equal(Ok(2))
  fabric_postgres.backend(settings).get(run.id_to_string(reference.child))
  |> should.equal(Error(store.NotFound))
}

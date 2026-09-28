//// Several nodes sharing one database, simulated by leased stores of
//// distinct node ids over one in-memory leased backend: a run's lease
//// says which node drives it, a live lease elsewhere reads `Working` and
//// is never taken, a command on an idle run works from any node, and a
//// runner commits only while its store holds the lease.

import fabric
import fabric/agent.{type Agent}
import fabric/observation as o
import fabric/policy
import fabric/run.{Requirement}
import fabric/store
import fabric/support
import fabric/support/nodes
import fabric/support/probe.{type Probe}
import fabric/support/restart
import fabric/support/scripted
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import sinal

fn one_slow(probe: Probe) -> Agent(Nil) {
  agent.new(
    "agent",
    scripted.plan([scripted.slow("a", "a")]),
    [scripted.gated_tool(probe)],
    policy.always_allow(),
  )
  |> support.agent
}

/// Every call of the gated tool whose input is `b` needs an approval.
fn b_reviewed(
  _context: Nil,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  case string.contains(action.arguments_json, "\"b\"") {
    True -> Ok(policy.RequireApproval(Requirement("review", 1)))
    False -> Ok(policy.Allow)
  }
}

fn states(run: fabric.Run(context)) -> List(run.ActionState) {
  let assert Ok(snapshot) = fabric.snapshot(run)
  list.map(snapshot.actions, fn(action) { action.state })
}

pub fn a_leased_store_checks_its_settings_test() {
  let backend = store.leased_memory().backend
  let name = process.new_name("settings")
  let leased = fn(node, lease) {
    store.leased(name, node:, lease:, backend:) |> result_error
  }
  leased("", 1000) |> should.equal(Error(store.InvalidNodeId("")))
  leased("a/b", 1000) |> should.equal(Error(store.InvalidNodeId("a/b")))
  leased("nonode@nohost", 1000)
  |> should.equal(Error(store.InvalidNodeId("nonode@nohost")))
  leased(string.repeat("n", 129), 1000)
  |> should.equal(Error(store.InvalidNodeId(string.repeat("n", 129))))
  leased("app@host-1.example:9", 99)
  |> should.equal(Error(store.LeaseTooShort(99, 100)))
  leased("app@host-1.example:9", 4_294_967_296)
  |> should.equal(Error(store.LeaseTooLong(4_294_967_296, 4_294_967_295)))
  leased("app@host-1.example:9", 100) |> should.equal(Ok(Nil))
  leased("app@host-1.example:9", 4_294_967_295) |> should.equal(Ok(Nil))
}

fn result_error(
  result: Result(a, store.LeaseConfigError),
) -> Result(Nil, store.LeaseConfigError) {
  case result {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

/// A run's lease is claimed with the work its runner is given, held while
/// the runner works, and released when nothing is left in flight.
pub fn a_runner_holds_its_runs_lease_while_it_works_test() {
  let probe = probe.new()
  let memory = store.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let assert Ok(run) = fabric.start(a, one_slow(probe), Nil, "go")
  let running = probe.arrival(probe)
  nodes.holding(memory.backend, fabric.id(run))
  |> should.equal(Ok(#("a", True)))
  probe.release(running)
  fabric.await(run, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  nodes.holding(memory.backend, fabric.id(run)) |> should.equal(Error(Nil))
}

/// Another node sees a run whose lease is live as `Working`, although it
/// knows no runner of it.
pub fn a_live_lease_elsewhere_reads_working_test() {
  let probe = probe.new()
  let memory = store.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let assert Ok(run) = fabric.start(a, one_slow(probe), Nil, "go")
  let running = probe.arrival(probe)
  let assert Ok(seen) = fabric.open(b, one_slow(probe), Nil, fabric.id(run))
  fabric.await(seen, 0) |> should.equal(Ok(run.Working))
  let assert Ok(snapshot) = fabric.snapshot(seen)
  snapshot.status |> should.equal(run.Working)
  probe.release(running)
  fabric.await(run, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
}

/// `recover` on another node leaves a run whose lease is live exactly as
/// it is: its runner keeps working and nothing becomes uncertain.
pub fn recover_does_not_take_a_live_lease_test() {
  let probe = probe.new()
  let memory = store.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let assert Ok(run) = fabric.start(a, one_slow(probe), Nil, "go")
  let running = probe.arrival(probe)
  let assert Ok(before) = fabric.snapshot(run)
  let revision = nodes.revision(memory.backend, fabric.id(run))
  let assert Ok(recovered) =
    fabric.recover(b, one_slow(probe), Nil, fabric.id(run))
  fabric.snapshot(run) |> should.equal(Ok(before))
  nodes.revision(memory.backend, fabric.id(run)) |> should.equal(revision)
  nodes.holding(memory.backend, fabric.id(run))
  |> should.equal(Ok(#("a", True)))
  fabric.await(recovered, 0) |> should.equal(Ok(run.Working))
  probe.release(running)
  fabric.await(run, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\""))))
  probe.count(probe, "start:a") |> should.equal(1)
}

/// An approval of an idle run works from any node: the node that commits
/// it claims the lease and runs the approved tool.
pub fn an_approval_of_an_idle_run_on_another_node_claims_the_lease_test() {
  let probe = probe.new()
  let memory = store.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("b", "b")]),
      [scripted.gated_tool(probe)],
      b_reviewed,
    )
    |> support.agent
  let assert Ok(run) = fabric.start(a, agent, Nil, "go")
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)
  nodes.holding(memory.backend, fabric.id(run)) |> should.equal(Error(Nil))
  let assert Ok(there) = fabric.open(b, agent, Nil, fabric.id(run))
  let assert Ok(run.Working) =
    fabric.approve(there, pending.reference, reviewer: None, context: Nil)
  let running = probe.arrival(probe)
  nodes.holding(memory.backend, fabric.id(run))
  |> should.equal(Ok(#("b", True)))
  let assert Ok(_) = restart.runner(b, fabric.id(run))
  restart.runner(a, fabric.id(run)) |> should.equal(Error(Nil))
  probe.release(running)
  fabric.await(there, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("final: \"b\""))))
}

/// An approval that needs the runner another node holds the lease for is
/// `RunUnattended` and changes nothing; through that node it works.
pub fn an_approval_needing_another_nodes_runner_is_unattended_test() {
  let probe = probe.new()
  let memory = store.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let agent =
    agent.new(
      "agent",
      scripted.plan([scripted.slow("a", "a"), scripted.slow("b", "b")]),
      [scripted.gated_tool(probe)],
      b_reviewed,
    )
    |> support.agent
  let assert Ok(run) = fabric.start(a, agent, Nil, "go")
  let running = probe.arrival(probe)
  let assert Ok([pending]) = fabric.pending(run)
  let assert Ok(before) = fabric.snapshot(run)
  let assert Ok(there) = fabric.open(b, agent, Nil, fabric.id(run))
  fabric.approve(there, pending.reference, reviewer: None, context: Nil)
  |> should.equal(Error(fabric.RunUnattended))
  fabric.snapshot(run) |> should.equal(Ok(before))
  let assert Ok(run.Working) =
    fabric.approve(run, pending.reference, reviewer: None, context: Nil)
  let second = probe.arrival(probe)
  probe.release(running)
  probe.release(second)
  fabric.await(run, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("final: \"a\" | \"b\""))))
}

/// A cancellation from another node wins over the live lease: it is
/// committed at once, the running tool becomes an uncertain effect, and
/// the old runner can commit nothing more.
pub fn a_cancellation_from_another_node_wins_over_a_live_lease_test() {
  let probe = probe.new()
  let memory = store.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let b = nodes.node(memory.backend, "b", nodes.long)
  let assert Ok(run) = fabric.start(a, one_slow(probe), Nil, "go")
  let running = probe.arrival(probe)
  let assert Ok(runner) = restart.runner(a, fabric.id(run))
  let assert Ok(there) = fabric.open(b, one_slow(probe), Nil, fabric.id(run))
  fabric.cancel(there)
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  nodes.holding(memory.backend, fabric.id(run)) |> should.equal(Error(Nil))
  let revision = nodes.revision(memory.backend, fabric.id(run))
  probe.release(running)
  restart.gone(runner)
  nodes.revision(memory.backend, fabric.id(run)) |> should.equal(revision)
  let assert [run.Uncertain(_)] = states(there)
}

/// A runner commits only while its store holds the run's lease: once
/// another owner claimed the expired lease, the runner's next commit, the
/// fence of a tool's start, is refused, and the tool's body never starts.
pub fn a_tool_start_is_refused_once_another_owner_claimed_the_lease_test() {
  let probe = probe.new()
  let memory = store.leased_memory()
  let a = nodes.node(memory.backend, "a", nodes.long)
  let replies = process.new_subject()
  let assert Ok(id) =
    sinal.handler_id("lease-test-claim" <> int.to_string(int.random(1_000_000)))
  // The handler runs in the runner right after the model reply that queues
  // the tool is committed, before the tool starts, and holds it there.
  let assert Ok(attachment) =
    sinal.observe(id, o.model_turn(), fn(_, turn: o.ModelTurn) {
      let go = process.new_subject()
      process.send(replies, #(turn.run, process.self(), go))
      let _ = process.receive(go, 5000)
      Nil
    })
  let assert Ok(run) = fabric.start(a, one_slow(probe), Nil, "go")
  let assert Ok(#(replied, runner, go)) = process.receive(replies, 5000)
  let _ = sinal.detach(attachment)
  replied |> should.equal(support.text(fabric.id(run)))
  // Meanwhile the lease expires and another owner (a sweeper) claims it.
  memory.advance(nodes.long + 1)
  memory.backend.claim_expired("sweeper", nodes.long, 10)
  |> should.equal(Ok([support.text(fabric.id(run))]))
  process.send(go, Nil)
  restart.gone(runner)
  probe.count(probe, "start:a") |> should.equal(0)
  states(run) |> should.equal([run.Queued])
  nodes.holder(memory.backend, fabric.id(run))
  |> should.equal(store.Held("sweeper", True))
}

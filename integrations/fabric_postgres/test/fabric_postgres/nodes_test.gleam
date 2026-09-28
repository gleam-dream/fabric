//// Two nodes, simulated by two leased stores with two pools of their own
//// on one database: a live lease on one node reads `Working` on the other
//// and is never taken; an expired lease is taken over exactly once; a
//// cancellation from the other node wins over a live lease.

import fabric
import fabric/run
import fabric/store.{type Store}
import fabric_postgres.{type Settings}
import fabric_postgres/agents
import fabric_postgres/support
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit/should

/// Leases short enough to expire within a test: renewed every 200 ms.
const lease = 600

/// The settings of `node` over a pool of its own, in `schema`.
fn node_settings(node: String, schema: String) -> Settings {
  let assert Ok(settings) =
    fabric_postgres.settings(support.pool(4), node:)
    |> fabric_postgres.with_schema(schema)
  fabric_postgres.with_lease(settings, lease)
}

/// A started store of `node`, linked to the caller.
fn node(node: String, schema: String) -> Store {
  started(node_settings(node, schema))
}

fn started(settings: Settings) -> Store {
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("fabric_postgres_node"), settings)
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn fresh_schema() -> String {
  let schema = support.schema()
  let _ = support.migrated(support.pool(1), "setup", schema)
  schema
}

/// The node whose store holds the run's lease, and whether it is live.
fn holder(schema: String, id: run.RunId) -> Result(#(String, Bool), Nil) {
  let backend = fabric_postgres.backend(node_settings("probe", schema))
  let assert Ok(current) = backend.get(run.id_to_string(id))
  case current.holder {
    store.Held(owner, live) -> {
      let assert Ok(#(node, _)) = string.split_once(owner, "/")
      Ok(#(node, live))
    }
    store.Free -> Error(Nil)
  }
}

fn incarnation(run: fabric.Run(Nil)) -> Int {
  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.incarnation
}

/// Runs `body` for each of `items` in its own process, all at once.
fn together(items: List(a), body: fn(a) -> b) -> List(b) {
  let results = process.new_subject()
  list.each(items, fn(item) {
    process.spawn(fn() { process.send(results, body(item)) })
  })
  list.map(items, fn(_) {
    let assert Ok(result) = process.receive(results, 10_000)
    result
  })
}

pub fn a_live_lease_on_one_node_reads_working_on_the_other_test() {
  let schema = fresh_schema()
  let gate = agents.gate()
  let agent = agents.agent(gate, 5)
  let a = node("a", schema)
  let b = node("b", schema)
  let assert Ok(started) = fabric.start(a, agent, Nil, "go")
  let arrival = agents.arrival(gate)
  let id = fabric.id(started)
  holder(schema, id) |> should.equal(Ok(#("a", True)))
  let assert Ok(seen) = fabric.open(b, agent, Nil, id)
  fabric.await(seen, 0) |> should.equal(Ok(run.Working))
  // Longer than a lease: node a's renewals keep it live.
  process.sleep(lease + 300)
  let assert Ok(recovered) = fabric.recover(b, agent, Nil, id)
  fabric.await(recovered, 0) |> should.equal(Ok(run.Working))
  incarnation(seen) |> should.equal(1)
  holder(schema, id) |> should.equal(Ok(#("a", True)))
  agents.release(arrival)
  // Node b sees the end committed by node a.
  fabric.await(seen, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("done: {\"done\":5}"))))
  holder(schema, id) |> should.equal(Error(Nil))
  agents.another(gate, 100) |> should.be_false
}

/// Node a dies with a tool running. Until its lease expires, recoveries on
/// b and c take nothing; after it, racing recoveries take the run over
/// once: the running tool is an uncertain effect, never run again, and
/// once reconciled the run finishes.
pub fn an_expired_lease_is_taken_over_exactly_once_test() {
  let schema = fresh_schema()
  let gate = agents.gate()
  let agent = agents.agent(gate, 5)
  // Node a's pool outlives it here, which changes nothing for the test.
  let settings = node_settings("a", schema)
  let #(owner, id) =
    agents.owned(fn() {
      let a = started(settings)
      let assert Ok(started) = fabric.start(a, agent, Nil, "go")
      fabric.id(started)
    })
  let arrival = agents.arrival(gate)
  agents.kill(owner)
  agents.gone(arrival.body, 1000) |> should.be_true
  let others = [node("b", schema), node("c", schema)]
  let recover_all = fn() {
    together(others, fn(node) {
      let assert Ok(there) = fabric.recover(node, agent, Nil, id)
      fabric.await(there, 0)
    })
  }
  recover_all() |> list.unique |> should.equal([Ok(run.Working)])
  let assert [b, ..] = others
  let assert Ok(seen) = fabric.open(b, agent, Nil, id)
  incarnation(seen) |> should.equal(1)
  process.sleep(lease + 100)
  let assert [Ok(run.Suspended([], [uncertain]))] = list.unique(recover_all())
  incarnation(seen) |> should.equal(2)
  holder(schema, id) |> should.equal(Error(Nil))
  agents.another(gate, 200) |> should.be_false
  let assert Ok(_) = fabric.reconcile(seen, uncertain.reference, "{\"done\":5}")
  fabric.await(seen, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("done: {\"done\":5}"))))
  agents.another(gate, 100) |> should.be_false
}

/// A cancellation on node b commits at once over node a's live lease;
/// node a learns of it at its next renewal and kills its runner with the
/// tool's body, which never finishes or runs again.
pub fn a_cancellation_from_the_other_node_wins_test() {
  let schema = fresh_schema()
  let gate = agents.gate()
  let agent = agents.agent(gate, 5)
  let a = node("a", schema)
  let b = node("b", schema)
  let assert Ok(started) = fabric.start(a, agent, Nil, "go")
  let arrival = agents.arrival(gate)
  let id = fabric.id(started)
  fabric.cancel_stored(b, id)
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  holder(schema, id) |> should.equal(Error(Nil))
  agents.gone(arrival.body, 2000) |> should.be_true
  fabric.await(started, 0) |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert Ok(snapshot) = fabric.snapshot(started)
  let assert [run.Uncertain(_)] =
    list.map(snapshot.actions, fn(action) { action.state })
  agents.another(gate, 100) |> should.be_false
}

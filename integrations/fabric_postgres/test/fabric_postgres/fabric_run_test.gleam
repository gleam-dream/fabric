//// Fabric runs on the PostgreSQL store: a run that waits for an approval
//// outlives its store, and a write whose reply is lost is confirmed by
//// reading it back.

import fabric
import fabric/run
import fabric/store
import fabric_postgres
import fabric_postgres/agents
import fabric_postgres/support
import gleam/erlang/process
import gleam/option.{Some}
import gleeunit/should

/// A run starts, suspends for an approval, and the store stops; a new
/// store process over the same table opens it, the approval runs the tool,
/// and the run finishes.
pub fn a_suspended_run_is_approved_after_a_store_restart_and_finishes_test() {
  let gate = agents.gate()
  let agent = agents.agent(gate, 500)
  let schema = support.schema()
  let name = process.new_name("fabric_postgres_runs")
  let settings = support.migrated(support.pool(4), "a", schema)
  let #(owner, id) =
    agents.owned(fn() {
      let assert Ok(runs) = fabric_postgres.store(name, settings)
      let assert Ok(Nil) = store.start(runs)
      let assert Ok(started) = fabric.start(runs, agent, Nil, "work")
      let assert Ok(run.Suspended([_], [])) = fabric.await(started, 5000)
      fabric.id(started)
    })
  // The store and everything it started stop.
  agents.kill(owner)
  let assert Ok(runs) = fabric_postgres.store(name, settings)
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(opened) = fabric.open(runs, agent, Nil, id)
  let assert Ok(run.Suspended([pending], [])) = fabric.await(opened, 0)
  pending.tool |> should.equal("work")
  let assert Ok(run.Working) =
    fabric.approve(
      opened,
      pending.reference,
      reviewer: Some("reviewer"),
      context: Nil,
    )
  let arrival = agents.arrival(gate)
  arrival.amount |> should.equal(500)
  agents.release(arrival)
  fabric.await(opened, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("done: {\"done\":500}"))))
  agents.another(gate, 100) |> should.be_false
}

/// A backend whose writes are performed but whose replies are lost (each
/// returns `Unavailable` after writing): Fabric reads each write back,
/// finds its own record at the revision it wrote, and the run finishes
/// as if nothing were lost.
pub fn writes_whose_replies_are_lost_are_confirmed_by_reading_back_test() {
  let gate = agents.gate()
  let settings = support.migrated(support.pool(4), "a", support.schema())
  let backend = fabric_postgres.backend(settings)
  let lost = fn(outcome) {
    case outcome {
      Ok(Nil) -> Error(store.Unavailable("the reply was lost"))
      refused -> refused
    }
  }
  let lossy =
    store.LeasedBackend(
      ..backend,
      insert: fn(run, record, lease) {
        lost(backend.insert(run, record, lease))
      },
      compare_and_set: fn(run, expected, record, lease) {
        lost(backend.compare_and_set(run, expected, record, lease))
      },
    )
  let assert Ok(runs) =
    store.leased(
      process.new_name("fabric_postgres_lossy"),
      node: "a",
      lease: 30_000,
      backend: lossy,
    )
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(started) = fabric.start(runs, agents.agent(gate, 5), Nil, "go")
  agents.release(agents.arrival(gate))
  fabric.await(started, 5000)
  |> should.equal(Ok(run.Finished(run.Completed("done: {\"done\":5}"))))
  agents.another(gate, 100) |> should.be_false
}

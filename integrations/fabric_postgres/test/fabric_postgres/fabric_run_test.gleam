//// Fabric runs on the PostgreSQL store: a run that waits for an approval
//// outlives its store, and a write whose reply is lost is confirmed by
//// reading it back.

import fabric
import fabric/reviewer
import fabric/run
import fabric/store
import fabric/store/backend
import fabric_postgres
import fabric_postgres/agents
import fabric_postgres/support
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None}
import gleam/time/duration
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
      let assert Ok(started) =
        fabric.start(
          runs,
          agent,
          id: run.new_id(),
          context: Nil,
          prompt: "work",
          correlation: None,
        )
      let assert Ok(run.Suspended([_], [])) =
        fabric.await(started, within: duration.milliseconds(5000))
      fabric.id(started)
    })
  // The store and everything it started stop.
  agents.kill(owner)
  let assert Ok(runs) = fabric_postgres.store(name, settings)
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(opened) = fabric.open(runs, agent, Nil, id)
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(opened, within: duration.milliseconds(0))
  pending.tool |> should.equal("work")
  let assert Ok(run.Working) =
    fabric.approve(
      opened,
      pending.reference,
      reviewer: reviewer.new("reviewer"),
      context: Nil,
    )
  let arrival = agents.arrival(gate)
  arrival.amount |> should.equal(500)
  agents.release(arrival)
  fabric.await(opened, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done: {\"done\":500}"))))
  agents.another(gate, 100) |> should.be_false
}

/// A backend whose writes are performed but whose replies are lost (each
/// returns `Unavailable` after writing): Fabric reads each write back,
/// finds its own record at the revision it wrote, and the run finishes
/// as if nothing were lost.
pub fn writes_whose_replies_are_lost_are_confirmed_by_reading_back_test() {
  lost_replies(4)
}

pub fn version_2_writes_keep_exact_bytes_when_replies_are_lost_test() {
  lost_replies(2)
}

fn lost_replies(version: Int) {
  let gate = agents.gate()
  let settings = support.migrated(support.pool(4), "a", support.schema())
  let backend = fabric_postgres.backend(settings)
  let lost = fn(outcome) {
    case outcome {
      Ok(Nil) -> Error(backend.Unavailable("the reply was lost"))
      refused -> refused
    }
  }
  let lossy =
    backend.LeasedBackend(
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
      lease: duration.milliseconds(30_000),
      backend: lossy,
    )
  let assert Ok(runs) = store.with_record_version(runs, version)
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(started) =
    fabric.start(
      runs,
      agents.agent(gate, 5),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  agents.release(agents.arrival(gate))
  fabric.await(started, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done: {\"done\":5}"))))
  agents.another(gate, 100) |> should.be_false
  stored_version(backend, fabric.id(started)) |> should.equal(version)
}

fn stored_version(backend: backend.LeasedBackend, id: run.RunId) -> Int {
  let assert Ok(row) = backend.get(run.id_to_string(id))
  let header = {
    use version <- decode.field("version", decode.int)
    decode.success(version)
  }
  let assert Ok(version) = json.parse(row.record, header)
  version
}

/// Configuration composes with the public PostgreSQL adapter. Old records
/// stay readable after the application switches its writer to version 4.
pub fn the_postgres_adapter_supports_the_write_version_window_test() {
  let settings = support.migrated(support.pool(4), "a", support.schema())
  let backend = fabric_postgres.backend(settings)
  let gate = agents.gate()
  let agent = agents.agent(gate, 500)
  let assert Ok(old_writes) =
    fabric_postgres.store(process.new_name("old-writes"), settings)
  let assert Ok(old_writes) = store.with_record_version(old_writes, 2)
  let assert Ok(Nil) = store.start(old_writes)
  let assert Ok(started) =
    fabric.start(
      old_writes,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(started, within: duration.milliseconds(5000))
  stored_version(backend, fabric.id(started)) |> should.equal(2)

  let assert Ok(new_writes) =
    fabric_postgres.store(process.new_name("new-writes"), settings)
  let assert Ok(new_writes) = store.with_record_version(new_writes, 4)
  let assert Ok(Nil) = store.start(new_writes)
  let assert Ok(opened) =
    fabric.open(new_writes, agent, Nil, fabric.id(started))
  let assert Ok(_) =
    fabric.approve(
      opened,
      pending.reference,
      reviewer: reviewer.new("reviewer"),
      context: Nil,
    )
  agents.release(agents.arrival(gate))
  fabric.await(opened, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done: {\"done\":500}"))))
  stored_version(backend, fabric.id(started)) |> should.equal(4)
  agents.another(gate, 100) |> should.be_false
}

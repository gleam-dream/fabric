//// A real VM crash: an isolated OTP peer owns a PostgreSQL run, and a
//// supervised sweeper recovers it after the operating system kills the VM.

import fabric
import fabric/run
import fabric/store
import fabric_postgres
import fabric_postgres/agents
import fabric_postgres/support
import gleam/erlang/process
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/string
import gleam/time/duration
import gleeunit/should

pub type Peer

@external(erlang, "fabric_postgres_peer_test_ffi", "with_peer")
fn with_peer(body: fn(Peer) -> a) -> a

@external(erlang, "fabric_postgres_peer_test_ffi", "start_run")
fn start_run(peer: Peer, schema: String, lease: Int) -> run.RunId

@external(erlang, "fabric_postgres_peer_test_ffi", "kill_peer")
fn kill_peer(peer: Peer) -> Nil

const lease = 600

/// Called inside the peer VM. Its owner process retains the pool, store,
/// and gated tool after the peer's RPC handler returns the run id.
pub fn start_owned_run(schema: String, lease: Int) -> run.RunId {
  let #(_, id) =
    agents.owned(fn() {
      let gate = agents.gate()
      let settings =
        support.migrated(support.pool(4), "peer", schema)
        |> fabric_postgres.with_lease(duration.milliseconds(lease))
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("fabric_peer_runs"), settings)
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
      let arrival = agents.arrival(gate)
      arrival.amount |> should.equal(5)
      fabric.id(started)
    })
  id
}

fn incarnation(run: fabric.Run(Nil)) -> Int {
  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.incarnation
}

/// `await` may see an expired lease before the next sweep has claimed it.
fn settled(run: fabric.Run(Nil), tries: Int) -> run.Status {
  let assert Ok(status) = fabric.await(run, within: duration.milliseconds(100))
  case status {
    run.Working | run.Unattended if tries > 0 -> {
      process.sleep(10)
      settled(run, tries - 1)
    }
    other -> other
  }
}

pub fn a_killed_peer_is_recovered_once_without_replaying_its_tool_test() {
  use peer <- with_peer
  let schema = support.schema()
  let id = start_run(peer, schema, lease)
  let gate = agents.gate()
  let agent = agents.agent(gate, 5)
  let settings =
    support.migrated(support.pool(4), "survivor", schema)
    |> fabric_postgres.with_lease(duration.milliseconds(lease))
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("fabric_survivor_runs"), settings)
  let assert Ok(sweeper) =
    fabric.sweeper(
      runs,
      [fabric.recovery(agent, fn(_) { Nil })],
      every: duration.milliseconds(25),
    )
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.add(store.supervised(runs))
    |> static_supervisor.add(sweeper)
    |> static_supervisor.start
  let assert Ok(seen) = fabric.open(runs, agent, Nil, id)

  // The boot scan and repeated scans leave a live remote lease alone,
  // including beyond its original duration while the peer renews it.
  fabric.await(seen, within: duration.milliseconds(lease + 300))
  |> should.equal(Ok(run.Working))
  incarnation(seen) |> should.equal(1)
  let backend = fabric_postgres.backend(settings)
  let assert Ok(store.Current(holder: store.Held(owner, True), ..)) =
    backend.get(run.id_to_string(id))
  string.starts_with(owner, "peer/") |> should.be_true

  kill_peer(peer)
  // No graceful handoff occurred: the surviving node still respects the
  // dead peer's unexpired lease before recovering its running action.
  fabric.await(seen, within: duration.milliseconds(0))
  |> should.equal(Ok(run.Working))
  incarnation(seen) |> should.equal(1)
  let assert run.Suspended([], [uncertain]) = settled(seen, 50)
  incarnation(seen) |> should.equal(2)
  uncertain.tool |> should.equal("work")
  agents.another(gate, 200) |> should.be_false
  incarnation(seen) |> should.equal(2)

  let assert Ok(_) = fabric.reconcile(seen, uncertain.reference, "{\"done\":5}")
  fabric.await(seen, within: duration.milliseconds(5000))
  |> should.equal(Ok(run.Finished(run.Completed("done: {\"done\":5}"))))
  agents.another(gate, 100) |> should.be_false
  incarnation(seen) |> should.equal(2)
}

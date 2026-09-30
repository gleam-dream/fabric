//// D1–D3: deadline time belongs to storage and cannot fall back silently.

import fabric/store
import fabric/support
import fabric/support/nodes
import fabric/support/probe
import fabric/support/restart
import fabric/testing
import gleam/erlang/process
import gleeunit/should

pub fn stores_share_backend_time_across_restart_without_changing_records_test() {
  let memory = testing.leased_memory()
  let #(owner, runs) =
    restart.owned(fn() { nodes.node(memory.backend, "clock-a", nodes.long) })
  let other = nodes.node(memory.backend, "clock-b", nodes.long)
  let assert Ok(_) =
    store.insert(runs, "clock-record", "retained", store.Detached(False, False))
  let assert Ok(before) = memory.backend.get("clock-record")
  let assert Ok(start) = store.now(runs)
  memory.advance(60_000)
  let assert Ok(advanced) = store.now(other)
  should.be_true(advanced >= start + 60_000)
  restart.crash(owner, runs)
  let restored = nodes.node(memory.backend, "clock-a", nodes.long)
  let assert Ok(recovered) = store.now(restored)
  should.be_true(recovered >= advanced)
  memory.backend.get("clock-record") |> should.equal(Ok(before))
}

pub fn an_unavailable_clock_never_uses_local_time_and_does_not_block_run_reads_test() {
  let memory = testing.leased_memory()
  let held = probe.new()
  let backend =
    store.LeasedBackend(..memory.backend, now: fn() {
      probe.gate(held, "clock")
      Ok(1)
    })
  let runs =
    nodes.node(backend, "clock", nodes.long) |> store.with_backend_timeout(500)
  let assert Ok(_) =
    store.insert(runs, "clock-record", "retained", store.Detached(False, False))
  let reply = process.new_subject()
  process.spawn(fn() { process.send(reply, store.now(runs)) })
  let _ = probe.arrival(held)
  process.receive(reply, 0) |> should.equal(Error(Nil))
  let assert Ok(row) = store.get(runs, "clock-record")
  row.record |> should.equal("retained")
  process.receive(reply, 0) |> should.equal(Error(Nil))
  let assert Ok(Error(store.Unavailable(_))) = process.receive(reply, 5000)
  let failed =
    store.LeasedBackend(..memory.backend, now: fn() {
      Error(store.Unavailable("clock offline"))
    })
  store.now(nodes.node(failed, "offline", nodes.long))
  |> should.equal(Error(store.Unavailable("clock offline")))
  let crashing =
    store.LeasedBackend(..memory.backend, now: fn() { panic as "clock crashed" })
  let assert Error(store.Unavailable(_)) =
    store.now(nodes.node(crashing, "crashed", nodes.long))
}

pub fn unleased_stores_use_an_epoch_that_survives_reopening_test() {
  let directory = restart.temp_dir()
  let first = support.directory(directory)
  let assert Ok(before) = store.now(first)
  // UTC milliseconds in the twenty-first century, not BEAM monotonic ticks.
  should.be_true(before > 946_684_800_000)
  let second = support.directory(directory)
  let assert Ok(after) = store.now(second)
  should.be_true(after >= before)
  let assert Ok(memory) = store.now(support.store())
  should.be_true(memory >= after)
  restart.remove_dir(directory)
}

import app
import fabric
import fabric/agent.{type Agent}
import fabric/observation
import fabric/run
import fabric/store
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/string
import gleeunit
import gleeunit/should
import sinal

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn a_member_finds_and_reserves_a_book_test() {
  let assert Ok(run) =
    fabric.start(memory(), librarian(), app.member("ada"), "reserve Dune")
  fabric.await(run, 5000)
  |> should.equal(
    Ok(
      run.Finished(run.Completed(
        "done: {\"isbn\":\"978-0441013593\",\"title\":\"Dune\"} | {\"confirmation\":\"ada:978-0441013593\"}",
      )),
    ),
  )
}

pub fn a_missing_book_is_explained_to_the_model_test() {
  let assert Ok(run) =
    fabric.start(
      memory(),
      librarian(),
      app.member("ada"),
      "reserve Necronomicon",
    )
  fabric.await(run, 5000)
  |> should.equal(
    Ok(
      run.Finished(run.Completed(
        "sorry: {\"error\":\"no book titled Necronomicon\"}",
      )),
    ),
  )
}

pub fn the_policy_denies_guests_with_a_visible_reason_test() {
  let assert Ok(run) =
    fabric.start(memory(), librarian(), app.member("guest"), "reserve Dune")
  let assert Ok(run.Finished(run.Completed(answer))) = fabric.await(run, 5000)
  answer
  |> should.equal(
    "done: {\"isbn\":\"978-0441013593\",\"title\":\"Dune\"} | {\"error\":\"denied\",\"detail\":\"guests cannot reserve\"}",
  )
}

pub fn an_unavailable_member_directory_is_a_host_failure_test() {
  let assert Ok(run) =
    fabric.start(memory(), librarian(), app.member(""), "reserve Dune")
  let assert Ok(run.Finished(run.Failed(run.PolicyFailed(_, reason)))) =
    fabric.await(run, 5000)
  reason |> should.equal("member directory unavailable")
}

pub fn a_long_inventory_scan_can_be_cancelled_test() {
  let arrivals = process.new_subject()
  let assert Ok(run) =
    fabric.start(
      memory(),
      librarian(),
      app.member_with_scan_gate("ada", arrivals),
      "scan the inventory",
    )
  // The scan body is running and blocked.
  let assert Ok(_release) = process.receive(arrivals, 5000)
  let assert Ok(_) = fabric.cancel(run)
  fabric.await(run, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
  let assert Ok(snapshot) = fabric.snapshot(run)
  snapshot.actions
  |> list.map(fn(action) { action.state })
  |> should.equal([run.Uncertain("stopped while running")])
}

pub fn the_configuration_is_checked_before_anything_starts_test() {
  app.librarian() |> should.be_ok
  app.misconfigured() |> should.be_error
}

// --- approvals, cancellation, restart -----------------------------------------

pub fn a_guardian_approves_a_junior_reservation_test() {
  let assert Ok(run) =
    fabric.start(memory(), librarian(), app.member("junior"), "reserve Dune")
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)
  pending.tool |> should.equal("reserve_book")
  let assert Ok(_) =
    fabric.approve(
      run,
      pending.reference,
      reviewer: Some("guardian-ann"),
      context: app.member("junior"),
    )
  fabric.await(run, 5000)
  |> should.equal(
    Ok(
      run.Finished(run.Completed(
        "done: {\"isbn\":\"978-0441013593\",\"title\":\"Dune\"} | {\"confirmation\":\"junior:978-0441013593\"}",
      )),
    ),
  )
}

pub fn a_rejected_reservation_is_explained_to_the_model_test() {
  let assert Ok(run) =
    fabric.start(memory(), librarian(), app.member("junior"), "reserve Dune")
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)
  let assert Ok(_) =
    fabric.reject(
      run,
      pending.reference,
      reason: "ask again tomorrow",
      reviewer: Some("guardian-ann"),
    )
  fabric.await(run, 5000)
  |> should.equal(
    Ok(
      run.Finished(run.Completed(
        "done: {\"isbn\":\"978-0441013593\",\"title\":\"Dune\"} | {\"error\":\"rejected\",\"detail\":\"ask again tomorrow\"}",
      )),
    ),
  )
}

pub fn a_paused_reservation_can_be_cancelled_test() {
  let assert Ok(run) =
    fabric.start(memory(), librarian(), app.member("junior"), "reserve Dune")
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)
  fabric.cancel(run) |> should.equal(Ok(run.Finished(run.Cancelled)))
  fabric.approve(
    run,
    pending.reference,
    reviewer: None,
    context: app.member("junior"),
  )
  |> should.equal(Error(fabric.RunEnded))
}

/// The process that started the run dies with its store; the paused run
/// survives on disk, and a new process recovers and approves it.
pub fn a_paused_reservation_survives_a_restart_test() {
  let dir =
    temp_root()
    <> "/fabric-restart-"
    <> int.to_string(int.random(1_000_000_000))
  let started = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let store = store.directory(process.new_name("desk-store"), dir)
      let assert Ok(Nil) = store.start(store)
      let assert Ok(run) =
        fabric.start(store, librarian(), app.member("junior"), "reserve Dune")
      let assert Ok(run.Suspended([_], [])) = fabric.await(run, 5000)
      process.send(started, fabric.id(run))
      process.sleep_forever()
    })
  let assert Ok(id) = process.receive(started, 5000)
  let monitor = process.monitor(owner)
  process.kill(owner)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)

  let store = store.directory(process.new_name("desk-store"), dir)
  let assert Ok(Nil) = store.start(store)
  let assert Ok(run) =
    fabric.recover(store, librarian(), app.member("junior"), id)
  let assert Ok([pending]) = fabric.pending(run)
  let assert Ok(_) =
    fabric.approve(
      run,
      pending.reference,
      reviewer: Some("guardian-ann"),
      context: app.member("junior"),
    )
  let assert Ok(run.Finished(run.Completed(_))) = fabric.await(run, 5000)
  delete_directory(dir)
}

@external(erlang, "file", "del_dir_r")
fn delete_directory(path: String) -> Dynamic

/// The system temporary directory, so a failed test leaves nothing in the
/// project.
fn temp_root() -> String {
  case getenv("TMPDIR") {
    Ok(dir) -> dir
    Error(Nil) -> "/tmp"
  }
}

@external(erlang, "app_test_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

// --- acquisitions through a sub-agent -------------------------------------------

/// The committee approves starting the purchaser; the purchaser's order
/// then waits for the treasurer, and that approval surfaces at the front
/// desk, naming the purchaser's run. Both are answered through the desk.
pub fn an_acquisition_needs_the_committee_then_the_treasurer_test() {
  let assert Ok(desk) =
    fabric.start(memory(), app.front_desk(), app.member("ada"), "acquire Dune")
  let assert Ok(run.Suspended([committee], [])) = fabric.await(desk, 5000)
  committee.tool |> should.equal("acquire")
  committee.reference.run |> should.equal(fabric.id(desk))
  let assert Ok(_) =
    fabric.approve(
      desk,
      committee.reference,
      reviewer: Some("committee-chair"),
      context: app.member("ada"),
    )

  let assert Ok(run.Suspended([treasurer], [])) = fabric.await(desk, 5000)
  treasurer.tool |> should.equal("order_book")
  { treasurer.reference.run != fabric.id(desk) } |> should.be_true
  let assert Ok(_) =
    fabric.approve(
      desk,
      treasurer.reference,
      reviewer: Some("treasurer-tom"),
      context: app.member("ada"),
    )
  fabric.await(desk, 5000)
  |> should.equal(
    Ok(
      run.Finished(run.Completed(
        "done: {\"order\":\"ordered {\\\"po\\\":\\\"PO-Dune\\\"}\"}",
      )),
    ),
  )
}

/// Cancelling the desk while the purchaser waits for the treasurer cancels
/// the purchaser too; its pending order is void.
pub fn cancelling_the_desk_cancels_a_paused_purchase_test() {
  let assert Ok(desk) =
    fabric.start(memory(), app.front_desk(), app.member("ada"), "acquire Dune")
  let assert Ok(run.Suspended([committee], [])) = fabric.await(desk, 5000)
  let assert Ok(_) =
    fabric.approve(
      desk,
      committee.reference,
      reviewer: None,
      context: app.member("ada"),
    )
  let assert Ok(run.Suspended([treasurer], [])) = fabric.await(desk, 5000)
  let assert Ok(purchaser) = fabric.child(desk, treasurer.reference.run)

  let assert Ok(_) = fabric.cancel(desk)
  fabric.await(desk, 5000) |> should.equal(Ok(run.Finished(run.Cancelled)))
  fabric.await(purchaser, 0) |> should.equal(Ok(run.Finished(run.Cancelled)))
  fabric.approve(
    desk,
    treasurer.reference,
    reviewer: None,
    context: app.member("ada"),
  )
  |> should.equal(Error(fabric.RunEnded))
}

// --- an interlibrary loan as a Saga workflow --------------------------------------

pub fn an_interlibrary_loan_runs_as_one_tool_test() {
  let assert Ok(loan) =
    fabric.start(memory(), app.front_desk(), app.member("ada"), "borrow Dune")
  fabric.await(loan, 5000)
  |> should.equal(
    Ok(run.Finished(run.Completed("done: {\"delivery\":\"REQ-Dune/COURIER\"}"))),
  )

  // No courier: the request was cancelled, so the failure is definite.
  let assert Ok(lost) =
    fabric.start(
      memory(),
      app.front_desk(),
      app.member("ada"),
      "borrow Lost Scroll",
    )
  fabric.await(lost, 5000)
  |> should.equal(
    Ok(
      run.Finished(run.Completed(
        "done: {\"error\":\"no courier carries Lost Scroll\"}",
      )),
    ),
  )
}

// --- observations -----------------------------------------------------------------

/// A handler the application attaches sees what the run did, after each
/// commit, from the forwarder the application routed Fabric's events
/// through.
pub fn observations_show_what_a_run_did_test() {
  let assert Ok(observation) = app.start_observation()
  let events = process.new_subject()
  let assert Ok(started_id) = sinal.handler_id("app-started")
  let assert Ok(started) =
    sinal.observe(started_id, observation.run_started(), fn(_, meta) {
      process.send(events, "started " <> meta.agent)
    })
  let assert Ok(child_id) = sinal.handler_id("app-child")
  let assert Ok(child) =
    sinal.observe(child_id, observation.child_started(), fn(_, meta) {
      process.send(events, "delegated " <> meta.action.tool)
    })
  let assert Ok(finished_id) = sinal.handler_id("app-finished")
  let assert Ok(finished) =
    sinal.observe(finished_id, observation.run_finished(), fn(totals, meta) {
      process.send(
        events,
        "finished "
          <> string.inspect(meta.outcome)
          <> " after "
          <> int.to_string(totals.turns)
          <> " turns",
      )
    })

  let assert Ok(desk) =
    fabric.start(memory(), app.front_desk(), app.member("ada"), "acquire Dune")
  let assert Ok(run.Suspended([committee], [])) = fabric.await(desk, 5000)
  let assert Ok(_) =
    fabric.approve(
      desk,
      committee.reference,
      reviewer: None,
      context: app.member("ada"),
    )
  let assert Ok(run.Suspended([treasurer], [])) = fabric.await(desk, 5000)
  let assert Ok(_) =
    fabric.approve(
      desk,
      treasurer.reference,
      reviewer: None,
      context: app.member("ada"),
    )
  let assert Ok(run.Finished(run.Completed(_))) = fabric.await(desk, 5000)
  let seen = receive_until(events, "finished Completed after 2 turns", [])
  list.each([started, child, finished], fn(attachment) {
    let _ = sinal.detach(attachment)
    Nil
  })
  app.stop_observation(observation)
  seen
  |> should.equal([
    "started front-desk", "started purchaser", "delegated acquire",
    "finished Completed after 2 turns", "finished Completed after 2 turns",
  ])
}

/// Lines until `last` has arrived twice (the child's run and the desk's
/// both finish after two turns).
fn receive_until(
  events: process.Subject(String),
  last: String,
  seen: List(String),
) -> List(String) {
  let assert Ok(line) = process.receive(events, 5000)
  let seen = [line, ..seen]
  case list.count(seen, fn(entry) { entry == last }) {
    2 -> list.reverse(seen)
    _ -> receive_until(events, last, seen)
  }
}

fn librarian() -> Agent(app.Member) {
  let assert Ok(librarian) = app.librarian()
  librarian
}

/// An in-memory store for one test, linked to it.
fn memory() -> store.Store {
  let runs = store.in_memory(process.new_name("app-runs"))
  let assert Ok(Nil) = store.start(runs)
  runs
}

/// A request handler starts a run and exits; the supervised store, not the
/// handler, owns the run's runner, so the run still finishes. The reference
/// names its run with a typed id; a string from a link parses back to it.
pub fn a_run_outlives_the_request_that_started_it_test() {
  let runs = store.in_memory(process.new_name("supervised-runs"))
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(store.supervised(runs))
    |> static_supervisor.start
  let handed = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(run) =
      fabric.start(runs, librarian(), app.member("junior"), "reserve Dune")
    process.send(handed, fabric.id(run))
  })
  let assert Ok(id) = process.receive(handed, 5000)
  let assert Ok(run) =
    fabric.recover(runs, librarian(), app.member("junior"), id)
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)
  run.parse_id(run.id_to_string(pending.reference.run))
  |> should.equal(Ok(fabric.id(run)))
  run.parse_id("../etc") |> should.equal(Error(Nil))
  let assert Ok(_) =
    fabric.reject(run, pending.reference, reason: "not today", reviewer: None)
  let assert Ok(run.Finished(run.Completed(_))) = fabric.await(run, 5000)
}

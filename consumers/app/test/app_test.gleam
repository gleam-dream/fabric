import app
import fabric
import fabric/run
import fabric/store
import gleam/erlang/process
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn a_member_finds_and_reserves_a_book_test() {
  let assert Ok(run) =
    fabric.start(
      store.in_memory(),
      app.librarian(),
      app.member("ada"),
      "reserve Dune",
    )
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
      store.in_memory(),
      app.librarian(),
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
    fabric.start(
      store.in_memory(),
      app.librarian(),
      app.member("guest"),
      "reserve Dune",
    )
  let assert Ok(run.Finished(run.Completed(answer))) = fabric.await(run, 5000)
  answer
  |> should.equal(
    "done: {\"isbn\":\"978-0441013593\",\"title\":\"Dune\"} | {\"error\":\"denied\",\"detail\":\"guests cannot reserve\"}",
  )
}

pub fn an_unavailable_member_directory_is_a_host_failure_test() {
  let assert Ok(run) =
    fabric.start(
      store.in_memory(),
      app.librarian(),
      app.member(""),
      "reserve Dune",
    )
  let assert Ok(run.Finished(run.Failed(run.PolicyFailed(_, reason)))) =
    fabric.await(run, 5000)
  reason |> should.equal("member directory unavailable")
}

pub fn a_long_inventory_scan_can_be_cancelled_test() {
  let arrivals = process.new_subject()
  let assert Ok(run) =
    fabric.start(
      store.in_memory(),
      app.librarian(),
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
  app.librarian() |> app.check |> should.equal(Ok(Nil))
  app.misconfigured() |> app.check |> should.be_error
}

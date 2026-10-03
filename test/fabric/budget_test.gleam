//// The family ledger is an internal storage boundary. Runner admission is a
//// separate contract; these tests prove durable reservation, not enforcement.

import fabric/budget as quota

import fabric/internal/budget/ledger
import fabric/internal/budget/model as budget
import fabric/internal/budget/record
import fabric/internal/store as store_core
import fabric/run
import fabric/store/backend
import fabric/support
import fabric/support/flaky
import fabric/support/restart
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import gleeunit/should

pub fn reservations_count_attempts_and_children_independently_test() {
  let limits = quota.Limits(5, 1, 2)
  let claims = [
    budget.GraphAttempt("root", 1, 1),
    budget.GraphAttempt("root", 1, 2),
    budget.GraphAttempt("root", 2, 1),
    budget.ModelAttempt("child", 1, 1, 1),
    budget.ModelAttempt("child", 2, 1, 1),
    budget.Child("child", 1),
  ]
  let assert Ok(full) = budget.restore(limits, claims)
  budget.usage(full) |> should.equal(quota.Usage(5, 1))
  list.each(claims, fn(claim) {
    budget.reserve(full, claim) |> should.equal(Ok(full))
  })
  budget.reserve(full, budget.ToolAction("child", 1, "call"))
  |> should.equal(Error(budget.Denied(quota.WorkLimit(5))))
  budget.reserve(full, budget.Child("another", 1))
  |> should.equal(Error(budget.Denied(quota.ChildLimit(1))))
  budget.reserve(full, budget.Child("child", 2))
  |> should.equal(Error(budget.ConflictingClaim))
}

pub fn zero_bounds_and_depth_refusals_never_spend_capacity_test() {
  let assert Ok(empty) = budget.new(quota.Limits(0, 0, 0))
  budget.reserve(empty, budget.GraphAttempt("root", 1, 1))
  |> should.equal(Error(budget.Denied(quota.WorkLimit(0))))
  budget.reserve(empty, budget.Child("child", 1))
  |> should.equal(Error(budget.Denied(quota.DepthLimit(0, 1))))
  let assert Ok(state) = budget.new(quota.Limits(1, 1, 1))
  budget.reserve(state, budget.Child("child", 2))
  |> should.equal(Error(budget.Denied(quota.DepthLimit(1, 2))))
  let assert Ok(next) = budget.reserve(state, budget.Child("child", 1))
  budget.usage(next) |> should.equal(quota.Usage(0, 1))
}

pub fn invalid_limits_or_claims_cannot_be_reserved_test() {
  list.each(
    [
      quota.Limits(-1, 1, 1),
      quota.Limits(1, -1, 1),
      quota.Limits(1, 1, -1),
      quota.Limits(1, 1, 64),
    ],
    fn(limits) {
      budget.new(limits) |> should.equal(Error(budget.InvalidLimits))
    },
  )
  let assert Ok(state) = budget.new(quota.Limits(10, 10, 63))
  list.each(
    [
      budget.GraphAttempt("../root", 1, 1),
      budget.GraphAttempt("", 1, 1),
      budget.GraphAttempt(string.repeat("r", 129), 1, 1),
      budget.GraphAttempt("root", 0, 1),
      budget.GraphAttempt("root", 1, 0),
      budget.ModelAttempt("root", 0, 1, 1),
      budget.ModelAttempt("root", 1, 0, 1),
      budget.ModelAttempt("root", 1, 1, 0),
      budget.ToolAction("root", 0, "call"),
      budget.Child("child", 0),
    ],
    fn(claim) {
      budget.reserve(state, claim) |> should.equal(Error(budget.InvalidClaim))
    },
  )
}

pub fn record_roundtrips_all_claim_kinds_without_trusting_counters_test() {
  let assert Ok(state) =
    budget.restore(quota.Limits(3, 1, 3), [
      budget.GraphAttempt("root", 1, 1),
      budget.ModelAttempt("root", 1, 1, 2),
      budget.ToolAction("root", 1, "a\u{0}\"b"),
      budget.Child("child", 3),
    ])
  let saved = record.Record("root", state)
  let encoded = record.encode(saved)
  record.decode(encoded) |> should.equal(Ok(saved))
  // Every logical write carries a fresh token, including equal payloads.
  should.be_false(record.encode(saved) == encoded)
  run.parse_id(record.id("root")) |> result.is_ok |> should.be_true
  should.be_false(record.id("root") == record.id("another"))
  record.decode(string.replace(encoded, "\"version\":1", "\"version\":2"))
  |> should.equal(Error(record.UnsupportedVersion(2)))
  list.each(
    [
      string.replace(encoded, "\"root\":\"root\"", "\"root\":\"another\""),
      string.replace(encoded, "\"work\":3", "\"work\":2"),
      string.replace(encoded, "\"depth\":3", "\"depth\":0"),
      string.replace(encoded, "\"kind\":\"tool\"", "\"kind\":\"unknown\""),
    ],
    fn(text) {
      let assert Error(record.Corrupt(_)) = record.decode(text)
    },
  )
}

pub fn restore_refuses_duplicate_or_conflicting_saved_claims_test() {
  let limits = quota.Limits(3, 3, 3)
  let work = budget.GraphAttempt("root", 1, 1)
  budget.restore(limits, [work, work])
  |> should.equal(Error(budget.ConflictingClaim))
  budget.restore(limits, [budget.Child("child", 1), budget.Child("child", 2)])
  |> should.equal(Error(budget.ConflictingClaim))
}

pub fn lost_acknowledgements_do_not_spend_twice_or_change_limits_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let limits = quota.Limits(1, 0, 0)
  let claim = budget.GraphAttempt("root", 1, 1)
  flaky.arm(backend, [flaky.FailAfter, flaky.FailAfter])
  let assert Ok(_) = ledger.ensure(runs, "root", limits)
  let assert Ok(state) = ledger.reserve(runs, "root", limits, claim)
  ledger.read(runs, "root") |> should.equal(Ok(#(2, state)))
  // Acknowledging an existing grant performs no write, even at its limit.
  flaky.arm(backend, [flaky.FailBefore])
  ledger.reserve(runs, "root", limits, claim) |> should.equal(Ok(state))
  ledger.ensure(runs, "root", limits) |> should.equal(Ok(state))
  ledger.read(runs, "root") |> should.equal(Ok(#(2, state)))
  ledger.ensure(runs, "root", quota.Limits(2, 0, 0))
  |> should.equal(Error(ledger.ChangedLimits))
  ledger.reserve(runs, "root", quota.Limits(2, 0, 0), claim)
  |> should.equal(Error(ledger.ChangedLimits))
}

pub fn a_late_grant_is_adopted_when_its_reservation_is_retried_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let limits = quota.Limits(2, 0, 0)
  let claim = budget.GraphAttempt("root", 1, 1)
  let assert Ok(_) = ledger.ensure(runs, "root", limits)
  flaky.arm(backend, [flaky.FailLate])
  let assert Error(ledger.Storage(backend.Unavailable(_))) =
    ledger.reserve(runs, "root", limits, claim)
  let assert Ok(state) = ledger.reserve(runs, "root", limits, claim)
  budget.usage(state) |> should.equal(quota.Usage(1, 0))
  ledger.read(runs, "root") |> should.equal(Ok(#(2, state)))
}

pub fn failed_writes_and_missing_ledgers_never_grant_capacity_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let limits = quota.Limits(2, 0, 0)
  let claim = budget.GraphAttempt("root", 1, 1)
  ledger.reserve(runs, "root", limits, claim)
  |> should.equal(Error(ledger.Storage(backend.NotFound)))
  flaky.arm(backend, [flaky.FailBefore])
  let assert Error(ledger.Storage(backend.Unavailable(_))) =
    ledger.ensure(runs, "root", limits)
  let assert Ok(initial) = ledger.ensure(runs, "root", limits)
  flaky.arm(backend, [flaky.FailBefore])
  let assert Error(ledger.Storage(backend.Unavailable(_))) =
    ledger.reserve(runs, "root", limits, claim)
  ledger.read(runs, "root") |> should.equal(Ok(#(1, initial)))
}

pub fn competing_stores_cannot_both_reserve_the_last_slot_test() {
  let backend = flaky.new()
  let first = flaky.store(backend)
  let second = flaky.store(backend)
  let limits = quota.Limits(1, 0, 0)
  let assert Ok(_) = ledger.ensure(first, "root", limits)
  let held = flaky.hold(backend, fn(id) { id == record.id("root") })
  let reply = process.new_subject()
  process.spawn(fn() {
    process.send(
      reply,
      ledger.reserve(first, "root", limits, budget.GraphAttempt("root", 1, 1)),
    )
  })
  let assert Ok(_) = process.receive(held, 1000)
  let assert Ok(winner) =
    ledger.reserve(second, "root", limits, budget.ModelAttempt("root", 1, 1, 1))
  flaky.release_held(backend)
  process.receive(reply, 1000)
  |> should.equal(
    Ok(Error(ledger.Reservation(budget.Denied(quota.WorkLimit(1))))),
  )
  ledger.read(second, "root") |> should.equal(Ok(#(2, winner)))
}

pub fn competing_creators_adopt_the_same_immutable_ledger_test() {
  let backend = flaky.new()
  let first = flaky.store(backend)
  let second = flaky.store(backend)
  let limits = quota.Limits(2, 1, 1)
  let held = flaky.hold(backend, fn(id) { id == record.id("root") })
  let reply = process.new_subject()
  process.spawn(fn() {
    process.send(reply, ledger.ensure(first, "root", limits))
  })
  let assert Ok(_) = process.receive(held, 1000)
  let assert Ok(initial) = ledger.ensure(second, "root", limits)
  let assert Ok(state) =
    ledger.reserve(second, "root", limits, budget.Child("child", 1))
  flaky.release_held(backend)
  process.receive(reply, 1000) |> should.equal(Ok(Ok(state)))
  budget.usage(initial) |> should.equal(quota.Usage(0, 0))
  ledger.read(second, "root") |> should.equal(Ok(#(2, state)))
}

pub fn reopening_the_directory_recovers_usage_and_duplicate_grants_test() {
  let dir = restart.temp_dir()
  let limits = quota.Limits(2, 1, 1)
  let claim = budget.ToolAction("root", 1, "call")
  let #(owner, #(runs, state)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let assert Ok(_) = ledger.ensure(runs, "root", limits)
      let assert Ok(_) = ledger.reserve(runs, "root", limits, claim)
      let assert Ok(state) =
        ledger.reserve(runs, "root", limits, budget.Child("child", 1))
      #(runs, state)
    })
  restart.crash(owner, runs)
  let reopened = support.directory(dir)
  ledger.ensure(reopened, "root", limits) |> should.equal(Ok(state))
  ledger.reserve(reopened, "root", limits, claim) |> should.equal(Ok(state))
  ledger.read(reopened, "root") |> should.equal(Ok(#(3, state)))
  let assert Ok(last) =
    ledger.reserve(
      reopened,
      "root",
      limits,
      budget.ToolAction("child", 1, "call"),
    )
  budget.usage(last) |> should.equal(quota.Usage(2, 1))
  ledger.reserve(reopened, "root", limits, budget.GraphAttempt("root", 1, 1))
  |> should.equal(Error(ledger.Reservation(budget.Denied(quota.WorkLimit(2)))))
  restart.remove_dir(dir)
}

pub fn unreadable_ledgers_are_never_replaced_with_fresh_capacity_test() {
  let runs = support.store()
  let limits = quota.Limits(2, 0, 0)
  let assert Ok(_) =
    store_core.insert(runs, record.id("root"), "{}", store_core.Keep)
  let assert Error(ledger.Unreadable(_)) = ledger.ensure(runs, "root", limits)
  let assert Error(ledger.Unreadable(_)) =
    ledger.reserve(runs, "root", limits, budget.GraphAttempt("root", 1, 1))
  let assert Ok(store_core.Entry(revision: 1, record: "{}", ..)) =
    store_core.get(runs, record.id("root"))
  ledger.ensure(runs, "../root", limits)
  |> should.equal(Error(ledger.InvalidRoot))
}

import fabric/graph/fork as value
import fabric/internal/graph/fork
import fabric/internal/run_id
import fabric/run
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

fn request() -> value.Request {
  value.Request(run.DefinitionId("review", 1), "42")
}

// F1–F4: equal inputs are distinct work; reverse completion cannot reorder a join.
pub fn pair_retains_distinct_members_and_joins_in_declared_order_test() {
  let occurrence = value.Occurrence(run_id.from_string("parent"), 3)
  let assert Ok(scope) = fork.new(occurrence, [request(), request()], 2, 2)
  let left = value.Reference(occurrence, 1)
  let right = value.Reference(occurrence, 2)
  fork.next(scope) |> should.equal(Some(left))
  let assert Ok(scope) = fork.admit(scope, left)
  fork.next(scope) |> should.equal(Some(right))
  let assert Ok(scope) = fork.admit(scope, right)
  fork.next(scope) |> should.equal(None)
  let assert Ok(scope) = fork.observe(scope, right, value.Succeeded("2"))
  fork.join(scope) |> should.equal(fork.Waiting)
  let assert Ok(scope) = fork.observe(scope, left, value.Succeeded("1"))
  fork.join(scope) |> should.equal(fork.Ready(Ok(["1", "2"])))
}

fn fresh(count: Int, concurrency: Int) -> fork.Scope {
  let assert Ok(scope) =
    fork.new(
      value.Occurrence(run_id.from_string("parent"), 3),
      list.repeat(request(), count),
      4,
      concurrency,
    )
  scope
}

fn reference(scope: fork.Scope, member: Int) -> value.Reference {
  value.Reference(fork.snapshot(scope).occurrence, member)
}

// F8 applies at each accepted transition as well as during partial recovery.
fn restored(scope: fork.Scope) -> fork.Scope {
  let assert Ok(recovered) = fork.restore(fork.snapshot(scope))
  recovered |> should.equal(scope)
  recovered
}

fn admit(scope: fork.Scope, ordinal: Int) -> fork.Scope {
  let assert Ok(next) = fork.admit(scope, reference(scope, ordinal))
  restored(next)
}

fn observe(
  scope: fork.Scope,
  ordinal: Int,
  progress: value.Progress,
) -> fork.Scope {
  let assert Ok(next) = fork.observe(scope, reference(scope, ordinal), progress)
  restored(next)
}

// F2: a waiting child consumes capacity; later members cannot skip admission.
pub fn bounded_map_releases_capacity_only_for_settled_members_test() {
  let scope = fresh(3, 1)
  fork.admit(scope, reference(scope, 2)) |> should.equal(Error(fork.NotNext))
  let scope = admit(scope, 1)
  fork.next(scope) |> should.equal(None)
  fork.admit(scope, reference(scope, 2)) |> should.equal(Error(fork.NotNext))
  let scope = observe(scope, 1, value.Succeeded("10"))
  fork.next(scope) |> should.equal(Some(reference(scope, 2)))
  let scope = admit(scope, 2) |> observe(2, value.Succeeded("20"))
  let scope = admit(scope, 3) |> observe(3, value.Succeeded("30"))
  fork.join(scope) |> should.equal(fork.Ready(Ok(["10", "20", "30"])))
  fork.owned(scope)
  |> should.equal([
    reference(scope, 1),
    reference(scope, 2),
    reference(scope, 3),
  ])
}

// F3: neither another parent nor an earlier loop visit can satisfy this scope.
pub fn stale_and_foreign_member_observations_are_refused_test() {
  let scope = fresh(2, 2) |> admit(1)
  let previous =
    value.Reference(value.Occurrence(run_id.from_string("parent"), 2), 1)
  let sibling =
    value.Reference(value.Occurrence(run_id.from_string("other-parent"), 3), 1)
  list.each([previous, sibling], fn(ref) {
    fork.observe(scope, ref, value.Succeeded("1"))
    |> should.equal(Error(fork.WrongOccurrence))
    fork.admit(scope, ref) |> should.equal(Error(fork.WrongOccurrence))
  })
  list.each([0, -1, 3], fn(ordinal) {
    fork.observe(scope, reference(scope, ordinal), value.Succeeded("1"))
    |> should.equal(Error(fork.UnknownMember))
  })
  fork.observe(scope, reference(scope, 2), value.Succeeded("1"))
  |> should.equal(Error(fork.NotAdmitted))
  fork.join(scope) |> should.equal(fork.Waiting)
}

// F3: repeated evidence is acknowledged; later evidence cannot rewrite a result.
pub fn repeated_terminal_evidence_is_idempotent_and_conflicts_are_refused_test() {
  let scope = fresh(1, 1) |> admit(1) |> observe(1, value.Succeeded("42"))
  fork.observe(scope, reference(scope, 1), value.Succeeded("42"))
  |> should.equal(Ok(scope))
  list.each(
    [value.Succeeded("43"), value.Failed("late"), value.Active, value.Cancelled],
    fn(progress) {
      fork.observe(scope, reference(scope, 1), progress)
      |> should.equal(Error(fork.ConflictingOutcome))
    },
  )
}

// F5: failure prevents fresh dispatch while an admitted sibling may still act.
pub fn failure_settles_admitted_siblings_and_keeps_late_success_as_evidence_test() {
  let scope = fresh(3, 2) |> admit(1) |> admit(2)
  let failed = reference(scope, 2)
  let scope = observe(scope, 2, value.Failed("review unavailable"))
  fork.next(scope) |> should.equal(None)
  fork.unsettled(scope) |> should.equal([reference(scope, 1)])
  fork.join(scope) |> should.equal(fork.Waiting)
  fork.member(scope, reference(scope, 3))
  |> should.equal(Ok(value.Member(request(), value.Withdrawn)))
  fork.admit(scope, reference(scope, 3)) |> should.equal(Error(fork.NotNext))
  let scope = observe(scope, 1, value.Succeeded("7"))
  fork.join(scope)
  |> should.equal(fork.Ready(Error(value.MemberFailed(failed))))
  fork.member(scope, reference(scope, 1))
  |> should.equal(
    Ok(value.Member(request(), value.Admitted(value.Succeeded("7")))),
  )
  fork.owned(scope) |> should.equal([reference(scope, 1), failed])
  fork.cancel(scope) |> should.equal(scope)
}

// F5: a budget or policy refusal does not manufacture an admitted child.
pub fn rejected_admission_stops_the_scope_without_owning_that_child_test() {
  let scope = fresh(3, 2) |> admit(1)
  let failed = reference(scope, 2)
  let assert Ok(scope) = fork.reject(scope, failed, "child budget exhausted")
  let scope = restored(scope)
  fork.owned(scope) |> should.equal([reference(scope, 1)])
  fork.unsettled(scope) |> should.equal([reference(scope, 1)])
  fork.observe(scope, failed, value.Succeeded("2"))
  |> should.equal(Error(fork.NotAdmitted))
  let scope = observe(scope, 1, value.Cancelled)
  fork.join(scope)
  |> should.equal(fork.Ready(Error(value.MemberFailed(failed))))
  fork.member(scope, failed)
  |> should.equal(
    Ok(value.Member(request(), value.Rejected("child budget exhausted"))),
  )
}

// F6–F7: cancellation closes admission, but cannot settle uncertain effects.
pub fn cancellation_preserves_uncertainty_until_child_settlement_test() {
  let scope = fresh(3, 2) |> admit(1) |> admit(2)
  let scope = observe(scope, 1, value.Uncertain("write acknowledgment lost"))
  let scope = fork.cancel(scope) |> restored
  fork.next(scope) |> should.equal(None)
  fork.join(scope) |> should.equal(fork.Unresolved([reference(scope, 1)]))
  let scope = observe(scope, 2, value.Cancelled)
  fork.join(scope) |> should.equal(fork.Unresolved([reference(scope, 1)]))
  let scope = observe(scope, 1, value.Succeeded("1"))
  fork.join(scope) |> should.equal(fork.Ready(Error(value.CancelledByCaller)))
  fork.owned(scope) |> should.equal([reference(scope, 1), reference(scope, 2)])
}

// F6: a ready join is not a committed parent result; stop still wins here.
pub fn cancellation_before_admission_or_join_leaves_no_new_business_work_test() {
  let pending = fresh(2, 2) |> fork.cancel |> restored
  fork.owned(pending) |> should.equal([])
  fork.next(pending) |> should.equal(None)
  fork.join(pending) |> should.equal(fork.Ready(Error(value.CancelledByCaller)))
  let completed = fresh(1, 1) |> admit(1) |> observe(1, value.Succeeded("1"))
  let cancelled = fork.cancel(completed) |> restored
  fork.join(cancelled)
  |> should.equal(fork.Ready(Error(value.CancelledByCaller)))
  fork.member(cancelled, reference(cancelled, 1))
  |> should.equal(
    Ok(value.Member(request(), value.Admitted(value.Succeeded("1")))),
  )
}

// F6: the first stop cause survives later cancellation, failure and expiration.
pub fn deadline_cleanup_keeps_its_cause_when_children_finish_test() {
  let scope = fresh(2, 1) |> admit(1)
  fork.expire(scope, -1) |> should.equal(Error(fork.InvalidDeadline(-1)))
  let assert Ok(scope) = fork.expire(scope, 10_000)
  let scope = fork.cancel(scope) |> restored
  fork.join(scope) |> should.equal(fork.Waiting)
  fork.next(scope) |> should.equal(None)
  let scope = observe(scope, 1, value.Failed("stop refused then job failed"))
  let assert Ok(scope) = fork.expire(scope, 20_000)
  fork.join(scope)
  |> should.equal(fork.Ready(Error(value.DeadlineElapsed(10_000))))
  let cancelled = fresh(1, 1) |> fork.cancel
  fork.expire(cancelled, 10_000) |> should.equal(Ok(cancelled))
}

// F7: uncertainty halts admission; authoritative resolution can resume it.
pub fn uncertainty_does_not_free_capacity_or_discard_other_results_test() {
  let scope = fresh(3, 2) |> admit(1) |> admit(2)
  let scope = observe(scope, 1, value.Uncertain("unknown effect"))
  let scope = observe(scope, 2, value.Succeeded("2"))
  fork.next(scope) |> should.equal(None)
  fork.join(scope) |> should.equal(fork.Unresolved([reference(scope, 1)]))
  let scope = observe(scope, 1, value.Active)
  fork.next(scope) |> should.equal(Some(reference(scope, 3)))
  let scope = admit(scope, 3) |> observe(3, value.Succeeded("3"))
  let scope = observe(scope, 1, value.Succeeded("1"))
  fork.join(scope) |> should.equal(fork.Ready(Ok(["1", "2", "3"])))
}

// F1: membership and request validation precede any ownership or execution.
pub fn empty_oversized_and_invalid_membership_have_explicit_outcomes_test() {
  let empty = fresh(0, 1)
  fork.next(empty) |> should.equal(None)
  fork.owned(empty) |> should.equal([])
  fork.join(empty) |> should.equal(fork.Ready(Ok([])))
  let occurrence = fork.snapshot(empty).occurrence
  fork.new(occurrence, [request(), request()], 1, 1)
  |> should.equal(Error(fork.TooManyMembers(2, 1)))
  list.each([#(0, 1), #(1, 0), #(-1, 1), #(1, -1)], fn(bounds) {
    fork.new(occurrence, [], bounds.0, bounds.1)
    |> should.equal(Error(fork.InvalidBounds))
  })
  list.each(
    [
      value.Occurrence(run_id.from_string("parent"), 0),
      value.Occurrence(run_id.from_string("parent"), -1),
      value.Occurrence(run_id.from_string("not/a/run"), 1),
    ],
    fn(occurrence) {
      fork.new(occurrence, [], 1, 1)
      |> should.equal(Error(fork.InvalidOccurrence))
    },
  )
  list.each(
    [
      value.Request(run.DefinitionId(" ", 1), "1"),
      value.Request(run.DefinitionId("review", 0), "1"),
      value.Request(run.DefinitionId("review", 1), "not-json"),
    ],
    fn(request) {
      fork.new(occurrence, [request], 1, 1)
      |> should.equal(Error(fork.InvalidRequest(1)))
    },
  )
}

// F3, F8: malformed outputs never become saved successful evidence.
pub fn malformed_success_cannot_satisfy_a_join_test() {
  let scope = fresh(1, 1) |> admit(1)
  fork.observe(scope, reference(scope, 1), value.Succeeded("not-json"))
  |> should.equal(Error(fork.InvalidOutput))
  fork.join(scope) |> should.equal(fork.Waiting)
  let saved = fork.snapshot(scope)
  fork.restore(
    value.Snapshot(..saved, members: [
      value.Member(request(), value.Admitted(value.Succeeded("not-json"))),
    ]),
  )
  |> should.equal(Error(fork.InvalidOutput))
}

// F8: restoring partial results preserves ownership, capacity and result order.
pub fn partial_restoration_adopts_members_without_readmitting_completed_work_test() {
  let scope = fresh(3, 2) |> admit(1) |> admit(2)
  let scope = observe(scope, 2, value.Succeeded("2")) |> restored
  fork.admit(scope, reference(scope, 1)) |> should.equal(Error(fork.NotNext))
  fork.admit(scope, reference(scope, 2)) |> should.equal(Error(fork.NotNext))
  fork.next(scope) |> should.equal(Some(reference(scope, 3)))
  let scope = admit(scope, 3) |> observe(3, value.Succeeded("3"))
  fork.join(scope) |> should.equal(fork.Waiting)
  let scope = observe(scope, 1, value.Succeeded("1"))
  fork.join(scope) |> should.equal(fork.Ready(Ok(["1", "2", "3"])))
}

// F8: forged lifecycle combinations cannot become an executable scope.
pub fn restoration_rejects_broken_admission_order_capacity_and_stop_evidence_test() {
  let base = fresh(2, 1)
  let saved = fork.snapshot(base)
  let pending = value.Member(request(), value.Pending)
  let active = value.Member(request(), value.Admitted(value.Active))
  let reserved = value.Member(request(), value.Reserved)
  let failed = value.Member(request(), value.Admitted(value.Failed("failed")))
  let withdrawn = value.Member(request(), value.Withdrawn)
  list.each(
    [
      value.Snapshot(..saved, members: [pending, active]),
      value.Snapshot(..saved, members: [active, active]),
      value.Snapshot(..saved, members: [active, reserved]),
      value.Snapshot(..saved, members: [reserved, reserved]),
      value.Snapshot(..saved, members: [
        active,
        value.Member(request(), value.Admitted(value.Succeeded("2"))),
      ]),
      value.Snapshot(
        ..saved,
        members: [active, value.Member(request(), value.Rejected("denied"))],
        stop: Some(value.MemberFailed(reference(base, 2))),
      ),
      value.Snapshot(..saved, members: [failed, withdrawn]),
      value.Snapshot(..saved, stop: Some(value.CancelledByCaller)),
      value.Snapshot(
        ..saved,
        members: [active, withdrawn],
        stop: Some(value.MemberFailed(reference(base, 1))),
      ),
      value.Snapshot(
        ..saved,
        members: [failed, withdrawn],
        stop: Some(
          value.MemberFailed(value.Reference(
            value.Occurrence(run_id.from_string("another"), 3),
            1,
          )),
        ),
      ),
      value.Snapshot(
        ..saved,
        members: [failed, withdrawn],
        stop: Some(value.MemberFailed(reference(base, 3))),
      ),
      value.Snapshot(
        ..saved,
        members: [withdrawn, withdrawn],
        stop: Some(value.DeadlineElapsed(-1)),
      ),
      // A refusal itself closes admission. It cannot appear after cancellation,
      // expiration or another member's earlier committed failure.
      value.Snapshot(
        ..saved,
        members: [value.Member(request(), value.Rejected("denied")), withdrawn],
        stop: Some(value.CancelledByCaller),
      ),
      value.Snapshot(
        ..saved,
        members: [failed, value.Member(request(), value.Rejected("denied"))],
        stop: Some(value.MemberFailed(reference(base, 1))),
      ),
    ],
    fn(snapshot) { fork.restore(snapshot) |> should.be_error },
  )
}

// F5: an independently canceled child is a failure of an otherwise open fork.
pub fn unexpected_child_cancellation_requires_sibling_settlement_test() {
  let scope = fresh(3, 2) |> admit(1) |> admit(2)
  let scope = observe(scope, 2, value.Cancelled)
  fork.next(scope) |> should.equal(None)
  fork.join(scope) |> should.equal(fork.Waiting)
  let scope = observe(scope, 1, value.Cancelled)
  fork.join(scope)
  |> should.equal(fork.Ready(Error(value.MemberFailed(reference(scope, 2)))))
}

import fabric/internal/graph/fork
import fabric/run
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should

fn request() -> fork.Request {
  fork.Request(run.Identity("review", 1), "42")
}

// F1–F4: equal inputs are distinct work; reverse completion cannot reorder a join.
pub fn pair_retains_distinct_members_and_joins_in_declared_order_test() {
  let occurrence = fork.Occurrence(run.issued("parent"), 3)
  let assert Ok(scope) = fork.new(occurrence, [request(), request()], 2, 2)
  let left = fork.Reference(occurrence, 1)
  let right = fork.Reference(occurrence, 2)
  fork.next(scope) |> should.equal(Some(left))
  let assert Ok(scope) = fork.admit(scope, left)
  fork.next(scope) |> should.equal(Some(right))
  let assert Ok(scope) = fork.admit(scope, right)
  fork.next(scope) |> should.equal(None)
  let assert Ok(scope) = fork.observe(scope, right, fork.Succeeded("2"))
  fork.join(scope) |> should.equal(fork.Waiting)
  let assert Ok(scope) = fork.observe(scope, left, fork.Succeeded("1"))
  fork.join(scope) |> should.equal(fork.Ready(Ok(["1", "2"])))
}

fn fresh(count: Int, concurrency: Int) -> fork.Scope {
  let assert Ok(scope) =
    fork.new(
      fork.Occurrence(run.issued("parent"), 3),
      list.repeat(request(), count),
      4,
      concurrency,
    )
  scope
}

fn reference(scope: fork.Scope, member: Int) -> fork.Reference {
  fork.Reference(fork.snapshot(scope).occurrence, member)
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
  progress: fork.Progress,
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
  let scope = observe(scope, 1, fork.Succeeded("10"))
  fork.next(scope) |> should.equal(Some(reference(scope, 2)))
  let scope = admit(scope, 2) |> observe(2, fork.Succeeded("20"))
  let scope = admit(scope, 3) |> observe(3, fork.Succeeded("30"))
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
  let previous = fork.Reference(fork.Occurrence(run.issued("parent"), 2), 1)
  let sibling =
    fork.Reference(fork.Occurrence(run.issued("other-parent"), 3), 1)
  list.each([previous, sibling], fn(ref) {
    fork.observe(scope, ref, fork.Succeeded("1"))
    |> should.equal(Error(fork.WrongOccurrence))
    fork.admit(scope, ref) |> should.equal(Error(fork.WrongOccurrence))
  })
  list.each([0, -1, 3], fn(ordinal) {
    fork.observe(scope, reference(scope, ordinal), fork.Succeeded("1"))
    |> should.equal(Error(fork.UnknownMember))
  })
  fork.observe(scope, reference(scope, 2), fork.Succeeded("1"))
  |> should.equal(Error(fork.NotAdmitted))
  fork.join(scope) |> should.equal(fork.Waiting)
}

// F3: repeated evidence is acknowledged; later evidence cannot rewrite a result.
pub fn repeated_terminal_evidence_is_idempotent_and_conflicts_are_refused_test() {
  let scope = fresh(1, 1) |> admit(1) |> observe(1, fork.Succeeded("42"))
  fork.observe(scope, reference(scope, 1), fork.Succeeded("42"))
  |> should.equal(Ok(scope))
  list.each(
    [fork.Succeeded("43"), fork.Failed("late"), fork.Active, fork.Cancelled],
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
  let scope = observe(scope, 2, fork.Failed("review unavailable"))
  fork.next(scope) |> should.equal(None)
  fork.unsettled(scope) |> should.equal([reference(scope, 1)])
  fork.join(scope) |> should.equal(fork.Waiting)
  fork.member(scope, reference(scope, 3))
  |> should.equal(Ok(fork.Member(request(), fork.Withdrawn)))
  fork.admit(scope, reference(scope, 3)) |> should.equal(Error(fork.NotNext))
  let scope = observe(scope, 1, fork.Succeeded("7"))
  fork.join(scope) |> should.equal(fork.Ready(Error(fork.MemberFailed(failed))))
  fork.member(scope, reference(scope, 1))
  |> should.equal(
    Ok(fork.Member(request(), fork.Admitted(fork.Succeeded("7")))),
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
  fork.observe(scope, failed, fork.Succeeded("2"))
  |> should.equal(Error(fork.NotAdmitted))
  let scope = observe(scope, 1, fork.Cancelled)
  fork.join(scope) |> should.equal(fork.Ready(Error(fork.MemberFailed(failed))))
  fork.member(scope, failed)
  |> should.equal(
    Ok(fork.Member(request(), fork.Rejected("child budget exhausted"))),
  )
}

// F6–F7: cancellation closes admission, but cannot settle uncertain effects.
pub fn cancellation_preserves_uncertainty_until_child_settlement_test() {
  let scope = fresh(3, 2) |> admit(1) |> admit(2)
  let scope = observe(scope, 1, fork.Uncertain("write acknowledgment lost"))
  let scope = fork.cancel(scope) |> restored
  fork.next(scope) |> should.equal(None)
  fork.join(scope) |> should.equal(fork.Unresolved([reference(scope, 1)]))
  let scope = observe(scope, 2, fork.Cancelled)
  fork.join(scope) |> should.equal(fork.Unresolved([reference(scope, 1)]))
  let scope = observe(scope, 1, fork.Succeeded("1"))
  fork.join(scope) |> should.equal(fork.Ready(Error(fork.CancelledByCaller)))
  fork.owned(scope) |> should.equal([reference(scope, 1), reference(scope, 2)])
}

// F6: a ready join is not a committed parent result; stop still wins here.
pub fn cancellation_before_admission_or_join_leaves_no_new_business_work_test() {
  let pending = fresh(2, 2) |> fork.cancel |> restored
  fork.owned(pending) |> should.equal([])
  fork.next(pending) |> should.equal(None)
  fork.join(pending) |> should.equal(fork.Ready(Error(fork.CancelledByCaller)))
  let completed = fresh(1, 1) |> admit(1) |> observe(1, fork.Succeeded("1"))
  let cancelled = fork.cancel(completed) |> restored
  fork.join(cancelled)
  |> should.equal(fork.Ready(Error(fork.CancelledByCaller)))
  fork.member(cancelled, reference(cancelled, 1))
  |> should.equal(
    Ok(fork.Member(request(), fork.Admitted(fork.Succeeded("1")))),
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
  let scope = observe(scope, 1, fork.Failed("stop refused then job failed"))
  let assert Ok(scope) = fork.expire(scope, 20_000)
  fork.join(scope)
  |> should.equal(fork.Ready(Error(fork.DeadlineElapsed(10_000))))
  let cancelled = fresh(1, 1) |> fork.cancel
  fork.expire(cancelled, 10_000) |> should.equal(Ok(cancelled))
}

// F7: uncertainty halts admission; authoritative resolution can resume it.
pub fn uncertainty_does_not_free_capacity_or_discard_other_results_test() {
  let scope = fresh(3, 2) |> admit(1) |> admit(2)
  let scope = observe(scope, 1, fork.Uncertain("unknown effect"))
  let scope = observe(scope, 2, fork.Succeeded("2"))
  fork.next(scope) |> should.equal(None)
  fork.join(scope) |> should.equal(fork.Unresolved([reference(scope, 1)]))
  let scope = observe(scope, 1, fork.Active)
  fork.next(scope) |> should.equal(Some(reference(scope, 3)))
  let scope = admit(scope, 3) |> observe(3, fork.Succeeded("3"))
  let scope = observe(scope, 1, fork.Succeeded("1"))
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
      fork.Occurrence(run.issued("parent"), 0),
      fork.Occurrence(run.issued("parent"), -1),
      fork.Occurrence(run.issued("not/a/run"), 1),
    ],
    fn(occurrence) {
      fork.new(occurrence, [], 1, 1)
      |> should.equal(Error(fork.InvalidOccurrence))
    },
  )
  list.each(
    [
      fork.Request(run.Identity(" ", 1), "1"),
      fork.Request(run.Identity("review", 0), "1"),
      fork.Request(run.Identity("review", 1), "not-json"),
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
  fork.observe(scope, reference(scope, 1), fork.Succeeded("not-json"))
  |> should.equal(Error(fork.InvalidOutput))
  fork.join(scope) |> should.equal(fork.Waiting)
  let saved = fork.snapshot(scope)
  fork.restore(
    fork.Snapshot(..saved, members: [
      fork.Member(request(), fork.Admitted(fork.Succeeded("not-json"))),
    ]),
  )
  |> should.equal(Error(fork.InvalidOutput))
}

// F8: restoring partial results preserves ownership, capacity and result order.
pub fn partial_restoration_adopts_members_without_readmitting_completed_work_test() {
  let scope = fresh(3, 2) |> admit(1) |> admit(2)
  let scope = observe(scope, 2, fork.Succeeded("2")) |> restored
  fork.admit(scope, reference(scope, 1)) |> should.equal(Error(fork.NotNext))
  fork.admit(scope, reference(scope, 2)) |> should.equal(Error(fork.NotNext))
  fork.next(scope) |> should.equal(Some(reference(scope, 3)))
  let scope = admit(scope, 3) |> observe(3, fork.Succeeded("3"))
  fork.join(scope) |> should.equal(fork.Waiting)
  let scope = observe(scope, 1, fork.Succeeded("1"))
  fork.join(scope) |> should.equal(fork.Ready(Ok(["1", "2", "3"])))
}

// F8: forged lifecycle combinations cannot become an executable scope.
pub fn restoration_rejects_broken_admission_order_capacity_and_stop_evidence_test() {
  let base = fresh(2, 1)
  let saved = fork.snapshot(base)
  let pending = fork.Member(request(), fork.Pending)
  let active = fork.Member(request(), fork.Admitted(fork.Active))
  let failed = fork.Member(request(), fork.Admitted(fork.Failed("failed")))
  let withdrawn = fork.Member(request(), fork.Withdrawn)
  list.each(
    [
      fork.Snapshot(..saved, members: [pending, active]),
      fork.Snapshot(..saved, members: [active, active]),
      fork.Snapshot(..saved, members: [
        active,
        fork.Member(request(), fork.Admitted(fork.Succeeded("2"))),
      ]),
      fork.Snapshot(
        ..saved,
        members: [active, fork.Member(request(), fork.Rejected("denied"))],
        stop: Some(fork.MemberFailed(reference(base, 2))),
      ),
      fork.Snapshot(..saved, members: [failed, withdrawn]),
      fork.Snapshot(..saved, stop: Some(fork.CancelledByCaller)),
      fork.Snapshot(
        ..saved,
        members: [active, withdrawn],
        stop: Some(fork.MemberFailed(reference(base, 1))),
      ),
      fork.Snapshot(
        ..saved,
        members: [failed, withdrawn],
        stop: Some(
          fork.MemberFailed(fork.Reference(
            fork.Occurrence(run.issued("another"), 3),
            1,
          )),
        ),
      ),
      fork.Snapshot(
        ..saved,
        members: [failed, withdrawn],
        stop: Some(fork.MemberFailed(reference(base, 3))),
      ),
      fork.Snapshot(
        ..saved,
        members: [withdrawn, withdrawn],
        stop: Some(fork.DeadlineElapsed(-1)),
      ),
      // A refusal itself closes admission. It cannot appear after cancellation,
      // expiration or another member's earlier committed failure.
      fork.Snapshot(
        ..saved,
        members: [fork.Member(request(), fork.Rejected("denied")), withdrawn],
        stop: Some(fork.CancelledByCaller),
      ),
      fork.Snapshot(
        ..saved,
        members: [failed, fork.Member(request(), fork.Rejected("denied"))],
        stop: Some(fork.MemberFailed(reference(base, 1))),
      ),
    ],
    fn(snapshot) { fork.restore(snapshot) |> should.be_error },
  )
}

// F5: an independently canceled child is a failure of an otherwise open fork.
pub fn unexpected_child_cancellation_requires_sibling_settlement_test() {
  let scope = fresh(3, 2) |> admit(1) |> admit(2)
  let scope = observe(scope, 2, fork.Cancelled)
  fork.next(scope) |> should.equal(None)
  fork.join(scope) |> should.equal(fork.Waiting)
  let scope = observe(scope, 1, fork.Cancelled)
  fork.join(scope)
  |> should.equal(fork.Ready(Error(fork.MemberFailed(reference(scope, 2)))))
}

import fabric/graph/fork
import fabric/graph/operation
import fabric/internal/graph/attachment
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record
import fabric/internal/run_id
import fabric/policy
import fabric/run
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn initial() -> graph.State {
  let assert Ok(#(state, _)) =
    graph.start(
      "fork-record",
      graph.Definition(run.DefinitionId("parent", 1), "parent-v1", 1),
      "0",
      graph.Prepared(
        "pair",
        run.DefinitionId("pair", 1),
        "[1,2]",
        operation.RequireReconciliation,
        operation.Fork(2, 2, "pair-v1"),
        None,
      ),
    )
  state
}

fn next(state: graph.State, event: graph.Event) -> graph.State {
  let assert Ok(#(state, _)) = graph.step(state, event)
  state
}

// F2, F8: reservation, acknowledgment and saved results survive roundtrips.
pub fn version_thirteen_retains_fork_scopes_and_rejects_legacy_downgrades_test() {
  let ready = initial()
  let assert graph.Ready(a) = ready.phase
  let ref = graph.reference(ready, a)
  let preparing = next(ready, graph.Inspected(ref, Ok(policy.Allow), None))
  let fixed =
    next(
      preparing,
      graph.ForkPrepared(
        ref,
        Ok([
          fork.Request(run.DefinitionId("one", 1), "1"),
          fork.Request(run.DefinitionId("two", 1), "2"),
        ]),
      ),
    )
  let occurrence = fork.Occurrence(run_id.from_string(ready.run), a.id)
  let first = fork.Reference(occurrence, 1)
  let second = fork.Reference(occurrence, 2)
  let reserved = next(fixed, graph.ForkAdmitted(ref, first))
  let acknowledged = next(reserved, graph.ForkObserved(ref, first, fork.Active))
  let partial =
    next(acknowledged, graph.ForkObserved(ref, first, fork.Succeeded("10")))
  let reserved_again = next(partial, graph.ForkAdmitted(ref, second))
  let complete =
    next(reserved_again, graph.ForkObserved(ref, second, fork.Succeeded("20")))
  let joined =
    next(
      complete,
      graph.ForkReturned(ref, "[10,20]", graph.Complete("0", "[10,20]")),
    )
  let blocked =
    next(complete, graph.ForkMappingFailed(ref, "[10,20]", "mapping failed"))
  let closing = next(blocked, graph.Cancel)
  let stopped = next(closing, graph.ForkStopped(ref))
  list.each(
    [
      ready,
      preparing,
      fixed,
      reserved,
      acknowledged,
      partial,
      reserved_again,
      complete,
      joined,
      blocked,
      closing,
      stopped,
    ],
    fn(state) {
      let assert Ok(bytes) = record.encode(state)
      record.decode(bytes) |> should.equal(Ok(state))
      record.decode(string.replace(bytes, "\"version\":15", "\"version\":13"))
      |> should.equal(Ok(state))
      record.decode(string.replace(bytes, "\"version\":15", "\"version\":12"))
      |> should.be_error
    },
  )
  graph.step(complete, graph.ForkWaiting(ref)) |> should.be_error
  graph.step(fixed, graph.ForkWaiting(ref)) |> should.be_error
  graph.step(reserved, graph.ForkWaiting(ref)) |> should.be_error
  record.encode(
    graph.State(..fixed, phase: graph.WaitingFork(a, graph.JoiningFork)),
  )
  |> should.be_error
  graph.step(partial, graph.ForkMappingFailed(ref, "", "early join"))
  |> should.be_error
  record.encode(graph.State(..fixed, phase: graph.Ready(a))) |> should.be_error
  record.encode(
    graph.State(
      ..fixed,
      phase: graph.Ended(graph.Failed(a, graph.Denied("lost work"))),
    ),
  )
  |> should.be_error
  record.encode(graph.State(..joined, forks: [])) |> should.be_error
  let assert Ok(bytes) = record.encode(fixed)
  record.decode(string.replace(bytes, "\"forks\":[", "\"missing_forks\":["))
  |> should.be_error
}

// G7, F8: branch attachments have their own identity domain and format gate.
pub fn branch_records_require_matching_attachments_and_version_thirteen_test() {
  let parent = run_id.from_string("parent")
  let id = attachment.branch_id("parent", 1, 2)
  let initial = initial()
  let assert graph.Ready(a) = initial.phase
  let ordinary =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(..a.prepared, kind: operation.Activity),
    )
  let state =
    graph.State(
      ..initial,
      run: id,
      parent: Some(run.GraphBranch(parent, 1, 2)),
      phase: graph.Ready(ordinary),
    )
  let assert Ok(bytes) = record.encode(state)
  record.decode(bytes) |> should.equal(Ok(state))
  record.decode(string.replace(bytes, "\"version\":15", "\"version\":12"))
  |> should.be_error
  record.encode(
    graph.State(..state, parent: Some(run.GraphBranch(parent, 1, 1))),
  )
  |> should.be_error
  record.encode(graph.State(..state, run: attachment.reserved_id("parent", 1)))
  |> should.be_error
}

// F6, F8: the armed deadline and first stop causes survive every phase.
pub fn fork_deadlines_require_version_fourteen_and_retain_expiration_test() {
  let original = initial()
  let assert graph.Ready(a) = original.phase
  let a =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(..a.prepared, deadline: Some(10)),
    )
  let ready = graph.State(..original, phase: graph.Ready(a))
  let ref = graph.reference(ready, a)
  let arming = next(ready, graph.Inspected(ref, Ok(policy.Allow), None))
  let assert graph.ArmingWait(_) = arming.phase
  let preparing = next(arming, graph.WaitArmed(ref, 100))
  let before_members = next(preparing, graph.ExpireWait(ref, 110))
  let assert graph.Ended(graph.Expired(_, graph.BeforeStart)) =
    before_members.phase
  let fixed =
    next(
      preparing,
      graph.ForkPrepared(
        ref,
        Ok([
          fork.Request(run.DefinitionId("one", 1), "1"),
          fork.Request(run.DefinitionId("two", 1), "2"),
        ]),
      ),
    )
  let occurrence = fork.Occurrence(run_id.from_string(ready.run), 1)
  let first = fork.Reference(occurrence, 1)
  let second = fork.Reference(occurrence, 2)
  let active =
    fixed
    |> next(graph.ForkAdmitted(ref, first))
    |> next(graph.ForkObserved(ref, first, fork.Active))
    |> next(graph.ForkAdmitted(ref, second))
    |> next(graph.ForkObserved(ref, second, fork.Active))
  let waiting = next(active, graph.ForkWaiting(ref))
  graph.step(waiting, graph.ExpireWait(ref, 109)) |> should.be_error
  let closing = next(waiting, graph.ExpireWait(ref, 110))
  let assert graph.Forking(a, graph.ClosingFork(operation.DeadlineReached(110))) =
    closing.phase
  let cancelled = next(closing, graph.Cancel)
  cancelled.phase |> should.equal(closing.phase)
  let stopped =
    cancelled
    |> next(graph.ForkObserved(ref, first, fork.Cancelled))
    |> next(graph.ForkObserved(ref, second, fork.Cancelled))
    |> next(graph.ForkStopped(ref))
  let assert graph.Ended(graph.Expired(_, graph.AfterFork)) = stopped.phase
  let complete =
    active
    |> next(graph.ForkObserved(ref, first, fork.Succeeded("10")))
    |> next(graph.ForkObserved(ref, second, fork.Succeeded("20")))
  let blocked =
    next(complete, graph.ForkMappingFailed(ref, "[10,20]", "invalid join"))
  let blocked_expired =
    blocked
    |> next(graph.ExpireWait(ref, 110))
    |> next(graph.ForkStopped(ref))
  let failed =
    next(active, graph.ForkObserved(ref, first, fork.Failed("failed first")))
  let failed_expired =
    failed
    |> next(graph.ExpireWait(ref, 110))
    |> next(graph.ForkObserved(ref, second, fork.Cancelled))
    |> next(graph.ForkStopped(ref))
  let assert [saved] = failed_expired.forks
  saved.stop |> should.equal(Some(fork.MemberFailed(first)))
  list.each(
    [
      ready,
      arming,
      preparing,
      before_members,
      fixed,
      waiting,
      closing,
      stopped,
      blocked,
      blocked_expired,
      failed_expired,
    ],
    fn(state) {
      let assert Ok(bytes) = record.encode(state)
      record.decode(bytes) |> should.equal(Ok(state))
      record.decode(string.replace(bytes, "\"version\":15", "\"version\":13"))
      |> should.be_error
    },
  )
  record.encode(
    graph.State(
      ..closing,
      phase: graph.Forking(
        a,
        graph.ClosingFork(operation.CancellationRequested),
      ),
    ),
  )
  |> should.be_error
  record.encode(
    graph.State(
      ..stopped,
      phase: graph.Ended(graph.Cancelled(a, graph.AfterFork)),
    ),
  )
  |> should.be_error
  record.encode(
    graph.State(
      ..preparing,
      phase: graph.PreparingFork(graph.Activation(..a, deadline: None)),
    ),
  )
  |> should.be_error
}

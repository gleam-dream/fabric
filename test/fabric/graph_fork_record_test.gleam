import fabric/graph/child
import fabric/graph/fork
import fabric/graph/operation
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record
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
      graph.Definition(run.Identity("parent", 1), "parent-v1", 1),
      "0",
      graph.Prepared(
        "pair",
        run.Identity("pair", 1),
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
  let preparing = next(ready, graph.Inspected(ref, Ok(policy.Allow)))
  let fixed =
    next(
      preparing,
      graph.ForkPrepared(
        ref,
        Ok([
          fork.Request(run.Identity("one", 1), "1"),
          fork.Request(run.Identity("two", 1), "2"),
        ]),
      ),
    )
  let occurrence = fork.Occurrence(run.issued(ready.run), a.id)
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
      record.decode(string.replace(bytes, "\"version\":13", "\"version\":12"))
      |> should.be_error
    },
  )
  graph.step(complete, graph.ForkWaiting(ref)) |> should.be_error
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
  let parent = run.issued("parent")
  let id = child.branch_id("parent", 1, 2)
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
  record.decode(string.replace(bytes, "\"version\":13", "\"version\":12"))
  |> should.be_error
  record.encode(
    graph.State(..state, parent: Some(run.GraphBranch(parent, 1, 1))),
  )
  |> should.be_error
  record.encode(graph.State(..state, run: child.reserved_id("parent", 1)))
  |> should.be_error
}

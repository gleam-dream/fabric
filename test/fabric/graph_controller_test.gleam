import fabric/graph/operation
import fabric/internal/graph/controller as graph
import fabric/policy
import fabric/run
import gleam/list
import gleam/option.{None}
import gleeunit/should

fn prepared(node: String) -> graph.Prepared {
  graph.Prepared(
    node,
    run.Identity(node, 1),
    "{}",
    operation.RequireReconciliation,
    operation.Activity,
    deadline: None,
  )
}

fn initial(limit: Int) -> graph.State {
  let definition =
    graph.Definition(run.Identity("review-loop", 1), "signature-1", limit)
  let assert Ok(#(state, [graph.Inspect(_)])) =
    graph.start("graph-1", definition, "0", prepared("generate"))
  state
}

fn advance(
  state: graph.State,
  event: graph.Event,
) -> #(graph.State, List(graph.Effect)) {
  let assert Ok(next) = graph.step(state, event)
  next
}

fn admitted(state: graph.State) -> graph.State {
  let assert graph.Ready(activation) = state.phase
  let assert #(state, [graph.Dispatch(_)]) =
    advance(
      state,
      graph.Inspected(graph.reference(state, activation), Ok(policy.Allow)),
    )
  state
}

fn running(state: graph.State) -> graph.State {
  let state = admitted(state)
  let assert graph.Queued(activation) = state.phase
  let assert #(state, []) =
    advance(state, graph.BodyStarted(graph.reference(state, activation)))
  state
}

pub fn one_completion_records_output_state_route_and_successor_together_test() {
  let before = running(initial(3))
  let assert graph.Running(activation) = before.phase
  let event =
    graph.Returned(
      graph.reference(before, activation),
      "\"draft\"",
      graph.Continue("1", prepared("review")),
    )
  let assert #(after, [graph.Inspect(next)]) = advance(before, event)
  after.value |> should.equal("1")
  after.allocated |> should.equal(2)
  next.id |> should.equal(2)
  next.attempt |> should.equal(1)
  after.phase |> should.equal(graph.Ready(next))
  after.receipts
  |> should.equal([
    graph.Receipt(activation, "\"draft\"", "1", graph.Next("review")),
  ])
  graph.step(after, event) |> should.equal(Error(graph.WrongPhase))
  let assert Ok(#(recovered, [graph.Inspect(restored)])) = graph.recover(after)
  restored |> should.equal(next)
  recovered.receipts |> should.equal(after.receipts)
}

pub fn cycles_allocate_distinct_visits_and_stop_before_excess_work_test() {
  let first = running(initial(2))
  let assert graph.Running(a1) = first.phase
  let #(second, _) =
    advance(
      first,
      graph.Returned(
        graph.reference(first, a1),
        "1",
        graph.Continue("1", prepared("generate")),
      ),
    )
  let second = running(second)
  let assert graph.Running(a2) = second.phase
  a1.id |> should.equal(1)
  a2.id |> should.equal(2)
  let #(stopped, effects) =
    advance(
      second,
      graph.Returned(
        graph.reference(second, a2),
        "2",
        graph.Continue("2", prepared("generate")),
      ),
    )
  stopped.allocated |> should.equal(2)
  stopped.receipts |> list.length |> should.equal(2)
  stopped.phase
  |> should.equal(graph.Ended(graph.Exhausted(prepared("generate"))))
  effects |> should.equal([])
}

pub fn stale_owner_and_attempt_cannot_start_or_finish_work_test() {
  let state = admitted(initial(2))
  let assert graph.Queued(activation) = state.phase
  let assert Ok(#(recovered, _)) = graph.recover(state)
  let recovered = admitted(recovered)
  graph.step(recovered, graph.BodyStarted(graph.reference(state, activation)))
  |> should.equal(Error(graph.StaleInvocation))
  graph.step(
    recovered,
    graph.BodyStarted(graph.Reference(recovered.incarnation, activation.id, 99)),
  )
  |> should.equal(Error(graph.StaleInvocation))
}

pub fn recovery_rechecks_queued_work_and_blocks_started_effects_test() {
  let queued = admitted(initial(2))
  let assert graph.Queued(activation) = queued.phase
  let assert Ok(#(recovered, [graph.Inspect(found)])) = graph.recover(queued)
  found |> should.equal(activation)
  recovered.phase |> should.equal(graph.Ready(activation))
  let started = running(initial(2))
  let assert graph.Running(started_activation) = started.phase
  let assert Ok(#(blocked, [])) = graph.recover(started)
  let assert graph.Blocked(found, graph.Uncertain(_)) = blocked.phase
  found |> should.equal(started_activation)
}

pub fn only_declared_bounded_replay_can_repeat_an_interrupted_body_test() {
  let base = initial(1)
  let assert graph.Ready(activation) = base.phase
  let replayable =
    graph.Prepared(
      ..activation.prepared,
      recovery: operation.ReplayInterrupted(2),
    )
  let first =
    running(
      graph.State(
        ..base,
        phase: graph.Ready(graph.Activation(..activation, prepared: replayable)),
      ),
    )
  let assert Ok(#(retry, [graph.Inspect(next)])) = graph.recover(first)
  next.id |> should.equal(1)
  next.attempt |> should.equal(2)
  retry.allocated |> should.equal(1)
  let second = running(retry)
  let assert Ok(#(blocked, [])) = graph.recover(second)
  let assert graph.Blocked(last, graph.Uncertain(_)) = blocked.phase
  last.attempt |> should.equal(2)
}

pub fn approval_requires_a_current_reference_and_fresh_requirement_test() {
  let state = initial(2)
  let assert graph.Ready(activation) = state.phase
  let requirement = run.Requirement("publish", 1)
  let assert #(waiting, []) =
    advance(
      state,
      graph.Inspected(
        graph.reference(state, activation),
        Ok(policy.RequireApproval(requirement)),
      ),
    )
  let assert graph.AwaitingApproval(_, reference) = waiting.phase
  let updated = run.Requirement("publish", 2)
  let assert #(changed, []) =
    advance(
      waiting,
      graph.Approved(reference, Ok(policy.RequireApproval(updated))),
    )
  let assert graph.AwaitingApproval(_, next) = changed.phase
  next.revision |> should.equal(reference.revision + 1)
  graph.step(changed, graph.Approved(reference, Ok(policy.Allow)))
  |> should.equal(Error(graph.StaleApproval))
  let assert Ok(#(restored, [])) = graph.recover(changed)
  let assert #(queued, [graph.Dispatch(_)]) =
    advance(restored, graph.Approved(next, Ok(policy.RequireApproval(updated))))
  let assert graph.Queued(_) = queued.phase
  graph.step(queued, graph.Approved(next, Ok(policy.Allow)))
  |> should.equal(Error(graph.WrongPhase))
}

pub fn policy_failure_and_denial_release_no_body_test() {
  let state = initial(2)
  let assert graph.Ready(activation) = state.phase
  let assert #(denied, []) =
    advance(
      state,
      graph.Inspected(
        graph.reference(state, activation),
        Ok(policy.Deny("blocked")),
      ),
    )
  denied.phase
  |> should.equal(
    graph.Ended(graph.Failed(activation, graph.Denied("blocked"))),
  )
  let assert #(failed, []) =
    advance(
      state,
      graph.Inspected(
        graph.reference(state, activation),
        Error("policy offline"),
      ),
    )
  failed.phase
  |> should.equal(
    graph.Ended(graph.Failed(activation, graph.PolicyFailed("policy offline"))),
  )
}

pub fn malformed_result_is_retained_for_reconciliation_test() {
  let state = running(initial(2))
  let assert graph.Running(activation) = state.phase
  let problem = graph.InvalidResult("not JSON", "decode failed")
  let assert #(blocked, []) =
    advance(
      state,
      graph.Unresolved(graph.reference(state, activation), problem),
    )
  blocked.phase |> should.equal(graph.Blocked(activation, problem))
  graph.step(
    blocked,
    graph.Reconciled(activation.id, 99, "1", graph.Complete("1", "1")),
  )
  |> should.equal(Error(graph.StaleInvocation))
  let assert #(done, []) =
    advance(
      blocked,
      graph.Reconciled(
        activation.id,
        activation.attempt,
        "1",
        graph.Complete("1", "1"),
      ),
    )
  done.phase |> should.equal(graph.Ended(graph.Completed("1")))
  done.receipts |> list.length |> should.equal(1)
}

pub fn cancellation_preserves_an_inflight_result_without_routing_test() {
  let state = running(initial(2))
  let assert graph.Running(activation) = state.phase
  let assert #(stopping, [graph.Stop]) = advance(state, graph.Cancel)
  let assert #(done, []) =
    advance(
      stopping,
      graph.Returned(
        graph.reference(state, activation),
        "1",
        graph.Continue("1", prepared("publish")),
      ),
    )
  done.phase
  |> should.equal(graph.Ended(graph.Cancelled(activation, graph.AfterResult)))
  done.allocated |> should.equal(1)
  done.value |> should.equal(state.value)
  done.receipts
  |> should.equal([graph.Receipt(activation, "1", state.value, graph.Canceled)])
}

pub fn cancellation_distinguishes_unstarted_and_unresolved_work_test() {
  let state = initial(2)
  let assert graph.Ready(activation) = state.phase
  let assert #(unstarted, []) = advance(state, graph.Cancel)
  unstarted.phase
  |> should.equal(graph.Ended(graph.Cancelled(activation, graph.BeforeStart)))
  let assert #(stopping, [graph.Stop]) = advance(running(state), graph.Cancel)
  let assert Ok(#(unresolved, [])) = graph.recover(stopping)
  let assert graph.Ended(graph.Cancelled(_, graph.UnresolvedCancellation(_))) =
    unresolved.phase
  let assert #(resolved, []) =
    advance(
      unresolved,
      graph.Reconciled(
        activation.id,
        activation.attempt,
        "1",
        graph.Continue("1", prepared("publish")),
      ),
    )
  resolved.phase
  |> should.equal(graph.Ended(graph.Cancelled(activation, graph.AfterResult)))
  resolved.allocated |> should.equal(1)
}

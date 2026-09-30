import fabric/graph/child
import fabric/graph/job
import fabric/graph/operation
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/flaky
import fabric/support/restart
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should

fn prepared(node: String) -> graph.Prepared {
  graph.Prepared(
    node,
    run.Identity("operation-" <> node, 2),
    "{\"input\":1}",
    operation.RequireReconciliation,
    operation.Activity,
    deadline: None,
  )
}

fn initial() -> graph.State {
  let assert Ok(#(state, _)) =
    graph.start(
      "graph-record",
      graph.Definition(run.Identity("review", 2), "sig-v2", 2),
      "0",
      prepared("generate"),
    )
  state
}

pub fn deadlines_retain_arming_due_time_and_expiration_without_legacy_downgrades_test() {
  let initial = initial()
  let assert graph.Ready(a) = initial.phase
  let a =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(
        ..a.prepared,
        kind: operation.Signal,
        deadline: Some(1000),
      ),
    )
  let ready = graph.State(..initial, phase: graph.Ready(a))
  let assert Ok(#(arming, _)) =
    graph.step(
      ready,
      graph.Inspected(graph.reference(ready, a), Ok(policy.Allow)),
    )
  let assert Ok(#(waiting, _)) =
    graph.step(arming, graph.WaitArmed(graph.reference(arming, a), 10_000))
  let assert graph.WaitingSignal(armed) = waiting.phase
  armed.deadline |> should.equal(Some(11_000))
  graph.step(waiting, graph.ExpireWait(graph.reference(waiting, armed), 10_999))
  |> should.be_error
  let assert Ok(#(expired, _)) =
    graph.step(
      waiting,
      graph.ExpireWait(graph.reference(waiting, armed), 11_000),
    )
  let assert Ok(#(accepted, _)) =
    graph.step(
      waiting,
      graph.Signaled(armed.id, armed.attempt, "1", graph.Complete("1", "1")),
    )
  list.each([ready, arming, waiting, expired, accepted], fn(state) {
    let assert Ok(encoded) = record.encode(state)
    record.decode(encoded) |> should.equal(Ok(state))
    record.decode(string.replace(encoded, "\"version\":13", "\"version\":9"))
    |> should.be_error
  })
  list.each(
    [
      graph.State(..initial, phase: graph.Ready(armed)),
      graph.State(..initial, phase: graph.ArmingWait(armed)),
      graph.State(..initial, phase: graph.WaitingSignal(a)),
      graph.State(
        ..initial,
        phase: graph.Ended(graph.Failed(armed, graph.DeadlineExpired(12_000))),
      ),
      graph.State(
        ..initial,
        phase: graph.Ended(graph.Cancelled(
          armed,
          graph.AfterFailure(graph.DeadlineExpired(11_000)),
        )),
      ),
    ],
    fn(state) { record.encode(state) |> should.be_error },
  )
  let assert Ok(bytes) = record.encode(waiting)
  record.decode(string.replace(bytes, "\"deadline\":11000", "\"deadline\":null"))
  |> should.be_error
  let assert Ok(legacy) = record.encode(initial)
  record.decode(string.replace(legacy, "\"version\":13", "\"version\":9"))
  |> should.equal(Ok(initial))
}

pub fn job_deadlines_keep_expiration_distinct_from_legacy_cancellation_test() {
  let initial = initial()
  let assert graph.Ready(a) = initial.phase
  let a =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(
        ..a.prepared,
        kind: operation.OwnedJob(job.Every(100)),
        deadline: Some(1000),
      ),
    )
  let ready = graph.State(..initial, phase: graph.Ready(a))
  let arming =
    next(ready, graph.Inspected(graph.reference(ready, a), Ok(policy.Allow)))
  let waiting =
    next(arming, graph.WaitArmed(graph.reference(arming, a), 10_000))
  let assert graph.WaitingJob(armed) = waiting.phase
  let ref = graph.reference(waiting, armed)
  let stopping = next(waiting, graph.ExpireWait(ref, 11_000))
  let started = next(stopping, graph.BodyStarted(ref))
  let accepted = next(started, graph.JobStopRequested(ref))
  let expired = next(accepted, graph.JobConfirmedStopped(ref))
  let completed =
    next(waiting, graph.JobExpired(ref, 11_000, job.Completed("1")))
  let cancelled_before_arming = next(arming, graph.Cancel)
  list.each(
    [
      ready,
      arming,
      waiting,
      stopping,
      started,
      accepted,
      expired,
      completed,
      cancelled_before_arming,
    ],
    fn(state) {
      let bytes = encoded(state)
      record.decode(bytes) |> should.equal(Ok(state))
      record.decode(string.replace(bytes, "\"version\":13", "\"version\":10"))
      |> should.be_error
    },
  )
  let stopped_bytes = encoded(stopping)
  record.decode(string.replace(stopped_bytes, "\"due\":11000", "\"due\":12000"))
  |> should.be_error
  record.decode(string.replace(
    stopped_bytes,
    ",\"cause\":{\"tag\":\"deadline\",\"due\":11000}",
    "",
  ))
  |> should.be_error
  list.each(
    [
      graph.State(
        ..initial,
        phase: graph.Ended(graph.Expired(a, graph.JobStopped)),
      ),
      graph.State(
        ..initial,
        phase: graph.Ended(graph.Expired(armed, graph.JobDetached)),
      ),
      graph.State(
        ..initial,
        phase: graph.Ended(graph.Expired(armed, graph.AfterResult)),
      ),
    ],
    fn(state) { record.encode(state) |> should.be_error },
  )
  let legacy_a =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(..a.prepared, deadline: None),
    )
  let legacy =
    graph.State(
      ..initial,
      phase: graph.StoppingJob(
        legacy_a,
        job.RequestAccepted,
        operation.CancellationRequested,
      ),
    )
  let without_cause =
    encoded(legacy)
    |> string.replace(",\"cause\":{\"tag\":\"requested\"}", "")
  record.decode(without_cause) |> should.be_error
  record.decode(string.replace(without_cause, "\"version\":13", "\"version\":9"))
  |> should.equal(Ok(legacy))
}

pub fn child_deadlines_retain_causes_and_uncertainty_without_legacy_downgrades_test() {
  let initial = initial()
  let assert graph.Ready(a) = initial.phase
  let a =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(
        ..a.prepared,
        kind: operation.Subgraph,
        deadline: Some(1000),
      ),
    )
  let ready = graph.State(..initial, phase: graph.Ready(a))
  let arming =
    next(ready, graph.Inspected(graph.reference(ready, a), Ok(policy.Allow)))
  let joining =
    next(arming, graph.WaitArmed(graph.reference(arming, a), 10_000))
  let assert graph.Joining(armed, id) = joining.phase
  let ref = graph.reference(joining, armed)
  let waiting = next(joining, graph.ChildWaiting(ref, id))
  let stopping = next(waiting, graph.ExpireWait(ref, 11_000))
  next(stopping, graph.Cancel) |> should.equal(stopping)
  let unresolved = next(stopping, graph.ChildStopped(ref, id, True))
  let settled = next(unresolved, graph.ChildCancellationSettled(ref, id))
  settled.phase
  |> should.equal(graph.Ended(graph.Expired(armed, graph.AfterChild(id))))
  list.each(
    [ready, arming, joining, waiting, stopping, unresolved, settled],
    fn(state) {
      let bytes = encoded(state)
      record.decode(bytes) |> should.equal(Ok(state))
      record.decode(string.replace(bytes, "\"version\":13", "\"version\":11"))
      |> should.be_error
    },
  )
  record.decode(string.replace(
    encoded(stopping),
    "\"due\":11000",
    "\"due\":12000",
  ))
  |> should.be_error
  list.each(
    [
      graph.State(..initial, phase: graph.WaitingChild(a, id)),
      graph.State(
        ..initial,
        phase: graph.Blocked(a, graph.InvalidResult("1", "mapping")),
      ),
      graph.State(
        ..initial,
        phase: graph.Ended(graph.Expired(armed, graph.JobDetached)),
      ),
      graph.State(
        ..initial,
        phase: graph.Ended(graph.Expired(armed, graph.AfterChild("wrong"))),
      ),
    ],
    fn(state) { record.encode(state) |> should.be_error },
  )
  let legacy_a =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(..a.prepared, deadline: None),
    )
  let legacy =
    graph.State(
      ..initial,
      phase: graph.StoppingChild(legacy_a, id, operation.CancellationRequested),
    )
  let without_cause =
    encoded(legacy) |> string.replace(",\"cause\":{\"tag\":\"requested\"}", "")
  record.decode(without_cause) |> should.be_error
  record.decode(string.replace(
    without_cause,
    "\"version\":13",
    "\"version\":11",
  ))
  |> should.equal(Ok(legacy))
}

pub fn owned_cancellation_records_require_version_nine_and_preserve_request_state_test() {
  let initial = initial()
  let assert graph.Ready(a) = initial.phase
  let a =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(
        ..a.prepared,
        kind: operation.OwnedJob(job.Every(100)),
      ),
    )
  list.each(
    [
      job.RequestQueued,
      job.RequestStarted,
      job.RequestAccepted,
      job.RequestRefused("refused"),
      job.RequestUncertain("unknown"),
    ],
    fn(progress) {
      let state =
        graph.State(
          ..initial,
          phase: graph.StoppingJob(a, progress, operation.CancellationRequested),
        )
      let assert Ok(encoded) = record.encode(state)
      record.decode(encoded) |> should.equal(Ok(state))
      record.decode(string.replace(encoded, "\"version\":13", "\"version\":8"))
      |> should.be_error
      record.decode(string.replace(encoded, "owned_job", "job"))
      |> should.be_error
    },
  )
  record.encode(
    graph.State(
      ..initial,
      phase: graph.Ended(graph.Cancelled(a, graph.JobDetached)),
    ),
  )
  |> should.be_error
  let readonly =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(..a.prepared, kind: operation.Job(job.Manual)),
    )
  record.encode(
    graph.State(
      ..initial,
      phase: graph.Ended(graph.Cancelled(readonly, graph.JobStopped)),
    ),
  )
  |> should.be_error
}

fn next(state: graph.State, event: graph.Event) -> graph.State {
  let assert Ok(#(state, _)) = graph.step(state, event)
  state
}

fn queued(state: graph.State) -> graph.State {
  let assert graph.Ready(activation) = state.phase
  next(
    state,
    graph.Inspected(graph.reference(state, activation), Ok(policy.Allow)),
  )
}

fn running(state: graph.State) -> graph.State {
  let state = queued(state)
  let assert graph.Queued(activation) = state.phase
  next(state, graph.BodyStarted(graph.reference(state, activation)))
}

fn encoded(state: graph.State) -> String {
  let assert Ok(text) = record.encode(state)
  text
}

pub fn waiting_children_keep_their_reserved_identity_and_roundtrip_test() {
  let state = initial()
  let assert graph.Ready(a) = state.phase
  let a =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(..a.prepared, kind: operation.Subgraph),
    )
  let id = child.reserved_id(state.run, a.id)
  let waiting = graph.State(..state, phase: graph.WaitingChild(a, id))
  record.decode(encoded(waiting)) |> should.equal(Ok(waiting))
  record.encode(
    graph.State(..waiting, phase: graph.WaitingChild(a, "unrelated")),
  )
  |> should.be_error
  let activity =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(..a.prepared, kind: operation.Activity),
    )
  record.encode(graph.State(..waiting, phase: graph.WaitingChild(activity, id)))
  |> should.be_error
}

pub fn saved_phases_and_all_terminal_dispositions_roundtrip_test() {
  let ready = initial()
  let queued = queued(ready)
  let running = running(ready)
  let assert graph.Running(activation) = running.phase
  let ref = graph.reference(running, activation)
  let waiting =
    next(
      ready,
      graph.Inspected(
        ref,
        Ok(policy.RequireApproval(run.Requirement("publish", 2))),
      ),
    )
  let blocked =
    next(
      running,
      graph.Unresolved(ref, graph.InvalidResult("not JSON", "output rejected")),
    )
  let stopping = next(running, graph.Cancel)
  let states = [
    ready,
    queued,
    running,
    waiting,
    blocked,
    stopping,
    next(running, graph.Unresolved(ref, graph.Uncertain("connection lost"))),
    next(
      running,
      graph.Returned(ref, "{\"result\":1}", graph.Complete("1", "true")),
    ),
    next(running, graph.FailedBody(ref, graph.OperationFailed("no result"))),
    next(ready, graph.Inspected(ref, Ok(policy.Deny("no access")))),
    next(ready, graph.Inspected(ref, Error("policy offline"))),
    next(ready, graph.Cancel),
    next(stopping, graph.Returned(ref, "1", graph.Complete("2", "2"))),
    next(stopping, graph.FailedBody(ref, graph.OperationFailed("failed"))),
    next(stopping, graph.Stopped),
    next(blocked, graph.Cancel),
  ]
  list.each(states, fn(state) {
    record.decode(encoded(state)) |> should.equal(Ok(state))
  })
}

pub fn stored_routing_and_budget_are_not_recomputed_after_decode_test() {
  let first = running(initial())
  let assert graph.Running(a1) = first.phase
  let second =
    next(
      first,
      graph.Returned(
        graph.reference(first, a1),
        "1",
        graph.Continue("1", prepared("review")),
      ),
    )
  let assert Ok(restored) = record.decode(encoded(second))
  let assert Ok(#(recovered, [graph.Inspect(a2)])) = graph.recover(restored)
  a2.id |> should.equal(2)
  a2.prepared |> should.equal(prepared("review"))
  recovered.receipts |> should.equal(second.receipts)
  let second = running(recovered)
  let finished =
    next(
      second,
      graph.Returned(
        graph.reference(second, a2),
        "false",
        graph.Continue("2", prepared("generate")),
      ),
    )
  let assert Ok(saved) = record.decode(encoded(finished))
  saved.phase
  |> should.equal(graph.Ended(graph.Exhausted(prepared("generate"))))
  saved.allocated |> should.equal(2)
  graph.recover(saved) |> should.equal(Error(graph.AlreadyEnded))
}

pub fn each_encoding_identifies_its_own_write_test() {
  let state = initial()
  let first = encoded(state)
  let second = encoded(state)
  { first == second } |> should.be_false
  record.decode(first) |> should.equal(record.decode(second))
}

pub fn recovery_contract_and_attempt_bound_survive_encoding_test() {
  let state = initial()
  let assert graph.Ready(a) = state.phase
  let prepared =
    graph.Prepared(..a.prepared, recovery: operation.ReplayInterrupted(2))
  let first =
    running(
      graph.State(..state, phase: graph.Ready(graph.Activation(..a, prepared:))),
    )
  let assert Ok(first) = record.decode(encoded(first))
  let assert Ok(#(retry, _)) = graph.recover(first)
  let assert Ok(retry) = record.decode(encoded(retry))
  let assert graph.Ready(a) = retry.phase
  a.attempt |> should.equal(2)
  a.prepared.recovery |> should.equal(operation.ReplayInterrupted(2))
  let assert Ok(#(blocked, [])) = graph.recover(running(retry))
  record.decode(encoded(blocked)) |> should.equal(Ok(blocked))
}

pub fn foreign_formats_and_future_versions_are_refused_before_state_decode_test() {
  record.decode("{\"format\":\"fabric.graph\",\"version\":1}")
  |> should.equal(Error(record.UnsupportedVersion(1)))
  record.decode("{\"format\":\"fabric.graph\",\"version\":2}")
  |> should.equal(Error(record.UnsupportedVersion(2)))
  record.decode("{\"format\":\"fabric.graph\",\"version\":3}")
  |> should.equal(Error(record.UnsupportedVersion(3)))
  record.decode("{\"format\":\"fabric.graph\",\"version\":4}")
  |> should.equal(Error(record.UnsupportedVersion(4)))
  let assert Error(record.Corrupt(_)) =
    record.decode("{\"format\":\"fabric.run\",\"version\":1}")
  let assert Error(record.Corrupt(_)) = record.decode("not JSON")
}

pub fn malformed_control_records_cannot_be_encoded_or_restored_test() {
  let state = initial()
  let assert graph.Ready(a) = state.phase
  let invalid = [
    graph.State(..state, run: "../escape"),
    graph.State(..state, incarnation: 0),
    graph.State(..state, approvals_issued: -1),
    graph.State(..state, allocated: 0),
    graph.State(..state, allocated: 2),
    graph.State(..state, value: "bad JSON"),
    graph.State(..state, phase: graph.Ready(graph.Activation(..a, attempt: 2))),
    graph.State(
      ..state,
      phase: graph.AwaitingApproval(
        a,
        graph.Approval(1, 1, 1, run.Requirement("publish", 1)),
      ),
    ),
    graph.State(..state, phase: graph.Ended(graph.Completed("0"))),
    graph.State(
      ..state,
      phase: graph.Ended(graph.Cancelled(a, graph.AfterResult)),
    ),
  ]
  list.each(invalid, fn(state) {
    record.encode(state) |> result.is_error |> should.be_true
  })
  let text = encoded(state)
  list.each(
    [
      string.replace(text, "\"allocated\":1", "\"allocated\":2"),
      string.replace(text, "\"attempt\":1", "\"attempt\":0"),
      string.replace(text, "\"tag\":\"ready\"", "\"tag\":\"unknown\""),
    ],
    fn(text) {
      let assert Error(record.Corrupt(_)) = record.decode(text)
      Nil
    },
  )
}

pub fn signal_records_cannot_be_restored_as_executable_bodies_test() {
  let initial = initial()
  let assert graph.Ready(a) = initial.phase
  let signal =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(..a.prepared, kind: operation.Signal),
    )
  let state = graph.State(..initial, phase: graph.Ready(signal))
  let waiting =
    next(
      state,
      graph.Inspected(graph.reference(state, signal), Ok(policy.Allow)),
    )
  waiting.phase |> should.equal(graph.WaitingSignal(signal))
  graph.needs_runner(waiting) |> should.be_false
  record.decode(encoded(waiting)) |> should.equal(Ok(waiting))
  let bad = [
    graph.State(..waiting, phase: graph.Queued(signal)),
    graph.State(..waiting, phase: graph.Running(signal)),
    graph.State(
      ..waiting,
      phase: graph.Blocked(signal, graph.Uncertain("not a body")),
    ),
    graph.State(..waiting, phase: graph.WaitingSignal(a)),
    graph.State(
      ..waiting,
      phase: graph.Ended(graph.Cancelled(
        signal,
        graph.UnresolvedCancellation(graph.Uncertain("not started")),
      )),
    ),
  ]
  list.each(bad, fn(state) {
    record.encode(state) |> result.is_error |> should.be_true
  })
  let malformed =
    string.replace(
      encoded(waiting),
      "\"tag\":\"waiting_signal\"",
      "\"tag\":\"running\"",
    )
  let assert Error(record.Corrupt(_)) = record.decode(malformed)
}

pub fn receipts_must_form_one_ordered_route_to_the_current_activation_test() {
  let state = running(initial())
  let assert graph.Running(a) = state.phase
  let second =
    next(
      state,
      graph.Returned(
        graph.reference(state, a),
        "1",
        graph.Continue("1", prepared("review")),
      ),
    )
  let assert [receipt] = second.receipts
  list.each(
    [
      graph.State(..second, receipts: [receipt, receipt]),
      graph.State(..second, receipts: [
        graph.Receipt(..receipt, route: graph.Finished),
      ]),
      graph.State(..second, receipts: [
        graph.Receipt(..receipt, route: graph.Next("other")),
      ]),
      graph.State(..second, receipts: [
        graph.Receipt(..receipt, activation: graph.Activation(..a, id: 2)),
      ]),
      graph.State(..second, receipts: [
        graph.Receipt(..receipt, output: "not JSON"),
      ]),
      graph.State(..second, value: "2"),
    ],
    fn(state) { record.encode(state) |> result.is_error |> should.be_true },
  )
  let corrupt =
    encoded(second)
    |> string.replace(
      "\"route\":{\"tag\":\"next\",\"node\":\"review\"}",
      "\"route\":{\"tag\":\"next\",\"node\":\"wrong\"}",
    )
  let assert Error(record.Corrupt(_)) = record.decode(corrupt)
  Nil
}

pub fn a_graph_record_survives_store_process_loss_and_cas_refuses_a_stale_route_test() {
  let dir = restart.temp_dir()
  let started = running(initial())
  let assert graph.Running(a) = started.phase
  let advanced =
    next(
      started,
      graph.Returned(
        graph.reference(started, a),
        "1",
        graph.Continue("1", prepared("review")),
      ),
    )
  let #(owner, runs) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      store.insert(runs, started.run, encoded(started), store.Keep)
      |> should.equal(Ok(1))
      store.commit(runs, started.run, 1, encoded(advanced), store.Keep)
      |> should.equal(Ok(2))
      runs
    })
  restart.crash(owner, runs)
  let reopened = support.directory(dir)
  let assert Ok(entry) = store.get(reopened, started.run)
  let assert Ok(restored) = record.decode(entry.record)
  restored |> should.equal(advanced)
  store.commit(reopened, started.run, 1, encoded(started), store.Keep)
  |> should.equal(Error(store.Conflict(2)))
  let assert Ok(#(recovered, [graph.Inspect(pending)])) =
    graph.recover(restored)
  pending.prepared.node |> should.equal("review")
  recovered.receipts |> should.equal(advanced.receipts)
  restart.remove_dir(dir)
}

pub fn graph_writes_use_the_store_lost_acknowledgement_confirmation_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let state = initial()
  flaky.arm(backend, [flaky.FailAfter, flaky.FailAfter])
  store.insert(runs, state.run, encoded(state), store.Keep)
  |> should.equal(Ok(1))
  let queued = queued(state)
  store.commit(runs, state.run, 1, encoded(queued), store.Keep)
  |> should.equal(Ok(2))
  let assert Ok(entry) = store.get(runs, state.run)
  record.decode(entry.record) |> should.equal(Ok(queued))
}

pub fn cancelled_receipts_cannot_rewrite_the_previous_application_state_test() {
  let first = running(initial())
  let assert graph.Running(a) = first.phase
  let second =
    next(
      first,
      graph.Returned(
        graph.reference(first, a),
        "1",
        graph.Continue("1", prepared("review")),
      ),
    )
  let second = running(second)
  let assert graph.Running(a) = second.phase
  let stopping = next(second, graph.Cancel)
  let cancelled =
    next(
      stopping,
      graph.Returned(
        graph.reference(second, a),
        "true",
        graph.Complete("2", "2"),
      ),
    )
  record.decode(encoded(cancelled)) |> should.equal(Ok(cancelled))
  let assert [first, last] = cancelled.receipts
  let forged =
    graph.State(..cancelled, value: "2", receipts: [
      first,
      graph.Receipt(..last, state: "2"),
    ])
  record.encode(forged) |> result.is_error |> should.be_true
}

pub fn job_records_require_version_seven_and_cannot_claim_owned_effect_states_test() {
  let initial = initial()
  let assert graph.Ready(a) = initial.phase
  let a =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(..a.prepared, kind: operation.Job(job.Manual)),
    )
  let ready = graph.State(..initial, phase: graph.Ready(a))
  let waiting =
    next(ready, graph.Inspected(graph.reference(ready, a), Ok(policy.Allow)))
  waiting.phase |> should.equal(graph.WaitingJob(a))
  let assert Ok(encoded) = record.encode(waiting)
  record.decode(encoded) |> should.equal(Ok(waiting))
  record.decode(string.replace(encoded, "\"version\":13", "\"version\":6"))
  |> should.be_error
  let cancelled = next(waiting, graph.Cancel)
  cancelled.phase
  |> should.equal(graph.Ended(graph.Cancelled(a, graph.JobDetached)))
  let assert Ok(encoded) = record.encode(cancelled)
  record.decode(encoded) |> should.equal(Ok(cancelled))
  list.each(
    [
      graph.State(..waiting, phase: graph.Running(a)),
      graph.State(
        ..waiting,
        phase: graph.WaitingJob(
          graph.Activation(..a, prepared: prepared("generate")),
        ),
      ),
      graph.State(
        ..waiting,
        phase: graph.Ended(graph.Cancelled(
          a,
          graph.UnresolvedCancellation(graph.Uncertain("not an owned effect")),
        )),
      ),
      graph.State(
        ..waiting,
        phase: graph.Ended(graph.Cancelled(
          graph.Activation(..a, prepared: prepared("generate")),
          graph.JobDetached,
        )),
      ),
    ],
    fn(state) { record.encode(state) |> should.be_error },
  )
  let assert Ok(encoded) = record.encode(initial)
  record.decode(string.replace(encoded, "\"version\":13", "\"version\":6"))
  |> should.equal(Ok(initial))
  record.decode(string.replace(encoded, "\"version\":13", "\"version\":5"))
  |> should.equal(Ok(initial))
}

pub fn scheduled_job_intervals_roundtrip_and_require_version_eight_test() {
  let initial = initial()
  let assert graph.Ready(a) = initial.phase
  let a =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(
        ..a.prepared,
        kind: operation.Job(job.Every(1000)),
      ),
    )
  let ready = graph.State(..initial, phase: graph.Ready(a))
  let waiting =
    next(ready, graph.Inspected(graph.reference(ready, a), Ok(policy.Allow)))
  let assert Ok(encoded) = record.encode(waiting)
  record.decode(encoded) |> should.equal(Ok(waiting))
  record.decode(string.replace(encoded, "\"version\":13", "\"version\":7"))
  |> should.be_error
  record.decode(string.replace(
    encoded,
    "\"poll_every\":1000",
    "\"poll_every\":0",
  ))
  |> should.be_error
  record.decode(string.replace(
    encoded,
    "\"poll_every\":1000",
    "\"poll_every\":4294967296",
  ))
  |> should.be_error
  record.decode(string.replace(
    encoded,
    "\"kind\":\"job\"",
    "\"kind\":\"activity\"",
  ))
  |> should.be_error
  let assert graph.WaitingJob(a) = waiting.phase
  let manual =
    graph.State(
      ..waiting,
      phase: graph.WaitingJob(
        graph.Activation(
          ..a,
          prepared: graph.Prepared(
            ..a.prepared,
            kind: operation.Job(job.Manual),
          ),
        ),
      ),
    )
  let assert Ok(manual_bytes) = record.encode(manual)
  record.decode(string.replace(manual_bytes, "\"version\":13", "\"version\":7"))
  |> should.equal(Ok(manual))
}

# Hand a call over by policy decision and end the agent run

<a id="adr-0021"></a>

Accepted 2026-11-16 in answer to gleam-dream/fabric issue 5, whose text the
`decisions` repository retains in
`docs/requests/fabric-tool-outcome-that-ends-a-run.md`. An application that
gives an agent's gated call to another system (a decision point where a person
decides, possibly days later) had two ways to stop the run from performing the
call, and neither ended the run. Parking the run on an approval no approver
can give leaves an approval that expires (seven days by default), and an
expired approval is a rejection the model reads, so the model takes another
turn and can tell a customer something the record contradicts. A tool body
that files the call and returns "filed for review" lets the run continue at
once. The two consumers worked around the gap: the `decisions` laboratory
cancels the parked run and starts a fresh one, and `payout_desk` keeps the
approval open forever and resumes the parked run once the decision is
recorded.

## Decision

A policy decision hands an action over: `policy.HandOver(reason)`. For an
agent run the action never runs, no model turn follows, and the run ends as
`run.Finished(run.HandedOver(action, tool, arguments_json, reason))`. The
action's record keeps the call as the model sent it, in the new action state
`run.Handover(reason)`.

- **Admitted with the model's reply.** The policy sees the reply's calls in
  order. At the first handover the run ends in the same commit as the reply:
  every other call that was allowed or waited for an approval is withdrawn
  (`NotStarted`), refusals keep their states, and calls after the handover are
  not shown to the policy. Nothing of the reply ran, so nothing is stopped.
- **Decided later.** An approval's policy recheck, or recovery's recheck of a
  queued action, can return `HandOver`. Work of that batch already in flight is
  then stopped exactly as a cancellation stops it: running bodies are stopped
  and become uncertain effects unless they settle late, active sub-agent runs
  are cancelled, and the run ends `HandedOver` once the batch has stopped.
- **Pending approvals.** Every approval request of the run is voided by the
  ending. An answer to one is refused with `RunEnded`, and an expiry finds
  nothing to expire, because an ended run accepts no answer, expiry or model
  turn. The answer that preceded a handover on recheck stays on the action as
  audit evidence and authorizes nothing.
- **Recovery.** The handover is part of one commit: the model reply's
  admission, the answer's recheck or the recovery's recheck. A runner lost
  before that commit leaves the earlier state, and recovery repeats the step
  (a lost model call is issued again as a new attempt). A runner lost after it
  leaves either an ended run, which recovery does not touch, or a stopping run
  whose stop recovery completes into the same `HandedOver` outcome. The handed
  over tool never runs, so no body runs twice.
- **Sub-agents.** A sub-agent run that hands one of its calls over ends its
  delegating parent the same way: the parent's delegation is `Handover`, and
  the parent's outcome names the child's action, so the application finds the
  call from the root. The child's other uncertain effects stay in the child's
  record for reconciliation. A finished parent that settles a delegation from
  stored child evidence (`settle_stored`) keeps the child's outcome as
  `ChildSettled`.
- **Graphs.** A graph run takes no handover. Its routes are the application's,
  an expired graph approval already fails the run instead of continuing it, and
  an operation another system decides is a signal wait
  (`operation.await_signal`) with a deadline. A graph policy that returns
  `HandOver` fails the run as `graph.PolicyFailed`, and the operation does not
  run. A managed agent node whose child run hands over is a definite child
  failure for its graph.
- **Continuing elsewhere.** The application files the call keyed by
  `HandedOver.action`, in its standard text form `run.action_ref_to_string`
  (`<run id>/<turn>.<call id>`, read back with `run.parse_action_ref`; the
  action id alone is `run.action_id_to_string`, `<turn>.<call id>`). A run
  id never contains `/` or `.` and a turn never contains `.`, so the first
  separator splits and a call id may contain either. When the other system
  has decided, `fabric.handover_history(snapshot, result:)` returns the run's
  transcript with a result for every call of the ending reply (the
  handed-over call gets the decision, encoded with `tool.reconciliation`; a
  refused call its refusal; a withdrawn call an error saying it never ran).
  `input.continuation(history)` takes that history as the follow-on run's
  whole original input, with no user message appended, and
  `fabric.start_with_input` starts it under its own id: the first model turn
  continues from the decision as the handed-over run's next turn would have.
  `input.new(history, prompt)` stays for an application that has something
  new to tell the model. The handed-over run itself never continues.
- **The follow-on and the policy.** The follow-on run is driven by the same
  agent and policy. A policy that always hands the call over hands it over
  again if the follow-on model repeats the call, so the application's policy
  recognises the follow-on (from its context, say) and denies or allows the
  call there. Fabric does not mark a follow-on run: the application decides
  what a follow-on is.
- **Parked runs.** A run already parked on an approval is ended without a
  model turn by `fabric.cancel`: the request is voided, its expiry passes
  without effect, and the parked action stays `NotStarted` with its arguments.
  No second mechanism is added for it. Such a run ended `Cancelled`, not
  `HandedOver`, so `handover_history` refuses it (`NotHandedOver`): an
  application moving from parking to handing over tells its in-flight parked
  cases from its own record or starts a fresh run. Continuing a cancelled
  parked run from its history is not supported in 0.3.0.

A continuation's original input ends with tool results instead of a user
prompt. The record keeps it as any original input: `initial_message_count`
marks the boundary, the snapshot's transcript starts with it, and
`fabric/history` stores the messages unchanged (its format did not change).
`AlreadyStarted(id, same)` and `matches_initial` compare original input
message for message, so a continuation and a prompted input of the same
history are different inputs. Readers before version 10 validated that
original input ends with a user prompt, so such a boundary is part of version
10: a version 10 reader accepts either ending, an earlier version still
requires the prompt, and a store whose writer is older than 10 refuses a
continuation before storing anything (`fabric.HistoryUnsupported`). No version
11 was added; version 10 is unreleased.

Record version 10 stores the handover (the action state, the outcome, and the
stop reason of a stopping batch). Readers accept versions 1–10. A store whose
writer is selected below version 10 cannot represent a handover; for it the
controller turns the policy's handover into `PolicyFailed`, so the run ends
closed without the action running and no commit is ever refused. Records
written by version 9 read unchanged (a fixture written by the published
fabric 0.2.0 is retained under `test/fixtures/records/`).

Every record a version 10 writer stores is labelled version 10, including runs
that never handed anything over, as every earlier format step labelled all of
its writes (ADR 0010: writer selection is distinct from reader compatibility).
A node still running the published fabric 0.2.0 reads such a record as
`UnsupportedVersion(10)`: `open`, `recover` and `cancel_stored` refuse it, its
retention and statistics projections read it as unknown, and it runs nothing.
This was checked by reading a version 10 record of a run without a handover
with the 0.2.0 source. It is the same step as version 8 to 9, so a rolling
deployment upgrades every reader first while the stores keep writer 9
(`store.with_record_version(store, 9)`), and selects 10 only after every node
reads it. Under writer 9 a handover fails its run as `PolicyFailed`.

## Rejected alternatives

- **A tool outcome returned by the body** (a `tool.Failure` variant or a
  handover-returning binding). The body would file the call inside its effect
  fence, so the handover would be an effect whose result can be lost: a runner
  lost after the fence and before the report leaves an uncertain effect, and a
  reconciliation would have to end the run instead of answering the model,
  which no current reconciliation does. Only the body would know the call is
  handed over, the policy and the approval path would not, and the model's
  call would already have reached the body. A policy decision is known before
  any effect, is one commit, and keeps the filing in the application's own
  outbox keyed by the action.
- **A tool kind declared in the agent definition** (a bodiless tool that always
  hands over). It is additive to `policy.Decision`, but it cannot express a
  call that runs below a limit and is handed over above it, and a static kind
  duplicates what the policy already decides per call.
- **A command that closes a parked run as handed over.** Cancellation already
  ends a parked run without a model turn and voids its approvals; a second
  command for the same ending would add an outcome without a new guarantee.
- **Letting in-flight siblings finish before the run ends.** It would keep a
  running body's result definite, but it needs a second stopping mode beside
  cancellation's, with its own interaction with cancel, drain and recovery. A
  handover decided while bodies run arises only from an approval or recovery
  recheck, so the cancellation stop is reused.

## Compatibility

The change adds a variant to four public types: `policy.Decision`
(`HandOver`), `run.Outcome` (`HandedOver`), `run.ActionState` (`Handover`) and
`fabric/telemetry.OutcomeKind` (`HandedOver`). `run.Outcome`,
`run.ActionState` and `OutcomeKind` are documented as unions that may grow;
`policy.Decision` is not, and an application that matches a decision
exhaustively no longer compiles. `input.InputError` gains
`NotEndingInToolResults`. The public additions are `fabric.handover_history`,
`fabric.HandoverHistoryError`, `input.continuation`,
`run.action_id_to_string`, `run.parse_action_id`, `run.action_ref_to_string`
and `run.parse_action_ref`. The agent record
format moves to version 10, and the default writer of every store is 10. The
change therefore needs fabric 0.3.0; consumers that pin `< 0.3.0` keep 0.2.0
until they opt in. `fabric_postgres` stores records as opaque bytes and needs
no migration, but its requirement must move to `>= 0.3.0 and < 0.4.0` when it
is released against 0.3.0; until fabric 0.3.0 is on Hex it depends on this
repository by path.

# A handed-over call ends an agent run

Source: gleam-dream/fabric issue 5. The `decisions` repository retains its
text in `docs/requests/fabric-tool-outcome-that-ends-a-run.md`.

## Problem

An application that gives an agent's gated call to another system (a person at
a decision point, possibly days later) could not end the run that asked. A run
parked on an approval nobody can give wakes when the approval expires: the
model reads the expiry as a rejection, takes another turn and can tell a
customer something the record contradicts. A tool body that files the call and
returns a result lets the run continue at once.

## Outcome

- A policy decision, `policy.HandOver(reason)`, ends an agent run at the call
  as `run.HandedOver(action, tool, arguments_json, reason)`, with no further
  model turn and without running the tool.
- The action's record keeps the call (`run.Handover(reason)`); snapshots, the
  history codec and record version 10 retain it.
- Every approval request of the run is voided; the other calls of the reply are
  withdrawn, or stopped as by cancellation when the handover is decided while
  they run.
- Recovery around the handover reaches the same ending on every store.
- A sub-agent's handover ends its parent; a graph takes no handover.
- `fabric.handover_history` lets a follow-on run continue the conversation with
  the decision as the call's result.

The design and its rationale are in `docs/design/design.typ` (section "Handing
an action over") and `docs/adr/0021-hand-a-call-over-by-policy-and-end-the-run.md`.

## Issues

- `issues/01-hand-a-call-over-by-policy.md`: the runtime change, tests, usage
  example and design layer.
- `issues/02-release-and-consumer-follow-up.md`: the release and the consumer
  changes this work leaves open.

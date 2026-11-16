# Read an ended run's snapshot or handover history without its agent

Status: needs-triage
Category: enhancement

## What

`fabric.snapshot` and therefore `fabric.handover_history` need a handle, and
a handle needs the live agent and context (`fabric.open`). A worker that only
files the handed-over call, or builds the follow-on input, has to construct
the agent and a context it does not otherwise use. A store-level read of an
ended run's snapshot, or of its handover history, would need neither, as
`fabric.reconcile_stored` and `fabric.settle_stored` already work without an
agent.

Deferred by the owner while preparing 0.3.0; not built.

## Comments

AI-assisted contribution. Raised by the first consumer of the handover
(Oversight's `payout_desk`).

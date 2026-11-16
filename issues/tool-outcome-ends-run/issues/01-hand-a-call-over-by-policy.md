# Hand a call over by policy and end the agent run

Status: done
Category: enhancement

## What

Add `policy.HandOver(reason)`. For an agent run the handed-over action never
runs and the run ends `run.HandedOver(action, tool, arguments_json, reason)`
with no further model turn. Record it in agent record version 10.

## Acceptance

- The issue's first example as a test: the same scripted model and gated tool
  end at the handover, the approval expiry passes, no third model call happens
  and no answer is produced (`test/fabric/handover_test.gleam`).
- Sibling calls of the reply are withdrawn, a voided approval is refused, and
  a handover on an approval recheck stops a running sibling.
- A runner killed before and after the handover is recorded recovers into the
  same ending on the in-memory store and on PostgreSQL
  (`integrations/fabric_postgres/test/fabric_postgres/handover_test.gleam`).
- A record written by the published fabric 0.2.0 still reads
  (`test/fixtures/records/published-0.2.0-parked.json`), and cancelling that
  parked run ends it without a model turn.
- A sub-agent's handover ends its parent; a graph policy's handover fails the
  graph closed; a managed agent's handover fails its graph.
- A compiled usage example (`examples/usage/src/usage/handover.gleam`) feeds a
  README section through Snips.
- ADR 0021 and the design layer record the decision and the rejected shapes.

## Comments

AI-assisted contribution. Implemented in the worktree on branch
`feat/tool-outcome-ends-run`, uncommitted, with every validation command of
`AGENTS.md` run and passing.

AI-assisted contribution. Review follow-up: added tests for a handover on
recovery's recheck of a queued action, sweeper recovery of a run stopping for
a handover (in-memory leased store and PostgreSQL), a directory store restart,
the `invoke` response, `run_finished` telemetry and the follow-on history of a
reply with refused and withdrawn calls. The telemetry test found that the
`run_finished` metadata enum lacked `HandedOver`, so typed handlers skipped the
event; fixed in `src/fabric/telemetry.gleam`. A published 0.2.0 reader refuses
a version 10 record as `UnsupportedVersion(10)`; ADR 0021 states the rollout.

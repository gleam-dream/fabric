# Release fabric 0.3.0 and move the consumers off their workarounds

Status: ready-for-human
Category: enhancement

## What

- Publish fabric 0.3.0. `policy.Decision` gained a variant that is not
  documented as growing, so an exhaustive match on it stops compiling; the
  agent record default writer moved to version 10.
- Before publishing `fabric_postgres`, replace its path dependency on this
  repository with `fabric = ">= 0.3.0 and < 0.4.0"` and lock it with
  `gleam deps update fabric`. Its README install snippet still names
  `>= 0.1.0 and < 0.2.0`, which predates this change.
- Roll readers to 0.3.0 on every node before any node writes version 10, or
  select writer 9 (`store.with_record_version`) until then; with writer 9 a
  handover fails the run as `PolicyFailed`.
- In `gleam-dream/oversight` (`apps/payout_desk`) and the `decisions` recipe,
  replace the parked approval (`run.Infinity`, an approver that refuses until
  the decision point answers, cancelling or resuming the parked run) with
  `policy.HandOver`, file the occurrence from `run.HandedOver.action`, and
  continue with `fabric.handover_history` and a follow-on run. Those
  repositories are not changed by this work.

## Open questions

- Whether a running sibling of a handover decided on an approval recheck
  should finish instead of being stopped. ADR 0021 keeps the cancellation stop;
  it is reversible without a format change only if a new stopping mode is
  added.

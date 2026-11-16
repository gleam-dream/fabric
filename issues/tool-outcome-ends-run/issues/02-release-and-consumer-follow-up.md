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

## Decided

- A running sibling of a handover decided on an approval's or recovery's
  recheck is stopped as a cancellation stops it, as ADR 0021 states. "Let it
  finish" is not built; it waits for a consumer whose policy changes its
  answer within one reply.

## Comments

AI-assisted contribution. The owner decided the four open points on
2026-11-16:

- **The shape.** `policy.HandOver` as built. An outcome returned by the tool
  body is not built; it waits for a consumer that must start work before it
  can know the call is another system's.
- **A running sibling.** Stopped as a cancellation stops it, as built.
- **The release.** A separate step after pull request 6 merges, in the three
  commits the 0.2.0 release used: release fabric 0.3.0 with its tag and Hex
  publication, consume it in the adapter and the consumers, then release
  `fabric_postgres` with its requirement on fabric 0.3.
- **The consumers.** `payout_desk` in `gleam-dream/oversight` is converted
  now, on a branch that pins this repository by Git and is not merged. The
  0.3.0 release waits for that branch to pass, so that a real consumer has
  used `policy.HandOver` and `fabric.handover_history` before the API is
  published. After the release the pin moves to Hex, the branch merges, and
  the `decisions` design, its ADR 0017 and its README are updated.

AI-assisted contribution. State on 2026-11-16, after the release:

- fabric 0.3.0 is published to Hex and tagged `v0.3.0`.
- `fabric_postgres` requires `fabric >= 0.3.0 and < 0.4.0` from Hex again,
  its README names that line, and it is released as 0.2.0, because its
  requirement on fabric moved to a line that 0.2 consumers cannot take.
- `payout_desk` was converted on a branch of `gleam-dream/oversight` before
  the release. It found four gaps that were fixed before 0.3.0
  (`input.continuation`, the text form of an action, and two points of
  documentation) and one in the documentation of `run.id_from_parts`.
- Still open, in other repositories: that branch moves its pin from Git to the
  Hex release and merges, and the `decisions` design, its ADR 0017 and its
  README are updated.

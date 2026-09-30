# Structured parallel graph contract

This refines G9 in the [wave tracker](wave-tracker.md) under the authorized
six-stage program. It owns the fork lifecycle described by
[GRAPH-FLOW](../../GRAPH-FLOW.md#parallel-composition-without-shared-writes).
Stage 4 remains open until the public runtime and persistent-backend scenarios
exercise this contract.

## Membership and ownership

A fork occurrence belongs to one parent run and one activation. It fixes an
ordered list of member requests before admitting any child. A request names a
versioned child definition and its encoded initial state. Member ordinals start
at one; equal inputs still produce different members. Repeating a node creates
another activation and another occurrence. Incarnations and observation attempts
do not change the occurrence or member identity.

Each reserved or acknowledged member owns a managed graph child with private state. Ordinary
operations and agents can participate through graph definitions. Pair composition
retains two independently typed answers; map composition retains one answer per
input position. Both use this same scope lifecycle. The parent commits one join
after the scope settles. Branches never write parent application state directly.

The scope records a positive maximum member count and a positive concurrency
limit. An empty map is successful with no children. An oversized map is refused
before admission. Concurrency counts admitted, unsettled members, including
members waiting for approvals, signals or reconciliation. Admission follows
declared order. Shared family work, child and depth budgets still apply.
Restoration also checks capacity at each admitted ordinal: an earlier member
that remains unsettled could not have freed its slot for a later member.

## Member lifecycle

| State                         | Meaning                                                |
| ----------------------------- | ------------------------------------------------------ |
| Pending                       | No child has been admitted.                            |
| Withdrawn                     | A stop prevented admission; no child is owned.         |
| Rejected(reason)              | Admission failed definitely; no child is owned.        |
| Reserved                      | Child identity is owned; creation is not acknowledged. |
| Admitted(Active)              | The scope owns a child whose result is not yet known.  |
| Admitted(Uncertain(evidence)) | Child effects or its result need resolution.           |
| Admitted(Succeeded(output))   | A validated encoded result is retained.                |
| Admitted(Failed(reason))      | A definite child failure is retained.                  |
| Admitted(Cancelled)           | The child is canceled with no unresolved effects.      |

Admission first retains a reservation. An observed child record changes it to
acknowledged progress. Both states consume concurrency and retain ownership.
Recovery may create a missing reserved child using the same identity; a missing
acknowledged child is data loss and cannot be recreated. A rejected admission
and a failed admitted child remain different because only the latter has a
child to retain and settle. Child records own detailed approval, signal, job
and effect evidence; the scope owns membership and join eligibility.

The scope is either open or stopping with a retained first cause: a failed
member, explicit cancellation, or expiration. A definite rejection, failure or
unexpected child cancellation closes admission and withdraws pending members.
Every admitted unsettled child must then receive cancellation and be observed
until settled. Later successes remain evidence and cannot turn the stopped
scope into a successful join. Later stop requests do not replace its cause.
The parent retains its own cancellation or expiration intent separately from
the scope's first failure. Canceling during sibling cleanup must suppress the
business fallback even when member failure remains the scope's first cause.
An admission rejection must itself be the saved stop cause: once another stop
has committed, admission can no longer be attempted or rejected.

Uncertainty alone blocks further member admission and joining. Already admitted
members may settle. Resolving the uncertain child's record can restore active
work or establish a terminal result. An observer error or unavailable child is
not a definite business failure and must never free its slot.

## Behavioral rules

| Rule | Required outcome                                                                                                                                                                                 |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| F1   | Creation validates the occurrence, positive bounds, request identities and encoded inputs, fixing all member ordinals before admission. Empty membership succeeds; excess membership is refused. |
| F2   | Admission selects the first pending member only when the scope is open, no member is uncertain and capacity remains. Committing admission precedes child start.                                  |
| F3   | An observation must name an admitted member of the exact occurrence. Identical terminal observations are idempotent; conflicting terminal observations are refused.                              |
| F4   | A successful join contains every member's result in declared order. Partial completion and uncertainty cannot release a join.                                                                    |
| F5   | Definite member failure retains its identity as the first stop cause, withdraws pending members and keeps ownership of admitted siblings until settlement.                                       |
| F6   | Explicit cancellation or expiration also closes admission and retains cleanup. Cancellation may win before the parent commits its join, even after all member results arrived.                   |
| F7   | Uncertainty prevents new admissions and join completion until authoritative child evidence resolves it. Stop intent never erases uncertainty.                                                    |
| F8   | Restoring a scope validates membership, bounds, admission order, stop cause and member-state coherence. Saved outcomes are reused without rerunning members.                                     |

## Join and failure handling

Successful pair and map results keep their native result types. A settled
definite member failure is a typed fork failure available to the node's
acceptance callback, so the application can route to a fallback. Its failed
member reference and all saved member outcomes remain inspectable. Explicit
parent cancellation and expiration bypass business acceptance, as they do for
serial managed children. A failed join callback retains the settled scope and
encoded output for reconciliation; it never repeats children. Reconciliation
may retry acceptance, but its output must agree with the retained member
results. Recovery checks fixed membership against the saved activation input
and the deployed typed binding before any member can run.

Readiness is derived from the saved scope. It is not another terminal flag.
A scope with unsettled admitted members cannot join, including after a stop.
The parent record's revision check arbitrates concurrent observations, stop
intent and join acceptance. An observation of a child result does not itself
authorize a successor or replace the parent's ownership checks.

## Runtime and persistence integration

The graph controller owns the scope within its execution record, retaining it
in history after a join. The runner commits membership and admissions before
effects, verifies deployed child definitions, reserves family capacity, starts
or adopts managed children, and commits observations. Live reports remain
fenced by the graph controller's incarnation and attempt. Scope references
add membership correlation; they do not replace that fence.

Idle discovery must observe every admitted unsettled child. Losing a local
notification cannot hide completion or cleanup after restart. Retention follows
every admitted child's reciprocal attachment and refuses pruning an incomplete
or unresolved family. Neither scheduling hints nor missing child records grant
permission to fabricate a result or a replacement child.

A fork may park only when it cannot admit another member, has no unacknowledged
starts, and is not ready to join. Discovery retains every unsettled child identity
and compares its last observed revision, including absence as evidence. A backend
claims the parent and records these observations atomically. The wait key includes
activation, attempt, mode and membership; execution revisions and incarnations
are not new waits. A membership change may require one new baseline observation.

Nested idle scopes expose retained progress without restarting children on each
observation. Discovery leaves an unchanged, unclaimed ancestor read-only and
releases an unchanged claimed wait after restoring its watches. It can recover
an independently expired descendant while preserving a live foreign parent
lease. Repeated cancellation follows retained cleanup instead of restarting it.
Both active and stopping scopes keep these rules, so scans converge after lost
notifications without reopening canceled business routes.

This introduces no Saga, Grind or new infrastructure dependency. The first
model supports all-success joins with settled failure handling. Streaming
partial results, sibling writes to shared state, races and quorum policies
remain outside this wave.

## Evidence and remaining integration

The public `graph.both(identity, left, right)` operation accepts independently
typed initial states and returns a typed pair or settled `fork.Failure`. Its
constructor returns `Result`; both managed runtimes must use the parent's store.
`graph.branch` opens a retained member by activation and one-based ordinal.

The map authoring surface is `graph.map(identity, child, max_members:,
concurrency:)`. Its input and successful output are native lists of the child's
state and answer types. Both bounds must be positive; empty input succeeds,
oversized input fails before reserving any child, and equal inputs still have
separate ordinal identities. A waiting or uncertain child continues to occupy
its concurrency slot. This uses the same typed failure and join rules as pairs.

The pure scope tests cover F1–F8's transition and restoration cases. Public pair
scenarios now prove overlapping execution, declared result order, typed fallback,
partial directory-backend restart, join failure, cancellation during uncertain
sibling cleanup, and refusal of changed membership or fabricated join results.
Graph records write version 13 and read 5–13; new scopes and branch attachments
cannot be downgraded. Retention projection 10 includes every owned member.

Map scenarios prove bounded overlap, ordered answers, distinct equal inputs,
empty and oversized inputs, failure withdrawal, and directory-backend restart
with completed, waiting and pending members. The separate graph consumer maps
full generation/review loops with private child state.

Discovery projection 9 schedules every unsettled member. Shared leased-backend
scenarios prove lost-watch recovery, convergent nested waits, cancellation with
uncertain leaf effects, and independent branch recovery under a live foreign
parent lease. PostgreSQL schema 6 retains all dependency revisions atomically;
its map scenario proves competing claims after store loss, changes in nonfirst
members, ordered completion through registered sweeping, and family pruning.
The schema upgrade preserves execution bytes, revisions, ages and scheduled
observation times. Older projections require a bounded metadata refresh.

Five family scenarios prove repeated visits with distinct branch identities,
stale-signal refusal after a directory restart, sibling joins with equal
definitions and inputs, and shared work/child/depth limits. Exact-capacity runs
survive recovery without reserving the same grant twice. Child admission refusal
leaves the denied member distinct from already admitted siblings and withdrawn
inputs. Nested scopes cannot reset ancestry depth or the parent's work limit.

Wave 4 remains active. Fork deadlines still require runtime evidence. The
persistent claim test covers a flat map; nested cleanup has been exercised
through the shared leased backend rather than PostgreSQL.

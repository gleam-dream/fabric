# Wave tracker: production readiness and application evidence

## Current state

- Last updated: 2026-09-30. Program complete; all three waves accepted locally.
- Approved outcome: the user's three-part goal below, in full. This follows the
  accepted graph program, not a reopening or reduction of that program.
- Active wave: none.
- Next: library publication and hosted CI remain deferred by the user; retained
  product features and optional authoring refinements are separate follow-ups.
- Evidence: the working tree began clean at `000edd9`. Existing CI checks out
  only Fabric and runs only its root suite. Four clean sibling revisions supply
  required path dependencies; their advertised GitHub locations did not serve
  those commits (three 404 responses, one missing-commit response).
- Dependency decision: the user explicitly deferred CI activation and library
  publication, and rejected retaining source snapshots. The temporary snapshot
  approach was removed. Prepare the complete gate against existing sibling
  checkouts; published dependencies will be configured later.
- Gate status: the replacement local gate passed all 41 checks. A repeat
  uncovered a scheduled-job discovery race (43 failures in 100 isolated runs).
  Claim revalidation plus a local reservation fixed the reproduced race:
  100 repetitions and two new regression scenarios pass. The final full gate
  passed all 41 checks, including 625 core and 57 real PostgreSQL tests.
- Checkpoints: `39e28a8` repairs scheduled observation; `4e491af` prepares the
  local gate and reconciles the backlog.
- Readiness status: the first S7 slice passed the complete local gate. Its
  [operations contract](operations.md) defines bounded storage probes, live
  acceptance, safe lease evidence and renewal age. Seven focused core scenarios
  pass, including a delayed probe, renewal failure, restart and an expired
  lease window. PostgreSQL proves migration is required and probes leave
  records untouched. Hosted CI and publication remain explicitly deferred.
- Statistics progress: O6–O11 have an implementation with SQL schema 7 and
  diagnostic projection 1. Six pure projection scenarios and all 64 PostgreSQL
  tests pass, including real lifecycle counts, ages, uncertainty, unknowns,
  budget exclusion and concurrent refresh/write. Expanded tests exposed the
  harness's 300-connection limit; server logs confirmed it. The new scenarios
  now close their pools on success or failure. The complete gate passed all
  41 checks, including 638 core and 64 PostgreSQL tests; statistics are accepted.

- Shutdown and runbook: O12–O16 and the [operations runbook](../../OPERATIONS.md)
  are implemented. Twelve public shutdown scenarios and the complete gate pass:
  all 41 checks, 650 core tests and 64 PostgreSQL tests. S7 is accepted locally.
  The realistic application and actual provider comparison are now implemented;
  earlier live adapter checks are not substituted for this evidence.
- Application: eight writing scenarios and seven evaluation-runner scenarios
  pass. Both actual reviewers completed the frozen 12-case corpus and separate-VM
  approval/save workflows. TypeSafe matched 12/12 labels; GPT-4.1 nano matched
  6/12. See the [comparison and authoring findings](writing-comparison.md).
  The initial full gate passed 45 checks. A live-run preflight exposed an empty
  inherited credential masking `.env.local`; the loader fix and regression pass.
  The final gate passed all 45 checks; the acceptance audit below closes this
  program. No core runtime code changed in the application wave.

## Original objective and authorization

1. Make verification reproducible: update the stale backlog and fix CI's sibling
   dependency setup and incomplete integration coverage.
2. Finish production operations (S7): readiness, counts and ages of stuck or
   unattended runs, recovery delays, shutdown summaries, and an operations
   runbook.
3. Exercise a realistic generation/review/revision application with real tools,
   approval and restart recovery. Run the same cases through an LLM and
   TypeSafe, comparing decision quality, latency and cost, and assess authoring
   friction.

The user explicitly selected these three outcomes as an active implementation
goal on 2026-09-30. They then clarified that only the verification logic should
be prepared now: libraries will be published and CI enabled later. This is an
explicit deferral, not evidence that hosted reproducibility has been proved. Normal design refinement, implementation, verification and
coherent checkpoint commits are authorized. Publication, deployment and adding
Saga or Grind to core are outside this program. No second plan approval is
needed for this accepted scope. Material changes to ownership or adoption will
be raised separately; precise operations behavior will be recorded before code.

## Product and boundaries

The shortest application path is a supplied source document and writing brief
through generation, a typed review decision, bounded revision, human approval
and a real saved artifact. Recovery must reuse completed work and the pending
approval without duplicating publication. Both reviewer implementations use
the same graph and case corpus. Quality measures use declared expected outcomes,
not the provider's self-reported confidence as accuracy.

| Boundary               | Development and target implementation                            | Evidence required                                                          |
| ---------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Toolchain              | Existing pinned Nix flake, Gleam, OTP, Python, PostgreSQL 16     | One complete local gate, ready for future CI wiring                        |
| Sibling libraries      | Existing local checkouts now; immutable published versions later | Clear missing-dependency failures; no vendoring or implicit fallback       |
| Persistence            | Existing store contract and PostgreSQL integration               | Real isolated database tests for operational gauges and failure handling   |
| Readiness and shutdown | Store-owned health and supervisor-owned runner accounting        | Boot, idle, live renewal, failure, drain and deadline evidence             |
| Application tools      | Typed application-owned filesystem/artifact operations           | Actual artifact and durable operation receipts, approval and restart       |
| Decisions              | Existing llm_wire LLM and optional TypeSafe adapters             | Actual inference on the same corpus, raw receipts, usage and elapsed times |
| Observation            | Existing Sinal facts and explicit read-only operational APIs     | Reporting cannot own or change workflow progress                           |

## Complete wave plan

### 1. Verification preparation (CI activation deferred by the user)

- Anchors: repository AGENTS tooling, PLAN validation and production slices,
  REMAINING release/continuous checks, graph contracts G1–G11.
- Outcome: one complete credential-free gate using the existing sibling
  arrangement, including all maintained packages, external services, PostgreSQL
  and the retained compiler-negative authoring proof. CI wiring remains a
  documented follow-up after publication.
- Core/shell: validate required package names and paths before any suite; invoke
  existing gates with explicit failure and retained logs.
- Libraries: existing Nix toolchain. No runtime adoption or hosted service.
- Scenarios: missing sibling, unknown or missing package/gate, failed check and
  later checks not misreported as passed. No snapshots or automatic dependency
  publication. Full checks must exercise real local services and PostgreSQL.
- Gate: `nix develop -c python3 scripts/check.py full`; the prepared `ci` profile
  uses exactly the same checks. Fast iteration remains available.
- Exit: successful complete local gate, negative checks and backlog reconciled
  to current evidence. Document that fresh standalone checkout and hosted CI
  await published dependency selection; these are not claimed as completed.
- Risk/revisit: activate CI and select immutable published versions only in the
  later publication work explicitly reserved by the user.

### 2. S7 production operations

- Anchors: REMAINING S7, PLAN S2 drain, S3 leases, S4 PostgreSQL and S5 sweeping;
  graph and agent lifecycle/uncertainty contracts remain unchanged.
- Outcome: callers can assess store readiness and inspect current work,
  unattended work, approval/reconciliation waits, per-node leases and recovery
  delay; shutdown reports successful handoffs, failed handoffs and forced kills.
- Core/shell: named lifecycle categories and timestamp semantics in a pure
  projection; real database aggregation, bounded health reads and supervisor
  accounting. Document startup/idle readiness explicitly.
- Libraries: existing PostgreSQL and Sinal only. No metrics service or queue.
- Scenarios: fresh/idle/busy stores; renewal failure and recovery; every run
  category and age; expired leases; concurrent changes; failed handoff; forced
  shutdown; reporting failures cannot authorize or repeat effects.
- Gate: focused public behavior tests, real temporary PostgreSQL suite, full
  reproducible gate. Include operational procedures tied to actual APIs/events.
- Exit: all requested gauges, readiness and summaries exercised and runbook
  procedures checked against code. No missing gauge called an accepted defer.
- Risk/revisit: lifecycle projection/version requirements and supervisor races;
  retain unknown or stale metadata explicitly instead of inventing counts.

### 3. Realistic application and provider comparison

- Anchors: graph G1–G11, adapter receipts and effect policy, new application
  contract within this user's explicit scope.
- Outcome: runnable generation/review/revision workflow with actual tools,
  human approval, restart and publication; same evaluation cases for both
  reviewer implementations, with a retained comparison report.
- Core/shell: shared native review outcome and bounded routes; real generation,
  independent LLM/classifier review, durable artifact effect and user approval.
- Libraries: existing llm_wire and fabric_typesafe, no added platform.
- Scenarios: approve, revise, reject/limit, invalid response, withheld/rejected
  approval, store restart while waiting, reuse of completed results and no
  duplicate publish. Offline error tests supplement actual provider execution.
- Gate: consumer behavioral tests plus full gate; explicit bounded live command
  with ignored local credentials and retained sanitized measurements.
- Exit: both providers actually run the same corpus; report quality against
  the corpus, sample size, latency, token usage and price assumptions; distinguish
  measured cost from an estimate or unavailable billing information. Record
  concrete authoring improvements supported by the exercise.
- Risk/revisit: model variability and billing evidence. Never substitute a
  scripted provider run or invented price for a required live comparison.

## Plan review and acceptance (revision 2)

This sequence implements the accepted user goal without new runtime adoption.
The shared local gate prepares verification first; operations become measurable
before the realistic consumer exercises them. Existing libraries remain owners
of their existing protocols. New operations detail is a refinement of S7, not
permission to move execution into observations or change effect replay.

Every accepted wave records its actual commands, results, contract coverage,
remaining substitutions and next action here. Completion requires all three
waves and a requirement-by-requirement audit; one green suite is insufficient.

## Wave history

### Wave 1 — accepted 2026-09-30

Delivered the shared credential-free verification command, dependency and
package coverage checks, retained command/results logs, failure reporting and
backlog reconciliation. The `ci` profile is prepared but the hosted workflow is
unchanged. No sibling source snapshots are retained.

Verification:

- `nix fmt` passed. `nix develop -c python3 scripts/check.py full --logs
/tmp/fabric-readiness-final-gate` passed all 41 checks: package formatting,
  warnings-as-errors builds, core/integration/consumer tests, actual PostgreSQL
  and job-service tests, and valid/invalid typed authoring consumers.
- Core: 625 tests; PostgreSQL: 57; gate failure/coverage scenarios: 5.
  Exact command, status, duration and local dependency evidence are in the
  gate's `results.json` and `dependencies.json`.
- A prior repeat failed the scheduled job scenario (43/100 isolated failures).
  The J12 repair reserves the local observation through claim release and
  rechecks current ownership. It passed 100 repetitions, all 7 scheduling
  scenarios, then the complete gate above. Failure evidence is retained under
  `/tmp/fabric-readiness-prepared-ci-gate`; focused results are in
  `/tmp/fabric-job-schedule-serialized.log` and
  `/tmp/fabric-job-schedule-regressions.log`.

Acceptance: requested local preparation and J12 behavior are implemented;
public scenarios cover claim loss and observer loss. Missing dependencies and
failed commands produce explicit failures. No runtime dependency or publication
was added. The local reservation changes no durable record format and grants
no new effect authority. Formatting and compiler checks pass; Python typing
remains a convention because no strict checker is configured.

Remaining distance: S7 and the realistic comparison are unbuilt. Hosted
verification still requires published dependency selection and a fresh hosted
run, explicitly deferred by the user. The next wave remains S7; the scheduling
repair supplies stronger recovery evidence without changing its scope.

### Wave 2 progress — readiness slice accepted 2026-09-30

O1–O5 are implemented by `store.readiness`: a bounded storage probe followed
by a current actor-state report, local runner count, lease duration and last
successful renewal age. Ready idle/startup behavior, read failure/crash/timeout,
lease expiry during a process stall, concurrent drain, renewal failure and
restart are covered by seven core scenarios. A real PostgreSQL scenario checks
an unmigrated database fails, migration makes it ready, and inspection creates
no row or record/lease mutation. Readiness does not claim or renew work.

`nix develop -c python3 scripts/check.py full --logs
/tmp/fabric-readiness-s7-gate` passed all 41 checks: 632 core tests and 58
PostgreSQL tests, plus the existing integrations, consumers and authoring proof.
The initial missing-API scenario failed before implementation; a manual focused
invocation initially lacked the telemetry application, then passed with runtime
dependencies started. The full gate starts them through the normal test runner.

This accepts the readiness slice, not wave 2. O6–O11 record the next statistics
contract. Database gauges, sweep backlog, shutdown summaries and the runbook
remain required before S7 is complete. No new runtime dependency or persisted
execution format was introduced.

### Wave 2 progress — statistics slice accepted 2026-09-30

O6–O11 are implemented by the pure `fabric/statistics` projection and
`fabric_postgres.stats` / `refresh_statistics`. Schema 7 stores diagnostic
metadata with the source revision atomically. One read-only SQL statement uses
one snapshot and clock sample for run buckets, intervention counts, record ages,
budget exclusion, explicit unknowns, per-node live leases and expired-lease lag.
Refresh preserves original bytes, revisions, leases and ages; it does not make
unsupported records healthy. No execution record format changed.

The first missing-API scenarios failed before implementation. Six core scenarios
cover agent and graph classifications, overlapping requests, unresolved terminal
effects, valid expiry, waits, unsupported formats, identity mismatch and budget
records. Six real PostgreSQL scenarios cover empty groups, actual agent and
graph lifecycles, exact counts, age meanings, lease groups, read-only reporting,
stale metadata, bounded refresh and a concurrent write/refresh.

Expanded tests initially exceeded the temporary server's 300-client limit;
`/tmp/fabric-postgres-statistics-diagnostic.log` retains PostgreSQL's explicit
"too many clients" evidence. The new scenarios now scope connection pools with
cleanup on success and failure. The test script retains server-side errors
before discarding its temporary cluster. The corrected PostgreSQL suite passed
all 64 tests without increasing the connection limit.

`nix develop -c python3 scripts/check.py full --logs
/tmp/fabric-statistics-full-gate` passed all 41 checks, including 638 core and
64 PostgreSQL tests, all consumers/integrations and the compiler-negative proof.
The package README records migration, refresh and gauge semantics. Acceptance
is limited to these diagnostic contracts; observations still grant no effect
authority. No dependency, hosted CI activation, publication or deployment was
added. S7 still requires shutdown summaries and the complete runbook; wave 3
still requires the real application and live comparison.

### Wave 2 — shutdown and operations accepted 2026-09-30

O12–O16 now report the supervised shutdown cohort through `observation.drain`.
The store confirms handoff writes, retains exit evidence from monitors, and a
reporting worker stops between the factory and store. Confirmed, failed and
pending handoffs are independent of killed, other and unobserved exits. Store
loss emits `drain_unavailable`. Collection and emission are bounded and neither
can authorize a workflow effect. Per-runner drain limits and recovery ownership
are unchanged; the application must budget the documented reporting overhead.

The first public scenario failed because the summary API was missing. Twelve
public scenarios now cover confirmed writes, lost acknowledgment readback,
unconfirmed writes, deadline kills, commits still pending after the deadline,
confirmed handoff followed by a blocked handler/kill, bounded summary observers,
idle stores with completed/suspended runs, graph handoff, admitted starts racing
drain, store loss and normal completion during drain. The admitted-start scenario
initially expected no handoff; inspection showed the existing runner can finish
its initial commit then hand off without starting effects, and the assertion was
corrected to that behavior. Existing drain, graph and supervision suites pass.

`nix develop -c python3 scripts/check.py full --logs
/tmp/fabric-shutdown-full-gate` passed all 41 checks, including 650 core and 64
real PostgreSQL tests, all integrations/consumers and compiler-negative proof.
The runbook was checked against the public APIs, lease/sweeper implementation,
current execution and projection versions, SQL schema and adapter migration notes.
It covers startup order, node identity, readiness, count/age interpretation,
recovery lag, lease/sweep tuning, shutdown, rolling upgrades, unknown identities,
reconciliation and complete-family retention. Final documentation formatting is
checked separately after this gate; no runtime edits followed the green gate.

Acceptance audit:

| Requirement                             | Evidence and judgment                                                                                                                                                       |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Readiness and renewal age               | O1–O5; seven core scenarios plus real PostgreSQL migration/no-mutation evidence. Passed.                                                                                    |
| Counts, ages, intervention and unknowns | O6–O11; six core and six PostgreSQL scenarios, including concurrency and read-only snapshots. Passed.                                                                       |
| Per-node leases and recovery backlog    | Statistics snapshot and expired-lease overdue age, with existing sweep/lease events. Passed; backlog age is explicitly not end-to-end latency.                              |
| Shutdown outcomes                       | O12–O16; twelve public scenarios, independent handoff/exit facts and bounded reporting. Passed.                                                                             |
| Operational procedures                  | Runbook tied to actual APIs, independent version windows and failure behavior. Passed by source review; no deployed-environment drill is claimed.                           |
| Design, scope and craft                 | No new dependency or stored execution format; observation remains diagnostic. State owns explicit evidence, effects stay supervised, and tests use public outcomes. Passed. |
| Complete verification                   | All 41 local checks pass. Hosted CI/publication remain deferred by the user.                                                                                                |

Wave 2 is accepted. Remaining authorized work is wave 3: the realistic artifact
workflow, approval/restart evidence and measured live decision comparison.
Publication, deployment and hosted CI activation remain outside this run.

### Wave 3 — application and comparison accepted 2026-09-30

`consumers/writing` composes the existing graph and decision adapters with real
source-read and artifact-save operations. Native approve/revise/reject values
control at most three drafts. Saving requires durable approval and uses a
stable run/activation key with identical-content acknowledgment and conflicting
content refusal. The application owns that effect contract; Fabric continues
to own admission, progress, recovery and policy. No core runtime or sibling
library implementation changed.

Eight Gleam scenarios cover successful approval/restart, revision/exhaustion,
review rejection, human-approval rejection, invalid/refused/incomplete output,
missing source, artifact identity and a saved result lost before graph commit.
The interrupted-save test initially expected automatic completion after
recovery; the existing per-attempt policy correctly requires a fresh approval.
The corrected scenario checks the old reference is refused, the new one
completes, the artifact is identical, and model calls are not repeated.

Seven Python scenarios validate frozen cases, literal allowlisted dotenv
loading, environment precedence, measured values and failed-attempt accounting.
The first live preflight sent no requests because an empty inherited API-key
variable masked `.env.local`. The loader now falls back for empty values, with
a regression test. This repair preceded the successful measured run.

The [live comparison](writing-comparison.md) retains every attempt and source
hash. Both actual providers completed all 12 frozen cases once, without retry
or fallback: GPT-4.1 nano matched 6/12 expected labels with a 2,698.5 ms median;
Jev 1.13.0 matched 12/12 with a 465 ms median. All outputs were valid typed
decisions. The report includes every disagreement, usage and dated public-price
estimates; measured billing remains unavailable. This small developer-authored
corpus does not establish general production accuracy.

Both complete live workflows reached approval, exited the VM, restored
identical snapshots in another VM and saved an artifact after a third VM
supplied approval. The demonstration operator is explicitly scripted. Saved
content matches each receipt's SHA-256, and earlier receipts remain unchanged.
These live examples completed on their first draft; deterministic scenarios
cover revision paths. Directory storage proves VM/process restart, not
power-loss durability. The successful live run made 28 provider requests.

Final verification:

- `nix develop -c python3 scripts/check.py full --logs
/tmp/fabric-writing-final-gate` passed all 45 checks after the loader repair:
  650 core tests, 64 real PostgreSQL tests, all integration/consumer/service
  suites, eight writing tests, seven evaluation tests and the typed-authoring
  positive/negative proof. Command, status, duration and dependency records are
  retained in that gate directory. No live credentials enter this gate.
- Retained evidence was recomputed against all 24 corpus/reviewer pairs, source
  hashes, summaries, restart snapshots and artifact digests. New local document
  links resolve. Final formatting is checked separately after this acceptance
  text; no implementation edits followed the successful gate.
- Authoring review found a useful small `Reviewer(receipt)` boundary and
  repetitive codec/stage mappings. Follow-up simplification and a larger holdout
  evaluation are recorded in REMAINING, without expanding this accepted scope.

#### Whole-goal acceptance audit

| Original outcome                      | Evidence and judgment                                                                                                                                                                                                                                                                               |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Reproducible verification and backlog | Shared fast/full/CI profiles, explicit sibling/package preflight, service/database coverage, retained failure logs and reconciled current inventories. Passed locally. Publication, standalone dependency resolution and hosted activation are explicitly deferred by the user's later instruction. |
| S7 operations                         | O1–O16: bounded readiness, renewal age, run/intervention/unknown counts and ages, per-node leases, expired-lease lag, independent shutdown handoff/exit evidence and runbook. Passed with real PostgreSQL and public lifecycle tests. No deployment drill is claimed.                               |
| Realistic application                 | W1–W6: actual files, generation, typed review, bounded revisions, approval, VM restart and interrupted-save recovery. Passed; scripted providers cover deterministic failure paths, while actual providers complete the live application.                                                           |
| Live decision comparison              | W7–W8: identical frozen cases and rubric, both real adapters, all attempts retained, quality/latency/usage/cost assumptions and concrete authoring findings. Passed; no inferred billing or broad accuracy claim.                                                                                   |
| Boundaries and verification           | Existing public APIs, no Saga/Grind core dependency, no sibling snapshots or hosted workflow change. All 45 local checks pass. Source/evidence consistency and documentation checked. Passed.                                                                                                       |

All three requested outcomes are accepted within the user's clarified local
scope. No required program work remains. Optional product features, publication,
deployment and hosted CI are not silently added to this goal.

# Wave tracker: production readiness and application evidence

## Current state

- Last updated: 2026-09-30. Program active; wave 1 accepted locally.
- Approved outcome: the user's three-part goal below, in full. This follows the
  accepted graph program, not a reopening or reduction of that program.
- Active wave: operations contracts and S7.
- Next: store readiness, PostgreSQL gauges and shutdown accounting, then the
  realistic application comparison.
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
- Next action: commit the verified changes and implement S7. Hosted CI and
  publication remain deferred by the user's explicit correction.

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

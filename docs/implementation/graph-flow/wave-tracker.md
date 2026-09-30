# Wave tracker: Fabric graph flow

## Current state

- Last updated: 2026-09-30.
- Program status: active. Full six-step objective remains open.
- Target design: [GRAPH-FLOW](../../GRAPH-FLOW.md), as selected by the user's
  explicit six-step implementation goal following the exploration.
- Approved first outcome: an application authors a generation/review graph
  with native types and scripted decisions; it returns a typed answer or
  stops at its activation limit. This is evidence for step 1, not completion
  of the full runtime objective.
- Plan revision: 3, 2026-09-29; preserves the six requested steps.
- Last closed wave: 2, public durable serial graph runtime.
- Active wave: 3, managed agents/subgraphs, durable signals and external jobs.
- Next wave: 4, typed fork/map/join with explicit failure handling.
- Open decisions: wave 3's owned remote cancellation, automatic observation and
  deadline contracts are being refined. Submission, receipt recovery and retained
  read-only job waits are proven against an independently retained service.
  Idle dependency discovery is implemented. Public shared work/child/depth budgets, mixed-family admission,
  root initialization and ledger retention are implemented. Registered graph
  sweeping recovers expired work and changed idle dependencies through mixed attachments. Shared parent
  identities and manual signal contracts are implemented.
  Native authoring, serial lifecycle, compatibility and public control are now
  concrete in the [durable sequential contract](durable-sequential.md).
  Actual remote credentials/endpoints are checked before wave 5. No new paid
  infrastructure is selected.
- Temporary substitutions: scripted decisions remain in tests and examples;
  real decision/protocol adapters are required in wave 5. The synchronous
  authoring driver has been replaced by the production persistent runner.
- Gate status: 520 root tests, four graph consumer tests, 15 app consumer tests,
  seven external-job consumer scenarios and two independent service tests pass.
  The PostgreSQL gate passes 47 tests, including job-wait recovery and pruning,
  migration and concurrent index refresh. Builds use
  warnings as errors. Explicit source formatting, `nix fmt`, `nix flake check`
  and `git diff --check` pass on this host.
- Current evidence: typed native operations and commands run through public
  start/read/await/recover/approval/reconciliation/cancellation APIs. Directory
  and PostgreSQL scenarios retain work over store-process loss. Terminal tool
  evidence and delegated outcomes settle without resuming canceled work.
  PostgreSQL prunes complete settled graph/agent families from their saved
  attachments, preserving unresolved effects and incomplete membership. Shared host
  startup and the executor preserve current agent behavior.
- Next action: add durable due-time observation to the retained job wait using
  the real service in `consumers/jobs`, followed by owned remote cancellation
  and explicit deadline outcomes under the
  [managed composition contract](managed-composition.md).
  These remain runtime states rather than blocking operation wrappers.
- Resume note: the user requested another checkpoint commit and continued
  implementation on 2026-09-30. The app goal is confirmed active with all six
  stages preserved. The initial runtime checkpoint
  is committed as `04ae481`. Initial subgraphs do not establish
  complete managed composition, parallel joins or real adapter support.

## Authorization and acceptance

The user supplied the complete six-step objective as an active implementation
goal on 2026-09-29. This authorizes implementation of the program already
presented, including using a compiled experiment to settle routine API
details. It does not authorize reducing the goal to the first experiment,
adding Saga/Grind dependencies, deploying services or bypassing effect policy.

The final result must provide typed graph authoring, durable sequential and
cyclic control, activation identity, policy admission, managed agents and
subgraphs, durable signals, external-job attachment, typed fork/map/join and
explicit failure handling. Real classifier, LLM and MCP adapters must be
exercised; protocol stubs alone do not establish provider acceptance. Finally,
evaluate an ordinary agent graph recipe with evidence for behavioral parity.
An evaluation may retain the existing agent controller if the evidence shows
that convergence does not simplify it; skipping that evaluation is not done.

The first runtime path is typed input → generate → review → bounded revision
→ typed answer. Later waves replace only the declared temporary boundaries.
The full objective includes all six waves below, not merely that first path.

## Governing contracts and coverage

These identifiers project the selected graph design into executable evidence.
They clarify the proposed examples for the authorized implementation program.

| Rule | Contract                                                                                                                                                                              | First evidence owner                                     |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| G1   | A graph binds heterogeneous native operation types without unchecked casts; codecs are required for durable values, provider schema is not.                                           | Wave 1 authoring consumer and codec tests                |
| G2   | Construction validates identity, positive bounds, unique nodes and destination references before any work runs. A runtime destination must be allowed by its source node.             | Wave 1 construction/routing tests                        |
| G3   | Every visit gets a fresh activation identity, including pure cycles; the limit stops the next activation before its body runs.                                                        | Wave 1 loop trace and bound tests; wave 2 recovery tests |
| G4   | Input selection, operation failure, codec failure and transition failure remain distinct; invalid or uncertain results release no successor work.                                     | Wave 1 failure tests; wave 2 fenced effects              |
| G5   | Result, state, route, activation identities and per-run bounds commit together before dispatch. Family capacity is reserved separately before admission; stored decisions are reused. | Wave 2 persistent restart and lost-ack tests             |
| G6   | An effect starts only after validated admission and a committed start fence. Lost results remain uncertain; approval uses fresh context after recovery.                               | Wave 2 effect/policy tests                               |
| G7   | Child identity and shared family capacity are reserved before start; recovery adopts saved children and grants. Signals are correlated, consumed once and retained durably.           | Wave 3 child/signal tests                                |
| G8   | External submission, accepted receipt and business completion are distinct; attachment/cancellation ownership is explicit.                                                            | Wave 3 real local job integration                        |
| G9   | A structured fork retains private branch results, joins only its own members in defined order, and preserves failure/uncertainty.                                                     | Wave 4 pair/map/join tests                               |
| G10  | Changing a typed decision producer does not change routes or recovery. Provider adapters preserve their real protocol and effect semantics.                                           | Wave 5 adapter tests and live/local protocol exercises   |
| G11  | An agent recipe is evaluated against current transcript, policy, approval, recovery, cancellation and version guarantees.                                                             | Wave 6 parity report and scenarios                       |

Canonical design anchors: GRAPH-FLOW sections “Four concepts at the authoring
boundary”, “One control decision per activation”, “Parallel composition
without shared writes”, “Waits and children are execution states”, “Recovery
is part of graph control” and “Evidence needed before calling it ready”.

## Technology and boundary register

| Boundary             | Development implementation                                                 | Target alternatives and first proof                             | Decision                                             |
| -------------------- | -------------------------------------------------------------------------- | --------------------------------------------------------------- | ---------------------------------------------------- |
| Language/runtime     | Existing Gleam 1.18+ and Erlang/OTP 28 Nix environment                     | Same runtime; wave 1 compilation                                | Retain                                               |
| Typed value encoding | Existing json_blueprint codecs, no schema requirement for internal values  | Custom codecs through the same checked API; wave 1 roundtrip    | Retain                                               |
| Decisions            | Scripted pure functions in wave 1                                          | llm_wire structured output and classifier protocol in wave 5    | Scripted only for first proof, then real adapters    |
| Persistence          | Existing encoded backend/CAS and ownership contracts, extracted for wave 2 | Directory process-restart tests; PostgreSQL ownership/CAS tests | Reuse; directory never claims power-loss durability  |
| Effect execution     | Existing committed start fence and policy semantics in wave 2              | Same invariants across tools, jobs, MCP and children            | Reuse, no second independent safety model            |
| Child/wait           | Existing parent-reserved identity protocol generalized in wave 3           | Agent, graph, external job with retained receipt                | Managed lifecycle, no opaque blocking wrapper        |
| Parallelism          | Explicit retained fork scopes in wave 4                                    | Typed pair and homogeneous map                                  | Isolated state; general concurrent channels deferred |
| External services    | Protocol clients/adapters in wave 5                                        | Classifier endpoint, llm_wire provider, MCP server              | Optional adapters, no Saga/Grind dependency          |

No new infrastructure dependency is needed for wave 1. Future new dependency
choices must be researched against current primary documentation before
adoption; existing package contracts are inspected locally. Network access,
credentials and real-service availability are evidence to establish in wave 5,
not reasons to substitute fake adapters for the final objective.

## Complete wave map

### 1. Typed authoring proof

- Purpose/outcome: compile and run a separately authored bounded
  generation/review loop; compare boolean, score and enum decisions.
- Contracts: G1–G4; native typed state/input/output, one route per visit,
  serialized input/output receipts, explicit failure classification.
- Core/shell: pure selection and acceptance around scripted callbacks; a
  synchronous local driver only. No external effects or durable claims.
- Libraries: existing Gleam stdlib, json_blueprint and gleeunit; no new library.
- Tests: typed external consumer; deliberate type mismatch refused by compiler;
  exact loop bound, repeated-node identities, invalid graph/route, failed
  selection/transition/codec, definite and uncertain handler failure.
- Gate: experiment and separate consumer `gleam build --warnings-as-errors`,
  `gleam test`, compiler-negative checks; root `gleam build --warnings-as-errors`,
  `gleam test`, `nix fmt`, `nix flake check`.
- Risk/revisit: erasing node-specific types must retain serializable receipts
  without widening business data to Dynamic. Findings settle the next API.
- Exit/removal: a reproducible proof and findings; the synchronous driver is
  never promoted as the durable runner. Keep the proof as historical evidence.

### 2. Durable sequential routing and effects

- Purpose/outcome: restart a routed cyclic graph without recomputing recorded
  decisions; protect effects through policy and committed starts.
- Contracts: G1–G6, explicit graph record/definition versions and bounded retries.
- Core/shell: pure graph controller → shared CAS/lease runner → fenced task.
- Libraries: existing Fabric backend, Blueprint, OTP, Sinal; PostgreSQL integration
  where ownership is exercised. No Saga or Grind.
- Real boundaries: persistent backend and actual local effects; no fake commit.
- Tests: corrupt/incompatible records, decision restart, stale/duplicate results,
  lost write acknowledgement, queued versus started recovery, changed approval
  context, cancellation/drain, lease loss, budget restoration.
- Gate: root build/tests/format plus graph consumer and PostgreSQL backend gate
  when the extraction changes that contract.
- Risks/revisit: current store and family types contain chat state. Extract only
  mechanisms used by both controllers, preserve existing record behavior.
- Exit: all listed behaviors pass through a public graph runtime on a real
  persistent backend; authoring experiment is no longer the runtime substitute.

### 3. Managed children, durable signals and external jobs

- Purpose/outcome: compose a graph/agent child, survive a wait and reconnect to
  an external job after process loss.
- Contracts: G7–G8; child references, signal identity/schema, consumed receipts,
  explicit attached/detached ownership and cancellation outcomes.
- Core/shell: child intent/reserved ID → child record; wait data → signal or
  durable wakeup; external adapter → actual independently retained local job.
- Libraries: existing OTP/store support; consumer-owned external job adapter.
  Saga/Grind remain optional and absent from core.
- Tests: lost child start/result acknowledgement, nested approval, child
  uncertainty, duplicate/stale/canceled signals, receipt without completion,
  remote acceptance before receipt loss, due wait across restart.
- Gate: full root/consumer gate and persistent multi-process integration tests.
- Risks/revisit: never represent a process handle as a durable receipt; family
  budgets and lifetime ownership must be enforced across runtime kinds.
- Exit: a durable graph composes real children and an independently running
  local job; scripted job completion is not sufficient.

### 4. Typed fork/map/join

- Purpose/outcome: run heterogeneous paired work and homogeneous mapped work,
  preserving typed results and explicit failure handling.
- Contracts: G9; private branch state, identified members, retained results,
  stable result order, settled failure/cancellation and uncertainty.
- Core/shell: persisted fork scope → bounded tasks/children → one parent join.
- Libraries: shared runtime from waves 2–3, no new concurrency package.
- Tests: equal payloads remain distinct, reverse completion order, sibling
  forks sharing definitions, stale prior-loop results, partial restart,
  failure while another branch acts, cancel, join failure, zero/oversized map.
- Gate: root/consumer gate plus persistent concurrency scenarios.
- Risks/revisit: the blocked parent cannot stream partial results; broader
  concurrent routing remains outside this selected first model.
- Exit: pair and map execute through managed fork scopes, never hidden blocking
  handlers; every member's result or uncertainty remains observable.

### 5. Real adapters

- Purpose/outcome: substitute actual LLM/classifier decision production and run
  MCP operations without changing graph control or persistence.
- Contracts: G10, provider-specific schema/errors/usage, validation and effect
  uncertainty. Retain Jev probability/rubric semantics where used.
- Core/shell: request encoding → real transport → validated typed receipt.
- Libraries: llm_wire and Blueprint retained; classifier/MCP clients optional.
  Inspect maintained clients first; material new adoption is resolved here.
- Tests: valid/invalid output, refusal, transport timeout, retry classification,
  schema drift, scoped remote identity, restart with provider receipt; exercise
  actual provider endpoints when credentials are available and a real local
  MCP server. Mark unavailable live acceptance explicitly, never silently waive.
- Gate: adapter build/tests, graph scenarios, recorded real protocol exercise,
  full root/consumer formatting and regression gate.
- Risks/revisit: live credentials/service availability and provider costs;
  use existing authorized setup and small bounded requests.
- Exit: working adapters plus evidence of real boundary execution. Stubs alone
  cannot close this wave.

### 6. Agent recipe evaluation

- Purpose/outcome: determine whether expressing the ordinary agent as a graph
  preserves behavior and simplifies the implementation.
- Contracts: G11 and the current agent design/retained oracle fixtures.
- Core/shell: graph recipe for model turns/tool batches over the same managed
  lifecycle, compared with current agent behavior.
- Libraries: already adopted provider/runtime contracts, no new dependency.
- Tests: provider data preservation, typed tools, fresh approval context,
  uncertain effects, child lifecycle, cancellation/drain, restart, mixed record
  versions and existing oracle fixtures.
- Gate: full root/consumer/integration gates plus parity comparison.
- Risks/revisit: migrate only after evidence; if convergence increases
  complexity, record that result and retain separate controllers over shared
  mechanisms. Breaking APIs are allowed; stored work needs explicit migration.
- Exit: implemented evaluation path, parity evidence and a justified decision
  on convergence, with remaining mismatches addressed or explicitly unresolved.

## Wave history

### Wave 1 — typed authoring proof

- Status: accepted as step 1 evidence; the six-step goal remains active.
- Closed: 2026-09-29.
- Hypothesis: heterogeneous native operations can share a typed state graph,
  retain checked receipt codecs and route through bounded cycles without
  Dynamic casts, Saga, Grind or provider-shaped chat replies.
- Design anchors: GRAPH-FLOW authoring/control sections; G1–G4 above.
- Delivered behavior: a separate consumer generates/reviews three drafts in
  six activations; five stops before the final review. Boolean, bounded score
  and enum producers use the same routing surface and return typed answers.
- Core and shell: checked graph definition, native projections and acceptance
  functions, local serialized receipts; synchronous scripted driver only.
- Boundaries: real Gleam compilation and Blueprint encoding/decoding; providers,
  effects, policy, persistence, children and parallelism remain unimplemented.
- Technology decisions: retain Blueprint without requiring JSON Schema for
  internal values; add Python 3 to the Nix dev shell for reproducible consumer
  and compiler-negative checks. No new runtime package dependency.
- Validation:
  - `nix develop -c python3 experiments/graph_authoring/check.py`: 12 library
    and 6 consumer tests pass; library and consumer build with warnings as
    errors; example reaches draft 3; valid fresh consumer builds and both
    native type mismatches fail as intended.
  - `nix develop -c sh -c 'gleam build --warnings-as-errors && gleam test'`:
    root builds and 333 tests pass. Expected crash/recovery supervisor reports
    occur within the passing runtime suite.
  - `nix fmt` and `nix flake check`: passed on aarch64-darwin. Other platform
    checks were not executed. Explicit experiment format checks also cover
    new untracked files that Git-based flake sources may omit.
  - `git diff --check`, local evidence links and both manifests checked.
- Findings: phase variants and typed binding work; destination membership is
  checked at construction and acceptance, not statically graph-indexed;
  codec failures must remain distinguishable from operation failures.
- Rejected alternatives: unchecked universal JSON business state and treating
  classifications as chat answers were unnecessary. A synchronous callback
  loop is insufficient as the production runner.
- Design changes: exact experimental signatures now exist; public production
  naming and serialized lifecycle are still to be settled in wave 2. No scope
  change from the authorized six-step program.
- Distance: step 1 is proved. Steps 2–6 remain required and open. Source
  inspection identifies store registration and executor type coupling, but
  provides no evidence of implemented graph durability.
- Revised remaining waves: 2 → 3 → 4 → 5 → 6, unchanged.
- Next action: specify serial activation records, extract the concrete fenced
  executor contract and run the current agent suite before adding graph work.
- Commit or handoff: uncommitted work in the current checkout; no commit asked
  for during this program.

### Wave 2 — sequential graph foundations (historical checkpoint)

- Status at this checkpoint: active; subsequently accepted below.
- Implemented:
  - `fabric/graph/operation`: native input/output/error classification,
    stable run/activation identity, current attempt and declared bounded replay.
  - `fabric/graph/definition`: heterogeneous typed binding, validated topology,
    state/answer codecs and read-only compatibility checks. Validation never
    reruns selection, operation bodies or routing callbacks.
  - Pure serial controller: admission, start fence, fresh visits through
    cycles, atomic completion decisions, approval references, reconciliation,
    recovery and cancellation dispositions.
  - Separate `fabric.graph` version 1 records: strict phase/history linkage,
    encoded native values and fresh write tokens. Existing chat formats are
    unchanged.
  - Shared executor generalized over identity/result; agent crash behavior
    remains uncertain through the existing runner adapter.
- Evidence: 371 root tests pass (333 previous + 38 new), build passes with
  warnings as errors. New tests exercise native integer generation with a
  boolean decision, route/codec incompatibility, bounded attempts, interrupted
  work, approval changes, duplicate/stale completion and cancellation. The
  executor tests use actual task ownership and start-fence barriers. A review
  regression proves cancelled receipts cannot rewrite earlier application
  state; it failed before the decoder invariant was added and passes now. Directory
  tests kill/reopen a store process and reject a stale write; injected lost
  acknowledgements use the real store confirmation path.
- Limits: record persistence tests do not execute a complete public graph
  runner. Graph store registration, runtime policy/context handling, bounded
  callbacks, leases, cancellation/drain and public control handles are still
  required. No live classifier, LLM or MCP acceptance is claimed.
- Compatibility decision: manifest equality covers declared nodes, operations,
  destinations and recovery contracts; graph identity/version and activation
  bound also match. Native codecs validate every saved input/output/state and
  answer. Application versions remain responsible for semantic code changes;
  the manifest is not a hash of callback implementations.
- Remaining waves: finish 2, then 3 → 4 → 5 → 6, unchanged.
- Work remains uncommitted.

Checkpoint gate:

- `nix develop -c sh -c 'gleam build --warnings-as-errors && gleam test'`:
  build passes, 371 tests pass. Expected supervisor crash reports are part of
  the passing fault/recovery tests.
- `nix develop -c sh -c 'cd consumers/app && gleam build --warnings-as-errors && gleam test'`:
  build passes, 15 tests pass, including the existing optional Saga consumer.
- `nix fmt`, `nix develop -c gleam format --check src test`,
  `nix flake check` and `git diff --check`: pass. Explicit format checking
  covers new untracked source/test files. Other platform checks were not run.
- PostgreSQL was not rerun at this component checkpoint: no store/backend
  contract changed. Graph ownership and lease acceptance remains required
  when its runner is connected.

Checkpoint review: the implemented component contracts conform to G1–G4 and
the retained serial state/encoding portion of G5–G6. Native operations retain
their types; the executor remains one shared mechanism; graph records and
deployed callbacks stay separate. Tests cover success, corrupt data, refused
transitions, store process loss and lost acknowledgements and actual executor ownership.
G5–G6 still lack full graph-runner acceptance, so wave 2 is not accepted.
The scope, standing repository rules and Saga/Grind boundary are unchanged.

### Wave 2 — public durable serial runtime

- Status: accepted on 2026-09-29; steps 3–6 remain open.
- Public surface: `fabric/graph` start, attach, read, await, recover, approve,
  reject, reconcile and cancel. Typed snapshots include current action data,
  approval/reconciliation references, raw invalid-result evidence and receipts.
- Shared mechanisms: the agent and graph use the same supervised startup,
  pinned store lifetime, CAS/lease backend, bounded callback isolation and
  fenced task executor. Graphs have a typed store endpoint; idle graphs hold
  no runner process. No Saga or Grind dependency was added.
- Behavior: conditional routes and bounded cycles persist accepted decisions;
  owner/attempt identities fence stale work. Policy has current context,
  approvals are rechecked, and its admitted body receives that context.
  Interrupted effects block or use their declared bounded replay contract.
  Cancellation, reconciliation, operation deadlines and shutdown handoff are
  explicit retained states.
- Boundary evidence: 22 public runtime scenarios cover the full serial
  lifecycle, including a changed decision producer after restart, failed and
  late start commits, failed completion commits, lost acknowledgements,
  concurrent starts, approval version changes, cancellation during held policy,
  incompatible-definition refusal, bounded replay, drain, live foreign leases
  and lease-loss body termination. Actual local tasks and effect ledgers are
  used, with a directory backend for process-restart scenarios.
- External consumers: `consumers/graph` compiles the public typed surface and
  runs the generation/review loop with no Saga or Grind dependency. The
  PostgreSQL package also consumes public graph APIs and proves approval,
  restart, completion and lease release on a throwaway real database.
- Review: source checks and public tests uphold G1–G6 for the serial runtime.
  Graph control remains separate from the ordinary agent controller while
  sharing effect-safety mechanisms. Steps 3–6 remain required. There is no
  claim of automatic graph sweep registration, arbitrary graph-family pruning,
  managed composition or real provider acceptance in this wave.
- Remaining: finish 3 (managed children/signals/jobs), 4 (typed parallel
  composition), 5 (real adapters), then 6 (agent-recipe parity evaluation).
- Work remains uncommitted; no commit was requested for this program.

Acceptance gate:

- Root `gleam build --warnings-as-errors`, `gleam format --check src test`
  and `gleam test`: pass, 393 tests.
- `consumers/graph`: warning-free build, explicit source formatting, two
  passing tests; its runnable example reaches `Completed(3)` through six
  native typed activations.
- `consumers/app`: warning-free build and 15 passing tests.
- `integrations/fabric_postgres`: explicit source formatting and the package's
  `scripts/test-postgres.sh` gate pass, 29 tests against a throwaway PostgreSQL
  cluster. The graph restart case consumes only public Fabric APIs.
- `nix fmt`, `nix flake check` and `git diff --check`: pass. Explicit Gleam
  checks cover untracked files omitted by the Git-based Nix source. The Nix
  check covers this host; other operating systems were not run.

Acceptance review: G1–G6 have implemented owners and direct public-runtime
evidence, including the final saved conditional-branch test. Native values
remain typed, stored data contains no callbacks, and effects use the shared
fence/ownership mechanisms. Fault tests prove refused, ambiguous and stale
outcomes release no successor. No Saga/Grind dependency, provider acceptance,
automatic graph sweeping or managed composition claim is included. The full
six-step goal remains active, with wave 3 next.

### Wave 3 — typed durable signal checkpoint

- Status: manual signal behavior implemented; wave 3 remains active. Managed
  children, external jobs and durable deadlines are still required.
- Surface: versioned `signal.Signal(value)`, `operation.await_signal`, public
  `AwaitingSignal` references, native `graph.deliver` and checked transport
  `graph.deliver_json`. The existing typed node selection/acceptance contract
  composes activities and waits without unchecked casts or suspended tasks.
- State: admission commits a wait and releases the runner/lease. Delivery
  commits consumption, result, state, route and successor together. The saved
  activation/reference identifies one visit. Duplicate bytes are acknowledged
  without invoking routing; conflicting or canceled signals are refused.
  Codec or transition rejection leaves the wait unconsumed.
- Compatibility: graph format version 2 adds execution modes and the wait
  phase, and refuses earlier version 1 records. Modes participate in the
  definition manifest; an activity cannot replace a retained wait. Chat record
  versions and the store backend contract are unchanged.
- Evidence: 11 public signal tests plus two operation/record invariants.
  Scenarios cover directory-store loss with no waiting runner, repeated visits,
  approval admission, wrong types/contracts/references, transition refusal,
  cancellation, duplicate/conflicting concurrent deliveries, failed/lost/late
  commits and a cancellation that wins while another store's delivery commit
  is held. Effect ledgers prove an unconfirmed consumption releases no body.
- Consumer: the same generation/review topology runs with either a scripted
  boolean producer or native human-signal values. No Saga/Grind dependency.
- PostgreSQL: a waiting signal releases its lease; after process loss another
  store consumes its native result once and acknowledges duplicate delivery
  from the same receipt.
- Gate: root build/tests pass (406), graph consumer build/tests pass (3),
  existing app consumer build/tests pass (15), PostgreSQL package gate passes
  (30). All builds use warnings as errors. `nix fmt`, explicit source formatting
  for the root/graph consumer/PostgreSQL package, `nix flake check` and
  `git diff --check` pass on this host. Other platforms were not tested.
- Review: this implements the signal portion of G7, not managed children or
  G8. Due-time wakeups, scheduling and external business completion are not
  represented by the manual API. The full six-wave objective is unchanged.
- Next: shared agent/graph parent references, reserved child identities,
  ancestral admission/cancellation and child-result observation. Existing
  `internal/family`, `internal/runner` and `internal/sweeper` are agent-specific;
  inspect and extract their actual shared mechanisms before extending them.
- Work remains uncommitted.

### Wave 3 — first managed-subgraph checkpoint

- Status: partial delivery of G7; wave 3 remains open. The user requested this
  checkpoint be committed and implementation continue on 2026-09-29.
- Surface: `graph.as_subgraph` retains native child state/answer types;
  `graph.child` opens the reserved child through a compatible runtime. Parent
  and child use the same store. Parent policy admits the durable attachment;
  child policy and ancestry gate each child effect.
- State: the parent reserves the child identity before dispatch. A reciprocal
  parent link and original input prevent adoption of unrelated work. Lost
  start or completion acknowledgement reconnects to that same child. Canceling
  before creation installs a child tombstone; canceling after an uncertain
  effect preserves uncertainty and never releases a successor.
- Compatibility: graph record version 3 adds original input, parent links,
  subgraph operation kind and child lifecycle states. Earlier unreleased graph
  formats are rejected. Chat records keep their existing version contract.
- Evidence: ten public child scenarios cover native answers, approval across
  directory-store restart, lost start/completion acknowledgements, cancellation
  before and after child start, child reconciliation, and cross-store refusal.
  PostgreSQL verifies parent lease expiry, takeover, the same retained child,
  approval and completion with both leases released.
- Gate: 416 root tests, 31 PostgreSQL tests, three graph consumer tests and 15
  existing app consumer tests pass. Builds use warnings as errors. The authoring
  proof also passes 12 tests, six consumer tests and two negative type checks.
  `nix fmt`, explicit Gleam formatting, `nix flake check` and `git diff --check`
  pass on this host; other platforms were not tested.
- Limits: parents still poll during child approvals/signals. Nested waits,
  idle-parent wakeups, canceled-child settlement, managed agents, family-wide
  budgeting/retention, jobs and deadlines remain. Automatic graph sweeping is
  not established. This checkpoint does not accept wave 3 or later waves.
- Next: settle canceled uncertain children without reopening parent work, then
  make idle child waits durable without retaining a parent runner, with explicit
  recovery for lost wakeups, and finish nested propagation before extending
  composition to ordinary agents.

### Wave 3 — canceled-child settlement and nested execution

- Status: the cancellation-settlement portion of G7 is implemented; wave 3
  remains open. `CancellingChild` exposes pending parent cancellation, and
  `ChildUnresolved` points to the child that owns uncertain effects. Ordinary
  parent reconciliation refuses to manufacture a child result.
- Behavior: reconcile a canceled leaf, then recover its canceled parent.
  Recovery reads the retained child outcome and commits `ChildSettled` only
  when uncertainty is resolved. It invokes no operation, policy or route and
  preserves parent state/receipts. Repeated recovery acknowledges the same
  record. Nested cancellation settles outward after store-process restart.
- Finding: the first nested test timed out while starting only two levels.
  Node callbacks captured full child runtimes repeatedly, definitions kept
  duplicate node collections, and child start/cancel closures each captured
  the runtime. Deployed callbacks now separate parent codecs/routes from child
  drivers, retain one node collection and one child reservation callback. An
  eight-level public scenario completes under the default callback bound.
- Evidence: six additional public tests cover settlement, directory restart of
  nested cancellation, failed/lost acknowledgements, competing CAS writes,
  cross-store refusal and eight-level composition. PostgreSQL adds a public
  canceled-child reconciliation/recovery case with both leases released and
  one observed external effect. The faster callbacks exposed an existing
  observation race; `await` now waits through committed child cancellation
  rather than returning the child's prior approval or uncertainty.
- Gate: 422 root tests, 32 PostgreSQL tests, three graph consumer tests and 15
  existing app consumer tests pass, with warning-free builds. `nix fmt`, explicit
  Gleam formatting, `nix flake check` and `git diff --check` pass on this host.
  The record stays at graph
  version 3; no new persistent variant or backend interface is required.
- Conformance: G1–G6 remain green. This extends G7 without claiming idle child
  wakeups, nested approval/signal propagation, managed agents, family-wide
  limits/retention or external jobs. G8–G11 and the full goal remain open.
- Next: durable idle child waits with recoverable wakeups, followed by nested
  wait propagation and the remaining managed-composition contracts.

### Wave 3 — idle child waits and nested notifications

- Status: idle and nested subgraph approval/signal waits now implement their
  G7 contract. The parent commits `WaitingChild`, releases its runner and lease,
  and retains the same child reference. A descendant's terminal answer must
  still pass through each intermediate graph's own acceptance callback.
- Wakeups: a confirmed parked write installs a store-owned local dependency
  registration. It starts no process per idle run. Changes trigger bounded,
  coalesced recovery checks; unchanged waits are not rewritten. An immediate
  check closes the observation/registration race, and a later parent write
  invalidates the previous registration. Store draining admits no new wakeup
  workers. The callback never treats a notification as a saved child outcome.
- Recovery: local hints can be lost with a store or skipped by a write through
  another store. Explicit parent recovery restores nested child attachments
  and the local registration, then checks saved outcomes. Observation APIs do
  not recover implicitly. A stored wait never recreates a missing child record.
- Compatibility: graph format version 4 adds `WaitingChild`; earlier unreleased
  graph formats are explicitly refused. Agent writer versions and the external
  backend interface are unchanged. The store's internal ownership contract now
  includes parked dependency observation.
- Evidence: five additional public child tests cover idle runner release,
  nested approval followed by a signal (all runners idle, all routes applied),
  store loss before completion notification, child completion before wakeup
  registration, and cancellation winning over a delayed wakeup commit. Record
  tests roundtrip the wait and reject foreign reservations and operation kinds.
  PostgreSQL now checks that parent and child leases are free before restart,
  then recovers the same attachment and completes it through public APIs.
- Gate: warning-free builds; 428 root tests, 32 PostgreSQL tests, three graph
  consumer tests and 15 existing app consumer tests pass. `nix fmt`, explicit
  Gleam formatting, `nix flake check` and `git diff --check` pass on this host.
  Other platforms were not tested.
- Conformance: this advances G7 and preserves G1–G6. It does not establish
  distributed notifications, automatic graph scanning, managed agents,
  family-wide budgets/retention, external jobs or durable deadlines. Wave 3 and
  the full six-step goal remain active; waves 4–6 are unchanged.
- Next: inspect the existing agent parent/action references and PostgreSQL
  family metadata, settle the shared graph/agent attachment representation,
  and exercise a real managed ordinary agent from a graph. Preserve the
  existing agent suite and avoid treating graph activations as chat action IDs.

### Wave 3 — shared parent identities and ancestry

- Status: both controllers retain `run.Parent`, distinguishing agent actions
  from graph activations. The agent snapshot exposes that sum; uncertainty
  references remain `ActionRef`. No graph activation is given a fake tool-call
  identity. The existing subgraph wire shape and version are unchanged.
- Admission: a shared bounded ancestry reader checks each parent's record
  identity and its exact active child reservation. Agent model calls and retries
  now perform this check, alongside existing tool fences, child starts and
  approval commands. Graph admission and execution use the same checked chain.
  Missing, unreadable, unrelated and stopped ancestors release no new work.
- Compatibility: agent format version 5 tags parent variants. Readers accept
  versions 1–5; writers 2–4 retain ordinary agent links in their historical
  shape. They refuse graph parents before a child insert or model invocation.
  Provider data still requires at least version 4. The existing agent sweeper
  stops at graph-owned families; it cannot reinterpret them as agent roots.
- Evidence: six new root tests cover parent roundtrips and legacy-write refusal,
  mixed graph/agent ancestry, wrong reservations, bounded ancestry, cancellation
  before the first model call and before a retry, and refused child approval.
  Rolling-upgrade cases exercise reads/writes between version 5 and 2, 3 and 4.
  Existing saved-delegation cancellation and tombstone scenarios remain green.
- Gate: 434 root tests, 32 PostgreSQL tests, three graph consumer tests and 15
  existing app consumer tests pass, with warning-free builds. Source formatting,
  `nix fmt`, `nix flake check` and `git diff --check` pass on this host.
- Conformance: this establishes the shared ownership prerequisite of G7. It
  does not establish the public managed-agent adapter, family-wide budgets or
  pruning, graph sweeper registration, external jobs or deadlines. Graph records
  still reject agent-action parents until graph-as-agent-tool is implemented.
  Wave 3 and the full six-step goal remain active.
- Next: bind the ordinary agent runner as a managed graph operation with an
  explicit typed answer adapter. Preserve all child approvals and uncertainty,
  reserved identity, same-store checks, restart, cancellation and idle wakeups.
  Check agent descendant ID/depth bounds under hashed graph-child identities;
  do not inherit assumptions about the shorter ordinary root ID. PostgreSQL
  still derives family roots from agent IDs and needs separate retention work.

### Wave 3 — public managed agent operations

- Status: `fabric/graph/agent` provides a typed definition, deployed runtime,
  managed operation and checked child handle. Ordinary agents run under a
  parent-reserved identity through the existing agent runner. Prompt and reply
  conversion are pure callbacks; the typed result follows normal graph
  acceptance. The parent never blocks an activity task on agent completion.
- Lifecycle: all approvals and uncertainties of an idle agent family retain
  their own references in `AgentInput`. Parent graphs park and wake on committed
  child progress, including graph → agent → delegated-agent nesting. Recovery
  adopts the saved agent and its prompt; lost start/completion acknowledgements
  never call the model twice. Conversion failure keeps the original agent reply
  and releases no route. Cross-store dispatch and child handles are refused.
- Cancellation: existing agents use their stored cancellation path. Missing
  agents are buried without prompt, context or answer callbacks. Settlement
  observes a completed child's outcome without business reply conversion or
  parent routing. Started tool uncertainty stays visible as `ChildUnresolved`.
- Bounds/compatibility: declared agent descendants must fit valid IDs below
  the 70-character graph reservation; construction considers each agent's
  actual depth and child-count bounds. Graph format version 5 adds `agent`
  operations and rejects earlier unreleased graph formats. Agent format/writer
  version 5 is unchanged from the shared-parent checkpoint.
- Evidence: thirteen public root tests cover typed replies, all approvals,
  idle wakeup, directory restart, canceled approvals, canceled running tools,
  active uncertainty reconciliation, invalid replies, nested families, lost
  acknowledgements, cancellation racing an insert, settlement with broken
  callbacks and valid/oversized descendant IDs. The external consumer replaces
  its boolean reviewer with managed agents and retains the same loop/receipts.
  A PostgreSQL scenario releases both leases, loses the store process, restores
  the same child/approval and performs its tool once before graph completion.
- Gate: 447 root tests, 33 PostgreSQL tests, four graph consumer tests and 15
  existing app consumer tests pass. Builds use warnings as errors; source
  formatting, `nix fmt`, `nix flake check` and `git diff --check` pass on this host.
- Remaining gap: the ordinary agent API rejects reconciliation after a terminal
  outcome. A canceled agent's uncertain tools therefore remain unresolved;
  terminal settlement and propagation through canceled delegated families are
  next. This checkpoint does not claim complete cancellation reconciliation,
  shared family budgets/retention, graph recovery scanning, jobs or deadlines.
  Wave 3 and all later waves remain active parts of the full six-step goal.

### Wave 3 — terminal agent evidence and delegated settlement

- Status: `fabric.reconcile_stored` retains evidence for an uncertain direct
  tool of a finished agent; `fabric.settle_stored` verifies and propagates
  saved child outcomes through finished delegated families. Both return the
  updated snapshot with unresolved actions. Neither needs a deployed agent
  definition, changes the outcome, nor calls execution callbacks.
- Evidence ownership: a parent cannot replace an uncertain child outcome with
  caller-supplied text. The settlement walk validates the exact reciprocal
  parent action before visiting the child. A missing or unreadable child is
  an error; active and uncertain children remain unresolved. A saved
  never-started tombstone establishes `NotStarted`.
- Recovery: writes commit independently from leaves outward. Duplicate tool
  evidence and unchanged family walks write nothing; different evidence is
  refused. Compare-and-set prevents competing writes from replacing a saved
  result. Exact write-token readback confirms lost acknowledgements. Repeating
  a walk finishes propagation after a parent write failed. Then graph recovery
  observes the settled agent while retaining canceled graph state and receipts.
- Compatibility: agent record version 6 adds `run.ChildSettled(outcome)` as
  terminal evidence, separate from a model-visible tool result. Decoding
  requires a finished parent and retained child reference. Readers accept
  1–6; writers 2–5 refuse this new state. Direct reconciliation uses the
  existing `Reconciled` representation. Graph format stays at version 5.
- Evidence: nine new root scenarios cover terminal record validation,
  duplicate/conflicting tool evidence, recursive families, interrupted
  propagation, missing/mismatched/active children, competing writes, old-writer
  refusal, saved tombstones and directory restart of a graph with two delegated
  levels. The existing running-agent cancellation test now proves later
  settlement. PostgreSQL adds cancellation, store restart and settlement with
  unchanged transcript/usage and no second effect; both leases are released.
- Gate: 456 root tests, 34 PostgreSQL tests, four graph consumer tests and 15
  existing app consumer tests pass, with warning-free builds. Source formatting,
  `nix fmt`, `nix flake check` and `git diff --check` pass on this host.
- Conformance: this extends G7's cancellation recovery and preserves G1–G6.
  Wave 3 remains open for family budgets/retention, recovery scanning, external
  jobs and deadlines. Waves 4–6 and the full six-step objective remain active.
- Next: make shared family limits and retention explicit across graph/agent
  boundaries, including PostgreSQL metadata for hashed graph reservations;
  then add external-job attachments and durable deadlines.

### Wave 3 — retention across graph and agent families

- Status: `fabric/retention` projects immediate attachments and settlement from
  supported records through their real decoders. PostgreSQL uses those saved
  relationships for arbitrary root IDs, hashed graph children and agent
  descendants. The former `run-…` prefix no longer defines a family.
- Retention: all members must be terminal and settled, old enough, readable,
  current in the index and free of live leases. Every named child must exist
  and repeat the parent's attachment; unexpected children also block deletion.
  Unresolved canceled effects retain the entire family. Historical receipts
  and delegation actions keep their child references until the family is pruned.
- Concurrency: pruning uses a serializable transaction with bounded retries,
  locks distinct roots for concurrent pruners, and revalidates member changes
  and renewed leases. A parent foreign key prevents late child inserts from
  creating an orphan after deletion. Pruning ends the family's replay window;
  run IDs must not be reused for new executions that may receive old messages.
- Upgrade: schema migration 2 adds the projection/source revision and indexed
  parent link. Original record bytes and agent/graph formats stay unchanged.
  Existing rows remain retained until bounded `refresh_retention` batches
  examine them. Refresh changes no execution revision, lease or record age.
  Old backend writes invalidate the source revision. Unknown records and
  missing-parent orphans remain retained, including after refresh.
- Evidence: three core projection tests cover all unsettled agent action
  variants, graph receipts/cancellation, reciprocal keys, unknown versions and
  storage-key mismatch. Six additional PostgreSQL scenarios cover incomplete
  or mismatched families, independent IDs sharing a prefix, old-root starvation,
  tombstones and late child insertion, uncertainty and child age, migration and
  old writes, concurrent lease renewal and escaped-NUL attachment keys. Existing
  concurrent-pruner tests now use validated records. Public graph cancellation
  tests verify retention before settlement and whole-family deletion afterward.
- Gate: 459 root tests, 40 PostgreSQL tests, four graph consumer tests and 15
  existing app consumer tests pass with warning-free builds. Source formatting,
  `nix fmt`, `nix flake check` and `git diff --check` pass on this host.
- Conformance: this establishes the PostgreSQL retention part of G7. It does
  not establish shared execution budgets, automatic graph recovery scanning,
  external jobs, deadlines or a directory-store pruning service. The full
  six-step objective stays active; waves 4–6 are unchanged.
- Next: define and reserve shared family budgets before graph/agent work is
  admitted, retaining the reservations across restarts and cancellation;
  continue with external jobs and durable deadlines.

### Wave 3 — durable family reservation storage

- Status: the internal family ledger implements the reservation contract in
  [managed composition](managed-composition.md#shared-family-reservations).
  It stores immutable work/child/depth limits and stable claims in a separate
  CAS record, preserving live workflow revisions. No runner or public budget
  API uses it yet; this checkpoint does not enforce family budgets.
- Behavior: exact duplicate claims reuse capacity; distinct graph attempts,
  model attempts and tool actions spend new work units. Child identities retain
  their depth. Exhausted limits, changed limits, conflicting identities,
  unreadable records and unconfirmed writes grant nothing. Reservations are
  monotonic, including failed or ambiguous attempts. Usage is reconstructed
  from validated stored claims rather than trusted serialized counters.
- Evidence: 12 focused tests cover independent work/child limits, depth/zero
  bounds, invalid claims, codecs and future formats, duplicate/conflicting
  stored identities, failed/lost/late write acknowledgements, concurrent
  creators and last-slot competition across stores, and directory restart.
- Gate: 471 root tests, 40 PostgreSQL tests, four graph consumer tests and 15
  app consumer tests pass with warnings as errors. Formatting, `nix flake check`
  and `git diff --check` pass on this host.
- Conformance: this proves the storage prerequisite of G7, not admission
  enforcement. G1–G6 remain green. The six-step goal remains active; wave 3
  still requires budget integration, graph recovery scanning, external jobs
  and durable deadlines. Waves 4–6 remain unchanged.
- Next: persist immutable root budget configuration, attach ledger retention,
  reserve before dispatch in both runtimes, and prove typed denial with
  cancellation/recovery and mixed children before exposing public configuration.

### Wave 3 — root budget records and inherited family identity

- Status: agent format 7 and graph format 6 retain an optional family-budget
  declaration on roots. Children cannot override it. No public configuration
  or admission enforcement is exposed yet; this remains a prerequisite of G7.
- Compatibility: agent readers accept 1–7 and writers 2–7, defaulting to 7.
  Older writers refuse configured limits. Graph version 5 remains readable
  without a budget; versions 1–4 remain refused. Current formats require the
  nullable budget field. A non-null field hidden in an older version is
  corrupt, so reading and rewriting it cannot silently reset capacity.
- Ownership: `ancestry.family` checks existing reciprocal attachments, returning
  the saved root declaration and actual depth through mixed graph/agent runs.
  Closed, unreadable or overlong ancestry never becomes an independent root.
  Existing effect checks use the same traversal and keep their behavior.
- Retention: projection version 2 includes a root-to-ledger link whose key
  contains the immutable limits. The ledger repeats it. Missing ledgers,
  unexpected ledgers and mismatched limits preserve the family; a settled,
  complete family removes both records. PostgreSQL schema stays at 2 and
  existing projections refresh through the already bounded backfill API.
- Evidence: six additional root tests prove codec compatibility, required
  fields, invalid limits, forbidden child overrides, cancellation/recovery
  preservation and reciprocal ledger metadata. The existing mixed-ancestry
  scenario now checks inherited limits and actual depth. A PostgreSQL scenario
  covers missing/mismatched ledgers, whole-family pruning and rejected late
  ledger insertion after deletion.
- Gate: 477 root tests, 41 PostgreSQL tests, four graph consumer tests and 15
  app consumer tests pass with warning-free builds. Formatting, `nix flake check`
  and `git diff --check` pass on this host.
- Conformance: G1–G6 remain green; these are G7 prerequisites. The full six-step
  goal remains active. Wave 3 still requires admission enforcement, automatic
  graph recovery scanning, external jobs and durable deadlines; waves 4–6
  remain unchanged.
- Next: establish a root ledger after the execution insert and before runner
  dispatch, repairing it from committed configuration on recovery. Reserve
  graph attempts, model attempts, tool actions and child starts through the
  verified family identity. Preserve typed quota refusals, started uncertain
  effects and never-started child evidence. Expose root configuration only
  after both runners enforce the shared budget and mixed-family recovery is
  proved through public APIs.

### Wave 3 — shared graph and agent budget enforcement

- Status: public agent and graph `start_with_budget` APIs enforce immutable
  work/child/depth limits across mixed families. Existing starts retain their
  per-run behavior. Saga and Grind remain absent from core.
- Initialization: commit the root declaration, create/adopt its ledger, then
  seal an initialized marker before releasing work. Lost/late acknowledgements
  are confirmed; existing claims are retained. A missing ledger after sealing
  is data loss, never fresh capacity. Recovery also finishes initialization of
  a canceled root without reviving work.
- Admission: graph attempts, agent model attempts and tool actions reserve work;
  managed children also reserve count/depth using verified family ancestry.
  Approval rechecks reuse claims, retries spend new units, and canceled or
  uncertain grants are never refunded implicitly. Missing-child recovery uses
  the same admission boundary. Quota refusals are typed; infrastructure failure
  leaves recoverable work without dispatching.
- Settlement: quota stops preserve started tools as uncertain, withdraw queued
  calls and settle children, recording never-started evidence where necessary.
  Older writers cannot discard either configuration or quota outcomes.
  Retention projection 3 validates initialized declarations and quota states;
  existing projections need refresh, while PostgreSQL schema stays at 2.
- Evidence: public scenarios cover shared graph/agent capacity, nested depth,
  zero-child rejection, cyclic graph bounds, approval restart, model retries,
  lost model reservations, interrupted model charges, partial tool batches,
  initialized-ledger loss, canceled bootstrap repair, and codec compatibility.
  Real PostgreSQL restart proves limits survive approval and that root, child
  and ledger prune as one settled family.
- Gate: 498 root tests, 42 PostgreSQL tests, four graph consumer tests and 15
  app consumer tests pass with warnings as errors. Formatting, `nix flake check`
  and `git diff --check` pass on this host.
- Conformance: G1–G6 remain green; G7 shared budget enforcement is proved. Wave
  3 remains active for graph recovery scanning, external jobs and durable
  deadlines. Waves 4–6 and the full six-step goal remain open and unchanged.
- Next: recover registered graph definitions through a bounded scan after
  process loss, then attach independently retained jobs and recover due waits.

### Wave 3 — registered graph recovery from expired leases

- Status: `graph.recovery(identity, build_runtime)` registers graph roots in
  the same `fabric.sweeper` used by ordinary agents. Kind plus versioned
  definition identity distinguishes registrations. The factory rebuilds the
  complete graph/child runtime against the pinned store, with a five-second
  bound and checked identity/store before any recovery starts.
- Topology: scan candidates follow decoded reciprocal family attachments,
  including graph-owned agents. Unknown, corrupt, misfiled and nonreciprocal
  records dispatch nothing. The existing 100-candidate batch, bounded root
  recovery and nonoverlapping scans remain unchanged.
- Ownership: recovering a graph with a live foreign lease can still recover
  its independently expired child. It neither takes the parent's lease nor
  rewrites that parent's state. Parent recovery later adopts the same child's
  outcome. Terminal retry cues release only after parent acknowledgement.
- Evidence: six public scenarios cover interrupted graph effects, graph-owned
  agents beneath a foreign parent, same-name agent/graph registrations,
  duplicate/wrong-store configuration, competing sweepers, unknown/misfiled
  records and invalid reciprocal attachments. A real PostgreSQL scenario
  restarts a budgeted graph/agent family automatically, exposes the interrupted
  tool as uncertain and completes only after reconciliation.
- Gate: 504 root tests, 43 PostgreSQL tests, four graph consumer tests and 15
  app consumer tests pass with warnings as errors. Formatting, `nix flake check`
  and `git diff --check` pass on this host.
- Conformance: this proves discovery of expired graph work under G7; it does
  not prove distributed discovery of a free idle wait after all local wakeups
  and child retry cues disappear. That case still has explicit recovery and
  remains open in wave 3 alongside external jobs and durable deadlines.
  Waves 4–6 and the active six-step objective remain unchanged.
- Next: provide a durable discovery/index contract for free waits and due
  wakeups, then exercise external-job submission, retained receipts and
  completion with an independently running local service.

### Wave 3 — validated idle dependency projection

- Status: `fabric/discovery` derives a versioned storage index for idle managed
  graph/agent attachments, including blocked children and unresolved child
  cancellation. It executes no application code. This is the index prerequisite;
  automatic free-wait claiming is still unimplemented.
- Identity: a key contains observation/settlement mode, activation, attempt and
  child identity. Recovering an unchanged wait preserves its key; a new graph
  visit changes it. Completed or settled attachments, ordinary activity effects
  and budget records have no idle dependency. Unknown/corrupt/misfiled records
  produce no usable index. Current managed children never retry independently;
  the attempt component retains the recorded invocation identity.
- Contract: store the dependency revision observed by each key separately from
  execution state. Claim an unseen or changed dependency and its run lease
  atomically. Preserve observations across unchanged wait rewrites; a child
  update during recovery remains eligible. Failed recovery keeps an expired-lease
  retry path. Source revision/version checks invalidate stale writer metadata.
- Evidence: four scenarios exercise both child runtime kinds, stable recovery,
  actual graph cycle transitions, settlement mode changes, excluded states,
  unknown/misfiled records and completion clearing dependency discovery.
- Gate: 508 root tests and the four graph/15 app consumer tests pass with
  warnings as errors. Formatting, `nix flake check` and `git diff --check` pass.
  PostgreSQL runtime/storage code is unchanged; its previous 43-test gate
  remains the last backend evidence, not proof of free-wait discovery.
- Conformance: the remaining G7 discovery gap is not closed. The six-stage goal
  remains active, including external jobs/deadlines and all of waves 4–6.
- Next implementation: add source-revision-checked discovery metadata and an
  observed key/dependency revision to the leased backend; PostgreSQL needs a
  forward migration and bounded refresh for existing rows. Claim free changed
  dependencies fairly alongside expired work, preserving execution revisions,
  leases and retention ages. Exercise store loss, cross-store child completion,
  unchanged waits, contention, old writes and missed cancellation settlement
  through registered recovery on the real backend before accepting discovery.

### Wave 3 — automatic idle dependency discovery

- Status: leased backends atomically claim free waits with unseen or changed
  child revisions. The shared sweeper reserves 50 candidates for expired work
  and 50 for idle dependencies, retaining independent per-run ownership and
  the existing registered-root checks. Failed recovery retains a lease retry cue.
- Persistence: PostgreSQL schema version 3 adds a validated discovery projection,
  source revision, observed key/revision and fair inspection order. Normal writes
  maintain metadata. `refresh_discovery` upgrades existing rows in bounded,
  concurrent batches without changing execution bytes, revisions, leases or ages.
  Unknown records are examined once per projection version. Old-writer revision
  changes invalidate metadata until refresh. Agent/graph record formats are unchanged.
- Recovery: discovery inspects unchanged, unclaimed relatives without rewriting
  them. Public nested-signal and nested-uncertainty regressions first reproduced
  repeated revision churn, then proved convergence across two stores and completion
  after external delivery or reconciliation without replaying an uncertain effect.
  Explicit recovery retains its local-wakeup behavior; discovery never recreates
  a child whose retained wait proves it previously existed.
- Evidence: a public PostgreSQL regression first reproduced a missed child outcome
  after store loss, then passed through registered scanning. Cancellation settlement
  now completes automatically without routing or replaying effects. Shared backend
  checks cover unchanged dependencies, changes during a claim, concurrent disjoint
  claims, bounded selection, and an interrupted claim's expired-lease retry path.
  PostgreSQL tests cover migration from schema 2, metadata-only refresh, stale
  old-writer indexes and concurrent refresh batches.
- Gate: 510 root tests, 46 PostgreSQL tests, four graph consumer tests and 15 app
  consumer tests pass with warnings as errors. Source formatting, `nix fmt`,
  `nix flake check` and `git diff --check` pass on this host.
- Conformance: this closes the free managed-wait discovery gap under G7. It does
  not deliver external jobs, durable deadlines, parallel joins or real decision
  adapters. Wave 3 remains open; waves 4–6 and the active six-stage goal are unchanged.
- Next: retain distinct submission intent, accepted job receipt and completion;
  prove lost-acknowledgement recovery against an independently running local job.
  Saga/Grind remain consumer-owned optional integrations outside the core.

### Wave 3 — real external-job submission and receipt recovery

- Status: the retained `consumers/jobs` example executes a typed submit-and-return
  graph against a separate loopback HTTP service. The service persists acceptance
  in SQLite, processes an uppercase artifact independently, and exposes its result
  and SHA-256 digest. This proves the first external composition contract under
  G8/J1–J5; it does not yet implement managed attachment.
- Identity: the consumer's logical key contains graph run ID and activation,
  excluding the retry attempt. The service atomically binds the key to its input
  and receipt. Concurrent duplicates return one receipt; changed input is refused;
  a new activation creates a distinct job. The existing bounded interrupted-replay
  contract is selected only because this service guarantees deduplication.
- Recovery: killing Fabric after remote acceptance and before its result commit
  returns the same receipt on attempt two. An unreplayable submission remains
  uncertain until explicit receipt reconciliation. A committed receipt is reused
  without any new submit. Detached work continues independently after Fabric loss;
  a receipt never claims business completion.
- Independent service: a separate OS process owns its queue and filesystem effects.
  Acceptance, queued work and completed artifacts survive that service's restart.
  Deterministic artifact replacement is the service's own recovery contract,
  not an exactly-once claim for arbitrary external effects. Test storage is
  temporary; no new Fabric dependency or external account is required.
- Gate: `nix develop -c consumers/jobs/test-service.sh` passes five Gleam scenarios
  and two service boundary tests. Core build/tests pass (510); graph and app
  consumer builds/tests pass (four and 15). Gleam builds use warnings as errors.
  `nix fmt`, `nix flake check` and `git diff --check` pass. No Python static-type
  checker is configured; its real protocol/restart tests are the executable gate.
  PostgreSQL source is unchanged; its prior 46-test result remains current evidence.
- Conformance: this checkpoint needs no new core submission abstraction because
  the fenced activity and stable invocation already supply this contract. Its
  explicit separate receipt and status models will be reused for managed waits.
  Automatic job observation, cancellation rights and durable deadlines remain
  wave 3 work; waves 4–6 and the full six-stage objective remain active.
- Next: retain an accepted receipt inside a managed graph wait, release idle
  execution ownership, and recover completion or cancellation by stable receipt
  after process loss. Reuse this real service to test the new runtime path.

### Wave 3 — retained read-only external-job observations

- Status: `job.observe` binds native receipt/output codecs to a bounded read;
  `operation.await_job` retains its admitted receipt in `AwaitingJob`. The wait
  owns no executor or lease. Explicit `graph.poll_job` records a checked business
  outcome and route atomically; it does not submit work. This delivers J6–J10.
- Identity and admission: references identify run, activation, attempt and
  versioned operation. Policy applies before observation. Pending, failed or
  timed-out reads retain the wait and reuse its shared work grant. Invalid
  outputs/routes release no successor. A repeated completed reference uses its
  retained result without another remote read.
- Cancellation: this binding owns observation only. Canceling it records
  `JobDetached`; a concurrent completion cannot revive it or dispatch successor
  work. An independently owned remote job continues to its real artifact.
  Definite remote failure terminates the node without its success route.
- Recovery: directory and PostgreSQL store loss preserve the receipt/reference.
  Managed subgraphs park around the wait. PostgreSQL retains waiting families
  and can prune them after settlement. The real service consumer restarts Fabric
  at an accepted job wait and completes without resubmitting.
- Compatibility: graph record 7 adds job waits and detached cancellation;
  readers retain support for representable versions 5–6. Retention projection 4
  and discovery projection 2 require metadata refresh. PostgreSQL schema remains 3. Explicit polling is the only job scheduling path in this checkpoint.
- Gate: 520 root, 47 PostgreSQL, four graph consumer, 15 app consumer and seven
  job consumer tests pass, plus two independent service tests. Builds use warnings
  as errors. Full source formatting, `nix fmt`, `nix flake check` and
  `git diff --check` pass. Two legacy graph-format fixtures were updated to
  exercise downgrade refusal from the new writer version; the rerun is green.
- Conformance: J6–J10 are covered by nine public core scenarios, a record
  compatibility scenario, a real PostgreSQL scenario and two added HTTP consumer
  scenarios. No Saga/Grind dependency was added. Owned remote cancellation,
  automatic completion observation and deadlines remain unbuilt; wave 3 and
  waves 4–6 stay open. The user reconfirmed commit/continue authorization and the
  full six-stage goal remains active on 2026-09-30.
- Next: make a retained job wait discoverable when its next observation is due,
  using storage-owned time and the registered sweeper, without holding an idle
  runner or spending a new work grant for every observation.

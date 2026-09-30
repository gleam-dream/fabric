# Wave tracker: Fabric graph flow

## Current state

- Last updated: 2026-09-29.
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
- Open decisions: wave 3's shared child/family representation and job/deadline
  contracts are being refined. Manual signal contracts are implemented.
  Native authoring, serial lifecycle, compatibility and public control are now
  concrete in the [durable sequential contract](durable-sequential.md).
  Actual remote credentials/endpoints are checked before wave 5. No new paid
  infrastructure is selected.
- Temporary substitutions: scripted decisions remain in tests and examples;
  real decision/protocol adapters are required in wave 5. The synchronous
  authoring driver has been replaced by the production persistent runner.
- Gate status: the first subgraph checkpoint passes 416 root tests, 31 PostgreSQL tests,
  three graph consumer tests and 15 existing app consumer tests. Builds use
  warnings as errors. Explicit source formatting, `nix fmt`, `nix flake check`
  and `git diff --check` pass on this host.
- Current evidence: typed native operations and commands run through public
  start/read/await/recover/approval/reconciliation/cancellation APIs. Directory
  and PostgreSQL scenarios retain work over store-process loss. Shared host
  startup and the executor preserve current agent behavior.
- Next action: finish canceled-child settlement and idle and nested child waits
  under the [managed composition contract](managed-composition.md), then managed
  agents, family budgeting/retention, jobs and deadlines. These remain runtime
  states rather than blocking operation wrappers.
- Resume note: the user requested a checkpoint commit and resumed implementation
  on 2026-09-29. The app goal still reports paused; its tool cannot unpause it.
  Repository work is authorized to continue. Initial subgraphs do not establish
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

| Rule | Contract                                                                                                                                                                  | First evidence owner                                     |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| G1   | A graph binds heterogeneous native operation types without unchecked casts; codecs are required for durable values, provider schema is not.                               | Wave 1 authoring consumer and codec tests                |
| G2   | Construction validates identity, positive bounds, unique nodes and destination references before any work runs. A runtime destination must be allowed by its source node. | Wave 1 construction/routing tests                        |
| G3   | Every visit gets a fresh activation identity, including pure cycles; the limit stops the next activation before its body runs.                                            | Wave 1 loop trace and bound tests; wave 2 recovery tests |
| G4   | Input selection, operation failure, codec failure and transition failure remain distinct; invalid or uncertain results release no successor work.                         | Wave 1 failure tests; wave 2 fenced effects              |
| G5   | Result, state, route, new activation identities and budgets commit together before dispatch. Stored decisions are reused.                                                 | Wave 2 persistent restart and lost-ack tests             |
| G6   | An effect starts only after validated admission and a committed start fence. Lost results remain uncertain; approval uses fresh context after recovery.                   | Wave 2 effect/policy tests                               |
| G7   | Child identity is reserved before start; recovery adopts the same child and redelivers outcomes. Signals are correlated, consumed once and retained durably.              | Wave 3 child/signal tests                                |
| G8   | External submission, accepted receipt and business completion are distinct; attachment/cancellation ownership is explicit.                                                | Wave 3 real local job integration                        |
| G9   | A structured fork retains private branch results, joins only its own members in defined order, and preserves failure/uncertainty.                                         | Wave 4 pair/map/join tests                               |
| G10  | Changing a typed decision producer does not change routes or recovery. Provider adapters preserve their real protocol and effect semantics.                               | Wave 5 adapter tests and live/local protocol exercises   |
| G11  | An agent recipe is evaluated against current transcript, policy, approval, recovery, cancellation and version guarantees.                                                 | Wave 6 parity report and scenarios                       |

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

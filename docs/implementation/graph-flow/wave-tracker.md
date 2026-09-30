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
- Last completed evaluation: wave 6, agent-loop graph recipe. The ordinary
  controller and managed-agent graph operation are retained after executable
  comparison. Wave 4 remains accepted; wave 5 is open for live validation.
- Active work: stage-5 actual LLM and classifier inference acceptance. The code,
  offline protocol gates and opt-in live entry points are implemented. Both live
  commands stopped before I/O because their existing API keys were missing or
  empty. The user has one pending request to identify usable provider setup.
- Adapter evidence: structured LLM decisions retain typed output and usage;
  TypeSafe retains native probabilities, enum distributions and rubric scores.
  Both use one routing consumer. MCP transport and schema-pinned binding run
  against a real local SQLite service. No new paid infrastructure was selected.
- Agent recipe result: five differential/counterexample scenarios and two
  comparisons covering three captured oracle cases establish supported round
  trips and the lifecycle mismatch. A batch receipt cannot retain tool A's
  individual success if tool B is interrupted before the batch returns.
  Existing agent APIs and record compatibility remain authoritative. The
  [evaluation](agent-recipe-evaluation.md) explains why a finer replacement
  still requires an agent-specific action lifecycle.
- Temporary substitutions: scripted LLM output and the TypeSafe protocol fixture
  are offline evidence only. Live provider acceptance is not waived. The
  evaluation-only recipe lives under `test/` and is not a production API.
- Gate status: root warnings-as-errors build and 623 tests pass, including all
  ten oracle tests. Graph/app/decision consumers pass 5/15/2; external jobs pass
  19 Gleam and five Python tests. PostgreSQL passes 57 tests. MCP and TypeSafe
  have 22/18 package scenarios and four/three independent service/fixture tests.
  Graph writer 14/readers 5–14, agent writer 7, discovery 10, retention 11 and
  PostgreSQL schema 6 remain unchanged. `nix fmt`, `nix flake check` and
  `git diff --check` pass on this host.
- Current evidence: the complete selected graph surface runs through public
  start/read/await/recover, approval, reconciliation and cancellation APIs.
  Directory/PostgreSQL scenarios retain work across store loss. Managed agent
  children preserve their own action lifecycle, late settlement and transcript.
- Next action: run the opt-in LLM and classifier commands when usable existing
  credentials are supplied, retain the actual provider evidence and correct any
  incompatibility it reveals. This is the remaining acceptance for the full
  six-stage goal. No further controller convergence is selected.
- Resume note: the user requested another checkpoint commit and continued
  implementation on 2026-09-30. The app goal is confirmed active with all six
  stages preserved. The stage-4 deadline checkpoint is committed as `ea21454`;
  the initial runtime checkpoint is `04ae481`. Initial subgraphs do not establish
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

| Rule | Contract                                                                                                                                                                              | First evidence owner                                                  |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| G1   | A graph binds heterogeneous native operation types without unchecked casts; codecs are required for durable values, provider schema is not.                                           | Wave 1 authoring consumer and codec tests                             |
| G2   | Construction validates identity, positive bounds, unique nodes and destination references before any work runs. A runtime destination must be allowed by its source node.             | Wave 1 construction/routing tests                                     |
| G3   | Every visit gets a fresh activation identity, including pure cycles; the limit stops the next activation before its body runs.                                                        | Wave 1 loop trace and bound tests; wave 2 recovery tests              |
| G4   | Input selection, operation failure, codec failure and transition failure remain distinct; invalid or uncertain results release no successor work.                                     | Wave 1 failure tests; wave 2 fenced effects                           |
| G5   | Result, state, route, activation identities and per-run bounds commit together before dispatch. Family capacity is reserved separately before admission; stored decisions are reused. | Wave 2 persistent restart and lost-ack tests                          |
| G6   | An effect starts only after validated admission and a committed start fence. Lost results remain uncertain; approval uses fresh context after recovery.                               | Wave 2 effect/policy tests                                            |
| G7   | Child identity and shared family capacity are reserved before start; recovery adopts saved children and grants. Signals are correlated, consumed once and retained durably.           | Wave 3 child/signal tests                                             |
| G8   | External submission, accepted receipt and business completion are distinct; attachment/cancellation ownership is explicit.                                                            | Wave 3 real local job integration                                     |
| G9   | A structured fork retains private branch results, joins only its own members in defined order, and preserves failure/uncertainty.                                                     | Wave 4 pair/map, nested recovery and PostgreSQL competing-claim tests |
| G10  | Changing a typed decision producer does not change routes or recovery. Provider adapters preserve their real protocol and effect semantics.                                           | Wave 5 adapter tests and live/local protocol exercises                |
| G11  | An agent recipe is evaluated against current transcript, policy, approval, recovery, cancellation and version guarantees.                                                             | Wave 6 parity report and scenarios                                    |

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

### Wave 3 — scheduled external-job observation

- Status: `job.with_poll_interval` opts an observer into the existing registered
  sweeper. The interval is retained in the operation contract. A scheduled wait
  is first eligible immediately; subsequent ready claims use the backend's last
  claim time and clock. Manual observation remains the default. This delivers
  J11–J13 without a new runtime dependency or scheduling service.
- Storage and ownership: ready claims atomically retain the key, dependency
  revision where applicable, claim time and lease. Concurrent claimers select
  disjoint work without changing execution bytes or revisions. Same-key writes
  and metadata refresh retain poll time. Recovery observes only a locally
  claimed wait; traversing an unclaimed child does not poll it early. Pending
  observation releases its lease; a failed callback retains the expired-lease
  recovery path. Polls reuse the wait's admitted work grant.
- Completion: successive visits are independently eligible. Business completion
  still commits output/state/route before successor work. Sweep diagnostics
  count an accepted route even when it advances without a new incarnation;
  a regression first exposed that missing progress count and then passed.
- Evidence: five public schedule scenarios cover due intervals, bounded and
  incompatible configuration, failed observations followed by store loss,
  nested discovery and repeated visits. A format scenario checks scheduled
  intervals and legacy manual records. The shared leased-backend conformance
  suite now checks concurrent poll claims and retained due intervals on memory
  and PostgreSQL. PostgreSQL scenarios prove restart and metadata-refresh
  preservation. The real HTTP consumer restarts Fabric and completes its
  independently produced artifact through the sweeper, with no manual poll or
  repeat submission.
- Compatibility: graph records write 8/read 5–8; older job records remain manual.
  Retention projection 5 and discovery projection 3 require refresh. PostgreSQL
  migration 4 expands the existing ready index to include scheduled waits;
  migration and packaged SQL agree. Deploy new graph readers before new writes.
- Gate: `gleam build --warnings-as-errors` and full root tests pass (526);
  temporary PostgreSQL tests pass (49); graph/app consumers pass (four/15);
  the job service gate passes eight Gleam and two Python scenarios. Source
  formatting, `nix fmt`, `nix flake check` and `git diff --check` pass.
- Conformance: this supplies automatic job observation and due-interval recovery,
  not remote cancellation authority or deadline outcomes. Wave 3 stays open.
  Waves 4–6 and the active six-stage objective remain intact.
- Next: represent owned cancellation intent, request acknowledgement, confirmed
  cancellation and uncertainty distinctly. Exercise that contract against the
  real service before adding deadline-triggered behavior. Keep read-only
  detachment available for jobs that Fabric does not own.

### Wave 3 — real external cancellation boundary

- Status: an explicit cancellation graph requests a stop through a normal
  policy-gated, fenced activity, then retains its acknowledgment while observing
  terminal evidence. Its typed result distinguishes stopped work from completion
  that won the race. This delivers J14–J17 at the real service boundary; managed
  owned cancellation through `graph.cancel` remains unbuilt.
- Remote contract: the artifact service saves cancellation intent before its
  acknowledgment and deduplicates by receipt. Stop admission and publication
  serialize under one SQLite transaction lock. The worker removes unpublished
  artifact residue before confirming cancellation. Completed results and their
  artifacts cannot be overwritten by a later stop request. Journal version 1
  migrates the earlier queued/complete records without replacing receipts.
- Recovery: a saved acknowledgment survives Fabric restart without another
  request. An interrupted request repeats only with the declared service
  idempotency contract. An unrepeatable request or returned transport uncertainty
  remains blocked until explicit reconciliation. Service restart retains both
  accepted stop requests and terminal outcomes.
- Evidence: six added public consumer scenarios cover approval/refusal, restart,
  safe and unsafe interrupted replay, returned uncertainty, and completion before
  cancellation. Three added service tests cover migration, cancellation restart
  with unpublished residue, and concurrent stop/publication. Malformed stop
  requests leave the remote job unchanged.
- Gate: `nix develop -c consumers/jobs/test-service.sh` passes 14 Gleam scenarios
  and five Python tests. Root and graph/app consumer builds use warnings as errors;
  their test suites pass 526, four and 15 tests. PostgreSQL source is unchanged;
  its previous 49-test result remains evidence. No Python static-type checker is
  configured. Source formatting, `nix fmt`, `nix flake check` and
  `git diff --check` pass.
- Conformance: the request and outcome use existing public activity and job-wait
  contracts; no new core dependency or record version is required. The explicit
  workflow is a boundary proof, not a blocking wrapper or a substitute for the
  retained owned-job lifecycle. Wave 3 and waves 4–6 remain open.
- Next: add the managed owned binding, keeping cancellation intent, request
  admission, acknowledgment, terminal evidence and uncertainty distinct. Local
  cancellation must suppress success routes while cleanup remains recoverable.
  Durable deadline outcomes follow that binding.

### Wave 3 — retained owned-job cancellation

- Status: `operation.own_job` admits a typed observer and stop-request callback
  under the distinct `OwnedJob` policy action. The admitted lifetime includes
  cancellation authority. `graph.cancel` commits intent and a queued request
  before the executor's start fence. This delivers J18–J21. Read-only bindings
  continue to detach without requesting a remote stop.
- Lifecycle: queued, started, accepted, refused and uncertain stop requests are
  distinct retained states. A saved acknowledgment releases the runner and
  lease, exposing `CancellingJob`. Lost runners during queued or started requests
  are observable as unattended. Recovery can dispatch a never-started request;
  interruption after its start remains uncertain and never silently replays.
  Repeated local cancellation does not reset that state.
- Settlement: manual or scheduled observation resolves accepted, refused or
  uncertain requests. Confirmed remote cancellation records `JobStopped`;
  completion retains its checked output with a canceled route, and failure
  retains its reason. Cleanup never resumes success routing. Families remain
  retained until authoritative terminal evidence, including under a canceled
  parent. Cleanup reuses admitted authority and capacity, so it can settle after
  new family work is closed or exhausted.
- Compatibility: graph records write 9/read 5–9. Owned states cannot be hidden
  in earlier formats or confused with read-only observation. Stop dispatch
  revalidates deployed code even when incompatible code recorded cancellation
  intent. Retention projection 6 and discovery projection 4 require metadata
  refresh; PostgreSQL schema stays 4. Cancellation observation has its own due
  scope, using the existing storage-owned clock and sweeper.
- Evidence: seven public ownership scenarios prove admission, refusal and
  uncertainty, failed fences, restart, canceled ancestry, exhausted budgets,
  compatible cleanup and suppression of routing. A record scenario covers
  request-state roundtrips, downgrade refusal and invalid ownership. PostgreSQL
  proves scheduled settlement after restart and retention/pruning of the root
  plus budget ledger. Three real HTTP scenarios cover saved and lost stop
  acknowledgments and remote completion that wins before local cancellation.
- Gate: root warnings-as-errors build and all 534 tests pass. Graph/app consumer
  builds and tests pass (four/15). The real service gate passes 17 Gleam scenarios
  and five Python tests; the temporary PostgreSQL gate passes 50 tests. Source
  formatting, `nix fmt`, `nix flake check` and `git diff --check` pass. No new
  dependency was introduced. Initial regression failures were hardcoded older
  version markers in compatibility fixtures; corrected downgrade checks pass.
- Conformance: the owned lifecycle is retained runtime state, not an operation
  that blocks until a remote job finishes. The explicit cancellation graph
  remains a composable consumer alternative, with its own declared safe replay.
  The owned binding resolves uncertain stop effects through authoritative
  observation; it does not infer that owning a job makes cancellation repeatable.
  Wave 3 stays open for durable deadlines, and waves 4–6 remain active.
- Next: retain deadline identity and expiration outcomes, using backend time and
  durable scheduling. Expiration must not be confused with confirmed remote
  cancellation, and interrupted cleanup must remain recoverable.

### Wave 3 — authoritative clock for durable deadlines

- Status: `store.now` exposes UTC Unix milliseconds through the new required
  `LeasedBackend.now` callback. This delivers D1–D3 as a prerequisite for retained
  wait deadlines. It does not implement wait expiration or close wave 3.
- Authority: PostgreSQL reads database time; unleased memory/directory stores
  use host UTC time. The leased test backend uses one UTC clock plus its test
  offset for reads, leases and discovery. Backend errors, crashes and timeouts
  propagate without a local fallback. Clock calls are bounded and leave the
  store actor free to serve unrelated reads.
- Evidence: three public scenarios cover shared time across store restart,
  nonmutating reads, unavailable/crashed/blocked callbacks and local epoch time.
  The shared backend contract checks preserved records and leases. PostgreSQL
  brackets public clock reads with independent database samples and verifies
  unchanged records. These tests establish clock behavior, not deadline recovery.
- Compatibility: custom leased backend constructors must supply `now`; record
  update syntax inherits it. Graph/agent records, discovery/retention projections
  and PostgreSQL schema versions remain unchanged. Wall-clock corrections can
  advance or delay eligibility; samples are not guaranteed monotonic.
- Gate: warnings-as-errors builds and all 537 root tests pass. Graph/app
  consumers pass four/15 tests; the real job service passes 17 Gleam scenarios
  and five Python tests. The temporary PostgreSQL gate passes 51 tests. Source
  formatting, `nix fmt`, `nix flake check` and `git diff --check` pass.
- Conformance: the full six-stage goal is confirmed active after the user's
  commit-and-proceed request. Stage 3 remains open for retained activation
  deadlines, expiration arbitration and recovery of overdue waits. Stages 4–6
  remain unchanged.
- Next: add activation-scoped signal deadlines and durable discovery, then
  extend expiration to managed children and external jobs while preserving
  owned cancellation progress and terminal evidence.

### Wave 3 — durable signal deadlines

- Status: `operation.with_deadline` bounds an admitted signal wait. Approval
  time does not consume the interval. A retained arming phase samples backend
  time, then commits an absolute due time before exposing a delivery reference.
  Interrupted arming recovers without repeating policy; saved deadlines never
  reset. This delivers D4–D8 for signals, not yet jobs or managed children.
- Outcome: recovery or delivery at a due wait commits
  `Failed(DeadlineExpired(due))` without an accepted value or successor route.
  Delivery checks time before acceptance and after its successful pure callback.
  The final sample determines eligibility; the subsequent revision check
  arbitrates concurrent delivery, cancellation and expiration. Clock sampling
  and writing remain separate operations, so this is not a strict database
  transaction-time cutoff. Identical consumed deliveries remain acknowledged.
- Discovery: `At(due)` uses the backend's UTC clock. Free overdue waits are
  recoverable by the registered sweeper after store loss. A backward clock
  correction releases a claim without changing its deadline or consuming future
  eligibility. Expiration is settled signal evidence and can be pruned with its
  family. Unleased stores require explicit recovery or delivery.
- Evidence: ten public scenarios cover approval, restart, automatic discovery,
  late delivery, repeated visits, definition changes, unavailable clocks,
  interrupted arming, a callback crossing its deadline, clock correction and a
  concurrent expiration/delivery race. A record scenario verifies arming, due
  times, expiration, accepted history, corrupt combinations and downgrade refusal.
  Shared backend checks prove absolute eligibility, preserved execution bytes
  and disjoint live claims. PostgreSQL proves actual database-time expiration
  after store loss, release and pruning without rewriting the saved due time.
- Compatibility: graph records write 10/read 5–10; agent records remain 7.
  Retention projection 7 and discovery projection 5 require metadata refresh.
  PostgreSQL migration 5 expands the ready index to include absolute deadlines;
  packaged and runtime SQL match. Custom backends must implement `At` eligibility.
  Existing definitions without deadlines retain their structural manifest.
- Gate: warnings-as-errors builds and all 548 root tests pass. Graph/app
  consumers pass four/15 tests; the real job service passes 17 Gleam scenarios
  and five Python tests. The temporary PostgreSQL gate passes 52 tests. Source
  formatting, `nix fmt`, `nix flake check` and `git diff --check` pass.
- Conformance: the six-stage goal stays active. This closes the signal deadline
  slice; stage 3 still needs job and managed-child expiration that retains
  unfinished cleanup. Stages 4–6 remain unchanged.
- Next: separate deadline intent from cancellation evidence for owned jobs,
  retain cleanup through restart, and combine due discovery with job observation.
  Apply the same distinction to child execution deadlines before closing stage 3.

### Wave 3 — durable job deadlines and retained cleanup

- Status: `operation.with_deadline` now bounds both read-only and owned job
  waits. Admission precedes clock arming; saved due times survive restart and
  do not reset. Submission remains a separate activation. Ownership permits
  explicit cancellation even if arming cannot read backend time.
- Outcome: read-only expiration detaches. Owned expiration saves
  `DeadlineReached(due)` separately from its fenced stop-request progress.
  Caller cancellation retains `CancellationRequested`; neither can overwrite
  the other's committed cause. Pending cleanup retains the family and uses its
  original admission even after ancestor closure or work-budget exhaustion.
  Cleanup observation needs no functioning deadline clock.
- Evidence: terminal remote cancellation, completion or failure settles
  `Expired(due, disposition)`. Checked completion retains a canceled receipt
  without business routing or an unnecessary stop request. A failed read that
  crosses the deadline still permits expiration. The bound applies to Fabric's
  observation/acceptance, not the service's completion timestamp. Clock samples
  and revision-checked writes remain separate operations.
- Discovery: jobs are eligible when either polling or their absolute deadline
  is due. Manual jobs can expire without periodic observation. Owned cleanup
  switches to its separate polling key without a deadline, avoiding immediate
  repeated polls. A manual binding still requires manual cleanup observation.
  PostgreSQL's existing schema-5 ready index supports the combined eligibility.
- Validation: six public deadline scenarios cover restart, terminal evidence,
  failed clocks/reads, exhausted budgets, scheduled polling and detachment. A
  record scenario covers all new phases, invalid cause/deadline combinations,
  downgrade refusal and legacy stop records. PostgreSQL proves expiration before
  a longer poll interval, cleanup across restart and final family pruning. Two
  real HTTP-service scenarios cover deadline cancellation and loss of the stop
  acknowledgment without repeating the request. The checks exposed and fixed
  an early claim release that otherwise prevented nested scheduled observation.
- Compatibility: graph records write 11/read 5–11; agent records remain 7.
  Version-11 stopping records require a cause; older stop records default to
  caller cancellation. Retention projection 8 and discovery projection 6 require
  metadata refresh. PostgreSQL schema remains 5. The public `CancellingJob`
  constructor adds a stop reason; discovery triggers add an optional deadline.
  No new dependency is introduced.
- Gate: warnings-as-errors builds and all 555 root tests pass. Graph/app
  consumers pass four/15 tests; the real job service passes 19 Gleam scenarios
  and five Python tests. The temporary PostgreSQL gate passes 53 tests. Source
  formatting, `nix fmt`, `nix flake check` and `git diff --check` pass.
- Conformance: the full six-stage goal is confirmed active. This closes job
  deadline support; stage 3 remains open for managed-child deadlines. Stages
  4–6 retain their scope and acceptance requirements.
- Next: retain the deadline cause across child start, observation, cancellation
  and uncertain settlement. Prove both managed agents and subgraphs, including
  lost start acknowledgment, nested cleanup and completion racing expiration,
  before closing stage 3.

### Wave 3 — managed-child deadlines and acceptance

- Status: `operation.with_deadline` now accepts managed agents and subgraphs.
  Admission retains arming before child creation; cancellation during unarmed
  admission starts no child. An armed deadline survives restart and gates child
  start, observation, result mapping and public reconciliation. Expiration saves
  its cause before stopping the reserved child; an uncreated child gets the
  existing never-started cancellation record.
- Outcome: `CancellingChild(reference, cause)` retains the distinction between
  explicit cancellation and expiration. `Expired(due, ChildSettled(reference))`
  keeps the actual child result in its child record. Uncertain effects remain
  `ChildUnresolved`, prevent family pruning and can later settle without parent
  routing. Deadline time is no longer needed for that cleanup. The cutoff governs
  parent acceptance; clock sampling and record commits remain separate operations.
- Discovery: child dependency changes and absolute due times share the existing
  backend index. Expired uncertainty switches to dependency-only settlement.
  A new nested scenario exposed a gap where a finished parent only read its direct
  child and never drove deeper job cleanup. Registered discovery now follows the
  retained chain; manual recovery keeps its existing selected-child semantics.
  Missing children refuse discovery instead of authorizing fresh creation.
- Evidence: eight public deadline scenarios cover graph restart, managed-agent
  uncertainty, arming-clock failure, expiration before child creation, successful
  mapping crossing the deadline, expired reconciliation, and nested job cleanup
  with an unavailable clock. A retained wait whose child is missing refuses
  expiration without changing its record. The record scenario covers all child deadline phases,
  legacy cause defaults, invalid combinations, cause preservation and downgrade
  refusal. PostgreSQL proves unchanged-child expiry after restart, retention of
  unresolved effects, later dependency-triggered settlement, no due-time spin,
  and pruning of the complete root/child/budget family.
- Compatibility: graph records write 12/read 5–12; agent records remain 7.
  Stopping-child records require a cause in format 12; older records decode as
  caller cancellation. The public `CancellingChild` constructor adds that cause.
  Retention projection 9 and discovery projection 7 require metadata refresh.
  PostgreSQL schema remains 5. No dependency was added.
- Gate: root warnings-as-errors build and all 564 tests pass; graph/app consumer
  builds and four/15 tests pass. The real job consumer passes 19 Gleam scenarios
  and five Python service tests. The temporary PostgreSQL gate passes 54 tests.
  Explicit source formatting, `nix fmt`, `nix flake check` and `git diff --check`
  pass on this host.
- Acceptance: G7–G8 and wave 3's exit criteria are satisfied by the retained
  public child/signal scenarios, actual database recovery and the independently
  running HTTP/SQLite job service. Lost start/result acknowledgments, nested
  approval, uncertainty, stale/duplicate/canceled signals, submission receipts,
  remote acceptance followed by receipt loss, lifetime ownership, family budgets
  and retention, and overdue recovery have executable evidence. Wave 3 is closed.
  The full six-stage goal remains active; stages 4–6 are still required.
- Next: implement typed fork/map/join as retained managed scopes, with member
  identity, deterministic result order, bounded admission and explicit failure,
  cancellation and uncertainty handling. Hidden blocking parallel operations do
  not satisfy that next wave.

### Wave 4 — bounded fork lifecycle

- Status: the pure scope lifecycle is implemented under G9 and F1–F8 in the
  [parallel composition contract](parallel-composition.md). This is an internal
  model checkpoint, not acceptance of public parallel execution. Wave 4 remains
  active; stages 5–6 and the full six-stage goal remain open.
- Behavior: each scope fixes ordered requests identified by parent run,
  activation and member ordinal. Admission follows that order and respects
  concurrency. Equal payloads remain separate work. Successful joins preserve
  declared order, regardless of the order in which results arrive.
- Failure and cleanup: a definite refusal, child failure or unexpected child
  cancellation retains the first failed member, withdraws unadmitted members,
  and waits for admitted siblings to settle. Explicit cancellation and expiry
  retain their own first cause. Uncertainty blocks new admissions and joining;
  later authoritative child evidence can resolve it. Late successes remain
  evidence, and all admitted children retain their ownership links.
- Restoration: a checked data snapshot preserves partial results without
  reenacting admission. Validation refuses malformed inputs/results, invalid
  references, broken admission order, missing stop causes and capacity violations.
  Corruption scenarios exposed two extra guards: a rejection must itself be
  the stop cause, and an earlier unsettled member cannot have freed a slot for
  a later member, even when that later member has already completed.
- Evidence: 15 focused lifecycle tests cover fixed membership, bounded map
  admission, reverse completion, stale and foreign references, identical and
  conflicting terminal observations, failure during sibling work, rejected
  admission, cancellation, expiration, uncertainty, empty/oversized membership,
  malformed output, partial restoration and corrupt lifecycle combinations.
  The initial authoring test failed on the missing model; both additional
  corruption cases failed before their corresponding validation fixes.
- Compatibility: this checkpoint adds no public operation or stored graph
  variant. Graph records still write 12/read 5–12; agent records remain 7;
  retention/discovery projections remain 9/7; PostgreSQL remains schema 5.
  No dependency was added. Snapshot restoration is not evidence of persistence
  or process-crash recovery for parallel work.
- Gate: root warnings-as-errors build, source formatting and all 579 tests pass.
  Graph/app consumer builds and four/15 tests pass. The real job consumer passes
  19 Gleam scenarios and five Python service tests. The temporary PostgreSQL
  gate passes 54 tests. `nix fmt`, `nix flake check` and `git diff --check` pass
  on this host.
- Next: use this model in the smallest public typed pair scenario with actual
  managed graph children. Persist scope membership/history and explicit branch
  attachments, fence observations, reserve family capacity, and retain every
  child for discovery and pruning. Then extend that runtime path to typed map,
  persistent restart and join-failure scenarios. Do not build another detached
  horizontal layer or count these pure tests as wave-4 runtime acceptance.

### Wave 4 — concurrent typed pairs and retained joins

- Status: public pair checkpoint under G1, G7, G9 and F1–F8. Wave 4 remains
  active; stages 5–6 remain open. The user authorized the checkpoint commit and
  continued implementation. The app goal was confirmed active with all six
  stages preserved.
- Delivery: `graph.both(identity, left, right)` binds independently typed child
  states and answers to one policy-gated operation. Its result is a typed pair
  or `fork.Failure`, which the application may route to a fallback. Each branch
  is an actual managed graph run with a stable parent/activation/member identity.
  `graph.branch` opens it with its native runtime. Both bindings must share the
  parent's store. No new dependency is introduced.
- Persistence: the parent retains fixed membership, reserved identities,
  acknowledged progress, ordered outcomes, and scope history. A lost start
  acknowledgment may reconnect to the same reservation; an acknowledged child
  record that disappears cannot be recreated. Child quota admission precedes
  reservation, and ancestry checks fence branch effects after parent stop.
  Local wakeups watch every unsettled member.
- Joining: a definite member failure closes admission and retains sibling
  cleanup. The parent's explicit stop intent is separate from the scope's first
  failure, so cancellation during cleanup suppresses the business fallback.
  Failed acceptance keeps settled child results without replaying children.
  Reconciliation and restored receipts must agree with those results. Fixed
  requests must match the typed binding and saved activation input.
- Evidence: six public scenarios prove overlapping execution and reverse-order
  completion, typed fallback, partial directory-backend restart with the same
  children, failed-join cancellation, cancellation during an uncertain sibling
  effect, and refusal of changed membership or saved outcomes. Two record
  scenarios cover every fork lifecycle phase, branch attachment identity,
  corruption, required fields and legacy downgrade refusal. Fifteen pure scope
  tests remain, extended to include reserved-member capacity. Forged join
  reconciliation, unowned scope phases and excess reservations failed before
  their corresponding fixes.
- Compatibility: graph records write 13/read 5–13. Scopes, fork operations and
  branch attachments require 13; agent records remain 7 and direct agent branch
  attachments are refused. Retention projection 10 retains reciprocal links for
  every reserved or acknowledged member. Discovery projection 8 recognizes the
  new record format; persistent multi-member waits are still unimplemented.
  PostgreSQL remains schema 5.
- Gate: the root warnings-as-errors build and all 587 tests pass. Graph/app
  consumer builds and four/15 tests pass. The external-job consumer passes 19
  Gleam scenarios and five independent Python service tests. The temporary
  PostgreSQL gate passes 54 tests. Source formatting, `nix fmt`,
  `nix flake check` and `git diff --check` pass on this host.
- Remaining scope: bounded typed map, nested idle/uncertain fork composition,
  persistent discovery after missed notifications, fork deadlines, repeated
  visits and sibling scopes, family-budget scenarios and PostgreSQL parallel
  contention. The existing database regression gate does not prove those new
  parallel paths. No wave-4 acceptance or full-goal completion is claimed.
- Next: implement bounded typed map on this same scope and managed-child path,
  including ordered outputs, empty input, oversized input and concurrency.

### Wave 4 — bounded native map

- Status: verified checkpoint on the committed pair runtime (`506e0a1`).
  Wave 4 and the complete six-stage goal remain
  active. No new infrastructure or dependency was selected.
- Delivery: `graph.map(identity, child, max_members:, concurrency:)` returns a
  typed operation from a native input list to an ordered list of child answers
  or a settled `fork.Failure`. It uses the same membership, branch identities,
  ownership, result validation, cancellation and retention as `graph.both`.
  Both bounds must be positive. Empty membership joins immediately; oversized
  input is refused before any child reservation. Equal payloads remain separate
  ordinal members. Waiting approval continues to occupy a concurrency slot.
- Evidence: five new public scenarios cover bounded overlapping work with
  out-of-order completion, zero and oversized inputs, invalid bounds, distinct
  equal inputs, failure that withdraws a pending member, and a directory restart
  with completed, waiting and unadmitted members. Recovery keeps the saved
  approval and completed receipt, then joins after approval. The public graph
  consumer maps complete generation/review loops over `[0, 2, 3]` and retains
  separate child state while returning `[3, 3, 4]` in input order.
- Compatibility: record/projection versions are unchanged from the pair
  checkpoint. Definition manifests bind member bounds, concurrency and the
  child's definition/version/manifest. No hidden blocking executor or second
  persistence mechanism was introduced.
- Gate: root warnings-as-errors build and all 592 tests pass. Graph/app
  consumer builds and five/15 tests pass. The external-job consumer passes 19
  Gleam scenarios and five independent Python service tests. The temporary
  PostgreSQL gate passes 54 tests. `gleam format --check`, `nix fmt`,
  `nix flake check` and `git diff --check` pass on this host.
- Remaining scope: persistent multi-dependency discovery, nested idle/uncertain
  scope observation and cleanup, fork deadlines, repeated visits and sibling
  scopes, shared family-budget scenarios, and PostgreSQL parallel contention.
  Stages 5–6 remain open. The next implementation reduces the discovery gap;
  explicit recovery and local wakeups do not close it.

### Wave 4 — multi-child discovery and nested recovery

- Status: checkpoint extending the bounded map runtime (`b1b899d`). Wave 4
  remains active and stages 5–6 remain open. The full goal is active.
- Delivery: idle fork discovery records every unfinished branch identity and
  its observed revision, including absence. PostgreSQL claims a changed parent
  atomically with these observations. Competing scanners cannot both claim the
  same free wait. A changed nonfirst member is sufficient; unchanged waits
  converge instead of repeatedly claiming their ancestors.
- Nested lifecycle: `child.Fork` exposes idle structured progress. Starting an
  existing child follows its saved state; repeated cancellation follows saved
  cleanup. Unclaimed unchanged ancestors remain read-only. Independently
  expired branches can recover beneath a live foreign parent lease without
  taking that parent's ownership. Parking requires all starts acknowledged,
  no ready admission and no ready join.
- Evidence: four shared leased-backend scenarios cover lost local watches,
  nested maps under a serial parent, canceled scopes with uncertain leaf
  effects, and independent descendant expiration. They verify unchanged idle
  revisions, ordered results, eventual settlement, suppressed business routing
  and no repeated effects. The nested polling and cancellation cases exposed
  restart loops before the fixes. Record checks rejected invalid parking only
  after the new shared guard.
- Database evidence: a real PostgreSQL map survives store-owner loss, detects
  changes to each branch, arbitrates concurrent claims, completes through
  registered sweeping and prunes its four-row settled family. A schema-5
  upgrade preserves exact execution bytes, revisions, ages and the existing
  scheduled-poll key and timestamp through migration and metadata refresh.
- Compatibility: graph records remain writer 13/readers 5–13, agent records 7
  and retention projection 10. Discovery is version 9 and PostgreSQL is schema 6. Stop older backend writers before migrating the replaced scalar dependency
  columns, then refresh stale discovery metadata in bounded batches. No new
  dependency or infrastructure was introduced.
- Gate: root warnings-as-errors build and all 596 tests pass. One existing
  held-runner lease test timed out in the first full run; its focused check and
  a full rerun passed unchanged. Graph/app consumer builds and five/15 tests
  pass. External jobs pass 19 Gleam scenarios and five service tests. PostgreSQL
  passes 56 tests. Source formatting, `nix fmt`, `nix flake check` and
  `git diff --check` pass on this host.
- Remaining: fork deadlines, repeated visits and sibling-scope isolation,
  shared family-budget scenarios, and acceptance of the complete parallel
  contract. Nested cleanup evidence uses the shared leased backend; the new
  PostgreSQL contention scenario covers a flat map. This checkpoint does not
  claim stage-4 acceptance or completion of the six-stage goal.

### Wave 4 — fork identity and family limits

- Status: five additional public scenarios on the recovery runtime (`3d3fb4c`).
  The existing implementation passes them without production changes. Stage 4
  remains active; stages 5–6 remain open.
- Evidence: a two-visit map retains four distinct children with identical
  inputs, survives directory-store loss under an exact shared work/child budget,
  and rejects earlier-visit signal references. Duplicate delivery to the old
  child preserves its prior result and cannot satisfy a later join.
- Composition: two sibling maps share the same definition and equal inputs
  under one root work/child/depth budget. Finishing one leaves the other waiting
  with no receipt. Cross-sibling signals are refused and the root joins in
  member order. Exhausted child capacity produces a rejected member, settled
  admitted siblings and withdrawn pending inputs. Nested maps cannot reset
  family depth, and children cannot start waits after the parent uses the final
  work grant.
- Gate: root warnings-as-errors build and all 601 tests pass. Source formatting,
  `nix fmt`, `nix flake check` and `git diff --check` pass. The graph/app/job/
  PostgreSQL gates from the preceding checkpoint still apply to their unchanged
  production and integration inputs: five/15/19 scenarios, five independent
  service tests and 56 database tests. This checkpoint changes tests and
  evidence documentation only; record and projection versions are unchanged.
- Remaining: implement fork deadlines through the existing backend-clock and
  retained-cleanup contracts, exercise nested cleanup against PostgreSQL, then
  assess the full parallel contract before accepting stage 4. Real adapters
  and the agent-recipe evaluation remain required afterward.

### Wave 4 — retained fork deadlines and acceptance

- Status: stage 4 accepted; stage 5 is now active. The six-stage goal remains
  active and unbounded, with real adapters and agent-recipe evaluation still
  required. No Saga/Grind dependency or new infrastructure was introduced.
- Delivery: `operation.with_deadline` bounds pair and map scopes using the
  existing backend-clock protocol. Approval precedes arming; preparation,
  admission, execution and acceptance share the retained absolute due time.
  Expiration withdraws pending members and preserves admitted cleanup. It keeps
  the parent's deadline cause even when a member failure started cleanup first.
  Cancellation after expiration cannot replace that cause.
- Arbitration: checks before member admission and around join callbacks prevent
  a known overdue result from routing. Reconciliation can correct an accepted
  member result's mapping before the deadline; afterward it expires the scope.
  Member results remain recorded in either case. Uncertain effects retain the
  family until authoritative child reconciliation, with no implicit replay.
- Persistence: joining waits are eligible on any member change or the deadline.
  Cleanup uses member changes only, so the expired timestamp cannot spin. The
  real PostgreSQL scenario proves two store losses around nested cleanup,
  reconciliation from another store, no extra member admission or effect replay,
  and pruning only after all five execution rows and their budget ledger settle.
- Compatibility: graph records write 14/read 5–14; fork deadlines cannot be
  downgraded to 13. Agent records remain 7. Discovery is 10, retention is 11,
  and PostgreSQL remains schema 6. Deploy compatible readers, then refresh both
  projections in bounded batches. Record checks reject mismatched stop causes,
  missing armed deadlines and invalid expired dispositions.
- Gate: root warnings-as-errors build and all 607 tests pass, including five
  public deadline scenarios and the expanded record lifecycle checks. Graph/app
  consumer builds and five/15 tests pass. External jobs pass 19 scenarios and
  five independent service tests. PostgreSQL passes 57 tests. Source formatting,
  `nix fmt`, `nix flake check` and `git diff --check` pass on this host.
- Acceptance audit of stage 4:

| Requirement                                                             | Current evidence                                                                                                                        |
| ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Typed heterogeneous pair and homogeneous bounded map                    | Public `graph.both`/`graph.map` scenarios in `graph_parallel_test`; separate graph consumer maps complete review loops.                 |
| Fixed members, capacity, empty/oversized input and ordered join (F1–F4) | Pure fork transitions plus public overlap, reverse completion, capacity and equal-input cases.                                          |
| Private state across sibling scopes and loop visits (G3, G9)            | `graph_parallel_family_test` rejects cross-sibling and stale-visit signals, preserving prior receipts across directory restart.         |
| Shared work, child and depth limits (G7)                                | Exact-capacity restart, explicit limit refusals and nested PostgreSQL cleanup with one root budget.                                     |
| Definite failure, cancellation and uncertainty (F5–F7)                  | Typed fallback, cancellation during uncertain sibling cleanup, retained first cause, reconciliation and suppressed canceled routing.    |
| Join failure and deadline arbitration (F6–F8)                           | Corrected join succeeds once before deadline; late callback/reconciliation expires without replay or successor receipts.                |
| Recovery, ownership and discovery (G7, F8)                              | Partial directory restart, lost-watch and foreign-parent lease cases, PostgreSQL competing claims and nested two-store-loss expiration. |
| Compatibility and retention (F8)                                        | Record 5–14 reads, downgrade/corruption refusal, retained reciprocal member attachments and six-row family pruning after settlement.    |

- Remaining goal work: actual LLM/classifier/MCP adapters and their real boundary
  evidence, then agent-loop parity evaluation. Broader quorum/streaming/shared
  state parallelism remains outside the selected fork contract rather than
  being silently counted as implemented.

### Wave 5: structured LLM decision binding

- Governing rule: G10 and [the decision adapter contract](decision-adapters.md).
  `fabric/graph/llm` performs one structured llm_wire request as an ordinary
  policy-gated activity. It persists the native answer, original JSON, requested
  model and optional usage. Refusal and output limits remain distinct typed
  outcomes; uncertain transport/validation failures release no route and do not
  trigger an automatic retry. Tool catalogs are rejected before I/O.
- Receipt compatibility: `fabric.graph.llm.v1` validates the native value against
  its saved JSON and rejects invalid models, usage and outcome tags. Deployment
  identity/version owns the prompt, provider and schema meaning. Graph writer
  14/readers 5–14, agent writer 7, retention 11, discovery 10 and PostgreSQL schema
  6 are unchanged by the adapter.
- Evidence: nine public tests prove typed results, usage, approval before I/O,
  durable reuse after store loss, refusal/limit distinction, invalid output,
  interrupted calls, HTTP failure handling, proven unsent failures, tool refusal,
  OpenAI schema projection/SSE and receipt corruption refusal. The independent
  decision consumer routes a native enum to `publish` or `revise` through the
  same graph with scripted settings and the real-provider entry point.
- Red/green: the first public scenario observed an unimplemented operation.
  Initial combinator composition then exposed expensive OTP closure copying:
  5,072,863 copied words for one receipt codec. Preloading did not fix the timed
  failures. Composing envelope fields inside the codec callbacks reduced that
  to 1,884 words; all nine focused scenarios passed in 0.16 seconds without
  increasing their five-second waits. This changes Fabric's adapter boundary,
  not json_blueprint's general implementation.
- Gate: root build/tests pass 616; decision consumer passes 1; existing graph
  and app consumers pass 5 and 15; jobs pass 19 Gleam and five Python scenarios.
  All builds use warnings as errors. `nix fmt`, `nix flake check` and
  `git diff --check` pass. Backend code is unchanged; its latest 57-test
  PostgreSQL gate is the accepted stage-4 checkpoint.
- Live limitation: the consumer's live command stopped before network I/O when
  `OPENAI_API_KEY` was absent or empty. Named-variable checks also found no
  non-empty Anthropic or TypeSafe key; no secret values were printed. The user
  has a pending request to identify an existing provider setup. No live model
  judgment, classifier execution or MCP acceptance is claimed.
- Remaining: inspect the `mcp_client` Hex package's source/version/ownership
  behavior before adoption, implement the classifier and MCP slices, prove
  actual provider/local-server boundaries, then evaluate the agent-loop recipe.
  The complete unbounded six-stage goal remains active.

### Wave 5: bounded application-owned MCP connection

- Governing rules: G6/G10 and [the MCP adapter contract](mcp-adapter.md).
  The optional `fabric_mcp` package contains the stdio transport; core has no
  MCP, Saga or Grind dependency. Native Blueprint parsing admits every outbound
  value and incoming envelope before dispatching more work. The selected
  protocol is MCP 2026-07-28 with per-request metadata. Older initialization,
  HTTP and multi-round-trip interactions are outside this first slice.
- Ownership: one application-owned connection outlives its operation tasks.
  Caller loss or deadline sends cancellation without claiming rollback.
  Queue time counts against deadlines; known expired work never dispatches.
  Responses must match the increasing request ID, late replies cannot complete
  another request, and malformed streams close. No request retries or reconnects
  occur automatically. Byte, notification and duration bounds are explicit.
- Red/green: public tests exposed nested duplicate keys reaching the actual
  counter and malformed replies leaving the connection eligible for another
  request. Both are now rejected at the transport boundary. Method-specific
  schemas and native graph receipts remain the next slice, not a transport claim.
- Evidence: 11 public client scenarios exercise a separate SQLite-backed Python
  server. Four independent service tests verify stdio contracts and persistence.
  The service commits a counter before simulated response loss; another process
  reads exactly that committed effect, with no automatic repeat. The tests also
  cover application/caller loss, cancellation receipt, stale replies, expired
  queue entries, invalid configuration, JSON errors and bounded noise/bytes.
- Gate: MCP warnings-as-errors build, 11 Gleam scenarios and four Python service
  scenarios pass (`/tmp/fabric-mcp-client-final.log`). The root gate passes all
  616 tests (`/tmp/fabric-mcp-root-gate.log`). `nix fmt`, `nix flake check` and
  `git diff --check` pass on this host.
  No backend, graph record or dependency protocol changes are made to Fabric.
- Acceptance: the connection's selected contracts and interface hold; behavior
  is checked through public client calls and an independent service. The source
  preserves effect uncertainty and package boundaries without another runtime.
  No design-ledger entry is cleared. This is a checkpoint toward stage 5, which
  remains active. Typed MCP graph binding, classifier/live LLM acceptance and
  stage 6 remain required; the full six-stage unbounded goal is confirmed active.

### Wave 5: typed MCP graph binding and offline descriptor recovery

- Governing rules: G6/G10 and [the MCP adapter contract](mcp-adapter.md).
  `fabric_mcp.discover` pins a bounded catalog entry and its supported Blueprint
  contracts. `bind` creates an ordinary policy-gated operation with separately
  named application identity, server and remote tool. Each invocation rediscovers
  and checks contracts before calling the tool; changed/unsupported schemas and
  server mismatches are definite pre-call failures. Post-call errors, malformed
  outputs, interrupted replies and conversion failures retain uncertainty.
- Native boundary: Blueprint checks native input against the remote contract.
  A pure application conversion consumes retained content and optional structured
  content. Output requires a persistence codec, not a provider schema. Tool
  annotations cannot authorize effects or opt in to replay. Content is retained
  without executing resource links or embedded data.
- Recovery: `fabric.mcp.tool.v1` saves the descriptor in application configuration.
  `fabric.mcp.receipt.v1` retains server/tool identities, schemas and original
  response. Both restore without a live connection. A receipt's native value
  must agree with its original response, and its saved contract must match the
  deployed binding. Application meaning changes still require an operation
  version change. Fabric graph writer 14/readers 5–14 and all backend formats
  remain unchanged.
- Evidence: the first public graph scenario failed at unimplemented discovery.
  Eleven graph/descriptor scenarios now cover native results, approval, drift,
  identity, supported/unsupported schemas, bounded catalog discovery, optional
  structured output, text-only output, complete-result compatibility, content
  preservation, conversion errors, corruption and offline restart. Cancellation
  sends the remote stop request and retains the graph's unresolved effect.
  Invalid/lost post-effect results never route or repeat the actual counter.
  Store-loss recovery reconstructs a saved descriptor with the connection closed
  and recovers its completed receipt; a new server observes one retained effect.
- Gate: `gleam build --warnings-as-errors`, all 22 package scenarios and four
  independent service tests pass (`/tmp/fabric-mcp-binding-final.log`). The root
  source is unchanged since its 616-test transport gate. `nix fmt`,
  `nix flake check` and `git diff --check` pass at the binding checkpoint.
- Acceptance: requested selected behavior, package boundaries, typed/persistence
  contracts and public behavioral evidence pass. No design-ledger entry is
  cleared. The MCP slice is accepted for modern stdio and the supported closed
  schema subset. HTTP, legacy initialization, arbitrary schema resolution and
  multi-round-trip interactions are not claimed.
- Remaining goal: the classifier producer and live LLM acceptance, followed by
  the agent-loop recipe/parity evaluation. The full unbounded six-stage goal
  remains active. No credential failure prevents independent classifier work.

### Wave 5: typed non-generative classifier and shared decision routes

- Governing rules: G6/G10 and [the classifier contract](classifier-adapter.md).
  The optional `fabric_typesafe` package uses the documented System One HTTP API
  directly, with the existing Gun transport dependency. Fabric core gains no
  classifier dependency. Noul retains the yes probability; Choice maps labels
  to native values and retains its distribution; Score retains its fractional
  position on the actual rubric. Confidence stays concentration evidence.
- Composition: checked question constructors and heterogeneous batches retain
  unique IDs and complete distributions. The decision consumer's LLM and
  classifier producers now use one `publish`/`revise` routing definition, with
  separate deployed identities and receipt codecs. Neither uses chat state,
  Saga or Grind. Routing thresholds and consequences belong to the application.
- Protocol: one request has verified TLS, byte/header/deadline bounds and owner
  cancellation. There are no redirects or automatic retries. Preparation and
  proven unsent connection failures are definite; post-dispatch uncertainty
  cannot release a successor. HTTP errors expose status and retry hints without
  copying the body or key into diagnostics.
- Recovery: `fabric.typesafe.receipt.v1` preserves the exact request/response,
  requested/resolved models, reported tokens and typed answers. Exact JSON
  range checks precede float projection; stored questions and rubrics must match
  the deployed batch. Native answer/model/usage forgery is refused. Completed
  receipts restore after store loss with the HTTP service already stopped.
  Graph writer 14/readers 5–14 and all backend formats remain unchanged.
- Evidence: 18 public package scenarios cover question shapes and invalid
  evidence, approval before I/O, transport limits, deadline/caller cancellation,
  failed dispatch, no redirects/retries, uncertainty and offline restart. Three
  independent Python tests check fixture shapes, status/hints and incomplete
  replies. Two separate consumer tests cover both routes with each producer.
  The fixture names itself `protocol-fixture-only`; it performs no inference.
- Corrections found during implementation: canonical JSON numbers needed a
  decimal mantissa before native float parsing, and credential validation needed
  to reject all ASCII controls rather than just CR/LF. Model identities now
  reject whitespace-only values on both fresh and restored receipts.
- Gate: package and consumer builds use warnings as errors. Their 18/2 Gleam
  tests and three independent HTTP checks pass. Core source remains unchanged
  from the 616-test root gate and the backend from its 57-test PostgreSQL gate.
  `nix fmt`, `nix flake check` and `git diff --check` pass on this host.
  Final evidence is retained in the adapter document.
- Live limitation: `gleam run -m fabric_decision_classifier` stopped before I/O
  because `TYPESAFE_API_KEY` was missing or empty. No Jev inference or provider
  spend occurred. The earlier live LLM limitation still applies. Provider
  credentials are requested once and remain pending; no offline fixture replaces
  that acceptance. The complete unbounded six-stage goal is active. Independent
  agent-recipe evaluation proceeds while stage-5 live acceptance remains open.

### Wave 6: executed agent-recipe evaluation

- Governing rule: G11 and [the evaluation report](agent-recipe-evaluation.md).
  The private executable probe uses model-turn and tool-batch graph nodes over
  the existing pure controller and encoded agent state. It changes no production
  API, dependency, controller or record format.
- Positive evidence: provider replay data, native tool success/model-visible
  errors, transcript order, usage, refusal/output limits and turn/token budgets
  match on supported paths. Two oracle tests cover the three captured basic
  round-trip/limit cases under their existing comparison rules. All eight
  ordinary-runtime oracle tests still pass.
- Counterexample: store loss after the first tool succeeds but while the second
  waits preserves only the batch's prior inner state in the recipe. The outer
  graph correctly blocks the batch; it cannot recover the first individual
  success. The ordinary runner preserves that success and marks only the second
  action uncertain. Cancellation has the same scope-level loss of detail.
  A per-action approval cannot be answered through a generic batch approval.
- Decision: retain the ordinary controller/runner and `fabric/graph/agent` as the
  supported composition. A finer graph recipe still needs agent-specific action
  admission, independent uncertainty, settlement, retry/backoff, public handles
  and record compatibility. No simplifying replacement has been demonstrated;
  the evaluated batch recipe is not shipped as one. This negative evaluation is
  the accepted stage-6 outcome allowed by the original program.
- Gate: root build and all 623 tests pass; graph/app/decision consumers pass
  5/15/2, jobs pass 19 plus five independent service tests, and PostgreSQL passes 57. Builds use warnings as errors. Adapter and formatting results are retained
  with the evaluation report. No design-ledger entry is cleared.
- Remaining goal: actual LLM and TypeSafe inference evidence, using the existing
  configured-provider question rather than another request for credentials.
  Stage 5 stays open. The full unbounded six-stage goal remains active and is
  not marked complete merely because its remaining live checks require input.

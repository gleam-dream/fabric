# Remaining work

Current after graph acceptance, 2026-09-30. This inventory consolidates the
accepted production plan, retained feature backlog, release gaps and
deferred proposals in [PLAN](PLAN.md) and [CAPABILITIES](CAPABILITIES.md).
Earlier slice notes remain historical; items completed in later slices
are not reopened here.

## New direction: agentic graph flow

The accepted implementation includes a Fabric-owned graph layer with typed
decisions, conditional routing, cycles and composable operations. Saga remains
independent; branching there is deferred, and neither Saga nor Grind becomes
a Fabric core dependency. [GRAPH-FLOW](GRAPH-FLOW.md) explores the design and
defines the selected six-step implementation program. The
[completion audit](implementation/graph-flow/completion-audit.md) accepts all
six stages. The graph runner handles conditional routes, bounded cycles, approval,
recovery, reconciliation, cancellation, shutdown handoff and typed durable
signals. Managed subgraphs and agents cover restart, approvals, lost
acknowledgements, cancellation races, idle/nested waits, shared family budgets,
retention and registered recovery. External jobs support submission, scheduled
observation and retained owned cancellation with real-service evidence.
Durable deadlines, typed parallel composition, real LLM/TypeSafe/MCP adapters
and the agent-recipe evaluation are complete. Ordinary agents remain managed
graph children to retain their per-tool recovery guarantees.

The current [production-readiness program](implementation/production-readiness/wave-tracker.md)
prepares complete local verification, delivers S7 and exercises a realistic
application with both decision providers. The user deferred CI activation and
library publication; those remain explicit later work.

## Next: S7 operations

Complete the accepted production-runtime plan with:

- **PostgreSQL statistics:** working and unattended runs; runs suspended
  on approval and awaiting reconciliation, each with a count and oldest
  age; leases per node. Add the proposed `fabric_postgres.stats` API and
  define the timestamps and queries behind each gauge.
- **Sweep lag:** report the age of the oldest expired lease. The current
  backend claim returns ids without expiry timestamps, so this needs a
  metadata contract or a separate query.
- **Drain summary:** report runners handed off, runners killed at the
  deadline and failed handoffs. The supervising process must account for
  killed runners because they cannot report their own shutdown.
- **Operations runbook:** startup and migration order, node identity,
  readiness, lease and sweep tuning, shutdown, rolling upgrades, unknown
  agent identities, uncertain-effect reconciliation and retention. Tie
  each procedure to the available events and gauges.

Already delivered from S7's original scope: family-safe PostgreSQL pruning;
`lease_lost`, `renewal_failed`, `run_taken_over` and per-run handoff events;
basic sweep counts; Sinal's unavailable-forwarder drop count; and
`store.readiness`, with a bounded backend probe, current acceptance, local
runner count and renewal age. New claims supply the first safe lease window;
idle stores need no renewal. See the precise [operations contract](implementation/production-readiness/operations.md).
Preserve
these and extend their coverage as the remaining operations surface lands.

## Later: S8 Grind integration

`integrations/fabric_grind` is optional. It provides scheduled wakeups and
delayed or unique starts, carrying run references rather than run state.
The sweeper already supplies recovery without Grind.

The accepted integration depends on four public Grind capabilities, absent
at the inspected revision `75e50ae`:

1. `worker.with_context_handler` with `JobContext` and input.
2. `worker.with_lost_attempt(Replay)`.
3. Supervised queue and PostgreSQL components.
4. A public connection or `submit_in(transaction)` for atomic submission.

Grind has an internal PostgreSQL connection helper; it does not satisfy
the public integration contract. Establish those APIs in Grind before
building the Fabric adapter.

## Retained product features

| Work                     | Required behavior or dependency                                                                                                                                                                                                           |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Approval expiry          | Store the request's issue time and evaluate expiry with a trusted or injected clock. A policy recheck can enforce application expiry today, but Fabric has no durable expiry model.                                                       |
| Edit and respond answers | Extend approval handling beyond approve and reject, with explicit continuation behavior.                                                                                                                                                  |
| Family token accounting  | Share token accounting across parent and child runs. Durable family work/model-attempt, child and depth limits are implemented; token limits remain per agent run.                                                                        |
| Narrower child context   | Let a delegation derive a child's context rather than passing the parent's context with the same type.                                                                                                                                    |
| Direct child recovery    | Give a directly recovered child consistent parent attachment and outcome delivery. S5 handles automatic root resolution and leased-parent polling; the public child-only recovery path still constructs its handle without a parent link. |
| Model progress streaming | Adapt llm_wire streams and close them when a run is cancelled.                                                                                                                                                                            |
| Structured final output  | Use llm_wire's structured session and support typed child results beyond decoding the child's final string.                                                                                                                               |
| Agent time budgets       | Add whole-agent elapsed-time budgets and per-tool deadlines with a trusted clock. Graph signal, job, managed-child and fork deadlines already exist.                                                                                      |
| Context compaction       | Specify and implement compaction or summarization after the earlier features. Budget exhaustion currently stops the run.                                                                                                                  |

These are retained backlog items, not prerequisites for finishing S7.
Their detailed acceptance rules still need to be designed before coding.

## Release and continuous checks

- Library publication and hosted CI activation are deferred by the user.
  Replace sibling path dependencies with published versions, or define
  a pinned public checkout arrangement before activating CI. Reconcile
  json_blueprint's reported 1.7.1 with its unreleased 2.0 work; publish the
  required sibling versions and Fabric packages when their release gates
  are met.
- The current CI dependency setup still checks out Fabric alone even though
  the packages resolve llm_wire, json_blueprint, Sinal and Saga beside it.
- The shared [verification command](VERIFICATION.md) prepares full package,
  consumer, service and temporary PostgreSQL checks for local use and later CI.
  Its current acceptance is tracked in the production-readiness program.

## Library improvements adopted

The four earlier sibling gaps are resolved. llm_wire now returns assistant
turns as data and validates caller-supplied conversations; Fabric stores the
turns, including signed Google parts and custom provider data. Its public
retry assessment supplies failure classification while Fabric retains retry
policy and budgets. Blueprint descriptions reach provider schemas, and
Fabric uses Blueprint's decode-error renderer.

The caller-owned conversation contract supersedes the proposed persistable
continuation API. There is no remaining continuation-handle feature to build.
See [PLAN](PLAN.md#library-adoption-caller-owned-conversations) for the new
model port, record version 4 and acceptance evidence. The adopted changes are
now committed in the local sibling repositories; publishing remains separate.

## Optional proposals and known limitations

These require a separate decision; they are not accepted delivery tasks:

- PostgreSQL notifications to reduce cross-node polling.
- Cheaper status and answer routing for wide or deep run families, which
  currently read the active descendants' records.
- Internal API extraction and easier access to approval requirements;
  the earlier ergonomics review deferred these because of module cycles
  and API shape.
- Rejecting an incompatible stranded run. Cancellation is available;
  rejection would need to define how an incompatible agent may continue.
- Cooperative cancellation grace, beyond the existing bounded late
  settlement support.
- Observation refinements: orphan cancellation can emit recovery; a
  child's completion can precede its parent's start observation; adopting
  a late insert can omit `run_started`. These are documented event-order
  limits, not evidence of a repeated tool effect.

## Excluded from Fabric

Coordination over Erlang distribution; directory-store power-loss
durability requiring a NIF; retrieval, vector stores and document loading;
exact LangGraph API compatibility, time travel and a general channel system;
remote Agent Protocol sub-agents; a general middleware chain. Serial agentic
graph control and bounded fan-out are implemented. Saga workflows remain external operations that consumers
may expose through tools or future graph adapters.

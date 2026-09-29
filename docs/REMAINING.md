# Remaining work

Current after production S6, 2026-09-28. This inventory consolidates the
accepted production plan, retained feature backlog, release gaps and
deferred proposals in [PLAN](PLAN.md) and [CAPABILITIES](CAPABILITIES.md).
Earlier slice notes remain historical; items completed in later slices
are not reopened here.

## Next: S7 operations

Complete the accepted production-runtime plan with:

- **PostgreSQL statistics:** working and unattended runs; runs suspended
  on approval and awaiting reconciliation, each with a count and oldest
  age; leases per node. Add the proposed `fabric_postgres.stats` API and
  define the timestamps and queries behind each gauge.
- **Readiness:** report whether the store is reachable and its last
  successful renewal is younger than its lease. Define readiness before
  the first renewal and while no run needs renewal.
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
basic sweep counts; Sinal's unavailable-forwarder drop count. Preserve
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
| Family budgets           | Share turn and token accounting across parent and child runs. Current budgets belong to individual runs.                                                                                                                                  |
| Narrower child context   | Let a delegation derive a child's context rather than passing the parent's context with the same type.                                                                                                                                    |
| Direct child recovery    | Give a directly recovered child consistent parent attachment and outcome delivery. S5 handles automatic root resolution and leased-parent polling; the public child-only recovery path still constructs its handle without a parent link. |
| Model progress streaming | Adapt llm_wire streams and close them when a run is cancelled.                                                                                                                                                                            |
| Structured final output  | Use llm_wire's structured session and support typed child results beyond decoding the child's final string.                                                                                                                               |
| Time budgets             | Add elapsed-time budgets and per-tool timeouts with a trusted clock.                                                                                                                                                                      |
| Context compaction       | Specify and implement compaction or summarization after the earlier features. Budget exhaustion currently stops the run.                                                                                                                  |

These are retained backlog items, not prerequisites for finishing S7.
Their detailed acceptance rules still need to be designed before coding.

## Release and continuous checks

- Replace sibling path dependencies with publishable versions, or define
  a reproducible checkout arrangement for development and CI. Reconcile
  json_blueprint's reported 1.7.1 with its unreleased 2.0 work; publish the
  required sibling versions and Fabric packages when their release gates
  are met.
- Repair CI's dependency setup: it checks out Fabric alone even though
  the packages resolve llm_wire, json_blueprint, Sinal and Saga beside it.
- Automate the external consumer, Saga and temporary PostgreSQL gates.
  They are checked locally; the current CI and root test suite do not
  exercise all four packages.

## Sibling improvements retained for separate work

These improve Fabric's adapter code but do not block S7:

- **llm_wire:** a persistable continuation or replay-preparation API that
  retains Google raw parts, custom replay behavior and exact-coverage
  validation across restarts.
- **llm_wire:** public retry classification, so Fabric need not infer it
  from error variants and HTTP status.
- **json_blueprint:** schema field descriptions that reach the model.
- **json_blueprint:** a public decode-error renderer, replacing Fabric's
  local rendering of located errors.

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
a LangGraph-compatible graph API with breakpoints, time travel, channels
or `Send`; remote Agent Protocol sub-agents; a general middleware chain.
Typed DAG workflows belong to Saga and enter Fabric as tools.

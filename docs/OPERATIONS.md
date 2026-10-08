# Operations runbook

This runbook covers PostgreSQL runtime operations and reports specified by
the [native design](design/design.typ#recovery-discovery-and-retention).
The application owns deployment, credentials, access control and alert thresholds.
Fabric owns saved execution and conditional writes. Reports help diagnose that
execution; they never authorize recovery or prove an external effect happened.

## Start a worker

1. Choose one stable node id per live VM. Reuse it after that VM restarts, but
   never on two live VMs. Use a stable store name within that node, avoiding the
   reserved `$runners` suffix. Node ids accept 1–128 letters, digits and
   `.`, `_`, `-`, `@`, `:`; `nonode@nohost` is refused. Generated process names
   alone do not distinguish VMs.
2. Start the application's PostgreSQL pool. Build `fabric_postgres.settings`
   with that connection and node id; choose the schema and lease duration.
   Apply `fabric_postgres.migrate(settings)` and require success before accepting
   run requests or enabling the sweeper. A migration failure fails startup.
   Migration is idempotent under a database advisory lock; SQL schema 7 is current.
3. After an upgrade, call `refresh_discovery`, `refresh_retention` and
   `refresh_statistics` with bounded positive batches, for example `limit: 100`.
   Repeat each until it returns zero. Concurrent refreshers skip locked rows;
   one zero does not prove another refresher finished. Check again once they
   finish. Unknown records can remain unknown after refresh; do not treat the
   refresh count as repaired executions. All three preserve execution bytes,
   revisions, leases and record-write ages.
4. Configure the store before starting it: `fabric_postgres.store(name, settings)`,
   optionally `store.with_record_version` and `store.with_drain`. Pass the returned
   store value consistently to every handle, graph and recovery registration.
5. Use this startup order under application supervision: pool, optional Sinal
   forwarder, migration barrier, store subtree, sweeper, request admission.
   A rest-for-one arrangement restarts dependents when an earlier component
   fails. The migration barrier must complete before the sweeper's immediate
   boot scan. Keep the pool and forwarder alive until the store finishes stopping.
6. Register every root's deployed recovery code with `sweeper.agent` or
   `sweeper.graph`, then supervise `sweeper.supervised(runs, roots, every: duration.seconds(1))`
   in place of `store.supervised(runs)`.
   Context is rebuilt from the root id; it is not stored. A graph factory must
   rebuild its children against the supplied pinned store. Reject configuration
   errors at startup. Expose admission only after `store.readiness(runs)` returns
   `Accepting`.

The [PostgreSQL setup](../integrations/fabric_postgres/README.md#setup) documents
pool construction and the backend contract. The directory backend supports
process/VM restart on one host, but lacks power-loss durability; use PostgreSQL
for this production procedure.

## Read health and progress

Call `store.readiness(runs)` for each worker and `fabric_postgres.stats(settings)`
for the shared database. Handle errors as failed observations, not healthy zeroes.
A successful readiness probe describes the instant after a bounded backend read;
it does not promise the next request will succeed.

| Evidence                           | Meaning and response                                                                                                                                                                                              |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Accepting`                        | Backend read succeeded, the factory accepts work, and any local runners have safe lease evidence. An idle/fresh worker can be ready before its first renewal.                                                     |
| `StoreDraining`                    | Remove this worker from admission and allow its shutdown to finish.                                                                                                                                               |
| `RunnerFactoryUnavailable`         | Inspect supervisor failures and startup configuration; the store cannot start runners.                                                                                                                            |
| `LeaseUnconfirmed`                 | Active runners lack a safe lease window. Check database reachability, pool contention and worker stalls. Fencing remains automatic.                                                                               |
| `last_success_age_ms`              | Local monotonic age since the start of the last confirmed renewal batch, including its round trip. `None` means none has succeeded in this store incarnation. A large age on an idle worker alone is not failure. |
| `working`                          | Known execution records needing a runner with a live database lease. This does not establish that a remote process is still alive.                                                                                |
| `unattended`                       | Known execution records needing a runner without a live lease. Inspect recovery registration, sweeps and the individual saved state.                                                                              |
| `waiting`                          | Known unfinished records not requiring a runner, including legitimate signal/job/child waits. Resolve the actual wait; age alone does not make it broken.                                                         |
| `approval`, `reconciliation`       | Records with current approval requests or unresolved results/effects. These counts overlap the main groups and each other. Children are counted individually, not again on their ancestors.                       |
| `finished`                         | Ended executions, possibly still requiring reconciliation. Finished does not mean safe to prune.                                                                                                                  |
| `unknown`                          | Missing, stale, incompatible, corrupt or mismatched diagnostic metadata. Refresh metadata, then inspect decoding/compatibility errors. Unknown is never evidence that there is no work.                           |
| `leases_per_node`                  | Live database leases by the node component of owner tokens. Compare with expected workers; investigate unexpected duplicate identities or lost nodes.                                                             |
| `expired_leases.oldest_overdue_ms` | Age of the oldest currently expired lease, a recovery backlog gauge. It is not end-to-end recovery latency.                                                                                                       |

Counts are for individual records, including managed children. Budget ledgers
are reported separately and excluded from run groups. Run-group
`oldest_record_age_ms` is time since the most recent durable record write—not
execution duration, approval issue time or time in that group. Claims, renewals
and projection refresh do not reset it. Empty groups have age `None`. Statistics
use one database snapshot and one database clock sample.

Choose alert thresholds from the application's expected waits and recovery
objectives. Track repeated readiness failures, increasing unattended/expired
backlog, unknown records, renewal failures, failed/unmatched sweeps and Sinal
forwarder drops. An event can be missing after process loss; use persisted state
and current gauges to investigate rather than event absence alone.

## Recover delayed work

The store renews leases every third of their duration. The default PostgreSQL
lease is 30 seconds; accepted durations are 100 ms through 2^32−1 ms. A shorter
lease permits quicker takeover but leaves less room for database delay and
process stalls. Fabric fences runners before their safe local lease window
expires. Keep node ids unique; do not bypass a lease by relabeling a live worker.

The sweeper scans at boot and waits its configured interval after each completed
batch. A batch claims at most 50 expired leases and 50 changed/due idle waits;
scans do not overlap. Root restoration has 30 seconds, including at most 5 seconds
to rebuild context. A failed or unmatched recovery leaves its claim to expire.
Recovery time therefore includes lease expiry, scan wait, earlier work and
backend/context latency; the configured scan interval is not a recovery SLA.
Measure backlog before changing capacity or intervals.

For a specific run, open it with `fabric.open` or `graph.open` and inspect
`fabric.snapshot`/`fabric.await` or `graph.snapshot`/`graph.await`. Read errors are evidence; retain
them. If work is unattended, use `fabric.recover` or `graph.recover` with its
compatible deployed definition. Explicit agent recovery can take an earlier
local store incarnation's lease immediately; foreign live leases remain held.
Do not repeatedly submit a new workflow to replace an unattended one.

`telemetry.sweep()` reports `claimed`, `recovered`, `unmatched` and `failed`.
Unmatched roots need their exact agent or graph identity/version registered.
Failed roots need their decoding, attachment, context, callback or backend error
resolved. A graph-owned agent is restored through the root graph registration.
Recoveries check definitions, codecs and saved attachments before executing.
Changing an identity to silence an incompatibility is not a migration.

A read-only database inspection can locate expired candidates without claiming
or changing them; substitute the configured schema for `public`:

```sql
SELECT run_id, revision, lease_owner, lease_until, updated_at
FROM public.fabric_runs
WHERE lease_until < clock_timestamp()
ORDER BY lease_until
LIMIT 100;
```

For legitimate waits, use the matching operation: current approval references
through `fabric.approve`/`reject` or `graph.approve`/`reject`; a typed signal through
`graph.deliver`; a manual job through `graph.poll_job`. Scheduled jobs, due
deadlines and changed managed-child dependencies need a registered sweeper.
An ordinary signal without a deadline needs explicit delivery. Approval can be
rechecked against fresh context and its requirement can change; fetch the new
request after a refusal instead of retrying a stale reference.

## Resolve uncertain effects

Inspect the original operation in the external system using its durable effect
identity, idempotency key or receipt. A missing Fabric result is not proof the
operation failed. Do not call the body again merely to discover whether it ran.

- For an active agent's uncertain tool, `fabric.reconcile` records the real result
  and can continue the run when its other waits are clear.
- For a finished agent's uncertain tool, `fabric.reconcile_stored` records evidence
  without restarting work. For finished delegations, settle descendants and use
  `fabric.settle_stored` to propagate their saved outcomes. Check the returned
  snapshot: a successful walk can still contain unresolved actions.
- For a graph operation, `graph.reconcile` accepts the actual output encoded with
  its output codec and the current reconciliation reference. After cancellation
  it retains the result without running a route. Managed-child outcomes must
  come from the actual child; recover the parent to observe them.
- For owned jobs, a saved cancellation request proves intent, not remote
  termination. Observe the external job through `graph.poll_job` or scheduled
  recovery until authoritative terminal evidence is saved. Read-only job
  cancellation detaches observation; it does not cancel external work.

An explicit replay contract can allow bounded replay of an interrupted graph
operation. That contract belongs to the application and its external effect;
operational reporting grants no additional replay permission. Keep unresolved
families retained. Cancellation stops further work but does not erase uncertainty.

## Stop or roll a worker

Stop request admission and the sweeper before the store subtree. Runners start
no new work during drain, wait for running bodies/model replies, save results and
hand off remaining work. The default per-runner window is 25 seconds, configured
by `store.with_drain`. At its deadline the supervisor kills the runner; interrupted
external effects can remain uncertain. Suspended runs have no runner to drain.

Allow the application's outer shutdown budget to cover the drain window, up to
four additional seconds for admission/accounting/observation, and process,
forwarder and pool cleanup. The factory stops runners concurrently. Abrupt VM or
host loss cannot produce a reliable summary and follows lease/recovery rules.

`telemetry.drain()` is emitted after the factory stops and before the store
closes. Store-name metadata identifies the local subtree. Its measurements are:

- `runners`: supervised processes present at admission close, including admitted
  starts racing shutdown; ordinary completed runners are excluded.
- `handed_off`, `failed_handoffs`, `pending_handoffs`: confirmed, unconfirmed and
  still-pending handoff evidence, once per runner. A runner finishing normally
  needs no handoff. Lost acknowledgments count as confirmed only after readback.
- `killed`, `exited`, `unobserved`: a partition of that cohort. Killed records a
  forced exit, including deadline enforcement; it does not identify its cause.
  A confirmed handoff and a kill can both describe one runner.
- `elapsed_ms`: monotonic time since admission closed. Pending/unobserved counts
  remain explicit after the one-second accounting deadline.

`drain_unavailable` means accounting could not be read; do not infer an empty
successful drain. Summary emission has a separate one-second bound. Keep the
Sinal forwarder alive through store shutdown and account for its drop events;
being enqueued does not prove delivery to an external monitoring system.

After restart, observe readiness, sweep results and expired backlog. Failed,
pending or killed handoffs require checking saved records and external effects;
the summary itself never instructs Fabric to repeat an operation.

## Deliver accepted turns and incorporate outcomes

- Admission and incorporation have separate failure windows. Admission records
  application acceptance before a Fabric run exists. Incorporation applies a
  retained Fabric outcome after that run finishes.
- Use an existing transactional job or outbox for admission. Oversight's
  [research-agent consumer](https://github.com/gleam-dream/oversight/tree/a207c516a9e128917799d7f857a348a90aa15dd9/apps/research_agent)
  records application acceptance and calls `grind.submit_in` on the same
  transaction. Its delivery mechanism is an example of atomic acceptance;
  sharing a pool or passing a borrowed `pog.Connection` to Fabric does not
  establish atomic Fabric admission.
- A delivery carries a stable accepted-turn key, authenticated principal and
  complete original input. Call `invoke.agent_with_history` with these values
  on every delivery. Keep the invocation wait below the delivery mechanism's
  deadline.
- Let the PostgreSQL adapter's leased store and registered Fabric sweeper own
  execution recovery. Register the agent with a context builder that supplies
  current credentials and authority. Do not add an application lease-renewal
  loop or abandoned-run scanner.
- Before invoking, read the application's applied-turn marker. If already
  applied, return the application's retained result. This guard must remain
  effective after the Fabric record is pruned.
- On `Answered`, obtain the existing native answer and generated messages.
  Apply them and mark the turn applied in one idempotent application
  transaction. A crash before commit leaves the Fabric outcome available for
  the next delivery; a lost commit acknowledgement is resolved by reading the
  applied-turn marker.
- Use `fabric/history.codec()` to retain and restore complete message values
  in application storage. Handle Blueprint decoding errors explicitly;
  malformed or unsupported saved history must not become an empty history.
  The codec's independent format does not change Fabric's execution records
  or make the incorporation transaction Fabric-owned.
- Keep pruning disabled for a store containing unapplied outcomes. The adapter's
  age-based `prune` has no application acknowledgement predicate; a sufficiently
  old finished run can be deleted even if the application has not incorporated
  it. A finite age alone cannot guarantee retention under an unbounded delivery
  delay.
- Coordinate pruning with application admission and incorporation before
  enabling it for an eligible store. Never invoke an applied turn after its
  Fabric record disappears: its application marker is the durable authority
  that prevents another execution.
- The adapter's
  [history delivery test](../integrations/fabric_postgres/test/fabric_postgres/history_test.gleam)
  exercises leased recovery, retained outcome incorporation in a real PostgreSQL
  transaction, duplicate delivery and the applied guard after pruning. Its
  provider is deterministic; it does not establish live-provider behavior or
  transactional queue admission.

| Observation                          | Delivery action                                                                                                                                                                                                                    |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Answered`                           | Incorporate the native answer and generated messages idempotently.                                                                                                                                                                 |
| `Working`                            | Preserve the same turn identity; let Fabric execution and the existing delivery mechanism continue.                                                                                                                                |
| `AwaitingApproval` / `AwaitingInput` | Record the suspended observation and arrange the required application interaction.                                                                                                                                                 |
| `OutcomeUnknown`                     | Inspect admission/effect evidence and reconcile the original execution; never submit the effect under a new key.                                                                                                                   |
| `Unattended`                         | Inspect recovery registration, lease state and sweeper health.                                                                                                                                                                     |
| `Ended`                              | Record the terminal failure or cancellation; retain any required evidence.                                                                                                                                                         |
| `Refused`                            | Inspect `code`: correct invalid configuration or handle `key_reused`. The existing `unavailable` code can represent a read/await failure after execution exists; retain the original identity and inspect the run before deciding. |

### Application-authored per-turn graph alternative

- An application can author a graph with a typed generation operation and a
  result-application node. The operation takes history from application graph
  state; the current managed-agent graph boundary remains prompt-only.
- The graph's retained generation receipt lets recovery retry only the
  unfinished application operation. Alternatively, an incorporation graph can
  accept an already retained agent answer under its own stable invocation key.
  Both forms still require transactional admission through the existing delivery
  mechanism.
- Define result application as an idempotent transaction keyed by the accepted
  turn. A crash after the transaction commits and before the graph saves its
  result remains an interrupted effect. Enable an existing replay contract
  only when repeating that transaction returns the same result without applying
  it again; otherwise preserve uncertainty and reconcile.
- A running or unresolved application node prevents the family from being a
  fully settled pruning candidate. A completed application node records the
  incorporation result before the graph completes. Application markers still
  prevent resubmission after the complete family is pruned.
- This alternative adds application graph/state/codecs and recovery registration.
  It is useful when result application must be part of the durable execution;
  it is separate from history-aware agent invocation. Neither option introduces
  a queue, a Fabric conversation resource or an atomic `admit_in` API.

## Upgrade formats deliberately

These versions are independent. Check all of them before a rolling deployment.

| Surface                                        | Current version and compatibility                                                                                                                                                                      |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Agent execution                                | Writes 8; reads 1–8. `store.with_record_version` can select 2–8 for representable states. Provider data needs 4, graph parents 5, child settlement 6, family budgets 7 and imported initial history 8. |
| Graph execution                                | Writes 15; reads 5–15. No agent-style writer downgrade setting. New graph features require compatible readers before new writes.                                                                       |
| Family budget record                           | Version 1. A missing required ledger refuses recovery.                                                                                                                                                 |
| PostgreSQL schema                              | Version 7. Apply migrations before new backend writers/recovery.                                                                                                                                       |
| Discovery / retention / statistics projections | Versions 13 / 12 / 2. Refresh each after upgrading; stale metadata is not valid execution evidence.                                                                                                    |

For agents, first deploy readers that understand the target format while
selecting the shared older writer. Enable newer features and writer settings
only after every participating reader is compatible. Configure before starting
stores and use the same value in the sweeper. The setting does not rewrite old
records or reconfigure live runners. Once newer records exist, rolling back the
binary alone may be impossible.

Version 8 retains the initial-input boundary used by duplicate comparison,
generated-message extraction and answer-repair accounting. Supported older
records retain their one-prompt semantics when read. A writer selected below
version 8 refuses imported history before starting work; selecting an older
writer does not remove history from a stored version 8 run.

Graph formats and SQL/backend compatibility require their own rollout. In
particular, stop older backend writers before migration 6, which replaces the
scalar dependency index with the fork-aware dependency array. See the
[adapter's migration notes](../integrations/fabric_postgres/README.md#idle-dependency-scheduled-job-and-deadline-discovery).
Do not use the agent writer setting as a graph or database compatibility switch.
Preserve old compatible recovery registrations until their retained executions
are completed or deliberately migrated.

## Retain and prune families

Choose the retention interval according to application needs. After refreshing
retention metadata, `fabric_postgres.prune(settings, ended_for: duration.hours(7 * 24), limit: n)`
deletes up to `n` eligible root families and returns the number of records deleted,
including children. Every member must be settled, old enough, currently readable,
reciprocally attached and free of a live lease. Uncertain effects, missing children,
unknown metadata or unresolved cleanup retain the whole family. A new settlement
resets that member's retention interval. Children and budget ledgers are not
independently disposable.

Use bounded scheduled calls and retain errors. A lost deletion acknowledgment
makes its count unknown; repeating prune is safe but cannot reconstruct the prior
count. Investigate long-retained finished families through their saved uncertainty
and attachments. Do not delete child rows or change phases to make pruning pass.
The [pruning contract](../integrations/fabric_postgres/README.md#pruning) describes
concurrency, refresh and incomplete-family behavior.

## Verification before adoption

Run `nix develop -c python3 scripts/check.py full --logs /tmp/fabric-check` in the
repository. This exercises all retained packages, real temporary PostgreSQL,
local services and the typed authoring consumer. The [verification guide](VERIFICATION.md)
documents dependencies and retained results. It does not load provider credentials.
The native [verification contract](design/design.typ#verification-and-extension-obligations)
and retained public suites cover readiness, statistics and shutdown scenarios. Hosted CI activation, library
publication and a deployment drill remain separate; no hosted result is claimed.

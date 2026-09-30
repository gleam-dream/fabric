# Production operations

S7 extends the existing store, leases, sweeping and shutdown ownership from
[PLAN](../../PLAN.md#production-runtime). These reports are diagnostic: saved
run records and lease conditions retain authority. No observation authorizes
an effect or replaces recovery. The accepted scope and remaining work are in
the [wave tracker](wave-tracker.md).

## Store readiness

`store.readiness(store)` returns `Result(Readiness, StoreError)`. A successful
report contains an acceptance status, the number of this store's live runners,
and lease information. A leased store reports its lease duration and the age
of its last successful renewal, or `None` before any successful renewal in this
store incarnation. Unleased stores report `Unleased`.

- **O1 — reachable storage:** a readiness request performs a bounded backend
  read. A missing probe key is success; a backend failure, crash or timeout is
  an explicit error. A stopped store is unavailable. The request neither
  creates a probe record nor blocks the store actor during backend work.
- **O2 — accepting work:** after the probe returns, the store reports
  `StoreDraining` when shutdown has begun, or `RunnerFactoryUnavailable` when
  its runner factory is unavailable. Otherwise it may report `Accepting`
  subject to O3. A probe started before shutdown cannot return an earlier
  acceptance snapshot after shutdown begins.
- **O3 — current lease evidence:** a leased store is ready only while every
  local runner has a confirmed, unexpired safe lease window. Before a runner's
  first renewal, its committed claim supplies this evidence. Subsequent
  successful renewals refresh it. The existing safety margin applies; an
  expired or missing window reports `LeaseUnconfirmed`. An idle store needs
  no renewal and can be ready regardless of the age of its previous renewal.
  Loss of a lease continues to fence the runner independently of readiness.
- **O4 — renewal age:** age uses this process's monotonic clock and the start
  of the last successful renewal request, conservatively including its round
  trip. Failure never refreshes this age. Restart starts with no successful
  renewal; no timestamp from a previous process is reused. Age is milliseconds
  and is never negative.
- **O5 — diagnostic only:** readiness never claims, renews, releases, writes
  or recovers work. Reporting uses the existing backend deadline and is
  independent of event handlers. Its answer describes the instant after the
  probe; it is not a guarantee that a later start or write will succeed.

`ReadinessStatus` is `Accepting`, `StoreDraining`,
`RunnerFactoryUnavailable` or `LeaseUnconfirmed`. `LeaseHealth` is `Unleased`
or `Leased(duration_ms, last_success_age_ms)`. The report's runner count is
local, not a count of every database lease or managed job observer. These are
read-only values, not additional persisted workflow states.

The store owns the lease evidence already used for fencing and its acceptance
state. The backend owns whether a read succeeds. The request samples acceptance
after the backend read so a slow probe cannot return stale pre-drain readiness.
The backend read uses a fresh opaque key and accepts a found record or
`NotFound`; it has no special write or cleanup path.

Coverage for this slice belongs in `store_readiness_test`: fresh and stopped
stores, idle and active leased stores, renewal success/failure and restart,
backend failure/timeout, ongoing normal reads during a held probe, and a drain
that starts while a probe is pending. Existing lease tests continue to own
fencing and recovery behavior. Database gauges and sweep lag are defined below.
Shutdown summaries and the full runbook remain unbuilt S7 work.

## Database statistics

`fabric_postgres.stats(settings)` returns a read-only snapshot
of the shared database. Counts concern individual execution records, including
managed children; they do not count families or expand child state onto every
ancestor. Budget ledgers are counted separately and excluded from runs.

- **O6 — execution counts:** supported agent and graph records are classified
  using their actual decoders and controller rules. Work needing a runner is
  `working` with a live database lease, or `unattended` without one. Other
  unfinished work is `waiting`; ended work is `finished`. The four buckets
  partition known runs. Waiting on a signal, external job or managed child is
  legitimate waiting, not automatically unattended work.
- **O7 — intervention counts:** approval counts identify records with a current
  approval request. Reconciliation counts identify saved unresolved results or
  effects, including unresolved cancellation and uncertain effects retained by
  ended agents. These independent counts may overlap each other and the O6
  buckets. An ancestor does not duplicate a child's requests. A count does not
  claim that every uncertainty is resolvable through the same API: ended agent
  effects require external reconciliation; child and job evidence belongs to
  the corresponding child or external service.
- **O8 — measured ages:** each count reports the oldest age since the record's
  latest durable write, explicitly named `oldest_record_age_ms`. It is not a
  request's issue age, execution duration or time spent in a category. Claims,
  renewals and metadata refresh do not reset it. The database supplies one
  timestamp for the snapshot. Empty groups have count zero and age `None`;
  ages are nonnegative milliseconds.
- **O9 — lease ownership and recovery delay:** report live leases grouped by
  the node component of the stored owner token, and expired leases with the
  age of the oldest expiry (`oldest_overdue_ms`). This overdue age measures
  current sweep backlog, not a promised recovery latency. It includes leased
  rows with unreadable execution metadata. A remote runner's loss is visible
  to these database gauges only once its lease expires or is released.
- **O10 — explicit unknowns:** corrupt, incompatible and mismatched records,
  missing projections, stale projection versions and revision mismatches count
  as `unknown`, never healthy zeroes. A versioned diagnostic projection is
  written atomically with each execution revision. `refresh_statistics` can
  rebuild stale projections in bounded batches, preserving source bytes,
  revision, lease and record age. A refresh examines unreadable rows once per
  projection version and leaves them unknown. Concurrent writers cannot attach
  a projection to the wrong source revision.
- **O11 — snapshot and failure:** counts, ages and lease groups share one
  database snapshot and clock sample. Reporting changes no records or leases.
  A query failure is an explicit error, not a cached or partial healthy report.
  Metadata refresh is explicit and separate from `stats`.

The core owns the pure classification of supported records. PostgreSQL owns
timestamps, leases, atomically maintained projections and aggregation. No new
workflow state or persisted timestamp is needed. The projection has its own
version, separate from agent, graph, budget and SQL schema versions; its version
must advance whenever supported formats or classification rules change.

Coverage for O6–O11 requires real database examples for all buckets and their
ages, overlapping interventions, graph waits, budget exclusion, unknown/stale
rows, per-node live leases and expired backlog, no-write reporting and refresh
preservation. Pure projection scenarios cover every phase class, unsupported
records and identity mismatch. The accepted implementation uses diagnostic
projection 1 and SQL schema 7; its complete gate evidence is in the wave tracker.

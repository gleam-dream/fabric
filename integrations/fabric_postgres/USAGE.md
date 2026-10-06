# PostgreSQL usage and maintenance

The [README](README.md) contains supervised setup and root recovery examples.
The application owns pool capacity, database settings and maintenance-call bounds.
Fabric's backend timeout bounds its worker wait; it is not a whole maintenance
operation deadline.

## Settings and migrations

- `settings(connection, node:)` defaults to schema `public` and a 30-second
  lease. Give every live VM a unique stable node id: 1–128 ASCII letters,
  digits or `.`, `_`, `-`, `@`, `:`. Never use `nonode@nohost`. `store` validates it.
- `with_lease` accepts a `Duration` from 100 ms to 2^32 − 1 ms. Fabric renews
  every third of the lease and self-fences runners after lost renewal.
- `with_schema` accepts 1–63 lowercase letters, digits or underscore, with no
  initial digit. `migrate` creates a missing schema; precreating it avoids
  requiring database CREATE privilege.
- `migrate` records unapplied forward steps in `fabric_schema_migrations` in one
  transaction under a schema-specific advisory lock. A schema already migrated
  further by a newer adapter remains unchanged. The same up statements and lock
  are available in [cigogne migrations](priv/migrations/).

## Upgrades and metadata refresh

Current schema is 7. Retention, discovery and statistics projections are versions
11, 12 and 1. Normal writes maintain these derived views with their source
revision. Older backend writes make them stale; unknown records stay retained
and unscheduled.

Stop older backend writers before migration 6, which replaces scalar dependency
columns. Migrate, deploy compatible readers and backends, then call
`refresh_retention`, `refresh_discovery` and `refresh_statistics` with `limit: 100`
until each returns zero. Refresh preserves exact record bytes, revisions, leases
and record ages. Counts include examined unknown records. Concurrent refreshers
skip locked rows, so zero describes that call rather than another batch's progress.

Record writer selection does not migrate existing data. Older writers refuse
states they cannot represent before changing the record. Downgrading after newer
writes needs a separate migration plan. See the
[record versions](README.md#record-versions) and
[compatibility contract](docs/design/design.typ#schema-and-record-compatibility).

## Pruning

`prune` requires a nonnegative age and positive root-family limit. It follows
saved attachments rather than id prefixes. Each member's age starts at its
latest execution-record write; a new settlement restarts that interval.
Missing children, stale metadata or unresolved effects retain the whole family.
A child is never deleted alone.

Pruning uses serializable transactions with finite retries and a parent foreign
key. Concurrent writes and renewals force revalidation; the foreign key prevents
delayed child insertion from recreating an orphan. A lost commit reply may leave
the count unknown, even though a later prune remains safe. Applications must
never reuse deleted ids for different runs that could receive old messages.

## Discovery

`claim_ready` leases a free eligible wait and records its observed dependency
revisions and claim time atomically. A concurrent dependency change remains
eligible for a later scan. Claims preserve execution revisions and record ages;
concurrent claimers skip locked candidates.

Scheduled polls are first eligible immediately. Later claims wait at least the
saved interval after the previous claim. Same-key writes and metadata refresh
preserve that timestamp. Load and scan intervals may delay observation.

An absolute deadline remains retained after a claim. Recovery checks time again;
if a backward clock correction makes the wait early, it releases the lease with
the original due time intact. Reads alone do not expire waits. After expiration,
owned cleanup retains its separate dependency or polling trigger without the
expired deadline. Unresolved cleanup prevents pruning.

Only claimed jobs are observed. Pending reads release their lease; failed
callbacks leave an expiry retry path. Manual waits without deadlines require
explicit delivery or observation. Stale or unknown projections cannot become
scheduling candidates. Refresh discovery metadata before relying on automatic
recovery after an upgrade.

## Diagnostics and backend time

`stats(settings)` reads one diagnostic snapshot without refreshing, claiming or
changing records. It counts individual runs, their own approval and reconciliation
evidence, unknown records, budget records and lease backlog. Intervention groups
may overlap execution groups. Children are counted individually; their flags
are not copied onto ancestors.

Ages measure the latest record write rather than duration in a phase. Empty
groups have no oldest age. Stale or unreadable projections count as unknown;
query or decoding failures return `StatsFailed`.

`store.now(runs)` reads database UTC Unix milliseconds without mutation. Lease,
deadline and scheduled eligibility use this clock. Failures never fall back on
caller time. Clock corrections can advance or delay due work.

`store.readiness(runs)` separately checks storage reachability, admission and
local runner lease safety. The [operations runbook](../../docs/OPERATIONS.md)
describes how to use these observations during startup, monitoring and drain.

## Schema reference

This SQL block describes the current row shape. The
[runtime migrations](src/fabric_postgres/internal/migrations.gleam) and
[cigogne migrations](priv/migrations/) remain the executable schema definitions;
tests compare their statements exactly.

```sql
CREATE TABLE fabric_runs (
  run_id text PRIMARY KEY CHECK (run_id ~ '^[A-Za-z0-9_-]{1,128}$'),
  revision bigint NOT NULL CHECK (revision >= 1),
  record text NOT NULL,          -- the exact bytes written
  phase text,                    -- the record's phase tag, for queries
  retention jsonb,               -- Fabric's validated family projection
  retention_revision bigint,     -- source revision of that projection
  parent_id text GENERATED ALWAYS AS (retention ->> 'parent') STORED
    REFERENCES fabric_runs(run_id) DEFERRABLE INITIALLY IMMEDIATE,
  discovery jsonb, discovery_revision bigint,
  statistics jsonb, statistics_revision bigint,
  dependency_ids jsonb GENERATED ALWAYS AS (discovery #> '{wait,dependencies}') STORED,
  observed_key text, observed_dependencies jsonb,
  discovery_checked_at timestamptz NOT NULL DEFAULT '-infinity',
  lease_owner text, lease_until timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK ((lease_owner IS NULL) = (lease_until IS NULL)));
-- indexes: expired leases, settled roots by age, immediate parents, idle dependencies
```

The [design](docs/design/design.typ) specifies conditional storage, lease time,
projection refresh, pruning and compatibility. The parent
[verification guide](../../docs/VERIFICATION.md) distinguishes compiler,
database and runtime evidence.

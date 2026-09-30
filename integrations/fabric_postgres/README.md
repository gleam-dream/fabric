# fabric_postgres

A PostgreSQL store for [Fabric](../../README.md) runs, for one node or
several nodes that share one database. Each run is one row of the table
`fabric_runs`: its latest record as text (the exact bytes Fabric wrote), its
revision, and its lease (an owner and an expiry). The package implements
Fabric's leased backend contract (`fabric/store`, Leases) and passes its
conformance checks (`fabric/testing.leased_backend_checks`).

It depends on `fabric` and `pog` (4.1, over `pgo` 0.20), not on Grind. It is
developed and tested against PostgreSQL 16.

## Setup

The application owns the connection pool and passes its `pog.Connection`:

```gleam
import fabric/store
import fabric_postgres
import gleam/erlang/process
import gleam/otp/static_supervisor
import pog

pub fn start(database_url: String, node: String) -> store.Store {
  let pool = process.new_name("db")
  let assert Ok(config) = pog.url_config(pool, database_url)
  let settings =
    fabric_postgres.settings(pog.named_connection(pool), node:)
    |> fabric_postgres.with_lease(30_000)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("runs"), settings)

  // The pool first, the store after it: a rest-for-one supervisor restarts
  // the store when the pool restarts, and stops the store (whose runners
  // drain and commit their handoffs) before the pool.
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.add(pog.supervised(config |> pog.pool_size(10)))
    |> static_supervisor.add(store.supervised(runs))
    |> static_supervisor.start
  let assert Ok(Nil) = fabric_postgres.migrate(settings)
  runs
}
```

`migrate` runs once the pool is up, before the first run starts or opens.
The store is then used like any Fabric store: `fabric.start(runs, ...)`,
`fabric.open`, `fabric.approve`, `fabric.recover`, and so on.

## Automatic recovery

Build one recovery registration per root definition. An agent
registration receives the root run id, including when an expired child
triggered the scan:

```gleam
let recoveries = [fabric.recovery(root_agent, context_for_run)]
let assert Ok(sweeper) = fabric.sweeper(runs, recoveries, every: 1000)
```

For graph roots, add `graph.recovery(identity, build_runtime)` to the same
list. The factory receives the pinned store and must rebuild the complete
graph, including managed child runtimes, against it. Agent and graph
registrations may share a name/version; duplicates within one runtime kind
are rejected. Saved reciprocal attachments determine which root to recover.
A graph-owned agent is recovered through its graph registration.

Add `sweeper` after `store.supervised(runs)` in the rest-for-one supervisor.
The order is pool, optional Sinal forwarder, store, sweeper. Shutdown stops
the sweeper before runners drain and keeps the pool available until their
handoffs are committed. Apply migrations before enabling recovery; a scan
against an unmigrated database reports a failure and retries next interval.

A scan runs at boot, then after each interval. It claims at most 50 expired
leases and 50 free waits with changed dependencies or due job observations,
and never overlaps the next scan. Each root's recovery has 30 seconds,
including at most 5 seconds to rebuild context. Invalid intervals, duplicate
registrations, and unleased stores are rejected before startup. Unknown
identities and failed recoveries leave their claims to expire; observe
`fabric/observation.sweep()` for counts. No run context is stored by Fabric.

Free managed waits remain discoverable after losing local wakeups, including
blocked children and unresolved child cancellation. An unchanged wait does
not repeatedly rewrite its descendants. Signal waits without a deadline need
explicit delivery. Held work still waits for lease expiry after a restart. Explicit `fabric.recover` with a known run id
can take over a prior local store process's lease immediately. Running tools
become uncertain after a crash and are never replayed; reconcile their
outcomes before the run continues. Family members have independent leases:
a live parent keeps its context and reads a remotely recovered child's
committed outcome.

## Record versions

The current runtime reads agent record versions 1–7 and writes version 7 by
default. Versions 2–6 remain writable for representable states. Assistant
provider data requires at least version 4; a graph parent attachment requires
version 5; settled child evidence requires version 6; root family-budget
declarations require version 7. For a deployment that must still write version 3:

```gleam
let assert Ok(runs) =
  fabric_postgres.store(process.new_name("runs"), settings)
let assert Ok(runs) = store.with_record_version(runs, 3)
```

Configure before starting the store, and use this returned value for all
run handles and the sweeper. Versions outside 2–7 return
`UnwritableVersion(requested, oldest, newest)`. Reads still accept 1–7.

Deploy version-4 readers everywhere before enabling the new llm_wire tool
turns, then restart with writer 4. Those turns preserve
provider data that versions 2 and 3 cannot retain. An older writer refuses
the response commit before dispatching tools, leaving the run unattended;
recover with writer 4 to continue. A mixed-version deployment must keep
these new tool turns disabled until the reader upgrade is complete.

Deploy version-5 readers before selecting writer 5. Version 5
distinguishes an agent-action parent from a graph-activation parent. Writers
2–4 retain ordinary agent parent links in their historical shape, but refuse
a graph attachment before inserting it or starting its model call. Graph
records have a separate version contract; this setting controls agent records.

Deploy version-6 readers before selecting writer 6. Terminal agent-family
settlement retains the child's outcome as `child_settled`, without invoking
the delegation's result mapper or resuming the parent. Writers 2–5 refuse
that evidence before changing the parent record. Direct terminal tool
reconciliation retains the existing `reconciled` representation.

Deploy version-7 readers before selecting writer 7. Version 7 retains optional
family-budget declarations on roots and typed quota outcomes; children cannot
override the root limits. Public agent and graph `start_with_budget` calls
enforce work, child and depth reservations across restarts. Initialization
creates/adopts the ledger and commits a root marker before any dispatch; an
initialized root with a missing ledger refuses recovery. Retention projection
version 3 introduced marker validation and attaches the ledger with matching
limits. The current retention projection is version 11; it also understands graph
job waits, owned cancellation, signal/job/child/fork deadlines and every retained
fork member. Run `refresh_retention` for existing
rows before they can be pruned by the current projection.

Graph records now write version 14 and read versions 5–14. Version 7 adds a retained
read-only job wait. Explicit `graph.poll_job` records its checked outcome;
canceling the wait detaches observation without canceling remote work. Deploy
version-14 graph readers before writing new records. Version 8 retains optional
polling intervals, including completed activation history. Missing intervals in
older records mean manual observation. Scheduled intervals cannot be hidden in
older record versions. PostgreSQL schema version 4 indexes scheduled polls along
with dependencies. Version 9 retains owned jobs and their fenced cancellation
requests. Accepted, refused and uncertain requests remain retained until an
authoritative observation settles the job. They share the poll index without
a new schema migration. Version 10 retains signal deadline configuration,
arming, absolute due times and expiration outcomes. Version 11 adds job deadlines
and records expiration separately from stop progress and terminal evidence.
Version 12 adds managed-child deadlines and retains expiration through uncertain
child settlement. Version 13 adds retained fork scopes, ordered member results
and reciprocal branch attachments. Version 14 adds fork deadlines, including
preparation, join acceptance and retained cleanup. These cannot be hidden in
older record versions. The current discovery projection is version 10 and schema version is 6.
Schema migration 5 adds absolute due waits; migration 6 indexes every unfinished
fork member. Run `refresh_discovery` to refresh existing metadata. Deadline
contracts and due times cannot be hidden in older record versions.

Existing values and runners retain their setting. The setting affects
future writes only: it neither rewrites rows nor makes an existing
newer row readable by an old reader. Rolling back after newer-format writes
therefore needs a separate migration plan.

The compatibility tests use the actual historical version-2 decoder.
They establish record-format compatibility; every participating runtime
must also support the same backend and lease protocol. Lease columns are
unchanged. A child cancelled before it starts uses version 2's empty,
cancelled record; the current reader restores its `never_started` meaning.
A state that cannot retain its meaning in version 2 fails before writing.

## Settings

- **`settings(connection, node:)`**: the node id names this VM among every VM
  that shares the database. It must be unique to the VM and the same after
  the VM restarts: a host name, or a pod's stable name (a StatefulSet
  ordinal, say), 1 to 128 letters, digits, and `.`, `_`, `-`, `@` or `:`.
  Never `nonode@nohost`, the name of every undistributed VM. Two live VMs
  given one node id could take each other's runs over.
- **`with_lease(settings, milliseconds)`**: how long a run stays with this
  node after its last renewal (default 30 000 ms, at least 100, at most
  2^32 - 1; `store` checks it). The store renews its runners' leases every
  third of the lease and kills a runner it could not renew in time. A
  shorter lease lets another node take over a stopped node's runs sooner,
  at the cost of more renewals; the database's clock alone judges expiry
  (`clock_timestamp()`), so the nodes' clocks need not agree.
- **`with_schema(settings, schema)`**: keeps the tables in `schema` (default
  `public`), a plain lowercase identifier; `migrate` creates it if missing.

`store.now(runs)` reads UTC Unix milliseconds from PostgreSQL's
`clock_timestamp()`, using the same clock as leases and scheduled discovery.
This read changes no execution records, leases or scheduling metadata. Errors
propagate without using the caller's clock. No migration is needed for this
clock API. Signal and job deadlines use it when arming and when accepting a
result or recovering a wait. Managed-child deadlines use it before child start
and parent acceptance; retained cleanup does not depend on the clock afterward.

## Migrations

`migrate(settings)` creates the schema if missing, then applies each
numbered migration not yet applied, in one transaction, under a
transaction-scoped advisory lock per schema; each is recorded in
`fabric_schema_migrations`. It is idempotent and safe to call from every
node at boot. Migrations only move forward: a database a newer version of
this package migrated further is left as it is.

The same migrations are in `priv/migrations/` in cigogne's format, for an
application that applies its migrations with cigogne; they take the same
advisory lock.

## Schema

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

Every write is one conditional statement, committed on its own: an insert
that does nothing when the run exists, or an update whose `WHERE` clause
checks the revision and the lease condition together. A write that changes
nothing is read back to say why (`Conflict`, `LeaseRefused`, `NotFound`).
The statements are written for READ COMMITTED, PostgreSQL's default; under
a REPEATABLE READ or SERIALIZABLE default a write that fails to serialise
(40001, or a deadlock, 40P01) changed nothing and is read back or retried.
Any other failure, a lost connection included, is `Unavailable`, which
Fabric confirms by reading its write back.

## Pruning

`prune(settings, ended_for: ms, limit: n)` deletes up to `n` complete,
settled families, oldest first. A family follows saved parent attachments,
including hashed graph children, managed agents and delegated descendants.
Run names do not establish membership. Every member must have a current,
readable retention projection, a definite terminal outcome, no live lease,
and no record update within `ms`. Terminal uncertainty, missing children,
unreadable records, mismatched attachments and unacknowledged children retain
the whole family. A new settlement starts its member's retention interval
again. A child is never pruned alone.

Fabric's `fabric/retention` projection uses the actual agent and graph record
decoders. It includes each parent/child attachment and whether the run settled.
Attachment keys are escaped JSON text, so a provider call ID containing NUL
does not become a NUL in PostgreSQL's index. The original record remains
byte-for-byte text. Each backend write updates its projection and source
revision atomically. An older backend's write leaves a revision mismatch,
which refuses pruning until refreshed.

Schema migration 2 replaces the name-prefix index with these projections and
a parent foreign key. Apply migrations before starting the new backend. Existing
records initially have no projection and remain retained. Call
`refresh_retention(settings, limit: 100)` in bounded batches until it returns
zero. It changes no record bytes, revisions, leases or record timestamps.
The count includes unreadable records and missing-parent orphans; they receive
an unknown projection and remain retained. Concurrent refreshers skip rows
another refresher holds, so zero is local to that call. Normal record writes
and a later projection-version upgrade refresh metadata again.

Pruning runs as a serializable transaction with bounded retries. Concurrent
pruners lock different roots; concurrent member updates or lease renewals
force revalidation. The foreign key prevents a delayed child insert from
recreating an orphan after its parent is deleted. This uses PostgreSQL's
[serializable isolation](https://www.postgresql.org/docs/16/transaction-iso.html#XACT-SERIALIZABLE)
and [foreign key constraints](https://www.postgresql.org/docs/16/ddl-constraints.html#DDL-CONSTRAINTS-FK).
Pruning ends the family's durable replay window; do not reuse its IDs for
another execution that could receive old messages.
A connection lost during commit can leave the deletion count unknown. A later
prune remains safe, but cannot report how many rows that earlier call removed.

## Tests

The tests need PostgreSQL and run only through the script, which starts a
throwaway cluster (a fresh `initdb` in a temporary directory, 127.0.0.1, a
random free port, trust authentication, removed on exit) and never reads
any `PG*` variable:

```sh
nix develop   # provides PostgreSQL 16
integrations/fabric_postgres/scripts/test-postgres.sh
```

Run without the script, `gleam test` fails, since `FABRIC_TEST_DATABASE_URL`
is unset. Fabric's own gate (the root package, `nix flake check`, CI) does
not run these tests and needs no PostgreSQL. The suite includes an isolated
Erlang VM killed with SIGKILL to verify automatic recovery without tool replay.

## Idle dependency, scheduled-job and deadline discovery

Schema version 3 introduced Fabric's validated discovery projection beside each
execution, maintained atomically on normal writes. `claim_ready` leases
a free wait and records its dependency revisions in one statement. Child changes
during recovery remain eligible for a later scan. These claims change neither
execution revisions nor retention ages. Concurrent scans skip locked rows and
check the least recently inspected waits first.

After migration, call `refresh_discovery(settings, limit: 100)` in bounded
batches until it returns zero. This refresh preserves record bytes, revisions,
leases and ages. Unknown or corrupt records are examined once per projection
version and never become scheduling candidates. Old backend writes invalidate
the source revision; refresh those rows before relying on automatic discovery.
Concurrent refreshers skip rows locked by others, so zero is local to that call.

Schema version 4 expands the discovery index to include scheduled job waits.
`job.with_poll_interval(observer, milliseconds)` saves the interval in the graph
contract. The first ready claim is immediately eligible. Each claim saves the
key and `discovery_checked_at` with its lease; further ready claims wait until
that timestamp plus the interval, using `clock_timestamp()`. Same-key record
writes and metadata refresh preserve this timestamp. A new activation is
eligible independently. Scans may be later than the due time under load.

Schema version 5 includes signal waits with an absolute due time. A ready claim
requires database time at or beyond that timestamp. Claims do not consume the
deadline: recovery validates the definition and samples time again before
committing expiration. If a clock correction makes the wait early again,
recovery releases the lease while retaining its original due time. It remains
discoverable when time reaches the deadline. Expiration records no accepted
signal value or successor route; completed signal deadlines can be pruned with
their settled family. Reads alone do not expire waits.

Discovery projection 6 combines a job's polling interval with its optional
absolute deadline. Either condition makes it eligible under the existing
schema-5 index. Manual jobs with deadlines use only absolute eligibility.
Expiration of an owned job retains its stop cause and cleanup progress; that
cleanup uses a separate polling key with no deadline, so the expired timestamp
cannot cause repeated immediate polls. Pending cleanup prevents family pruning.
Refresh both discovery and retention metadata after upgrading these projections.

Discovery projection 7 also combines a child dependency with its optional deadline.
An unchanged child can therefore expire after the parent restarts. Uncertain
expiration switches to dependency-only settlement; reconciliation makes the
parent eligible again. Registered discovery follows retained nested cleanup,
without recreating missing children or reopening parent routes. Retention
projection 9 preserves child links and refuses to prune unresolved expiration.

Discovery projection 9 and schema version 6 extend dependency waits to every
unfinished fork member. A claim records a map from child identity to revision;
a missing child has a null revision, so creation, change or disappearance can
make the parent eligible. A claim does not authorize recreating a missing
acknowledged child. Unchanged waits stop being eligible until a dependency or
deadline changes. Nested recovery preserves live foreign parent leases while
following independently expired descendants.

Stop older backend writers before applying migration 6: it replaces the scalar
`dependency_id` and `observed_revision` columns with `dependency_ids` and
`observed_dependencies`. Migrate, deploy the compatible backend, then run
`refresh_discovery` in bounded batches before relying on idle discovery.
The migration leaves record bytes, revisions, leases, retention ages and
scheduled-poll observation times intact. Stale projections remain ineligible
until refreshed; dependency waits receive a fresh baseline observation.

Discovery projection 10 adds fork deadlines to those dependency waits. A changed
member or the absolute deadline makes a joining scope eligible; after expiration,
cleanup uses member changes alone. Failed join acceptance remains eligible at
its retained deadline. Nested cleanup survives loss of both the original store
and its recovery store, and unresolved effects prevent pruning until reconciled.
Those fork-deadline changes need no schema migration beyond 6. Refresh discovery and retention metadata
after deploying graph-version-14 readers.

Register the graph with the shared sweeper. Only a claimed job is observed;
recovery does not poll unclaimed relatives. Pending reads release their lease.
Failed callbacks keep a lease-expiry retry path; completion uses the normal
conditional route commit. Manual, canceled and completed job waits are excluded.

Discovery provides a reason to inspect a run. Registered recovery still checks
the saved attachments, compatible definitions, effect policy and ownership
before it can execute any work.

## Readiness and operational statistics

`store.readiness(runs)` performs a bounded storage read and reports the store's
current acceptance status, local runner count and lease renewal age. A fresh or
idle store can be ready before any renewal. A working store requires a safe
lease window for each runner, initially established by its committed claim.
Draining stores do not report `Accepting`. A backend failure is an error.

`fabric_postgres.stats(settings)` reads one database snapshot with one clock
sample. It returns working, unattended, waiting and finished run groups;
approval and reconciliation groups; unknown records; budget-record count;
live leases per node; and expired leases with the oldest overdue age.

Run groups count individual records, including children. Approval and
reconciliation groups can overlap the main groups. They describe each record's
own evidence, without duplicating child requests onto ancestors. Reconciliation
includes uncertain effects retained by ended agents; those require external
resolution, rather than restarting a finished agent. Signal, job and managed
child waits are not automatically unattended work.

`oldest_record_age_ms` measures time since the latest durable record write, not
the duration of an approval request or workflow. `oldest_overdue_ms` measures
time since the oldest lease expired. Empty groups have no oldest age. Neither
query claims, renews, writes or recovers work.

Schema migration 7 adds a diagnostic projection and its source revision. New
writes maintain both atomically. After migration or a projection upgrade, run
`refresh_statistics(settings, limit: 100)` in bounded batches until zero.
Refresh preserves record bytes, revisions, leases and record ages. Stale,
unsupported, corrupt and mismatched records count as unknown; they never become
healthy zeroes. Unreadable records are examined once per projection version.

See the core [operations contract](../../docs/implementation/production-readiness/operations.md)
for classification and timestamp semantics. Shutdown summaries and the complete
operations runbook remain under development.

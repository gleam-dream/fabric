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

Build one `Recovery` per root agent. Its context function receives the
root run id, including when an expired child triggered the scan:

```gleam
let recoveries = [fabric.recovery(root_agent, context_for_run)]
let assert Ok(sweeper) = fabric.sweeper(runs, recoveries, every: 1000)
```

Add `sweeper` after `store.supervised(runs)` in the rest-for-one supervisor.
The order is pool, optional Sinal forwarder, store, sweeper. Shutdown stops
the sweeper before runners drain and keeps the pool available until their
handoffs are committed. Apply migrations before enabling recovery; a scan
against an unmigrated database reports a failure and retries next interval.

A scan runs at boot, then after each interval. It claims at most 100 expired
leases and never overlaps the next scan. Each root's recovery has 30 seconds,
including at most 5 seconds to rebuild context. Invalid intervals, duplicate
root identities, and unleased stores are rejected before startup. Unknown
identities and failed recoveries leave their claims to expire; observe
`fabric/observation.sweep()` for counts. No run context is stored by Fabric.

Only expired leases are discoverable, so an automatic scan waits for expiry
even after this store restarts. Explicit `fabric.recover` with a known run id
can take over a prior local store process's lease immediately. Running tools
become uncertain after a crash and are never replayed; reconcile their
outcomes before the run continues. Family members have independent leases:
a live parent keeps its context and reads a remotely recovered child's
committed outcome.

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
  root_id text GENERATED ALWAYS AS (substring(run_id from '^run-[0-9a-f]+')) STORED,
  lease_owner text, lease_until timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK ((lease_owner IS NULL) = (lease_until IS NULL)));
-- indexes: expired leases, ended runs by age, families by root
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

`prune(settings, ended_for: ms, limit: n)` deletes up to `n` finished
families: a root run that ended at least `ms` ago, with every sub-agent
run of its family, only when all of them ended (or never started) and none
holds a live lease. An ended sub-agent run is never deleted on its own,
since recovering its parent would start it again. Run it periodically from
any node; concurrent calls delete each family once.

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

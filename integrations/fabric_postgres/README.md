# fabric_postgres

Stores [Fabric](../../README.md) runs in PostgreSQL and coordinates their leases
across Erlang nodes. It borrows the application's `pog.Connection`.

## Installation

For the current checkout, add this directory as a path dependency in your
application's `gleam.toml`. For an application beside the Fabric checkout:

```toml
[dependencies]
fabric_postgres = { path = "../fabric/integrations/fabric_postgres" }
```

The package targets Erlang, requires Gleam 1.18 or later, and is tested against
PostgreSQL 16. Its pog 4.1 and pgo 0.20 ranges match Grind's shared-pool requirements.

## Setup

The application owns the pool. Start it before the store and keep it available
until the store's runners have drained. This setup uses rest-for-one supervision
to preserve that order:

```gleam
import fabric/store
import fabric_postgres
import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/time/duration
import pog

pub fn start(database_url: String, node: String) -> store.Store {
  let pool = process.new_name("db")
  let assert Ok(config) = pog.url_config(pool, database_url)
  let settings =
    fabric_postgres.settings(pog.named_connection(pool), node:)
    |> fabric_postgres.with_lease(duration.seconds(30))
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

Apply migrations after the pool starts and before admitting runs or enabling
recovery. `migrate` applies forward steps atomically and serializes callers per
schema; repeating it after a lost acknowledgement is safe.

Settings default to schema `public` and a 30-second lease. Every live VM sharing
the database must have a unique stable node id. Fabric renews leases every third
of their duration and self-fences runners after lost renewal. See
[settings and migrations](USAGE.md#settings-and-migrations) for accepted values
and schema privileges.

## Automatic recovery

Register complete root definitions with Fabric's sweeper:

```gleam
let roots = [sweeper.agent(root_agent, context: context_for_run)]
let assert Ok(subtree) =
  sweeper.supervised(runs, roots, every: duration.seconds(1))
```

Use this subtree in place of `store.supervised(runs)`, after the pool and optional
Sinal forwarder. Shutdown stops the sweeper before runners drain. For graph
roots, register `sweeper.graph(identity, build: build_runtime)` and rebuild all
managed runtimes against the supplied store.

An agent root factory receives the root run id even when an expired child led
to discovery. Context is rebuilt live and is never stored. Tools with uncertain
outcomes after a crash require reconciliation; they are not replayed implicitly.
A live parent and an expired child retain independent leases.

## Record versions

Agent readers accept versions 1–7; writers support 2–7 and default to 7. Graph
readers accept 5–15 and write 15. Deploy compatible readers before enabling a
newer writer or capability.

Configure the returned store value before starting it and use that value for
every handle and sweeper. To select agent writer 3:

```gleam
let assert Ok(runs) =
  fabric_postgres.store(process.new_name("runs"), settings)
let assert Ok(runs) = store.with_record_version(runs, 3)
```

Writer selection changes future agent writes; it neither rewrites rows nor
downgrades graph records. See [upgrade procedures](USAGE.md#upgrades-and-metadata-refresh)
and the [compatibility contract](docs/design/design.typ#schema-and-record-compatibility).

## Pruning

`prune(settings, ended_for: age, limit: n)` deletes at most `n` complete settled
root families and returns the total deleted row count, including descendants
and budget ledgers. Every member must have current readable retention metadata,
reciprocal membership, sufficient age, definite settlement and no live lease.
Uncertain outcomes retain the whole family.

Pruning ends the family's replay window; never reuse its ids for another run.
A lost commit reply can leave the deleted count unknown. See
[pruning details](USAGE.md#pruning) for concurrency and refresh requirements.

## Idle dependency, scheduled-job and deadline discovery

The sweeper discovers expired leases and free waits with changed dependencies,
due polls or absolute deadlines. Claims supply a reason to inspect a run;
recovery still validates definitions and reciprocal attachments. Database time
judges eligibility, so clock corrections can advance or delay due work.

Stop older backend writers before schema migration 6, which replaces scalar
dependency columns. Migrate, deploy compatible backends, then refresh metadata
before relying on discovery or pruning. See
[discovery and upgrades](USAGE.md#discovery) for polling and deadline behavior.

## Development

From the parent Fabric repository, run the disposable database harness:

```sh
nix develop -c integrations/fabric_postgres/scripts/test-postgres.sh
```

The harness creates and removes a private PostgreSQL cluster. Direct `gleam test`
fails without its test URL. The cluster disables `fsync` and `synchronous_commit`;
these tests do not establish production power-loss durability.

[Usage and maintenance](USAGE.md) covers metadata refresh, diagnostics and the
schema. The [operations runbook](../../docs/OPERATIONS.md) covers startup,
readiness, recovery and shutdown. The [design](docs/design/design.typ),
[rendered design](docs/design/design-layer.pdf), [vocabulary](docs/design/CONTEXT.typ),
[coverage](docs/COVERAGE.md) and [ADRs](docs/adr/) describe the storage contracts.

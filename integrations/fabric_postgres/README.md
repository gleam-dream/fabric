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

<!-- prettier-ignore-start -->

<!-- snips: test/fabric_postgres/readme_example.gleam#setup -->
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

<!-- prettier-ignore-end -->

Apply migrations after the pool starts and before admitting runs or enabling
recovery. `migrate` applies forward steps atomically and serializes callers per
schema; repeating it after a lost acknowledgement is safe.

Settings default to schema `public` and a 30-second lease. Every live VM sharing
the database must have a unique stable node id of 1–128 ASCII letters, digits or
`.`, `_`, `-`, `@` and `:`; `nonode@nohost` is refused. `with_lease` accepts 100 ms
to 2^32 − 1 ms, and Fabric renews every third of the lease and self-fences
runners after lost renewal. `with_schema` accepts 1–63 lowercase letters, digits
or underscores with no initial digit. `migrate` creates a missing schema, and
precreating it avoids needing the database CREATE privilege. It records applied
steps in `fabric_schema_migrations` under a schema-specific advisory lock, and a
schema already migrated further by a newer adapter stays unchanged. The same
statements are available as [cigogne migrations](priv/migrations/).

## Automatic recovery

Register complete root definitions with Fabric's sweeper. This integration-test
excerpt uses a 25-millisecond interval and a `Nil` context; choose the interval
and context factory for your application:

<!-- prettier-ignore-start -->

<!-- snips: test/fabric_postgres/peer_test.gleam#automatic-recovery -->
```gleam
let assert Ok(subtree) =
  sweeper.supervised(
    runs,
    [sweeper.agent(agent, fn(_) { Nil })],
    every: duration.milliseconds(25),
  )
```

<!-- prettier-ignore-end -->

Use this subtree in place of `store.supervised(runs)`, after the pool and optional
Sinal forwarder. Shutdown stops the sweeper before runners drain. For graph
roots, register `sweeper.graph(identity, build: build_runtime)` and rebuild all
managed runtimes against the supplied store.

An agent root factory receives the root run id even when an expired child led
to discovery. Context is rebuilt live and is never stored. Tools with uncertain
outcomes after a crash require reconciliation; they are not replayed implicitly.
A live parent and an expired child retain independent leases.

## Record versions

Agent readers accept versions 1–8; writers support 2–8 and default to 8. Imported
initial history requires version 8; older writers refuse it before admission. Graph
readers accept 5–15 and write 15. Deploy compatible readers before enabling a
newer writer or capability.

Configure the returned store value before starting it and use that value for
every handle and sweeper. To select agent writer 2:

<!-- prettier-ignore-start -->

<!-- snips: test/fabric_postgres/fabric_run_test.gleam#record-version -->
```gleam
let assert Ok(old_writes) =
  fabric_postgres.store(process.new_name("old-writes"), settings)
let assert Ok(old_writes) = store.with_record_version(old_writes, 2)
```

<!-- prettier-ignore-end -->

Writer selection changes future agent writes; it neither rewrites rows nor
downgrades graph records. Older writers refuse states they cannot represent before
changing the record, and downgrading after newer writes needs a separate migration
plan. The [design](docs/design/design-layer.pdf) states the compatibility contract.

## Pruning

`prune(settings, ended_for: age, limit: n)` deletes at most `n` complete settled
root families and returns the total deleted row count, including descendants
and budget ledgers. Every member must have current readable retention metadata,
reciprocal membership, sufficient age, definite settlement and no live lease.
Uncertain outcomes retain the whole family.

Pruning ends the family's replay window; never reuse its ids for another run.
A lost commit reply can leave the deleted count unknown, and repeating `prune`
is safe. Pruning runs in serializable transactions with finite retries, so
concurrent writes force revalidation.

## Idle dependency, scheduled-job and deadline discovery

The sweeper discovers expired leases and free waits with changed dependencies,
due polls or absolute deadlines. Claims supply a reason to inspect a run;
recovery still validates definitions and reciprocal attachments. Database time
judges eligibility, so clock corrections can advance or delay due work.

Stop older backend writers before schema migration 6, which replaces scalar
dependency columns. Migrate, deploy compatible backends, then refresh metadata
before relying on discovery or pruning. Scheduled polls are first eligible
immediately and later claims wait at least the saved interval; an absolute
deadline stays retained after a claim.

## Maintenance

After an upgrade, call `refresh_retention`, `refresh_discovery` and
`refresh_statistics` with `limit: 100` until each returns zero. Refresh preserves
exact record bytes, revisions, leases and record ages, and concurrent refreshers
skip locked rows, so a zero describes that call only. Counts include examined
unknown records.

`stats(settings)` reads one diagnostic snapshot without refreshing, claiming or
changing records, and `store.now(runs)` reads database UTC milliseconds, the clock
that lease, deadline and scheduled eligibility use. `store.readiness(runs)`
separately checks storage reachability, admission and local runner lease safety.
The application owns pool capacity and maintenance-call bounds, and the backend
timeout bounds only a worker wait.

## Examples

Each usage topic is a compiled test that the disposable-cluster harness below
runs, so a changed signature fails the gate.

| Topic                                                 | Example                                                                                                                                                                                                 |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Settings, pool, start, run and recover                | [`readme_example.gleam`](test/fabric_postgres/readme_example.gleam), run by [`readme_test.gleam`](test/fabric_postgres/readme_test.gleam)                                                               |
| Migration, schemas and the cigogne files              | [`migrate_test.gleam`](test/fabric_postgres/migrate_test.gleam)                                                                                                                                         |
| Pruning finished run families                         | [`prune_test.gleam`](test/fabric_postgres/prune_test.gleam)                                                                                                                                             |
| Idle dependency, scheduled-job and deadline discovery | [`discovery_test.gleam`](test/fabric_postgres/discovery_test.gleam)                                                                                                                                     |
| Diagnostics, readiness and backend time               | [`statistics_test.gleam`](test/fabric_postgres/statistics_test.gleam), [`readiness_test.gleam`](test/fabric_postgres/readiness_test.gleam), [`clock_test.gleam`](test/fabric_postgres/clock_test.gleam) |
| Record versions and historical records                | [`record_test.gleam`](test/fabric_postgres/record_test.gleam), [`history_test.gleam`](test/fabric_postgres/history_test.gleam)                                                                          |

## Development

From the parent Fabric repository, run the disposable database harness:

```sh
nix develop -c integrations/fabric_postgres/scripts/test-postgres.sh
```

The harness creates and removes a private PostgreSQL cluster. Direct `gleam test`
fails without its test URL. The cluster disables `fsync` and `synchronous_commit`;
these tests do not establish production power-loss durability.

The [design](docs/design/design-layer.pdf), [vocabulary](docs/design/design-layer.pdf),
[coverage](docs/COVERAGE.md) and [ADRs](docs/adr/) describe the storage contracts,
and the parent Fabric design layer describes startup, readiness, recovery and
shutdown.

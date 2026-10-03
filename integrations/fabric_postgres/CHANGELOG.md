# Changelog

All notable changes to `fabric_postgres` are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
package uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Changed

- **Breaking:** `with_lease` takes a `Duration` (default 30 s) and `prune`'s
  `ended_for` is a `Duration`; `PruneAgeNegative` carries it.

### Added

- A leased PostgreSQL backend for Fabric runs (`fabric_postgres.store`,
  `backend`) over the application's own `pog.Connection`, with
  revision- and lease-checked writes judged by the database clock.
- Forward-only, idempotent migrations (`migrate`) in a configurable schema
  (`with_schema`).
- Family-aware retention (`prune`), database-wide diagnostic snapshots
  (`stats`, `fabric_postgres/statistics`), and refreshes of the retention,
  discovery and statistics projections after a migration.
- Tests that `string.inspect` of settings, a backend, a store and a
  migration failure never prints the pool's password.

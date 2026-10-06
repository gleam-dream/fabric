# Changelog

## Unreleased

### Added

- Leased PostgreSQL storage for Fabric records over an application-owned
  `pog.Connection`, with exact-byte reads, revision/lease conditional commits,
  database time, lease renewal and expired/ready claims.
- Configurable schema and forward, advisory-locked migrations, with equivalent
  retained cigogne SQL.
- Complete-family pruning, versioned retention/discovery/statistics projections
  and bounded metadata refresh without changing execution evidence.
- Database-wide diagnostic snapshots and disposable PostgreSQL tests covering
  concurrency, restart, cleanup, compatibility and credential-safe inspection.
- Native adapter design, canonical vocabulary, coverage and concise decision
  records. [ADR 0006](docs/adr/0006-consolidate-design-and-retain-executable-evidence.md)
  preserves unpublished API-history provenance.

### Changed

- Lease and pruning ages use `Duration`. The backend/projection port is under
  `fabric/store`; automatic recovery uses `fabric/sweeper` registrations.
- Standing architecture and format contracts live in the native layer; README
  retains compiled setup, maintenance procedures and operational links.

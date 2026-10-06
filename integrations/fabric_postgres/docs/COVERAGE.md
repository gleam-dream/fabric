# Fabric PostgreSQL design coverage

- One persistence context owns this nested package. Parent Fabric owns run,
  controller, attachment and family meaning; this layer captures storage
  construction, mutation authority and maintenance behavior.
- Every listed part exists in the inspected nested checkout. Captured rows name
  their design owner; standard infrastructure carries its reason.

| Part                                                                                                                    | Status       | Design owner or reason                                                                                     |
| ----------------------------------------------------------------------------------------------------------------------- | ------------ | ---------------------------------------------------------------------------------------------------------- |
| `src/fabric_postgres.gleam`: settings, schema validation, store/backend values                                          | captured     | [Construction and pool lifetime](design/design.typ#construction-and-pool-lifetime)                         |
| `src/fabric_postgres/internal/backend.gleam`: reads, insert, CAS and error classification                               | captured     | [Conditional storage and effect timing](design/design.typ#conditional-storage-and-effect-timing)           |
| `src/fabric_postgres/internal/backend.gleam`: clock, renewal and expired claims                                         | captured     | [Lease renewal and backend time](design/design.typ#lease-renewal-and-backend-time)                         |
| `src/fabric_postgres/internal/backend.gleam`: ready claims and observation persistence                                  | captured     | [Ready discovery and recovery](design/design.typ#ready-discovery-and-recovery)                             |
| `src/fabric_postgres/internal/retention.gleam`: refresh and orphan handling                                             | captured     | [Projection maintenance](design/design.typ#projection-maintenance)                                         |
| `src/fabric_postgres/internal/retention.gleam`: serializable family deletion                                            | captured     | [Family closure and pruning](design/design.typ#family-closure-and-pruning)                                 |
| `src/fabric_postgres/internal/discovery.gleam`                                                                          | captured     | [Projection maintenance](design/design.typ#projection-maintenance)                                         |
| `src/fabric_postgres/statistics.gleam` and `internal/statistics.gleam`                                                  | captured     | [Diagnostic snapshots](design/design.typ#diagnostic-snapshots)                                             |
| `src/fabric_postgres/internal/migrations.gleam`, `priv/migrations/*.sql`, `priv/cigogne.toml`                           | captured     | [Schema and record compatibility](design/design.typ#schema-and-record-compatibility)                       |
| `test/fabric_postgres`: conformance, byte/readback, migration, isolation, nodes, refresh/prune and statistics scenarios | captured     | [Verification and operating limits](design/design.typ#verification-and-operating-limits)                   |
| `test/fabric_postgres`: graph/agent restart, child/fork, deadlines, readiness/clock and writer compatibility scenarios  | captured     | [Verification and operating limits](design/design.typ#verification-and-operating-limits)                   |
| `test/fabric_postgres/readme_example.gleam`, README equality test and test support/FFI                                  | captured     | [Verification and operating limits](design/design.typ#verification-and-operating-limits)                   |
| `scripts/test-postgres.sh`                                                                                              | captured     | [Verification and operating limits](design/design.typ#verification-and-operating-limits)                   |
| `gleam.toml`: target, supported toolchain and aligned pog/pgo ranges                                                    | captured     | [Verification and operating limits](design/design.typ#verification-and-operating-limits)                   |
| `manifest.toml`, conventional test entry point                                                                          | standard     | Generated dependency resolution and gleeunit entry wiring; behavior belongs to captured scenarios.         |
| Parent flake/dev shell/runtime gate and tracker                                                                         | standard     | This package borrows the parent infrastructure; no independent flake, tracker or runtime CI is introduced. |
| README, CHANGELOG, AGENTS and native documentation                                                                      | out-of-scope | Usage, current changes and instructions are documentation surfaces rather than another runtime subsystem.  |

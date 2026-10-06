# Preserve exact conditional-write and database lease evidence

<a id="adr-0002"></a>

- A record is exact text with a positive expected revision. One autocommitted
  conditional statement advances the revision and applies its lease condition.
  PostgreSQL JSON normalization would destroy the byte evidence Fabric uses to
  confirm a write after acknowledgement loss.
- Derive the phase in Gleam rather than through PostgreSQL execution-record JSON
  parsing. PostgreSQL JSON conversion rejects escaped NUL that is valid inside
  retained model/tool data. Metadata uses safe escaped attachment-key text;
  original record text remains separate.
- Leases select the live driver, while revisions serialize replacement. Hold
  accepts the same owner even after expiry; renewal accepts only live leases.
  An expired handoff therefore cannot be revived by a delayed renewal. The
  adapter's backend time is the database clock, while Fabric owns local
  monotonic self-fencing and stopped-runner cleanup.
- READ COMMITTED is the statement baseline. Recognized serialization/deadlock
  failures permit finite readback/retry because the statement changed nothing.
  Other operational failures remain Unavailable; replaying every failed write
  would erase its unknown-outcome distinction.
- Evidence: production-plan S3/S4 and focused renewal correction at Fabric
  [23cb7c3](https://github.com/gleam-dream/fabric/commit/23cb7c3), current
  `internal/backend.gleam`, `record_test`, `isolation_test`, `nodes_test` and
  `fabric_run_test`. Genuine byte/readback and blocked-writer tests retain the
  actual predicates. Original aggregate decision date is unknown.

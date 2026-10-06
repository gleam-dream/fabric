# Read diagnostics as one observation without granting execution authority

<a id="adr-0004"></a>

- Statistics uses one MVCC read and one materialized backend clock sample.
  Combining independent clock samples or automatically refreshing while reading
  would make group comparisons inconsistent and turn observation into maintenance.
- Run groups count individual records including children. Intervention flags
  describe each record's own evidence and may overlap execution groups; copying
  child requests onto every ancestor would inflate operator counts.
- Budget records are counted separately. Stale, corrupt, unsupported or misfiled
  interpretations remain unknown rather than healthy zero. Ended uncertain
  agents still require external reconciliation and are not candidates to restart
  business work.
- Ages mean time since the last record write or time overdue on the oldest
  expired lease. They do not mean duration in the current phase. Empty groups
  have absent ages, and read failures return StatsFailed rather than an empty
  snapshot.
- Evidence: schema migration 7, `src/fabric_postgres/statistics.gleam`,
  `internal/statistics.gleam`, parent diagnostic projection and
  `statistics_test` at
  [baseline revision](https://github.com/gleam-dream/fabric/tree/ab678abe3b49b2d8dedc8b63845c35a60e6f918f/integrations/fabric_postgres).
  Parent operations semantics remain in its native layer and runbook.
  An original acceptance date or broader load/availability claim is not supplied
  by this evidence.

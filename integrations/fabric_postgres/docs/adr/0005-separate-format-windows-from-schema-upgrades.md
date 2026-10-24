# Separate record writer compatibility from schema and projection upgrades

<a id="adr-0005"></a>

- Agent writer selection changes future encoded agent records only. It does not
  rewrite existing rows, downgrade graph envelopes or make newer data readable
  by an older runtime. Reader rollout precedes enabling a capability requiring a
  newer retained representation.
- Older writers refuse states whose meaning they cannot preserve before storing
  a changed result or releasing dependent work. Actual historical v2 decoding
  tests establish compatible writes; round-tripping through the current decoder
  would prove a different property.
- Provider data, tagged graph parents, child settlement and root budgets have
  independent agent-version minima. Graph job ownership, polling, wait/fork
  deadlines, correlation and approval history belong to the graph envelope.
  Missing optional historical deadlines remain absent rather than gaining a
  current default on read.
- Schema migration and metadata refresh do not change encoded execution bytes.
  Migration 6 replaces scalar dependency columns, so older backend writers must
  stop before it; migrate/deploy/refresh precede relying on new idle discovery.
  A downgrade after newer writes requires a separately designed migration.
- Evidence: parent record fixtures and native compatibility unit, adapter
  `fabric_run_test`, `discovery_test`, migrations and retained version section at
  [baseline revision](https://github.com/gleam-dream/fabric/blob/ab678abe3b49b2d8dedc8b63845c35a60e6f918f/integrations/fabric_postgres/README.md).
  The historical rollout prose described accumulated unreleased construction,
  not published-version migration support. Individual original dates are unknown.

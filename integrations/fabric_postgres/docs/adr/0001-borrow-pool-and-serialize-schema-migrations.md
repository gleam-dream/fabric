# Borrow the application's pool and serialize forward schema migration

<a id="adr-0001"></a>

- The adapter borrows `pog.Connection`; the application owns pool settings,
  supervision, checkout capacity and shutdown. A separate package keeps pog out
  of Fabric core. Creating another adapter-owned pool would prevent ordinary
  shared-pool composition and introduce a second resource lifetime.
- The pool precedes the store or store/sweeper subtree in rest-for-one order.
  The store drains before the pool stops. Migration and required metadata refresh
  form an application startup barrier before recovery and admission.
- Schema names are checked lowercase identifiers before SQL construction.
  Runtime migration applies forward numbered steps in one transaction under a
  schema-specific advisory lock, with READ COMMITTED visibility after waiting.
  A newer recorded schema is left unchanged rather than implicitly downgraded.
- Applications may instead apply the exact retained cigogne up statements.
  Cigogne down statements are explicit application tooling, not an automatic
  runtime downgrade contract. Append new migrations rather than editing released
  steps.
- Evidence: Fabric production-plan S4 retained at
  [baseline revision](https://github.com/gleam-dream/fabric/blob/ab678abe3b49b2d8dedc8b63845c35a60e6f918f/docs/PLAN.md),
  adapter `src/fabric_postgres.gleam`, internal migration definitions,
  `priv/migrations`, `migrate_test` and compiled `readme_example`.
  The original separate-package/pool rationale is explicit there; no single
  original acceptance date is inferred from the accumulated plan.

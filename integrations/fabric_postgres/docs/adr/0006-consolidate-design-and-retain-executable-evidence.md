# Consolidate adapter design while retaining executable and historical evidence

<a id="adr-0006"></a>

- Under the user's documentation-migration authorization on 6 October 2026,
  standing adapter architecture moves from the long README into one native
  PostgreSQL design context, canonical glossary and coverage map. Material
  rationale has concise ADR homes; usage and maintenance procedures remain in
  README and the parent operations runbook.
- The adapter CHANGELOG contains only Unreleased notes. Its unpublished wave
  names are replaced by current capabilities; package version stays unchanged.
  Exact source, SQL, fixture, example and FFI blocks remain evidence. The first
  README example remains byte-identical to its compiled test module.
- Earlier Oversight release review proposed a `config` constructor and a single
  adapter Error. Current inspected source instead exposes opaque Settings,
  schema/store validation and operation-specific maintenance errors. The old
  proposal is not a supported alias or accepted runtime rewrite.
- Round 9 retained the two PostgreSQL adapters while retiring Fabric bridge
  packages. This adapter borrows a compatible shared pog/pgo pool without
  importing Grind or a universal durability abstraction. Parent Fabric ADRs own
  graph, agent and external-effect semantics.
- Evidence: Fabric
  [baseline](https://github.com/gleam-dream/fabric/tree/ab678abe3b49b2d8dedc8b63845c35a60e6f918f/integrations/fabric_postgres)
  and Oversight release review/decisions/plan at
  [3baff7030a96d5b6cf78b2335c16d8c203727da5](https://github.com/gleam-dream/oversight/tree/3baff7030a96d5b6cf78b2335c16d8c203727da5/docs/release-api).
  Research/type experiments are not database oracles. The disposable database
  harness disables fsync and synchronous_commit, so its retained tests do not
  establish power-loss durability. This migration changes no runtime behavior,
  API, schema, encoded records or published history.

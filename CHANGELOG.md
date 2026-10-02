# Changelog

All notable changes to `fabric` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The optional
integration packages under `integrations/` keep their own changelogs.

## Unreleased

### Added

- Bounded agent runs (`fabric`, `fabric/agent`): typed tools, an explicit
  policy gate, turn and timer limits, shared work, child and depth budgets,
  and approval-gated sub-agents.
- Durable runs over a named, supervisable store (`fabric/store`): pause,
  approval, resume, cancellation, restart recovery, drained shutdown and a
  leased store contract for several nodes sharing one database, with an
  in-memory backend and conformance checks (`fabric/testing`).
- Agentic graphs (`fabric/graph`): typed operations, conditional routing,
  bounded cycles, durable signals, external jobs, managed subgraphs and
  agents, typed parallel pairs and bounded maps, deadlines that survive
  restart, and family retention.
- Model adapters over llm_wire: `fabric/llm` for agent turns and
  `fabric/graph/llm` for one structured decision per graph activity.
- Sinal observations of runs and graphs (`fabric/observation`).
- A test that `string.inspect` of a model from `fabric/llm` and of an
  operation from `fabric/graph/llm` never prints the provider key held in
  their llm_wire settings.

### Fixed

- The README no longer says the suite skips PostgreSQL:
  `scripts/check.py full` runs the `fabric_postgres` gate.

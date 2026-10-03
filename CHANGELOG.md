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

### Changed

- Fabric and its packages build on the wave 3 APIs of HTTP Gun and Saga.
  The tests play cassettes with `http_gun/testing.playback`, and
  `test/fixtures/llm/hello.json` is converted to HTTP Gun's cassette schema
  2 with every header and byte unchanged.
- **Breaking:** `fabric_saga.tool` returns the tool instead of a `Result`.
  Saga no longer validates a configuration ahead of a run: a configuration
  it refuses fails the call definitely, naming every violation, before any
  step runs.
- `fabric_saga` reports an attempt that returned an error its step marks
  with `saga.unknown_when` (`ActionReturnedUnknown`) as an uncertain effect,
  never a definite failure: a refund the provider may have taken waits for
  reconciliation instead of reaching the model as a failure it could retry.
- `fabric/graph/llm` and `fabric_mcp` derive their codec placeholders with
  json_blueprint's `codec.placeholder`; `fabric_mcp` no longer decodes `nil`
  to obtain one. Stored receipts are unchanged.
- Fabric builds on the wave 2 APIs of Sinal and json_blueprint. Events are
  emitted with `sinal.emit`, which follows the application's forwarder
  routes as `forwarder.emit_routed` did; the event names and metadata keys
  are unchanged.
- **Breaking:** `fabric/graph/fork.result_codec` returns the codec, not a
  `Result`: json_blueprint's union builder has no construction error. The
  JSON (`{"tag": "ok" | "error", "value": ...}`) is unchanged.
- `fabric/graph/llm.receipt_codec` writes a receipt as the
  `fabric.graph.llm.v2` object `{"format", "model", "outcome", "usage"}`. It
  still reads the `fabric.graph.llm.v1` nested arrays stored before, with the
  same checks.
- Codec errors in tool admission and graph records are rendered by
  json_blueprint's `describe_decode_error` and `describe_encode_error`.

### Fixed

- The README no longer says the suite skips PostgreSQL:
  `scripts/check.py full` runs the `fabric_postgres` gate.

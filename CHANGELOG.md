# Changelog

All notable changes to `fabric` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The optional
integration packages under `integrations/` keep their own changelogs.

## Unreleased

Round 5 is described with before/after snippets in
[docs/migration-round-5.md](docs/migration-round-5.md).

### Added

- Caller-chosen run ids: `fabric.start(.., id:, ..)` and `run.new_id()`. A
  start under a stored id returns `AlreadyStarted(id)`, so a retried job
  starts its run once.
- A run correlation (`sinal/correlation.Correlation`), given to
  `fabric.start(.., correlation: Some(c))` or derived from the run id,
  stored with the run, inherited by sub-agent runs, and carried in every
  `model.Request` (with `run` and `turn`), every `tool.Call` and the
  metadata of every run event. `fabric/llm` tags each turn's HTTP Gun
  client view with it, so one agent serves every run.
- `tool.Call`, the call a handler answers (run, action, correlation).
- `fabric.await_with(run, within:, or: selector)` and `fabric.Awaited`:
  wait for the run or a caller's message in one receive.
- Default bounds: `agent.Limits.model_timeout` (600 s; a slow call is a
  retryable failure), `tool_timeout` (60 s; a stopped body is an uncertain
  effect), `max_result_bytes` (1 MiB; a larger result ends the run with
  `OutputEncodingFailed`), and `tool.with_timeout` for one tool;
  `run.Timeout` (`After(Duration)` or `Infinity`). The README lists every
  default.
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

- **Breaking:** `fabric.start` and `fabric.start_with_budget` take
  labelled `id:`, `context:`, `prompt:` and `correlation:` arguments. A taken
  id is `AlreadyStarted(id)`, no longer `StartRefused`.
- **Breaking:** tool handlers receive a `tool.Call` after the context:
  `fn(context, call, input)` for `tool.bind`, `fn(context, call, input,
settlement)` for `tool.bind_settling`.
- **Breaking:** `model.Request` gains `run`, `turn` and `correlation`.
- **Breaking:** every public timeout, deadline, interval and lease is a
  `gleam/time/duration.Duration`: `fabric.await(run, within:)`,
  `graph.await(handle, within:)`, `fabric.sweeper(.., every:)`,
  `agent.Limits.policy_timeout`, `model_retry_delay` and `command_timeout`,
  `tool.bind_settling(.., within:)`, `store.leased(.., lease:)`,
  `store.with_drain`, `operation.with_deadline`, `job.with_poll_interval`,
  and the errors that report them. `graph.with_timeouts` takes labelled
  `callbacks:`, `operations:` and `commands:`. Stored records, the backend
  port and discovery projections keep integer milliseconds.
- **Breaking:** the metadata records of run events gain `correlation`.
- **Breaking:** `fabric_saga.tool` takes `input: fn(context, tool.Call,
input) -> workflow_input`, so a workflow can use the run context, and a
  `Duration` `rollback_within`; each Saga run carries the Fabric run's
  correlation.
- Fabric builds on json_blueprint's opaque `codec.Schema`:
  `contract.from_schema` cannot fail, so `fabric/llm` no longer maps its
  error.
- **Breaking:** Fabric and its packages build on the wave 4 APIs of LLM Wire,
  HTTP Gun and Saga. `fabric/llm.model` takes an `llm_wire.Config` and a
  `String` model; `fabric/graph/llm.new`'s request builder returns an
  `llm_wire.Config` and a plain `llm_wire.Request(String)`, to which Fabric
  adds the structured output; `Receipt.usage` is a `message.Usage`. Failure
  details come from `llm_wire.describe_failure` and retry decisions from
  `llm_wire.advise`. Receipt bytes are unchanged.
- `fabric/llm` stores a turn's provider data with LLM Wire's
  `message.turn_replay_to_json` under the same `llm_wire.turn.v1` tag and
  restores it with `turn_replay_decoder`. New records omit the `issues`
  list, which Fabric answers per call itself; records from the previous
  release still restore and replay the same request JSON
  (`test/fabric/llm_turn_format_test.gleam` keeps their exact bytes). A
  release before this one cannot read records written by this one.
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

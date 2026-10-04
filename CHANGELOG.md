# Changelog

All notable changes to `fabric` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The optional
integration packages under `integrations/` keep their own changelogs.

## Unreleased

Wave 5 is described with before/after snippets in
[docs/migration-wave-5.md](docs/migration-wave-5.md), round 5 in
[docs/migration-round-5.md](docs/migration-round-5.md).

### Wave 5, typed answers (slice F3)

#### Added

- `agent.with_answer(spec, codec)`: a typed final answer. The model is
  given the codec's JSON Schema (`model.Request.answer`), and a run
  completes with the decoded value (`run.Completed(value)`) or ends with
  `run.AnswerInvalid(raw:, reason:)`. `build` refuses a codec without a
  schema (`agent.AnswerSchemaUnavailable`).
- `fabric/llm` asks the provider for the answer's schema as structured
  output (`llm_wire.with_output`); a reply outside the schema keeps its
  text and ends the run with `AnswerInvalid`.
- `telemetry.OutcomeKind.AnswerInvalid` (`"answer_invalid"`).
- `graph.status_kind` (`Active`, `NeedsRecovery`, `NeedsInput`, `Ended`)
  and `graph.describe_status`.

#### Changed

- **Breaking:** `agent.Spec`, `agent.Agent`, `fabric.Run`, `run.Status`,
  `run.Outcome`, `run.Snapshot` and `fabric.Awaited` gain the answer type;
  `agent.new` returns `Spec(context, String)`. `run.Completed(text:)` is
  `run.Completed(answer:)`; `run.ChildSettled` holds an `Outcome(String)`.
- **Breaking:** `model.Request` gains `answer: Option(codec.Schema)`.
- **Breaking:** `agent.with_sub_agent(spec, definition, to:, prompt:)`
  drops `output:`: the child's answer type is the delegation's output type.
- **Breaking:** `graph_agent.new(identity, agent, input:, prompt:)` drops
  `output:` and `answer:`: the operation's output codec is the agent's
  answer codec. `graph_agent.child` returns `fabric.Run(context, output)`.
- **Breaking:** graph commands return the run's status, as the agent
  runtime's do: `graph.await`, `recover`, `poll_job`, `cancel`, `approve`,
  `reject`, `deliver`, `deliver_json` and `reconcile` return
  `Result(graph.Status(answer), graph.Error)`; `graph.snapshot` reads the
  record.
- `fabric.child` returns `Run(context, String)`, and the store-only
  commands read the stored text: `cancel_stored` returns `Status(String)`,
  `reconcile_stored` and `settle_stored` return `Snapshot(String)`.

#### Compatibility

- A run stores its answer as the model's text, as before: completed runs
  stored before typed answers read as `Completed(text)` under a plain agent
  and through a typed agent's codec when the text decodes (fixtures
  `pre-answer-*.json`). An invalid answer is stored as a completion with
  an `"answer_invalid"` key, which older readers read as the text answer.

### Wave 5, one vocabulary for agents and graphs (slice F5)

#### Added

- `policy.Step` (`ToolCall(id)`, `Activation(activation:, attempt:)`),
  `policy.Target.RunOperation(node:, operation:, kind:)` and
  `policy.OperationKind`: one `policy.Action` for both runtimes.
- Graph approvals take a `reviewer.Reviewer` and the current context, and
  record the answer (`graph.Snapshot.approvals`, `graph.Receipt.approvals`).
- Graph approval expiry: `graph.with_approval_expiry(runtime, run.Timeout)`,
  7 days by default, stored with the request; an expired request fails the
  run (`graph.ExpiredApproval(due)`) and a late answer is
  `graph.ApprovalExpired`. `await`, an answer, `recover` and the sweeper
  expire it (`store/discovery` version 12).
- Graph waits (signal, job, child, fork) expire after 7 days by default;
  `operation.with_deadline(op, run.Infinity)` waits without one.
- Graph runtime setters: `graph.with_callback_timeout`,
  `with_operation_timeout` (`run.Timeout`), `with_command_timeout`,
  `with_family_budget`.
- `graph.start(.., correlation:)`: a graph run's correlation is stored,
  passed to `operation.Invocation.correlation`, inherited by child runs
  (managed agents too) with the family's root, and carried in its events.
- Graph telemetry: `graph_started`, `activation_started`,
  `activation_settled`, `graph_approval_requested`,
  `graph_approval_answered`, `graph_cancelled`, `graph_finished`.
- `graph.error_kind` (`fabric.ErrorKind`), `graph.describe_error`,
  `graph.describe_failure`, `graph.open`, `graph.snapshot`,
  `graph.cancel_stored`, `graph.ChildProblem`.
- `definition.new`, `definition.with_max_activations` (default 100),
  `definition.describe_build_error`; `graph_agent.new` and
  `graph_agent.runtime`; `graph_llm.decision` and `graph_llm.call`.
- `reviewer.Error`, `reviewer.Part`, `reviewer.describe_error`,
  `reviewer.max_bytes`.

#### Changed

- **Breaking:** `policy.Action.id` is `step`, `tool` is `name`;
  `policy.Target` gains `RunOperation`. `graph.Action` and `graph.Policy`
  are gone.
- **Breaking:** `operation.Failure` is gone: graph operations classify with
  `tool.Failure` (`operation.new`, `operation.own_job`,
  `operation.BodyFailed`, `fabric/graph/llm`).
- **Breaking:** `graph.new(definition, store, context: fn(RunId) -> context,
policy:)`; `graph.with_timeouts` and `graph.start_with_budget` are gone.
- **Breaking:** `graph.attach` is `graph.open` (it reads and checks the
  record), `graph.read` is `graph.snapshot`; `graph.cancel` returns the
  snapshot after the commit; `graph.approve(handle, ref, reviewer:,
context:)`, `graph.reject(handle, ref, reason:, reviewer:)`,
  `graph.reconcile(handle, ref, content)`.
- **Breaking:** `graph.Error` is typed: `CommandRefused(String)`,
  `StoreFailed`, `DefinitionRejected`, `UnsupportedRecordVersion`,
  `InvalidTimeout`, `Busy` and `OwnerUnknown` are replaced by
  `RunNotFound`, `StoreUnavailable`, `IncompatibleDefinition`,
  `ValueRefused`, `UnsupportedVersion`, `WrongReference`,
  `StaleReference`, `AlreadyAnswered`, `RequirementChanged`,
  `SignalConflict`, `NotReconcilable`, `ReconcileChildFirst`,
  `ChildMismatch`, `RunEnded`, `RunnerBusy`, `RunUnattended`, and a start
  with a stored id is `AlreadyStarted(id, same_input:)`.
- **Breaking:** `definition.Spec` is opaque (`definition.new`);
  `definition.build` returns every problem, `List(BuildError)`, including
  each operation's settings (`InvalidOperation`); `definition.node_id` is
  total; `operation.with_deadline` takes a `run.Timeout`; it,
  `operation.with_replay` and `job.with_poll_interval` are total
  (`job.ConfigurationError` is gone); `graph.both` and `graph.map` return
  the operation and panic on bounds below 1.
- **Breaking:** `fabric/graph/agent.Definition` is opaque
  (`graph_agent.new`, `graph_agent.runtime`); `fabric/graph/llm.new` is
  `decision` with an opaque `Call`.
- **Breaking:** `operation.Invocation` gains `correlation`.
- **Breaking:** `reviewer.new` and `reviewer.with_issuer` return
  `Result(Reviewer, reviewer.Error)` and refuse an empty part or one over
  256 bytes.
- Agent approval deadlines are set and judged by the store's clock
  (`store.now`), as graph deadlines are, not by the checking node's.
- Graph records are version 15 (`correlation`, `root`, approval
  `expires_at` and `approvals`, the `approval_expired` failure, all
  optional on read); records of version 14 and earlier read and recover
  unchanged, and a request or wait stored without a deadline keeps none.

### Wave 5, failures and configuration (slice F2)

#### Added

- `fabric.Error`, `fabric.ErrorKind` (`NotFound`, `Refused`, `Retry`,
  `Unavailable`, `Incompatible`), `fabric.error_kind` and
  `fabric.describe_error`.
- `fabric/reviewer`: `Reviewer`, `reviewer.new(subject)`,
  `reviewer.with_issuer`, `reviewer.subject`, `reviewer.issuer`.
- Approval expiry: `agent.with_approval_expiry(spec, run.Timeout)`, 7 days
  by default. The deadline is stored with the request
  (`run.AwaitingApproval.expires`, `run.PendingApproval.expires`); an
  expired request rejects its action (`run.Expired`, `telemetry.Expired`),
  and a late answer is `fabric.ApprovalExpired`. `await`, an answer,
  `recover` and the sweeper reject it; `store/discovery` (version 11)
  projects its deadline. Requests stored without a deadline never expire.
- `tool.with_replay(tool, max_attempts)`: a body that crashed, ran past
  its timeout or lost its runner is started again instead of becoming
  uncertain; `run.ActionRecord.replays`.
- `tool.name`, `tool.description`, `tool.input_codec`, `tool.output_codec`,
  `tool.action(settlement)` and `tool.reconciliation(definition, result)`.
- `model.error(kind, detail)`, `model.with_retry_after`, `model.ErrorKind`,
  `model.error_kind`, `model.is_retryable`, `model.retry_after`,
  `model.error_detail`, `model.describe_error`; the runner waits a
  provider's delay (up to 10 minutes) before a retry, and `fabric/llm` maps
  llm_wire's failure and `Retry-After` into them.
- `model.tool_call` and `model.with_provider_replay`.
- Agent setters: `with_max_turns`, `with_max_concurrency`,
  `with_token_budget`, `with_max_children`, `with_max_depth`,
  `with_policy_timeout`, `with_model_retry_delay`, `with_command_timeout`,
  `with_model_timeout`, `with_tool_timeout`, `with_max_result_bytes`,
  `with_family_budget`; `agent.Limit`, `agent.describe_config_error`.
- `budget.limits(work:)`, `budget.with_children`, `budget.with_depth`.
- `run.id_from_parts(prefix, parts)`: a total id from known parts.
- `fabric.AlreadyStarted.same_input`.

#### Changed

- **Breaking:** `fabric.StartError`, `RecordError` and `CommandError` are
  one `fabric.Error`; `Unreadable` and `StartRefused` are gone.
- **Breaking:** `model.ModelError` and `model.ToolCall` are opaque;
  `budget.Limits` is opaque.
- **Breaking:** `agent.Limits`, `agent.default_limits` and
  `agent.with_limits` are gone; `ConfigError`'s per-field variants are
  `InvalidLimit(limit:, value:, minimum:, maximum:)` and `InvalidToolLimit`.
- **Breaking:** `fabric.approve` and `fabric.reject` take a
  `reviewer.Reviewer`, not an `Option(String)`; `run.Approval.reviewer` is
  an `Option(Reviewer)`.
- **Breaking:** `fabric.start_with_budget` is gone: the family budget is on
  the agent (`agent.with_family_budget`).
- **Breaking:** `run.AwaitingApproval` and `run.PendingApproval` gain
  `expires`; `run.ActionRecord` gains `replays`; `run.Answer` gains
  `Expired`; `telemetry.Answered` gains `Expired`.
- Records stay compatible: a string reviewer, a missing deadline, a missing
  replay count and a model failure without a kind all read (fixtures in
  `test/fixtures/records`). New keys are written only when they apply.

#### Fixed

- A sweeper started with `sweeper.start` stops when its caller exits, also
  normally; it used to keep scanning after a script or test ended, and its
  sweep events reached other observers.

### Wave 5, structure (slice F1)

#### Added

- `fabric/sweeper`: `sweeper.agent` and `sweeper.graph` build a `Root`;
  `sweeper.supervised(store, roots, every:)` supervises the store's subtree
  and then its sweeper, so the sweeper cannot be ordered wrongly;
  `sweeper.start` runs one beside a store started with `store.start`;
  `SweeperError` (with `DuplicateRoot` and `StoreNotRunning`) and
  `describe_error`.
- `fabric.cancel_when_down(run, owner:)`: the run is cancelled when the
  owner process exits.
- `store.stop`: stops a store started with `store.start`, draining its
  runners.
- `fabric/store/backend`: the backend port (`StoreError`, `Stored`,
  `Current`, `Holder`, `Lease`, `LeasedBackend`) and its contract.
- Every run event's metadata names its family's root run (`root`), so a
  sub-agent's events join their root's; `lease_lost` carries the run's
  `root` and `correlation`. A sub-agent record stores its root as
  `"root"`; a root record's bytes are unchanged, and a sub-agent record
  written before reads its parent as its root.
- `operation.input_codec` and `operation.output_codec` are documented: they
  read a `graph.Receipt`'s JSON.

#### Changed

- **Breaking:** `fabric/observation` is `fabric/telemetry`, and
  `observation.ActionRef` is `telemetry.Action`.
- **Breaking:** the backend port moves from `fabric/store` to
  `fabric/store/backend` (`store.NotFound` is `backend.NotFound`, and so
  on). `fabric/discovery`, `fabric/retention` and `fabric/statistics` move
  to `fabric/store/discovery`, `retention` and `statistics`.
  `testing.leased_backend_checks` and `testing.leased_memory` are
  `fabric/store/conformance.checks` and `conformance.leased_memory`.
- **Breaking:** `fabric.recovery`, `fabric.Recovery`, `fabric.sweeper`,
  `fabric.SweeperError` and `graph.recovery` are replaced by
  `fabric/sweeper` (`DuplicateRecovery` is `DuplicateRoot`).
- **Breaking:** renames: `run.Identity` is `run.DefinitionId`,
  `graph.Approval` is `graph.ApprovalRef`, `graph.Route.Canceled` is
  `graph.Stopped` (a `Cancelled` variant would clash with
  `graph.Cancelled`; the route also covers a deadline), and
  `tool.bind_settling` takes `settle_within:`.
- **Breaking:** no public module has an `@internal` item. `run.issued`,
  `model.call`, `agent.admitted`, the tool, store, graph, job, signal,
  operation and definition accessors, `graph.backing_store`,
  `child.attachment`, `reserved_id` and `branch_id` move to
  `fabric/internal/*`. Opaque types (`Model`, `Agent`, `Tool`,
  `tool.Definition`, `Store`, `graph.Runtime`, `graph.Handle`,
  `definition.Definition`, `operation.Operation`, `job.Observer`,
  `signal.Signal`) are aliases of internal representations.

#### Removed

- **Breaking:** `graph.approval_requirement`; read `approval.requirement`.

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

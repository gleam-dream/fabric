# Changelog

All notable changes to `fabric` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The optional
integration packages under `integrations/` keep their own changelogs.

## Unreleased

- Bound nested graph runtime copying by retaining callback environments once
  and only input contracts in managed-child bindings; preserve existing deadlines.

### Round 9

- Moved classification graph decisions into `fabric/graph/classify` over llm_wire. Removed the `fabric_typesafe` bridge; migrated decision and writing consumers. Old receipt and graph-store fixtures written before the migration remain readable.

Wave 5 is described with before/after snippets in
[docs/migration-wave-5.md](docs/migration-wave-5.md), round 5 in
[docs/migration-round-5.md](docs/migration-round-5.md).

### Wave 5, round 8: a graph child admitted after its parent closed is cancelled

#### Fixed

- A graph child run (a fork member, a subgraph) that reached its own
  admission after its parent had stopped admitting work (the parent was
  closing its fork or stopping) ended `Failed(PolicyFailed("parent no longer
accepts child work"))`, though no policy failed and the parent was
  cancelling it. It now ends `Cancelled(BeforeStart)`, as when the parent's
  cancellation reaches it first. An approval answered in that window is
  `RunEnded`, and a fork admitting members under a closed ancestor stops as
  for a failed ancestry check. The order was rare (about 1 in 300 runs of
  `child_budget_closes_admission_and_keeps_refused_members_distinct_test`
  under CPU load, before round 8 too); the new
  `a_member_admitted_after_its_parent_closed_is_cancelled_test` takes it
  every time.

### Wave 5, round 8: approvers and proofs

#### Changed

- **Breaking:** `fabric.approve(run, ref, proof:, context:)`,
  `fabric.reject(run, ref, proof:, reason:)`,
  `graph.approve(handle, ref, proof:, context:)` and
  `graph.reject(handle, ref, proof:, reason:)` take an `approvers.Proof`
  instead of a `reviewer.Reviewer`; `reject`'s labelled arguments are now
  `proof:` then `reason:`. A proof is made only by `approvers.check`, with
  the approvers given to the agent (`agent.with_approvers`) or graph runtime
  (`graph.with_approvers`), for the request's requirement. Fabric no longer
  takes a bare reviewer that any code could build.
- **Breaking:** an agent or graph runtime without approvers refuses every
  answer: `fabric.ProofRefused(approvers.NoApprovers)`,
  `graph.ProofRefused(approvers.NoApprovers)`. Its requests wait until they
  expire or the run is cancelled; a run opened with an agent value that has
  approvers is answered as usual.
- **Breaking:** `run.Approval` gains `verifier: Option(String)`, the name of
  the approvers that verified the answer. Positional construction of
  `run.Approval` needs the fifth argument; reads by label are unchanged.
- `fabric.Error` and `graph.Error` gain `ProofRefused(approvers.ProofError)`,
  classified `Refused`.

#### Added

- `fabric/approvers`: `Approvers(credential)`, `new(name, verify)`,
  `with_proof_lifetime` (default 60 s), `name`, `check`, the
  opaque `Proof` with `reviewer`, `verifier` and `requirement`, `Denial`
  (`NotAuthenticated`, `NotAuthorized`, `Unavailable`) with
  `describe_denial`, and `ProofError` (`NoApprovers`, `OtherApprovers`,
  `OtherRequirement`, `ProofExpired`) with `describe_proof_error`. A proof is
  accepted only by the approvers value that made it (each `new` mints its
  own identity), for the requirement it was checked for, within the
  lifetime of the receiving agent's approvers.
- `agent.with_approvers`, `graph.with_approvers`. A sub-agent without
  approvers of its own is answered with its parent's.
- `testing.trusting_approvers()`: approvers whose credential is the
  reviewer itself, for tests; every call returns the same approvers.
- The answer's record stores `"verifier"`. Records written before it (a
  string reviewer, a typed reviewer with an issuer, or none) read with no
  verifier and stay answerable
  (`test/fixtures/records/pre-round-8-suspended.json`).
- The warden recipe: about 30 lines in the README and the module doc of
  `fabric/approvers`, compiled and tested verbatim by
  `consumers/approvers_warden` against warden's test provider. The gate step
  `approvers-recipe` (`scripts/check.py recipe`) checks that the three
  copies are identical. Fabric does not depend on warden.

### Wave 5, round 7: exact roots for records stored before roots

#### Fixed

- A sub-agent or graph child record written before wave 5 stores no
  `"root"`. Its events carried its parent as the family's root, which is
  wrong below the first level. A read of the store now derives the exact
  root by following the stored parent links (at most 64, without repeats)
  to a root run or to the first ancestor that stores its root, and the
  run's next commit stores it, so the walk is paid once. A missing or
  unreadable ancestor, or an overlong chain, gives the topmost readable
  ancestor (the parent when none can be read); that root is never stored,
  and an unavailable store fails the read instead of inferring one.

#### Added

- `telemetry.root_inferred()` (`[fabric, run, root, infer]`), with
  `RootInferred(run, root, ancestor, problem, correlation)` and
  `RootProblem` (`AncestorMissing`, `AncestorUnreadable`, `AncestryCycle`,
  `AncestryTooLong`): emitted by a reader each time it falls back to an
  inferred root.

#### Changed

- `fabric_relay`'s tests match relay's opaque `client.Error` through
  `client.reason`.

### Wave 5, round 6: llm_wire content filters are refusals

#### Changed

- Fabric builds on llm_wire's round 6, which reports a provider's content
  filter as `error.ContentFiltered(stage: InPrompt | InOutput, reason)`
  instead of `Refused`. `fabric/llm` turns that failure into a
  `model.Refusal`, so a run that a Gemini or Anthropic safety stop ends is
  still `run.Refused`, not `run.Failed(ModelFailed(..))`, and it is not
  retried. `fabric/graph/llm.decision` records it as a `Refusal` receipt,
  not an uncertain effect. The reason is `error.describe`'s line, which
  keeps the stage and the provider's own reason:
  `"Provider content filter blocked the prompt: SAFETY"` where it was
  `"Prompt blocked by safety policy: SAFETY"`, and
  `"Provider content filter stopped the output: refusal"` where Anthropic's
  reason was the streamed text. OpenAI's `content_filter` stop, an
  `OutputLimited` turn before, is now also a refusal. No public type changed.
- The tests use llm_wire's opaque `testing.Reply` (`testing.events`,
  `testing.tool_call`, `testing.http_status`, and `testing.status`,
  `testing.chunks`, `testing.is_interrupted` in the loopback fake provider).

### Wave 5, round 6: bounds are checked by a build step

#### Changed

- **Breaking:** `graph.new` returns an opaque `graph.Spec`; its setters
  (`with_callback_timeout`, `with_operation_timeout`,
  `with_command_timeout`, `with_approval_expiry`, `with_family_budget`)
  only store, and `graph.build(spec) -> Result(Runtime, List(ConfigError))`
  reports every bound out of range at once instead of the setters
  panicking. `graph.ConfigError` is `InvalidLimit(limit:, value:,
minimum:, maximum:)`, the agent's shape; `graph.Limit` names the setter;
  `graph.describe_config_error(s)`. An approval expiry may now be up to
  2^53 - 1 ms, as for agents (it is a stored deadline, not a timer).
- **Breaking:** `graph.map` no longer panics on `max_members` or
  `concurrency` below 1: `definition.build` reports them as
  `InvalidOperation(node, operation.InvalidLimit(MaxMembers | Concurrency,
..))`.
- **Breaking:** the range problems of `definition.build` take the same
  shape: `definition.InvalidActivationLimit(n)` is
  `InvalidLimit(MaxActivations, n, 1, 2^53 - 1)`;
  `operation.InvalidAttemptBound`, `InvalidDeadline` and
  `InvalidPollInterval` are `operation.InvalidLimit(ReplayAttempts |
Deadline | PollInterval, ..)`. `operation.with_replay` takes at most 100
  attempts, as `tool.with_replay`; `definition.with_max_activations` at
  most 2^53 - 1.
- **Breaking:** `fabric_relay.with_wait` no longer panics; `serve` returns
  `Result(Tool, List(fabric_relay.ConfigError))` (see the fabric_relay
  CHANGELOG).

#### Added

- `definition.describe_build_errors`: every problem `build` reported, in
  one line.

### Wave 5, gate reliability

#### Added

- `fabric_relay.run_of(result)` reads the run a served call names in its
  result's `_meta`, so a client needs no raw key (see the fabric_relay
  CHANGELOG).

#### Fixed

- A store started with `store.start` whose caller died could still hold
  its name after every process linked to the caller had exited: the
  keeper exited at once and left the store's process to notice the death.
  The keeper now stops the store's subtree and waits for it first, so a
  node that waits for those links can start a store under the same name.

### Wave 5, leftovers (slice F6)

#### Added

- `run.host_failure_kind` (`PolicyFault`, `ToolFault`, `ModelFault`),
  `run.describe_host_failure`, `run.action_state_kind` (`Active`,
  `NeedsApproval`, `NeedsReconciliation`, `Ended`) and
  `run.describe_action_state`. `describe_outcome` keeps its text.
- `agent.describe_config_errors`: every problem `build` reported, in one
  line.
- `tool.unconfirmed_reconciliation(note)`: the content that tells the model
  an effect is still unconfirmed, instead of hand-written JSON.

#### Changed

- `fabric/llm` wraps an answer whose schema has no object root (a list, a
  scalar, a nullable value, a union) as `{"answer": ..}` for the provider
  and unwraps the reply, so such an answer no longer fails every turn; the
  run stores the answer's own JSON. llm_wire still refuses a `codec.union`.
- **Breaking (behaviour):** `fabric.start` and `graph.start` return the
  read's error (`StoreUnavailable`, `CorruptRecord`, `UnsupportedVersion`)
  for a taken id whose record cannot be read, instead of
  `AlreadyStarted(_, same_input: False)`.
- `fabric_typesafe` posts through a caller's `http_gun.Client`, and
  `fabric_relay.service` takes the definition; see their CHANGELOGs.

#### Documentation

- The README and `fabric_saga` say that a Saga step reads the run's
  correlation with `saga.correlation_of(key)`. The README's review example
  reconciles an effect as still unknown.

### Wave 5, a corrective answer turn, Relay and docs (slice F4)

#### Added

- A corrective answer turn. A final answer the answer codec refuses no
  longer ends the run at once: the model gets one more turn whose request
  holds the refused answer and a user message naming the codec's complaint
  and the answer's JSON Schema. The turn counts against the turn and token
  budgets and is stored like any turn, so a recovered run goes on with it.
  `agent.with_answer_attempts(spec, n)` sets the final answers a run asks
  for in all (default 2; 1 restores the old behaviour); `build` checks 1 to
  100 (`agent.AnswerAttempts`).
- `telemetry.TurnResult.AnswerRejected` (`"answer_rejected"`) for a model
  turn whose answer was refused and corrected.
- `integrations/fabric_relay`, which replaces `fabric_mcp`: Relay MCP
  tools in agents (`fabric_relay.tool`, `discover`, `discovered`) and graphs
  (`operation`), and agents served as Relay tools (`serve`), with the run's
  correlation and idempotency keys on every call. See its
  [CHANGELOG](integrations/fabric_relay/CHANGELOG.md).
- `run.describe_outcome`: one line for a run's outcome.
- A README and a CHANGELOG for `fabric_saga`.

#### Changed

- **Breaking (behaviour):** a typed agent whose model answers badly makes
  one more model call before it ends with `run.AnswerInvalid`, whose `raw`
  is the last answer.
- **Breaking:** `telemetry.TurnResult` and `agent.Limit` gain a variant.

#### Removed

- **Breaking:** `integrations/fabric_mcp`, its stdio client and its Python
  service tests. Use `fabric_relay` over `relay/client`.

#### Documentation

- The README opens with the common path (usage, then the defaults table,
  which gains the answer attempts), lists the integrations in one table, and
  moves status and scope to the end. It records that the graph runtime
  ships in Fabric 1.0 (release decision 2) and that durability ownership
  (decision 1) is open, and states that `check.py full` runs the PostgreSQL
  suite.
- Every integration has a CHANGELOG; `fabric_saga` and `fabric_relay` have
  a README.

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

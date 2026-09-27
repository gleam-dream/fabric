# Fabric implementation plan

Fabric is a bounded, typed LLM agent runtime. It owns the agent loop, tool
execution policy, budgets, the run record, and cancellation. It consumes
llm_wire for providers and json_blueprint for tool codecs. Typed workflows
belong to Saga, durable delivery to Grind, observations to Sinal; Fabric is not
a DAG compiler or a workflow engine.

The architecture follows variant A of
[experiments/workflow_composition/FINDINGS.md](../experiments/workflow_composition/FINDINGS.md):
a Fabric-owned pure controller, a thin OTP runner, and a plain task executor
with one concurrency budget per run. Every accepted transition is committed
before its effects run, a fence commits `Running` before a tool body runs, and
an idle run is data in the store with no process holding it.

## Decisions carried into every slice

- **One ordinary path.** `agent.new(model, tools, policy)`, then
  `fabric.start(store, agent, context, prompt)`, then `fabric.await`.
  Advanced capabilities are distinct functions (`fabric.answer`,
  `fabric.recover`, `fabric.reconcile`, `agent.with_token_budget`), not
  flags.
- **Policy is a required argument.** There is no implicit allow; the named
  `policy.always_allow()` exists for tests and deliberate choices. A policy
  error, crash, or missing decision within `agent.with_policy_timeout` is a
  host failure (fail closed).
- **One action shape for the gate.** `policy.Action` identifies the run, turn
  ordinal, provider call id, target name, and exact validated arguments. Slice
  2 adds a sub-agent start as another target of the same gate without changing
  existing fields.
- **Arguments are validated before policy.** An unknown tool or malformed
  arguments are model-visible outcomes and never reach the policy or the
  handler. This diverges from lab decision D6, which treats an input decode
  failure as a host failure: here the model produced the bad input and can
  correct it, and no effect is possible.
- **Arguments rejected after admission are a host failure.** The arguments
  are decoded again when the tool starts. If they no longer decode, or no
  tool of that name is registered, the host's tool changed between admission
  and start; the model's arguments were valid. The run stops with
  `ToolChanged`, the handler never ran, and nothing is uncertain. Both
  causes share that one variant because both mean the same thing to the
  application. Recovery refuses such a record up front
  (`ToolNotRegistered`, `ArgumentsNotAccepted`), so the host failure remains
  only for a codec that changes behaviour within one runner.
- **Every typed failure is classified.** `tool.bind` requires a classifier
  from the handler's typed error to `Explain(text)` (model-visible) or
  `Uncertain(evidence)` (blocks until reconciled). There is no default: a
  timeout after a request was sent must not look like a clean failure.
- **Crash after the fence is an uncertain effect**, never a retry and never a
  model-visible failure. Output that cannot be encoded is a host failure.
- **Continuation by transcript rebuild.** llm_wire's `Continuation` is opaque,
  holds an Erlang reference and closures, and cannot survive a restart. Fabric
  keeps its own transcript (`model.Message`, with provider call metadata) and
  the llm_wire adapter re-`prepare`s the full request each turn. This is the
  one path, in memory and after restart. It loses Google raw non-call parts of
  a tool turn and custom-provider `Replay` closures, and it gives up llm_wire's
  exact-coverage check at `prepare_continue`; Fabric enforces coverage itself
  (the next turn is requested only when every call of the batch has a
  model-visible result, fed back in call order).
- **Budgets.** The model-turn limit counts every attempt, including failed and
  retried calls. Exhaustion retains outstanding state and dispatches no tool
  whose result could not be continued. A token budget counts observed `Usage`;
  a reply without usage under a token budget stops the run with
  `BudgetUnverifiable`; without a token budget, missing usage is counted in the
  snapshot. There is no elapsed-time budget API, so it cannot be silently
  accepted.
- **Ownership.** The application opens a `Store` (in memory, a directory, or
  its own backend through `store.new`); the store process is linked to the
  process that opened it. A runner exists only while model or tool work is in
  flight; it monitors the store and stops when the store goes. The runner
  traps exits; the executor and the model task are linked to it, and tool
  tasks to the executor, so killing the runner kills them all and a task that
  dies becomes a message to the runner. The model task is linked rather than
  monitored for exactly that reason: a monitor would let it outlive a killed
  runner.
- **Claim in the commit that hands out work.** A runner is registered in the
  same store step that commits the state giving it work, and released in the
  commit that leaves nothing in flight. There is never a moment where the
  record needs a runner the store does not know, and a watcher woken by the
  idle commit already sees no runner. A command that loses a commit to a
  newer owner reads the newer record and is validated again.
- **Runner loss is reported, not waited on.** When a runner dies while its
  record still needs one, the store drops its registration and wakes every
  `await`, which then returns `NoRunner`. Commands that would start work
  return `RecoveryRequired`; `cancel` needs no recovery. Recovery is an
  explicit `fabric.recover`, because a store knows only the runners of its own
  VM: taking a run over automatically could steal it from a live runner in
  another VM. An older runner cannot commit after a takeover (its revision is
  stale), so the takeover is safe; it is not a lease.
- **A task that dies without a report** (killed from outside) is recorded as an
  uncertain effect, whether or not its fence was committed.
- **Model retries back off.** A retryable model failure is retried after
  `agent.with_model_retry_delay` (default 200 ms), doubling per consecutive
  failure up to 64 times; the wait is inside the model task, so a cancel ends
  it. Every attempt counts against the turn limit.
- **Answers are authenticated by the application.** `fabric.answer` records
  the `reviewer` it is given as is. The application authenticates and
  authorizes the reviewer before calling it; Fabric checks only that the
  reference is current and that the policy, run again with the context the
  application passes, still allows the action.

## Public API (slice 2a)

```gleam
// fabric/tool — typed application tools
pub opaque type Definition(input, output)
pub fn define(name: String, description: String, input: Codec(i), output: Codec(o)) -> Definition(i, o)
pub opaque type Tool(context)
pub fn bind(definition: Definition(i, o), handler: fn(context, i) -> Result(o, e),
            classify: fn(e) -> Failure) -> Tool(context)
pub type Failure { Explain(message: String)  Uncertain(evidence: String) }
pub fn call(definition: Definition(i, o), id: String, input: i) -> Result(model.ToolCall, codec.EncodeError)
pub fn name(tool: Tool(context)) -> String

// fabric/policy — the gate
pub type ActionId { ActionId(turn: Int, call_id: String) }
pub type Action { Action(run: String, id: ActionId, tool: String, arguments_json: String) }
pub type Requirement { Requirement(name: String, version: Int) }
pub type Decision { Allow  Deny(reason: String)  RequireApproval(Requirement) }
pub type Policy(context) = fn(context, Action) -> Result(Decision, String)
pub fn always_allow() -> Policy(context)

// fabric/model — the model port Fabric owns
pub type ToolCall { ToolCall(id: String, name: String, arguments_json: String,
                             provider_id: Option(String), provider_state: Option(String)) }
pub type Message { UserMessage(text: String)  AssistantMessage(text: String, calls: List(ToolCall))
                   ToolResultMessage(call_id: String, content: String) }
pub type ToolSpec { ToolSpec(name: String, description: String, schema: codec.Schema) }
pub type Request { Request(system: Option(String), messages: List(Message), tools: List(ToolSpec)) }
pub type Usage { Usage(input_tokens: Int, output_tokens: Int) }
pub type Reply { FinalAnswer(text, usage)  ToolRequest(text, calls, usage)
                 Refusal(reason, usage)  Truncated(partial_text, usage) }  // usage: Option(Usage)
pub type ModelError { ModelError(reason: String, retryable: Bool) }
pub opaque type Model
pub fn new(call: fn(Request) -> Result(Reply, ModelError)) -> Model

// fabric/llm — llm_wire adapter
pub fn model(settings: llm_wire/config.Config, model_id: llm_wire/types.ModelId) -> Model

// fabric/agent — pure configuration
pub opaque type Agent(context)
pub fn new(model: Model, tools: List(Tool(context)), policy: Policy(context)) -> Agent(context)
pub fn with_identity(agent, name: String, version: Int) -> Agent(context)  // default agent/1
pub fn with_system_prompt(agent, text: String) -> Agent(context)
pub fn with_max_turns(agent, limit: Int) -> Agent(context)          // default 8
pub fn with_max_concurrency(agent, limit: Int) -> Agent(context)    // default 4
pub fn with_token_budget(agent, tokens: Int) -> Agent(context)      // default: none
pub fn with_policy_timeout(agent, milliseconds: Int) -> Agent(context)      // default 5000
pub fn with_model_retry_delay(agent, milliseconds: Int) -> Agent(context)   // default 200
pub fn validate(agent) -> Result(Nil, List(ConfigError))
pub type ConfigError { DuplicateToolName(String)  InvalidToolName(String)  ToolSchemaUnavailable(String)
                       MaxTurnsNotPositive(Int)  MaxConcurrencyNotPositive(Int)  TokenBudgetNotPositive(Int)
                       PolicyTimeoutNotPositive(Int)  ModelRetryDelayNegative(Int)
                       InvalidIdentity(name, version) }

// fabric/store — where runs live
pub opaque type Store
pub fn in_memory() -> Store
pub fn directory(path: String) -> Result(Store, StoreError)
pub fn new(get: fn(String) -> Result(Stored, StoreError), insert: fn(String, String) -> Result(Nil, StoreError),
           compare_and_set: fn(String, Int, String) -> Result(Nil, StoreError)) -> Store
pub fn close(store: Store) -> Nil
pub type Stored { Stored(revision: Int, record: String) }
pub type StoreError { NotFound  AlreadyExists  Conflict(current: Int)  Unavailable(reason: String) }

// fabric/run — what a run is and becomes (data only)
pub type Status { Working  Suspended(approvals: List(PendingApproval), uncertain: List(UncertainAction))
                  Finished(Outcome) }
pub type ApprovalRef { ApprovalRef(run: String, id: ActionId, requirement: Requirement, revision: Int) }
pub type PendingApproval { PendingApproval(reference: ApprovalRef, tool: String, arguments_json: String) }
pub type Answer { Approve  Reject(reason: String) }
pub type Approval { Approval(requirement, revision, answer: Answer, reviewer: Option(String)) }
pub type Identity { Identity(name: String, version: Int) }
pub type Incompatibility { OtherAgent(stored: Identity)  ToolNotRegistered(id, tool)
                           ArgumentsNotAccepted(id, tool, detail) }
pub type Outcome { Completed(text)  Refused(reason)  OutputLimited(partial_text)  BudgetExhausted(Budget)
                   BudgetUnverifiable(turn)  Cancelled  Failed(HostFailure) }
pub type ActionState { Queued  Running  AwaitingApproval(requirement, revision)  Succeeded(content)
                       ToolFailed(content)  Denied(reason)  Rejected(reason)  InvalidArguments(detail)
                       UnknownTool  Uncertain(evidence)  Reconciled(content)  NotStarted  Faulted(detail) }
pub type HostFailure { PolicyFailed(id, reason)  OutputEncodingFailed(id, detail)  ToolChanged(id, detail)
                       ModelFailed(ModelError)  ModelProtocolViolation(reason) }
pub type ActionRecord { ActionRecord(id: ActionId, call: ToolCall, state: ActionState, approvals: List(Approval)) }
pub type TokenUsage { TokenUsage(input_tokens, output_tokens, unreported_replies) }
pub type Snapshot { Snapshot(run, agent: Identity, incarnation: Int, status, turns_used, max_turns,
                             usage: TokenUsage, transcript, actions) }

// fabric — running
pub opaque type Run(context)
pub fn start(store: Store, agent: Agent(c), context: c, prompt: String) -> Result(Run(c), StartError)
pub fn recover(store: Store, agent: Agent(c), context: c, id: String) -> Result(Run(c), RecoverError)
pub fn await(run, within: Int) -> Result(Status, AwaitError)   // first non-Working status
pub fn status(run) -> Result(Status, RecordError)
pub fn snapshot(run) -> Result(Snapshot, RecordError)
pub fn pending(run) -> Result(List(PendingApproval), RecordError)
pub fn answer(run, reference: ApprovalRef, answer: Answer, reviewer: Option(String), context: c)
  -> Result(Status, CommandError)
pub fn cancel(run) -> Result(Status, CommandError)
pub fn reconcile(run, action: ActionId, content: String) -> Result(Status, CommandError)
pub fn id(run) -> String
pub type StartError { InvalidAgent(List(ConfigError))  StartFailed(StoreError) }
pub type RecordError { RunNotFound  StoreFailed(StoreError)  UnsupportedVersion(found: Int)
                       CorruptRecord(detail)  IncompatibleAgent(List(Incompatibility)) }
pub type CommandError { RunEnded  UnknownAction(ActionId)  NotReconcilable(ActionId)  WrongPhase
                        WrongReference  StaleReference  AlreadyAnswered  RequirementChanged(PendingApproval)
                        RecoveryRequired  Contended  Unreadable(RecordError) }
pub type AwaitError { StillWorking  NoRunner  AwaitUnreadable(RecordError) }
pub type RecoverError { RecoverInvalidAgent(List(ConfigError))  RecoverUnreadable(RecordError)
                        RecoverContended }
```

Model-visible failure content has one encoding: `{"error": text}` for typed
failures (`{"error":"tool_failed"}` when hidden) and unknown tools
(`{"error":"unknown_tool"}`), and `{"error": kind, "detail": text}` for
`denied`, `rejected`, and `invalid_arguments`. llm_wire's `ToolResult` has no error flag,
so the disposition lives on Fabric's `ActionState`, not in the wire result.

Internal (importable but unstable): `fabric/internal/controller` (pure
transitions), `record` (the versioned JSON codec and the compatibility
check), `registry`, `executor`, `runner`, `live`, `bounded`, `invocation`.

## Slice 1 — bounded agent execution

Acceptance:

1. Typed heterogeneous tools with a registry rejecting duplicate and invalid
   names and schema-less codecs; declarations and dispatch from the same
   definitions; per-invocation argument validation; outcomes success, typed
   failure (hidden or rendered), host failure, invalid arguments, unknown tool,
   uncertain effect.
2. Explicit policy gate (allow, deny, require approval, error fails closed)
   over a uniform `Action`.
3. Pure controller with a closed phase model, correlated report acceptance,
   turn and token budgets, and suspension as data. The per-run concurrency
   limit is enforced by the executor, not the controller.
4. Pure scripted model tests plus the llm_wire adapter tested against a local
   OpenAI Responses SSE stub with two tool calls and distinct ids.
5. Runner with commit-before-effect, fence, bounded executor, and cancellation
   of active and suspended runs; no sleeps in tests.
6. Pure, validatable configuration with defaults.
7. External consumer `consumers/app` using public imports only.
8. Two or three executed BeamWeaver differential fixtures, or an explicit
   unverified record.

## Slice 2a — durable pause, approval, resume, cancellation, restart

Implemented. Acceptance, each with its executed evidence:

1. Record codec (versioned JSON; another version is `UnsupportedVersion`,
   anything unreadable `CorruptRecord`) and a public store port over encoded
   records (`store.new(get:, insert:, compare_and_set:)`) with an in-memory
   store and a durable directory store whose compare-and-set holds across
   processes and VMs (`record_test`, `store_test`).
2. `fabric.answer` works with no live process, also after a restart; wrong
   reference, stale revision or requirement, already answered, and run ended
   are distinct refusals that leave the pause intact; eight concurrent
   answers have one winner and the tool runs once; the policy checked at
   answer time wins over an approval; a changed requirement issues a new
   request (`RequirementChanged`); the reviewer is recorded as given
   (`approval_test`, `answer_test`).
3. Restart against the directory store with every Fabric process killed:
   recovery bumps a trusted incarnation with compare-and-set; queued tools
   and a lost model call are issued again (the model call against the turn
   budget); a running tool becomes an uncertain effect that needs
   `reconcile` and is never retried, including when its effect happened and
   its result was never committed; completed results survive; a runner of an
   older incarnation cannot commit; duplicate and concurrent recoveries take
   the run over once; a finished run opens unchanged; another agent identity,
   a missing tool, arguments a changed codec no longer accepts, an
   unsupported version, corrupt data, and an unknown run are refused
   (`durable_test`).
4. Cancellation while paused needs no process and voids the pending
   approvals; cancel racing an answer always ends `Cancelled` with the tool
   run at most once; a run whose runner was killed can be cancelled without
   recovery (`approval_test`, `durable_test`, `runner_test`).
5. Runner loss is reported (`NoRunner`), a closed store is reported
   (`AwaitUnreadable(StoreFailed(Unavailable))`), and model retries back off
   (`durable_test`, `runner_test`).
6. BeamWeaver anti-oracle rows B2–B5 executed, and fixtures for approve (A1),
   reject (A3), and a cold restart across a pause (A13) compared
   ([ORACLE.md](ORACLE.md#slice-2a-results)).
7. Consumer: approval with its continuation, rejection, cancel while paused,
   and restart through the directory store (`consumers/app`).

Backlog from this slice:

- **Approval expiry.** Not implemented. An application can deny late answers
  through the policy recheck (its context carries the current time), but
  Fabric does not record when a request was issued. Expiry needs an injected
  clock and an issue time on `AwaitingApproval`, a record change.
- **Edit and respond answers** (BeamWeaver A2, A3 respond) are not offered.
- **Cross-VM ownership.** The directory store makes commits safe across VMs,
  but a store knows only its own runners, so `recover` in one VM takes over a
  run another VM still drives. A lease or heartbeat would let recovery wait
  for a live owner.
- **Cancel of an incompatible record.** Every command, `cancel` included,
  requires the record to be compatible with the agent; a run whose pending
  tool was removed cannot be cancelled under the new agent.

## Slice 2b — sub-agents and observations

- Sub-agent start as a gated action behind the same policy gate and
  approval checkpoint; a child suspension escalates to the parent; child
  cancellation through the parent (anti-oracle B1).
- Sinal facts after accepted transitions (`fabric/observation`).
- Optional Saga integration: a Saga workflow exposed as one typed tool.

## Slice 3 — streaming, structure, durable stores

- Streamed model progress through llm_wire `session.stream`, with
  cancellation closing the stream.
- Structured final output via llm_wire's structured session.
- Elapsed-time budget with a trusted clock and per-tool timeouts.
- Database store adapter (the port and a directory store exist) and Grind
  delivery carrying only a run reference.
- Supervision tree instead of starter-owned stores.

## Slice 1 status and friction

Slice 1 is implemented: see the gates in the repository README and the
oracle results in [ORACLE.md](ORACLE.md#slice-1-results). Friction observed in
sibling packages, recorded for separate evidenced improvements (no sibling was
changed):

- **llm_wire validated tool calls while reading the response** (resolved in
  llm_wire `660370f`). An unknown tool name or schema-invalid arguments failed
  the whole turn with `ProtocolError`. `llm.model` now selects
  `types.ReportInvalidToolCalls`, and Fabric's registry answers each such call
  (`invalid_calls_through_llm_wire_get_per_call_feedback_test`).
- **llm_wire's `Continuation` is opaque and in-memory only**
  (`session.gleam:19-21`). Rebuilding from public `Message` values works but
  loses Google raw parts and custom `Replay` closures, and the exact-coverage
  check of `prepare_continue` is unavailable on a rebuilt request. A persistable
  continuation envelope, or a public replay-preparation function that keeps the
  coverage check, would remove both losses.
- **llm_wire has no retry classification for errors.** `RetryEvidence` says
  whether a request may have reached the provider, not whether retrying can
  help; Fabric derives `retryable` from `WireError` variants and HTTP status
  (`src/fabric/llm.gleam` `failure`).
- **llm_wire had no public test transport** (resolved in llm_wire
  `5cf5232`). Fabric's loopback SSE stub is replaced by `llm_wire/testing`.
- **llm_wire accepted any non-empty tool name** (resolved: `types.tool_name`
  now enforces the providers' grammar). Fabric's registry uses it instead of
  its own copy of the grammar.
- **json_blueprint schemas carry no descriptions** (`codec.gleam:94-112`), so
  tool parameter descriptions cannot reach the model.
- **json_blueprint has no public decode-error renderer**; Fabric renders
  located errors for the model itself
  (`src/fabric/internal/invocation.gleam` `describe_decode_error`).
- **Unpublished path dependencies.** json_blueprint reports version 1.7.1 on
  its unreleased 2.0 branch; llm_wire, json_blueprint, and sinal resolve only
  as `../` path dependencies, so `.github/workflows/ci.yml` cannot build Fabric
  without checking the siblings out beside it.
- **sinal** is not used yet (observations are slice 2b); no friction observed.

## Tested sibling revisions

Fabric resolves its siblings as `../` path dependencies. The gates of slice 2a
passed against these revisions, each with a clean working tree:

| Package        | Revision  | Relationship                                                              |
| -------------- | --------- | ------------------------------------------------------------------------- |
| llm_wire       | `3b126fe` | Direct dependency (`fabric/llm`, `llm_wire/testing` in tests)             |
| json_blueprint | `ecf5c60` | Direct dependency (tool codecs)                                           |
| sinal          | `f4622b6` | Transitive, through llm_wire; Fabric does not import it yet               |
| saga           | `f241395` | Not a dependency; the revision reviewed for the slice 2b integration plan |

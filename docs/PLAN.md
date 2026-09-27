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
  `fabric.start(agent, context, prompt)`, then `fabric.await`. Advanced
  capabilities are distinct functions (`tool.bind_reporting`,
  `agent.with_token_budget`, `fabric.reconcile`), not flags.
- **Policy is a required argument.** There is no implicit allow; the named
  `policy.always_allow()` exists for tests and deliberate choices. A policy
  error is a host failure (fail closed).
- **One action shape for the gate.** `policy.Action` identifies the run, turn
  ordinal, provider call id, target name, and exact validated arguments. Slice
  2 adds a sub-agent start as another target of the same gate without changing
  existing fields.
- **Arguments are validated before policy.** An unknown tool or malformed
  arguments are model-visible outcomes and never reach the policy or the
  handler. This diverges from lab decision D6, which treats an input decode
  failure as a host failure: here the model produced the bad input and can
  correct it, and no effect is possible.
- **Typed failure detail is hidden by default.** `tool.bind` shows the model a
  fixed failure text; `tool.bind_reporting` classifies each typed error as
  `Explain(text)` (model-visible) or `Uncertain(evidence)` (blocks until
  reconciled).
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
- **Ownership.** The process that calls `fabric.start` owns the run's
  in-memory store (linked). A runner exists only while model or tool work is in
  flight; it monitors the store and stops when the store goes. The executor is
  linked to the runner and traps exits; tool and model tasks are linked below
  it, so killing the runner kills them.

- **Release in the idle commit.** The runner's commit that leaves nothing in
  flight also clears its live registration in the store, so any watcher woken
  by that commit already sees `is_live == False`.
- **A crashing policy fails closed.** `fabric.start` wraps the policy so a
  raised exception becomes a policy error (host failure), like an `Error`.
- **A task that dies without a report** (killed from outside) is recorded as an
  uncertain effect, whether or not its fence was committed.

## Public API (slice 1)

```gleam
// fabric/tool — typed application tools
pub opaque type Definition(input, output)
pub fn define(name: String, description: String, input: Codec(i), output: Codec(o)) -> Definition(i, o)
pub opaque type Tool(context)
pub fn bind(definition: Definition(i, o), handler: fn(context, i) -> Result(o, e)) -> Tool(context)
pub fn bind_reporting(definition: Definition(i, o), handler: fn(context, i) -> Result(o, e),
                      report: fn(e) -> Failure) -> Tool(context)
pub type Failure { Explain(message: String)  Uncertain(evidence: String) }
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
pub fn with_system_prompt(agent, text: String) -> Agent(context)
pub fn with_max_turns(agent, limit: Int) -> Agent(context)         // default 8
pub fn with_max_concurrency(agent, limit: Int) -> Agent(context)   // default 4
pub fn with_token_budget(agent, tokens: Int) -> Agent(context)     // default: none
pub fn validate(agent) -> Result(Nil, List(ConfigError))
pub type ConfigError { DuplicateToolName(String)  InvalidToolName(String)  ToolSchemaUnavailable(String)
                       MaxTurnsNotPositive(Int)  MaxConcurrencyNotPositive(Int)  TokenBudgetNotPositive(Int) }

// fabric/run — what a run is and becomes (data only)
pub type Status { Working  Suspended(approvals: List(PendingApproval), uncertain: List(UncertainAction))
                  Finished(Outcome) }
pub type Outcome { Completed(text)  Refused(reason)  OutputLimited(partial_text)  BudgetExhausted(Budget)
                   BudgetUnverifiable(turn)  Cancelled  Failed(HostFailure) }
pub type ActionState { Queued  Running  AwaitingApproval(requirement, revision)  Succeeded(content)
                       ToolFailed(content)  Denied(reason)  InvalidArguments(detail)  UnknownTool
                       Uncertain(evidence)  Reconciled(content)  NotStarted  Faulted(detail) }
pub type HostFailure { PolicyFailed(id, reason)  OutputEncodingFailed(id, detail)  ModelFailed(ModelError)
                       ModelProtocolViolation(reason) }
pub type ActionRecord { ActionRecord(id: ActionId, call: ToolCall, state: ActionState) }
pub type TokenUsage { TokenUsage(input_tokens, output_tokens, unreported_replies) }
pub type Snapshot { Snapshot(run, status, turns_used, max_turns, usage: TokenUsage, transcript, actions) }

// fabric — running
pub opaque type Run
pub fn start(agent: Agent(c), context: c, prompt: String) -> Result(Run, StartError)
pub fn await(run: Run, within: Int) -> Result(Status, AwaitError)   // first non-Working status
pub fn status(run: Run) -> Result(Status, CommandError)
pub fn snapshot(run: Run) -> Result(Snapshot, CommandError)
pub fn cancel(run: Run) -> Result(Status, CommandError)
pub fn reconcile(run: Run, action: ActionId, content: String) -> Result(Status, CommandError)
pub fn is_live(run: Run) -> Bool
pub fn id(run: Run) -> String
pub type StartError { InvalidAgent(List(ConfigError)) }
pub type CommandError { RunEnded  UnknownAction(ActionId)  NotReconcilable(ActionId)  WrongPhase
                        Contended  StoreUnavailable }
pub type AwaitError { StillWorking  AwaitStoreUnavailable }
```

Model-visible failure content has one encoding: `{"error": text}` for typed
failures (`{"error":"tool_failed"}` when hidden) and unknown tools
(`{"error":"unknown_tool"}`), and `{"error": kind, "detail": text}` for
`denied` and `invalid_arguments`. llm_wire's `ToolResult` has no error flag,
so the disposition lives on Fabric's `ActionState`, not in the wire result.

Internal (importable but unstable): `fabric/internal/controller` (pure
transitions), `registry`, `executor`, `store`, `runner`.

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
   turn and token budgets, concurrency limit, and suspension as data.
4. Pure scripted model tests plus the llm_wire adapter tested against a local
   OpenAI Responses SSE stub with two tool calls and distinct ids.
5. Runner with commit-before-effect, fence, bounded executor, and cancellation
   of active and suspended runs; no sleeps in tests.
6. Pure, validatable configuration with defaults.
7. External consumer `consumers/app` using public imports only.
8. Two or three executed BeamWeaver differential fixtures, or an explicit
   unverified record.

## Slice 2 — durable pause and escalation

- Record codec (versioned JSON) for the run state and a public store port over
  encoded records (`store.new(get:, insert:, compare_and_set:)`), with the
  in-memory store as default.
- `fabric.answer(run, reference, Approve | Reject, context)` with policy
  recheck under the current context, revision-checked references, and
  distinct `WrongReference`, `StaleReference`, `AlreadyAnswered`, `RunEnded`
  outcomes; single winner under concurrent answers (compare-and-set).
- Restart: a trusted incarnation per started runner; `fabric.recover` marks
  fenced `Running` actions uncertain, redispatches `Queued`, re-issues a lost
  model call against the turn budget.
- Sub-agent start as a gated action; a child suspension escalates to the
  parent; child cancellation through the parent.
- Sinal facts after accepted transitions (`fabric/observation`).
- Acceptance adds the durable anti-oracle rows B2–B4 and the A1–A7, A13
  fixtures.

## Slice 3 — streaming, structure, durable stores

- Streamed model progress through llm_wire `session.stream`, with
  cancellation closing the stream.
- Structured final output via llm_wire's structured session.
- Elapsed-time budget with a trusted clock and per-tool timeouts.
- Durable store adapter and Grind delivery carrying only a run reference.
- Supervision tree instead of starter-owned stores.

## Slice 1 status and friction

Slice 1 is implemented: see the gates in the repository README and the
oracle results in [ORACLE.md](ORACLE.md#slice-1-results). Friction observed in
sibling packages, recorded for separate evidenced improvements (no sibling was
changed):

- **llm_wire validates tool calls while reading the response.** An unknown
  tool name or schema-invalid arguments fail the whole turn with
  `ProtocolError` (`src/llm_wire/internal/openai.gleam` `handle_output_item_done`,
  `internal/anthropic.gleam:681`, `internal/google.gleam:637`, via
  `types.validate_tool_arguments`, `types.gleam:301`). Fabric therefore cannot
  give the model per-call `invalid_arguments` or `unknown_tool` feedback
  through llm_wire (`test/fabric/llm_test.gleam`,
  `malformed_arguments_through_llm_wire_fail_the_model_call_test`). A per-call
  validation result on `ToolCall`, or an opt-out, would let the caller decide.
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
- **llm_wire has no public test transport.** `internal/tcp` and
  `test/fake_server.gleam` are not importable, so Fabric carries its own
  loopback SSE stub (`test/fabric_stub_ffi.erl`).
- **llm_wire accepts any non-empty tool name** (`types.tool_name`,
  `types.gleam:47`) although providers require `^[a-zA-Z0-9_-]{1,64}$`; Fabric
  checks names itself.
- **json_blueprint schemas carry no descriptions** (`codec.gleam:94-112`), so
  tool parameter descriptions cannot reach the model.
- **json_blueprint has no public decode-error renderer**; Fabric renders
  located errors for the model itself
  (`src/fabric/internal/invocation.gleam` `describe_decode_error`).
- **Unpublished path dependencies.** json_blueprint reports version 1.7.1 on
  its unreleased 2.0 branch; llm_wire, json_blueprint, and sinal resolve only
  as `../` path dependencies, so `.github/workflows/ci.yml` cannot build Fabric
  without checking the siblings out beside it.
- **sinal** is not used yet (observations are slice 2); no friction observed.

> Research evidence produced 2026-09-27 by read-only inspection and execution of sibling repositories and BeamWeaver; the scratchpad paths it references (`/private/tmp/claude-501/...`, `$SP/...`) were ephemeral and may no longer exist.

# Sibling package API survey for Fabric

Surveyed 2026-09-27, read-only. All `file:line` citations are relative to `/code/gleam-dream/<package>/`. Where source and README/design disagreed, I followed the source.

## 0. Snapshot, toolchain, dependency wiring

| Package        | HEAD                                       | Branch                           | Tree               | gleam.toml name/version                          | Gleam req       | Target        |
| -------------- | ------------------------------------------ | -------------------------------- | ------------------ | ------------------------------------------------ | --------------- | ------------- |
| llm_wire       | `36dbc259f20ddf5dbabbd62b65bc94ef0fa9fef7` | master                           | clean              | llm_wire 0.1.0                                   | >= 1.18.0       | erlang        |
| json_blueprint | `ecf5c60bc77a0d30cded619519d07ba7ef8a4f1d` | implementation/schema-aware-core | clean              | json_blueprint 1.7.1 (2.0 migration in progress) | (none declared) | erlang+js FFI |
| sinal          | `f4622b67394965c18091ef95390cfd55ad6502db` | master                           | clean              | sinal 0.1.0                                      | >= 1.18.0       | erlang        |
| relay          | `c0510b3fd54fb5cc348e80cedbd19b849af074ee` | master                           | clean              | relay 0.1.0                                      | >= 1.18.0       | erlang        |
| saga           | `f2413958b15fcbc336d33cb47c90189257037e12` | master                           | clean              | saga 0.1.0                                       | >= 1.18.0       | erlang        |
| grind          | `9eeb9ad4d7af95c327433677eb22bfbeb2d0f1d8` | master                           | **DIRTY** (see §6) | grind 0.1.0                                      | >= 1.18.0       | erlang        |
| warden         | `a594edd543de9a67af9531bba01691fdaa107b56` | master                           | clean              | warden 0.1.0                                     | >= 1.18.0       | erlang        |
| fabric         | `bf61d187027c366dafb3f92e48565756a944029e` | master                           | clean              | fabric 0.1.0                                     | >= 1.18.0       | erlang        |

Dependency graph, where `path` means a relative `../x` path dependency:

- json_blueprint depends on gleam_stdlib `>=0.60 <2.0`, gleam_json 3.x, and gleam_crypto 1.x. It has no sibling dependencies.
- sinal depends on gleam_stdlib `<1.0`, gleam_erlang 1.x, gleam_otp 1.x, and `telemetry == 1.4.2`.
- llm_wire depends on json_blueprint (path), sinal (path), gun `>=2.6 <3`, gleam_http 4.x, gleam_json, gleam_erlang, and gleam_otp. Its dev dependencies are mist and anthropic_gleam.
- relay depends on json_blueprint (path), sinal (path), `mist == 6.0.2`, `gun == 2.6.0`, gleam_http, and gleam_json.
- saga depends on sinal (path), gleam_stdlib, and gleam_erlang.
- grind depends on sinal (path), `pog >=4.1 <4.2`, `pgo >=0.20 <0.21`, gleam_json, and exception.
- None of these packages has been published to Hex. Every sibling reference in every manifest is `source = "local"`, with `path = "../json_blueprint"` or `path = "../sinal"`. llm_wire's CHANGELOG lists "convert local Blueprint and Sinal path dependencies" as remaining release work. json_blueprint 1.0 to 1.6 **are** on Hex, and those tarballs sit in the local Hex cache, but the 1.7.1/2.0 codec API used by llm_wire and relay is local only. **A consumer must use path deps.**
- `saga/sibling-revisions.txt` and `relay/sibling-revisions.txt` pin `sinal=13105bb`. Sinal HEAD is 2 commits ahead of that pin, adding the bounded forwarder. The pin is an ancestor of HEAD.

Dev shell (checked by running it):

- `nix develop` in fabric provides **gleam 1.18.1**, **Erlang/OTP 28** (erlang-28.5.0.6 from `beam28Packages.erlang`), rebar3 3.27.0, and lefthook. See `fabric/flake.nix` devShells.default.
- The Hex cache at `~/Library/Caches/gleam/hex/hexpm/packages` holds 397 tarballs. Every hex `outer_checksum` in the manifests of llm_wire, json_blueprint, sinal, relay, saga, grind, and fabric is present in that cache.
- Path-dependency probe: I copied fabric to `scratchpad/fabric-probe`, added path deps on llm_wire, json_blueprint, sinal, saga, and relay plus gleam_json, and ran `gleam test` inside the fabric dev shell. **It resolved, compiled, and passed** (2 tests).
  - Resolved versions: gleam_stdlib 0.71.0, gleam_json 3.1.0, gun 2.6.0, mist 6.0.2, and telemetry 1.4.2.
  - The sibling repos showed no git changes afterwards, because path deps compile into the consumer's `build/`.
  - I did not verify that resolution works with the network cut off. New requirement ranges may still query the Hex index. All tarballs are cached.
  - Adding relay pulls in mist, glisten, and gramps. relay pins `mist == 6.0.2` and `gun == 2.6.0`, so Fabric inherits those exact pins.
  - Probe source: `scratchpad/fabric-probe/src/probe.gleam`. It contains a scripted adapter, a transcript rebuilt from public values, `prepare_continue`, and a Saga workflow defined at runtime that fans out over N tool calls.
- Fabric can therefore declare `llm_wire = { path = "../llm_wire" }` and the other siblings the same way. It must also list `json_blueprint = { path = "../json_blueprint" }` and `sinal = { path = "../sinal" }` directly if it imports them, and those paths must match the siblings' own relative paths.

---

## 1. llm_wire

Public modules are `llm_wire/config`, `llm_wire/session`, `llm_wire/types`, `llm_wire/provider`, `llm_wire/provider/{openai,anthropic,google}`, `llm_wire/pool`, and `llm_wire/telemetry`. Everything under `llm_wire/internal/*` is internal (`gleam.toml:8`).

### 1.1 Configure, make a buffered request, get tool calls, continue

- **Provider config:**
  - Each provider module builds an options value, which a config function turns into a `config.Config`:
    - `openai.options(key)`, then `config.openai(opts)` (`src/llm_wire/provider/openai.gleam:13`, `src/llm_wire/config.gleam:24`)
    - `anthropic.options(key)`, then `config.anthropic(opts)` (`config.gleam:36`)
    - `google.options(key)`, then `config.google(opts)` (`config.gleam:48`)
  - `types.api_key(raw)` builds the key (`types.gleam:64`). It is opaque and there is no public expose.
  - `Config` is opaque (`config.gleam:14`). Modifiers are `with_endpoint`, `with_limits`, `with_deadlines`, `with_pool`, and `with_ca_cert_file` (`config.gleam:67-88`).
  - Built-in endpoints:
    - OpenAI: `https://api.openai.com/v1` + `/responses`, the Responses API (`internal/api.gleam:1863`)
    - Anthropic: `/messages` (`api.gleam:1890`)
    - Google: `:streamGenerateContent?alt=sse` (`api.gleam:1929`)
  - All three always stream over SSE, and the buffered API collects the stream.
- **Request:**
  - `types.new_request(model_id, messages)` (`types.gleam:377`) plus `with_tools`, `with_max_tokens`, `with_temperature`, `with_top_p`, `with_stop_sequences`, and `with_prompt_cache` (`types.gleam:390-412`).
  - `types.model_id(raw)` builds the model ID (`types.gleam:13`).
  - The `Request` record is public (`types.gleam:364`).
- **Message types:** `Message` is fully public (`types.gleam:225-234`). Its constructors are `SystemMessage`, `UserMessage`, `UserContent(parts)`, `AssistantMessage`, `AssistantContent`, `AssistantToolCalls(calls)`, `AssistantToolCallsWithText(text, calls)`, and `ToolResultMessage(call_id, content: String)`.
- **Buffered call:**
  - `session.prepare(config, request) -> Result(PreparedCall, WireError)` (`session.gleam:65`)
  - `session.run(prepared) -> Result(RunResult, RunFailure)` (`session.gleam:142`). This is `stream` followed by `collect`.
  - `RunResult` has four variants (`session.gleam:23-37`):
    - `RunText(text, usage)`
    - `RunToolCalls(text, calls: List(types.ToolCall), continuation: Continuation, usage)`
    - `RunOutputLimited(partial_text, partial_calls, usage)`
    - `RunRefusal(reason, usage)`
  - `RunFailure(error: WireError, retry: RetryEvidence)` (`session.gleam:61`)
- **Tool declarations are Blueprint-based, not raw JSON Schema:**
  - `types.tool_from_codec(name: ToolName, description, input_codec: codec.Codec(a)) -> Result(ToolDefinition, WireError)` (`types.gleam:246`). It derives the schema via `codec.schema` and builds a `runtime.RuntimeContract`.
  - The decoded value is **discarded**: the stored closure returns `Result(Nil, WireError)` (`types.gleam:242`, `:260-269`). llm_wire only validates arguments. The application must decode `arguments_json` itself with the same codec.
  - `types.tool_from_contract(name, description, runtime.RuntimeContract)` builds a schema-only tool (`types.gleam:278`).
  - `ToolDefinition` is opaque (`types.gleam:236`). Its accessors are `tool_name_of`, `tool_description`, and `tool_schema` (`:288-298`).
  - Duplicate tool names are rejected at prepare time (`types.gleam:334-353`).
  - `provider.blueprint_schema(codec.Schema) -> Result(json.Json, WireError)` projects a Blueprint schema to JSON (`provider.gleam:133`).
- **Tool calls:**
  - `ToolCall(id: CallId, name: ToolName, arguments_json: String, provider_id: Option(String), provider_state: Option(String))` is a **public record** (`types.gleam:199-207`).
  - `CallId` and `ToolName` are opaque strings. They are built with `types.call_id(raw)` and `types.tool_name(raw)` and read with `call_id_to_string` and `tool_name_to_string` (`types.gleam:26-58`).
  - `types.tool_call(id, name, args)` builds a call with no provider metadata (`types.gleam:211`).
  - Arguments are validated against the schema and codec before the result is surfaced, and again at continue (`api.gleam:564-566`, `types.gleam:301-331`).
- **Submitting results:**
  - `types.ToolResult(call_id: CallId, content: String)` (`types.gleam:355`)
  - `session.prepare_continue(continuation, List(ToolResult)) -> Result(PreparedCall, WireError)` (`session.gleam:96`)
  - `api.prepare_continue` (`internal/api.gleam:524-600`) enforces:
    - The same origin, provider, and model.
    - **Exact coverage.** An unknown, duplicate, or missing result ID raises `PreparationError` (`api.gleam:640-686`). Results may arrive in any order and are re-sorted to provider order.
  - It then appends `AssistantToolCallsWithText(text, source_calls)` and the `ToolResultMessage`s to the saved conversation. It copies the sampling options and re-encodes, using the provider replay when one is present.
  - Content is a plain `String`. There is no structured, error, or is_error flag on `ToolResult`.

### 1.2 Continuation and persistence (claim verified)

- `session.Continuation` is **opaque** (`session.gleam:19-21`). It holds `source: PreparedCall` and `replay: api.Continuation`.
- `PreparedCall` holds the full `config.Config`, including the opaque `ApiKey`, the adapter closures, and an optional pool pid (`session.gleam:14-16`).
- `api.Continuation` (`internal/api.gleam:47-59`) holds:
  - `origin: reference.Reference`, an Erlang ref that is unique per VM and cannot survive a restart
  - `expected_calls`, `source_calls`, `assistant_text`, and `conversation: List(Message)`
  - `response_id`
  - `provider_continuation: Option(ProviderContinuation)`, which is `GoogleProviderContinuation(parts: List(String))` or `CustomProviderContinuation(replay: provider.Replay)`. `provider.Replay` is a closure (`internal/stream_types.gleam:6-9`, `provider.gleam:47-52`).
- The only public accessor is `session.continuation_response_id` (`session.gleam:236`).
- **Claim confirmed: the continuation is opaque and has no public encode, decode, serialize, or restore.** No such function exists in any public module. `grep -i persist|serializ|restore` in `src` finds nothing.
- `CHANGELOG.md:18-20` lists "durable continuation" as outside this candidate.
- `session.prepared_request_json(prepared) -> String` (`session.gleam:232`) exposes the encoded wire body. It is diagnostic only, with no inverse.
- **Rebuilding a transcript from public types works, and compiled in the probe:**
  - Persist the conversation as `List(Message)` plus the `ToolCall` records. `ToolCall` is fully public, including `provider_id` and `provider_state`.
  - On resume, build `types.new_request(model, history ++ [AssistantToolCallsWithText(text, calls), ToolResultMessage(id, content)...]) |> with_tools(tools)` and call `session.prepare` again.
  - Caveats:
    - (a) Fabric must write its own JSON codec for `Message`, `ToolCall`, and `Content`. `CallId`, `ToolName`, and `ModelId` round-trip through their `_to_string` and constructor functions.
    - (b) Google: provider replay uses the raw saved `parts` from `GoogleProviderContinuation` (`api.gleam:1219-1230`). A rebuilt request instead goes through `google_tool_turn`, which re-emits `functionCall` with `id` from `provider_id` and `thoughtSignature` from `provider_state` (`api.gleam:1290-1318`). Signatures survive, but any other raw model parts in that turn (text or thought parts) are lost.
    - (c) A custom provider's `Replay` closure is lost. The rebuilt request uses the adapter's plain `encode`.
    - (d) OpenAI and Anthropic keep no server-side state. `response_id` is not replayed as `previous_response_id` (grep finds none), and Anthropic calls carry `provider_state: None` (`internal/anthropic.gleam:824-825`). A rebuilt transcript is therefore equivalent for those two providers.
    - (e) Exact-coverage validation and the "same provider/model" guard are lost on rebuild, so Fabric must enforce them itself.

### 1.3 Deterministic, scripted, or fake providers

- Custom providers exist: `config.from_provider(provider.adapter(provider.Spec(...)))` (`config.gleam:63`, `provider.gleam:16-29`, `:127`).
- `Spec` has these fields:
  - `identity: types.Provider`. Use `Custom(name)` (`types.gleam:99-104`).
  - `endpoint: types.Endpoint`
  - `headers`
  - `encode: fn(Request, List(ProjectedTool), Option(OutputFormat)) -> Result(EncodedRequest(path, body), WireError)`
  - `project_tool_schema` and `project_output_schema`, both `fn(codec.Schema) -> Result(json.Json, WireError)`. `provider.blueprint_schema` works for both.
  - `new_reducer: fn(Limits, List(ToolDefinition)) -> Result(Reducer, WireError)`
- `provider.reducer(state, step, terminal, retry)` (`provider.gleam:110`) builds a reducer from:
  - `step: fn(state, provider.Event(event, data, id, retry)) -> Result(#(state, List(StreamProgress)), WireError)`
  - `terminal: fn(state) -> Option(provider.Terminal)`
- `provider.Terminal` (`provider.gleam:80-97`) has these variants: `Text(text, usage)`, `ToolCalls(text, calls, response_id, replay: Option(Replay), usage)`, `OutputLimited`, `Refusal`, `Failure(error, retry)`, and `Cancellation(retry)`.
- `provider.replay(state, encode_fn)` captures a typed continuation encoder (`provider.gleam:54`).
- **There is no in-process transport.** The runtime always opens an HTTP/SSE connection to `endpoint`: "The runtime, rather than the adapter, owns transport" (`provider.gleam:8-9`, `session.gleam:111-140`).
  - A scripted provider therefore needs a local socket server that emits SSE frames.
  - llm_wire's own tests use `test/fake_server.gleam`, a raw TCP listener built on `llm_wire/internal/tcp`. That module is internal, so Fabric cannot import it.
  - The canonical example is `test/external_provider.gleam:26-263`, driven by `test/external_provider_test.gleam:15-20` and `:66-90`. It uses `event: text`, `event: tool` (`id|name|args`), and `event: done` frames.
  - A probe compiled a minimal adapter: `scratchpad/fabric-probe/src/probe.gleam` `scripted()`.
- **Implication for Fabric:** for deterministic unit tests without sockets, Fabric needs its own model-port abstraction. That is a function from a Fabric request to a Fabric turn result, with an llm_wire-backed implementation and a pure scripted implementation. Alternatively, Fabric tests can run a mist or gen_tcp SSE fake. mist 6.0.2 is already present through relay.

### 1.4 Streaming, cancellation, structured output, usage, errors

- **Streaming:**
  - `session.stream(prepared) -> Result(Stream, RunFailure)` (`session.gleam:111`)
  - `session.next(stream) -> Result(ReadResult, ReadError)`. `ReadResult` is `NextProgress(StreamProgress)` or `StreamTerminal(Terminal)`, and `Terminal` is `Finished(RunResult) | Failed(WireError, RetryEvidence) | Cancelled(RetryEvidence)` (`session.gleam:43-57`, `:199`).
  - `StreamProgress` is `TextDelta(block_id, text) | RefusalDelta | ReasoningDelta | ProviderExtension(provider, event_name) | UsageUpdate(Usage)` (`types.gleam:418-424`).
  - `next` uses the config's `read_timeout_ms`. `ReadTimeout` is a benign error, and `collect` simply loops on it (`session.gleam:156`).
  - `session.collect(stream)` drains to a `RunResult`.
- **Close and cancel:**
  - `session.close(stream) -> Result(CloseOutcome, types.ReadError)`, where `CloseOutcome` is `ConsumerClosed | ProviderCancellationConfirmed | AlreadyTerminal` (`session.gleam:224`, `types.gleam:479-483`).
  - `close` works from any process that holds the `Stream` value, because it sends a `Close` to the owner actor (`internal/owner.gleam:235-249`).
  - The stream owner **monitors the process that opened the stream** and cleans up when that process dies (`owner.gleam:121`, `:144`, `:843-850`). Killing a task that is blocked in `session.run` therefore cancels the HTTP request.
  - There is no cancellation token for the buffered `run` call.
  - The owner also enforces deadlines: `Deadlines(overall_timeout_ms=60000, idle_timeout_ms=15000, read_timeout_ms=5000)` (`types.gleam:174-184`).
  - Resource limits are set by the `Limits` record (`types.gleam:106-142`).
- **Structured output:**
  - `session.prepare_structured(config, request, output_name, output_codec: codec.Codec(o))` (`session.gleam:289`)
  - `run_structured`, `stream_structured`, `next_structured`, `collect_structured`, and `close_structured`
  - `StructuredRunResult(o)` has four variants (`session.gleam:255-269`):
    - `StructuredValue(value: o, raw_json, usage)`
    - `StructuredNeedsTools(text, calls, continuation: StructuredContinuation(o), usage)`
    - `StructuredOutputLimited`
    - `StructuredRefusal`
  - `prepare_structured_continue(StructuredContinuation(o), results)` (`session.gleam:310`)
  - The output is decoded through the Blueprint runtime contract, and a mismatch raises `OutputValidationError` (`types.gleam:463`).
- **Usage:**
  - `Usage(input_tokens, output_tokens, total_tokens)` (`types.gleam:414-416`)
  - It appears as `Option(Usage)` on every `RunResult` variant and as `UsageUpdate` progress during streaming.
  - It has no cache or reasoning token fields.
- **Errors:**
  - `WireError` (`types.gleam:449-464`) has these variants:
    - `ConfigurationError(reason)` and `PreparationError(reason)`
    - `TransportError(reason)`
    - `HttpStatusError(status_code, body, retry_hint: Option(RetryHint))`. `RetryHint` is `RetryDelaySeconds(Int) | RetryHeaderValue(String)`.
    - `ProviderError(code, message)` and `ProtocolError(reason)`
    - `ResourceLimitExceeded(limit_name, limit_value, measured_value)`
    - `DeadlineExceeded(OverallDeadline|IdleDeadline|ReadDeadline)`
    - `CancelledLocally`
    - `OutputValidationError(reason)`
  - `RetryEvidence(classification: NoRequestSent|RequestMayHaveReachedProvider|EffectUnknown, response_bytes_observed, semantic_progress_observed)` (`types.gleam:426-438`)
  - `ReadError` is `StreamClosed|ConcurrentReadConflict|OwnerUnavailable|ReadTimeout` (`types.gleam:472-477`).
  - llm_wire does no automatic retry (`CHANGELOG.md:20`), so the retry layer belongs to the caller.
- **Pool:** `pool.start(PoolConfig)`, `pool.stop`, and `pool.info` (`pool.gleam:47-81`). The caller owns the pool and attaches it with `config.with_pool`.
- **Telemetry:**
  - A single Sinal event, `[llm_wire, observation]`, with `Nil` measurements and `Metadata(stage, provider, outcome)` strings. Stages are Prepared, RequestSent, FirstProgress, Terminal, Cancelled, Deadline, and Cleanup (`telemetry.gleam:7-48`).
  - `telemetry.observation_event()` is public and can be used for subscriptions. No content is carried.

---

## 2. saga (critical)

Public modules are `saga`, `saga/execution`, `saga/observation`, and `saga/testing`. `saga/internal/*` is internal (`gleam.toml:5`). README states "in-memory execution only — no durable journals, no persistence" (`README.md:7`).

### 2.1 Defining a workflow

- `saga.step(name, run: fn(i) -> Result(o, e)) -> Step(i, o, e, u)` (`src/saga.gleam:251`). The default is one attempt and no undo.
- `saga.undo(step, fn(i, o) -> Result(Nil, u))` (`saga.gleam:271`)
- `saga.compensate(step, max_attempts:, with: fn(i, AttemptFailure(e), Attempt) -> Recovery(o, e, u))` (`saga.gleam:288`)
  - `AttemptFailure` is `Returned(e)|Crashed(Crash)|TimedOut` (`:47-51`).
  - `Attempt(number, remaining)` (`:40-42`)
  - `Recovery` is `Retry | RetryAfter(ms) | Continue(output, Undo(u)) | Abort(e) | AbortAfterCleanupFailure(e, u) | Hold(evidence: e)` (`saga.gleam:150-157`).
- `saga.timeout(step, ms)` bounds each attempt (`saga.gleam:319`).
- `saga.map_step_errors` (`:326`) and `saga.map_errors(workflow, error:, undo_error:)` (`:1187`)
- **Typed ports:**
  - `saga.perform(input: Port(i,e,u), step) -> Port(o,e,u)` (`:586`)
  - `saga.map(port, fn)` (`:525`, not memoized; it runs inside the consuming task)
  - `saga.both(a, b) -> Port(#(a,b))` (`:537`)
  - `saga.all(first, rest: List(Port(a))) -> Port(List(a))` (`:560`)
  - `saga.embed(input, workflow)` composes a workflow in sequence, sharing the same run and journal (`:1133`)
- `saga.define(name, build: fn(Port(i,e,u)) -> Port(o,e,u)) -> Result(Workflow(i,o,e,u), List(DefinitionError))` (`saga.gleam:812`).
  - The builder runs **once** at define time, and the graph is static afterwards (`saga.gleam:753-797`).
  - `DefinitionError` is `EmptyWorkflowName | EmptyStepName | InvalidMaxAttempts | InvalidTimeout | ForeignPort | OrphanStep` (`:171-183`).
- `saga.describe(wf) -> List(StepDescriptor(address, depends_on, undoable, compensates, max_attempts, timeout))` (`:187-198`, `:1106`)
- **Dynamic fan-out:** there is no `and_then`, `traverse`, or `traverse_parallel`. They are listed as Deferred in `CAPABILITIES.md:106-107`.
  - The workaround is to call `saga.define` at runtime, once per model turn, with one `perform` per tool call, combined with `saga.all`.
  - **Verified in the probe:** `turn_workflow(["a","b","c"])` returned `Completed(["a","b","c"])` and `[]` returned `Completed([])`.
  - `define` is cheap, O(N). Step names must be non-empty, and repeated names get an `#n` suffix.

### 2.2 Running

- `execution.config() -> Config(max_concurrency: schedulers_online, deadline: None, step_timeout: Some(60_000), settle_timeout: 5000, cleanup_timeout: 5000)` (`src/saga/execution.gleam:29-64`). `validate` collects every violation (`:78`).
- `execution.run(workflow, input, config) -> Result(Outcome, RunError)` blocks (`:312`). `RunError` is `InvalidConfig | ExecutionLost(Crash)` (`:111-114`).
- `execution.start(...) -> Result(Execution(o,e,u), RunError)` does not block (`:355`).
  - `execution.await(execution, timeout:)` is **owner-only**, meaning only the process that called `start` may await (`:571-588`). `AwaitError` is `AwaitTimedOut | NotOwner | AlreadyAwaited | Lost(Crash)` (`:265-270`).
- `Outcome(o,e,u)` (`:197-203`) has these variants:
  - `Completed(o)`
  - `CompletedWithUnknownEffects(o, unknown_effects)`
  - `Failed(cause: Cause(e), settlement)`
  - `Cancelled(reason: CancelRequested|OwnerExited, settlement)`
  - `Unresolved(step, evidence: e, settlement)`
- `Cause` is `StepFailed | StepCrashed | StepTimedOut | RetryLimitReached | RetrySuperseded | OutputCrashed` (`:127-138`).
- `Settlement` fields are `undone`, `undo_failures`, `not_undoable`, `held`, `interrupted`, `compensation_failures`, and `sibling_failures` (`:168-178`).
- **Concurrency:** `Config.max_concurrency` bounds a single run only. Budgets shared across runs or nested runs are Deferred (`CAPABILITIES.md:121-122`).
- **Timeouts:**
  - Per-step `saga.timeout`, falling back to a default `step_timeout` of 60s.
  - A per-run `deadline` that is opt-in.
  - A timed-out attempt is killed and reported `interrupted`, and its effect is treated as unknown, never undone (`execution.gleam:16-20`).

### 2.3 Cancellation, compensation, observation

- **Cancellation:**
  - `execution.cancel(execution)` sends an async, idempotent `CancelRequest` (`execution.gleam:606-614`). Any holder of `Execution` may call it; only `await` is owner-restricted.
  - It stops admitting new steps and gives in-flight steps `settle_timeout` to finish. **Survivors are killed** and reported `interrupted` with unknown effect.
  - Completed steps are then undone in reverse completion order, each undo bounded by `cleanup_timeout`.
  - Owner exit also cancels (`OwnerExited`).
  - Worst-case duration is `deadline + settle_timeout + (undone + compensations) * cleanup_timeout` (`:8-14`).
- **Compensation:**
  - Covers retry and backoff decisions, replacement output (`Continue`), and reverse-order undo.
  - `Hold(evidence)` leaves effects unresolved with no rollback, and the outcome becomes `Unresolved` (`saga.gleam:143-157`).
  - Undo is not retried (`CAPABILITIES.md:125-126`).
  - Post-success undo of a completed run is Deferred.
- **Progress:**
  - `execution.progress(execution, timeout:) -> Result(Progress(run_id, phase: Running|Settling|RollingBack, steps: List(StepProgress(address, state))), ProgressError)` (`:628-649`)
  - `StepState` values: Waiting, Attempting(n), Compensating(n), RetryScheduled(n), Succeeded, FailedStep, Interrupted, Undoing, Undone, UndoFailedStep, and Skipped (`:217-229`).
  - `execution.pid` and `execution.run_id` are available (`:651-658`).
  - `saga/testing.wait_until(execution, matching:, within:)` polls until a predicate matches (`src/saga/testing.gleam:43`).
- **Sinal events** (`src/saga/observation.gleam:237-425`): `[saga,run,start]`, `[saga,run,stop]`, `[saga,step,start]`, `[saga,step,stop]`, `[saga,step,compensate,stop]`, and `[saga,step,undo,stop]`. Emit errors are ignored, because observations never control a run (`observation.gleam:6-10`).

### 2.4 Suspension, durability, and children: none shipped

- Nothing in `src` provides suspend, pause, wait-for-signal, or resume. The only "journal" is an in-memory list of undo closures (`internal/coordinator.gleam:44-52`).
- `Hold` / `Unresolved` is **terminal**. It releases the run with effects left in place, and nothing can resume it.
- A step can block in-process on a `Subject` to wait for an approval, but only up to its timeout. That wait is not durable, holds a concurrency slot, and a cancellation kills it.
- `CAPABILITIES.md:94-122` lists these as **Deferred**:
  - Durable execution (PostgreSQL journals, checkpoints, freeze/thaw, snapshot codecs, restore)
  - `saga_grind`, the optional runner
  - Durable approvals and approval signals
  - Process-loss resume and in-memory halt/resume
  - Independent children
  - `and_then`/`traverse`
  - Fabric/LLM nodes, bounded agent loops as nodes, and suspending agents
  - Supervisor integration
  - Stable persisted step identities
- There is no `saga_grind` directory under `/code/gleam-dream`.
- Closure serialization is **Excluded** (`CAPABILITIES.md:132-134`).

### 2.5 Design (`oversight/saga-design.md`) versus shipped

| Design element                                               | Design says                                                                                                                                                                                                                                                                                                                                                 | Shipped                                                                                                                                                      |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Durable runner / freeze-thaw (`saga-design.md:536-584`)      | `saga_grind` owns progress, readiness, activity outcomes, revisions, child links, and compensation journals. Grind owns delivery. It needs memory and PG checkpoint backends, "review tickets, expected revision commits". Suspension "commits its wait and releases worker capacity". Approval signals require authentication, revision checks, and dedup. | None of it. The design itself says "the checkpoint and Grind modules contain interface evidence and unfinished bodies, not runtime guarantees" (`:579-584`). |
| Suspending agents (`:147-164`)                               | "An approval pause must suspend through one continuation owner rather than fail or rerun the agent … Suspended agents … remain unresolved required consumers"                                                                                                                                                                                               | Not implemented. Deferred.                                                                                                                                   |
| Dynamic `and_then` / `traverse_parallel` (`:483-534`)        | A proposed sketch, not an API                                                                                                                                                                                                                                                                                                                               | Absent. Runtime `define` is the workaround.                                                                                                                  |
| Independent children (`:586-630`)                            | Typed child contracts, admission receipts, attachment, and compensation authority                                                                                                                                                                                                                                                                           | Only `embed` (the same run). Children are Deferred.                                                                                                          |
| Running a whole local Saga inside one Grind job (`:560-563`) | Allowed, but after delivery loss the whole workflow restarts. It is not per-activity durability.                                                                                                                                                                                                                                                            | This is the only durable option available today.                                                                                                             |
| Capability table (`:1302-1329`)                              | "No … production scheduler, durable runner, or schema-graph implementation is claimed."                                                                                                                                                                                                                                                                     | Consistent with shipped. The local scheduler with concurrency, cancel, and timeouts _is_ now shipped.                                                        |

### 2.6 Fabric turn pipeline: what Saga provides and what is missing

Target pipeline: model turn, then parallel tool calls, then a durable approval pause, then resume, then the next turn.

| Need                                                                 | Saga today                                                                                                                                                                                                                                                                         |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Run one model call as a step with timeout and retry                  | Yes: `step`, `timeout`, and `compensate`, with `RetryAfter` for backoff. Pair it with llm_wire `RetryEvidence` so that only `NoRequestSent` is auto-retried.                                                                                                                       |
| Fan out N tool calls in parallel, bounded, and collect typed results | Yes, via `saga.define` at runtime per turn, `all`, and `max_concurrency`. Verified in the probe.                                                                                                                                                                                   |
| Undo or compensate side-effecting tools on failure                   | Yes: `undo` runs in reverse order, and `Hold` covers ambiguous effects.                                                                                                                                                                                                            |
| Cancel an in-flight turn                                             | Yes: `execution.cancel`. In-flight tools are killed after `settle_timeout` and reported interrupted. Killing the step process that owns an llm_wire stream also closes the stream through the owner monitor.                                                                       |
| Live progress                                                        | Yes: `progress` and the Sinal events.                                                                                                                                                                                                                                              |
| **Approval pause (durable)**                                         | **Missing.** There is no waiting state. Options: (1) end the turn workflow before gated tools, with Fabric persisting a pending-approval record, and start a fresh workflow on resume; (2) use `Hold`/`Unresolved` as the "stop here" signal, which is terminal and not resumable. |
| **Resume after restart**                                             | **Missing.** There is no journal, checkpoint, or restore. Fabric must own a versioned continuation record (as `fabric-design.md:57-58` also asks) and rebuild the llm_wire transcript from public messages (§1.2).                                                                 |
| Multi-turn loop                                                      | There are no cycles or `and_then`. Iteration must live inside a node, as `saga-design.md:158-160` specifies, or in Fabric's own controller. Use one Saga run per turn.                                                                                                             |
| Durable per-activity execution, `saga_grind`, and children           | Missing. Grind-based delivery must carry a Fabric run reference (§6).                                                                                                                                                                                                              |
| Budgets shared across nested runs                                    | Missing. Only per-run `max_concurrency` exists.                                                                                                                                                                                                                                    |

**Conclusion:** use Saga as the _local, per-turn_ executor for a tool-call batch, with typed results, timeouts, cancellation, and compensation. Fabric must own the loop, approval suspension, the persisted continuation record, and resume. Durability comes from Fabric's store plus Grind jobs, not from Saga.

---

## 3. json_blueprint

- **Version status.** The package reports version 1.7.1, but this branch holds an **unreleased 2.0**:
  - `CHANGELOG.md:3` reads "Unreleased — intended 2.0", and `:11` says "manifest version remains 1.7.1 until a release decision".
  - The migration guide is `docs/migration-2.0.md`.
  - Hex has 1.7.1, which is the legacy `Decoder` API. The new modules are unpublished, so **Fabric needs a path dependency**. llm_wire and relay already use one.
  - Recent commits on the branch:
    - `ca50b5a` "feat!: simplify Blueprint codecs and retire the migration adapter"
    - `f908501` "feat!: configurable strict decoding and fallible codec mappings"
    - `ecf5c60` "docs: prepare Blueprint 2.0 migration"
- **API choice.** Use `json/blueprint/codec.Codec(a)`, which `docs/migration-2.0.md:5` calls the canonical definition.
  - The legacy `json/blueprint.Decoder` is kept for recursive types. It is not deprecated.
  - Neither llm_wire nor relay uses the legacy API.
- **Public modules.**
  - Legacy: `json/blueprint`, `json/blueprint/dynamic`, `json/blueprint/schema`.
  - New:
    - `codec`
    - `value`: the exact JSON `Value` ADT
    - `number`
    - `json_text`: `render_value`
    - `parser` and `parser_limits`
    - `runtime`: contracts and validation
    - `document`: loads Draft 2020-12 documents
    - `codegen`
  - `json/blueprint/internal/*` is internal.
- **Codec constructors.** Line numbers are in `src/json/blueprint/codec.gleam`.
  - Scalars: `string()` 1004, `int()` 1009, `number()` 1014, `bool()` 1019, `integer_between` 1503, `number_between` 1522, `string_enum` 1308.
  - Containers: `list` 1038, `pair` 1024, `nullable` 1055.
  - Object properties:
    - `required(name, c)` 1089
    - `optional(name, c)` 1098, which yields `Missing|Present`
    - `optional_option` 1109, which yields `Option`
    - `combine` 1130, then `object(props)` 1156
  - Records and fields: `record2` 1171 and `record3` 1198 return `Result(Codec, PropertyError)`. `field(name, c)` 1229 builds a single-key object.
  - Unions: `tagged(l_tag, l, r_tag, r)` 1414 supports **two cases only**, using a `{tag, value}` envelope.
  - Mapping: `imap` 971 and `try_imap` 981.
  - Custom codecs: `new` 124 has no schema, and `from_parts(enc, dec, schema)` 131 takes one.
- **Unknown fields.** Object codecs **reject unknown fields** (`codec.gleam:1275-1291`). Blueprint 1.x ignored them.
- **Encoding and decoding.**
  - `encode(codec, a) -> Result(Value, EncodeError)` (:261)
  - `decode(codec, Value) -> Result(a, DecodeError)` (:265)
  - `encode_json(codec, a) -> Result(String, _)` (:172)
  - `decode_json(codec, String) -> Result(a, JsonDecodeError)` (:180) uses a strict parser: 10 MiB, depth 128, and duplicate keys rejected.
  - `decode_json_with_limits` is at :189. `decode_json_native` at :199 goes through gleam/json.
  - **There is no public `Codec(a)` decode from `Dynamic`.** The `decode_native_*` helpers at :761-923 take decoder functions, not a codec. Route through a JSON string or `parser.parse_value_from_string(limits, s)` (`parser.gleam:69`), then `codec.decode`.
  - **There is no public `Value -> gleam_json Json` conversion.** llm_wire and relay each carry an internal one. Render with `json_text.render_value` instead.
- **Deriving a tool schema.**
  - `codec.schema(c) -> Result(Schema, SchemaError)` (:269) returns `UnknownSchema` for `new`-built codecs.
  - `codec.schema_json(c) -> Result(String, _)` (:276) returns a full Draft 2020-12 document.
  - `codec.schema_value(Schema) -> Value` is at :1559 and `schema_document` at :1637.
  - Objects always emit `additionalProperties:false`.
  - llm_wire consumes `codec.Schema` directly (§1.1).
- **Gap for LLM tools: no field descriptions.**
  - The `Schema` ADT has no `description` or `title` (`codec.gleam:94-112`), so property descriptions cannot reach the model through a codec.
  - `document.load` rejects keywords that are not supported, such as `description` or open objects (`document.gleam:213-234`, `:631`).
  - llm_wire `ToolDefinition` accepts only a `codec.Schema` or a `RuntimeContract`, so it has no raw-JSON-schema passthrough.
- **Runtime contracts.**
  - Build them with `runtime.from_codec` (:35) or `from_schema` (:28).
  - `validate(contract, Value) -> Result(ValidatedValue, ValidationError)` (:75) reports errors with a path.
  - `runtime.decode(codec, ValidatedValue)` is at :97.

## 4. sinal

Public modules are `sinal`, `sinal/fields`, `sinal/span`, `sinal/forwarder`, and `sinal/exception`.

- **Defining an event.**
  - `sinal.event(name: List(Atom), measurements: Fields(m), metadata: Fields(d)) -> Result(Event(m, d), EventError)` (`src/sinal.gleam:25`). `Event` is opaque, and the only error is `EmptyEventName`.
  - Field builders in `sinal/fields.gleam`:
    - `empty` :33, `string(Atom)` :86, `int` :96, `bool` :106
    - `field(key, enc, dec)` :50
    - `optional` :132
    - `pair` :175, which rejects duplicate keys
    - `imap` :211
- **Emitting.**
  - `sinal.emit(event, m, d) -> Result(Nil, EmitError)` (:214) runs **synchronously in the caller** through `telemetry:execute`. The only error is `EncodingFailed`.
  - Spans:
    - Define with `span.define_span(prefix, start_meta, extra_measurements, stop_meta)` (`span.gleam:176`). Reserved keys are rejected.
    - Run with `span.run_span` (:314), which panics if the start metadata fails to encode, or `span.run_span_result` (:289), which returns `SpanOutcome` and does not panic.
    - `span.events(span)` returns the start, stop, and exception descriptors.
- **Subscribing.**
  - `sinal.handler_id(String)` :56.
  - `attach(id, event, handler: fn(Event, m, d) -> Result(Nil, e), on_failure)` (:252).
  - `observe(id, event, fn(m, d) -> Nil)` (:265).
  - `attach_many` :282 and `detach(Attachment)` :186.
  - Scoped forms: `with_attachments` :388, and `subscription` :166 / `subscriptions` :173 / `with_subscriptions(plan, run)` :431, which detaches in reverse order.
- **Test capture.** Sinal ships no helper module, so tests use one of two patterns:
  - **Same process:** attach a handler that does `process.send(subject, meta)`, then `process.receive` and `detach` (`relay/test/relay/telemetry_test.gleam:12-28`, `llm_wire/test/llm_wire_api_test.gleam:458-469`).
  - **Cross-process:** run the work inside `with_subscriptions` with a collector process (`saga/test/observation_test.gleam:30-86`).
- **Failure semantics.**
  - Delivery is synchronous, and handler order is unspecified (`sinal/README.md:22`, `:401-402`).
  - When a handler returns `Error` or the decode fails, sinal calls `on_failure` and raises. Native `:telemetry` then **detaches that handler** and emits `[telemetry, handler, failure]`, but the emitter does not crash (`sinal.gleam:340-359`, `README.md:23`).
  - `emit` never reports handler failures to the emitter.
  - `detach` does not wait for callbacks that are already in flight.
- **Forwarder** (`sinal/forwarder.gleam`).
  - An opt-in, bounded, best-effort async hop.
  - API: `new(name, capacity)` :128, `supervised(fwd) -> ChildSpecification` :141, `emit` :252.
  - Errors: `ForwardEncodingFailed|CapacityExceeded|ForwarderUnavailable`. Drops are reported as `[sinal, forwarder, dropped]`.
  - Spans cannot be forwarded.
  - The forwarder is newer than the `13105bb` pin used by saga and relay.
- **Pattern for Fabric to copy.**
  - Put the events in one `fabric/observation` module.
  - Give each event its own metadata and measurement record types, with a `pub fn x_event()` that builds `Fields` via `pair` + `imap` and uses `let assert Ok` on a constant name.
  - Keep the emit helper internal and ignore emit errors.
  - Emit only after the state transition, with low-cardinality metadata and no content.
  - Model closed enums with saga's `closed_string_field` (`saga/observation.gleam:209-234`).
  - Reference implementations: `llm_wire/telemetry.gleam:30-48`, `relay/telemetry.gleam:39-200`, `saga/observation.gleam:237-256`.

## 5. relay (MCP)

relay provides an MCP server and client for the 2026-07-28 revision, over stdio and Streamable HTTP.

- **Tool definitions** (`src/relay/tool.gleam`).
  - Names: `tool_name(String)` :28 accepts 1-128 characters from `[A-Za-z0-9._/-]`. Some LLM providers reject `.` and `/`, so Fabric must re-validate names.
  - Constructors:
    - `definition(name, input: Codec(i), output: Codec(o)) -> Result(Definition(i, o), ToolAdmissionError)` :308. The input schema must be an object, field, or tagged schema.
    - `content_definition(name, input)` :249.
  - Metadata:
    - `with_description` :356 and `with_title` :369.
    - `with_annotations(ToolAnnotations(title, read_only_hint, destructive_hint, idempotent_hint, open_world_hint))` :379/:124.
    - `with_input_schema_override(def, Value)` :278 is the only way to advertise field descriptions. The codec still decodes.
  - Accessors: `definition_input_codec` :336, `definition_output_codec` :342, `definition_metadata` :330.
  - Handlers:
    - `handle(def, fn(input) -> Result(output, e))` :498.
    - `handle_with_error_renderer` :508.
    - `handle_advanced(def, fn(HandlerCallContext(ctx), input) -> Result(HandlerResult(o), e))` :545. The context carries `application: ctx`, `input_responses`, and `report_progress` (:447). `HandlerResult` is `Complete(o, content) | Content(blocks) | NeedsInput(dict)` (:456).
  - Registry and dispatch:
    - `registry` :707, `register` :714.
    - `declarations(reg, ctx) -> List(ToolDeclaration(name, metadata, input_schema: codec.Schema, override, output_schema))` :778/:424.
    - `dispatch(reg, ctx, name, args: Value) -> Result(Value, DispatchError)` :838, plus `dispatch_with_content` :856 and `dispatch_with_progress` :867.
    - `DispatchError` is `UnknownTool | InvalidInput | PublicApplicationFailure(String) | ContentOnlyOutput | InvalidOutput | InputRequiredOutput` (:487).
- **Sharing tools with Fabric works.** The same `Codec` and handler serve both sides:
  - To declare a tool to the LLM, call `llm_wire types.tool_from_codec(name, desc, tool.definition_input_codec(def))` or `tool_from_contract(name, desc, runtime.from_schema(decl.input_schema))`.
  - To execute a call:
    1. Run `parser.parse_value_from_string(arguments_json)`.
    2. Pass the value to `tool.dispatch_with_content`.
    3. Render the result into `ToolResult(content: String)`.
  - The adapter also has to:
    - map name grammar,
    - turn `Option(String)` descriptions into a `String`,
    - handle schema overrides, since llm_wire cannot carry them,
    - decide what `NeedsInput`/`InputRequired` means for an LLM, which has no analogue,
    - map `DispatchError` to model-visible text.
- **Authorization** (`src/relay/authorization.gleam`).
  - It is an OAuth resource-server seam: `BearerToken`, `Verifier(principal)` :105, and `admit(verifier, token, ProtectionConfig) -> GrantedRequest(p)` :200.
  - `tool_policy(visibility:, execution:)` :173 builds a policy. Its callbacks receive `(ctx, GrantedRequest, ToolDeclaration)` and **never see the arguments**.
  - `protect_registry` :191, `dispatch_granted` :263, and `visible_declarations` :301 apply it.
  - Nothing in `relay/src` other than this module references it; only tests do. It is a standalone library seam.
  - It cannot serve as Fabric's per-action approval gate, because that gate needs the arguments.
- **Client.**
  - Connect with `http_config(url)` :112 + `connect_http` :274, or `stdio_config` :300 + `connect_stdio` :626.
  - `list_tools(client) -> Result(List(ToolDeclaration), String)` :714. Here the `input_schema` is `json.Json`.
  - `call_discovered(client, decl, args: Value) -> ToolCallOutcome(Value)` :906 is meant for forwarding a provider tool call. There is also `call_definition` :882 and `resume_tool` :926.
  - Remote MCP tools can therefore be exposed to an LLM, **but** their arbitrary JSON schemas must first become a `RuntimeContract` via `parser.parse_schema_document_from_string`. That step often fails on `description`, open objects, or untagged unions. llm_wire has no raw-schema passthrough, so a gap remains.
- **`runtime.gleam`** is the per-connection MCP server actor:
  - `start` :161.
  - Tool invocations run in unlinked, monitored workers with a 30s timeout.
  - It emits the relay telemetry events.
  - Fabric does not need it unless Fabric hosts an MCP server.

## 6. grind (tree dirty; library src is stable)

- **Repository state.**
  - `git status --short` shows these as modified: `.github/workflows/ci.yml`, `AGENTS.md`, `README.md`, `docs/RISKS.md`, `docs/UNIQUENESS-CONTRACT.md`, `src/grind/internal/migrations.gleam`, and `test/grind_test.gleam`. `test/grind/` is untracked.
  - `git diff --stat -- src` shows only `src/grind/internal/migrations.gleam`, and that change is a doc comment pointing to the new test path (lines 12-13).
  - The large diff is `test/grind_test.gleam` being split into `test/grind/**`.
  - **The public library code matches HEAD `9eeb9ad`.** Only test layout and docs are in flux.
- **Public modules.**
  - `grind/worker`:
    - `Codec(v)` is a versioned gleam_json encoder plus a `decode.Decoder` (worker.gleam:21). It uses gleam_json, **not Blueprint**.
    - `define` / `define_with_error_codec` (:162/:173).
    - `with_queue_handler` (:222), `with_retry_policy` (:233), `with_max_attempts` (:123).
    - `WorkerResponse` is `WorkerSucceeded | WorkerFailed | WorkerSnoozed(RetryDelay, reason) | WorkerDiscarded | WorkerCancelled | WorkerUncertain` (:73-80).
  - `grind/job`:
    - `JobHandle(i, o, e)` is opaque.
    - `State` has 11 states (:140-151).
    - `Outcome` is at :200-211.
  - `grind/registry`: `new(queue)`, `register`. Each registry serves one queue with many worker types.
  - `grind/queue`:
    - `QueuePolicy` :39.
    - `default_policy` :69 polls every 250ms, runs concurrency 1, and uses a 30s lease.
    - `start` :536, `process_one` :863, `process_available` :930, `stop` :963.
  - `grind/postgres`:
    - `settings`, `start`, `migrate` :1369.
    - `submit` :2010, `submit_at` :2027, `submit_with_id` :3443 (idempotent receipt), `submit_unique` :3363.
    - `reconcile_unique` :3515, `bind_handle` :2253, `state`, `outcome`.
    - `cancel` :2401, `resolve_uncertain` :720-790, `prune_finished`.
  - Also public: `grind/unique`, `grind/submission`, `grind/pruner`, and `grind/observation` (Sinal events, emitted through a per-database forwarder, best-effort).
- **Handlers.**
  - `perform: fn(input) -> Result(output, error)` receives **no job context**: no job id, no attempt number, no cancel flag (worker.gleam:154).
  - Workers default to 20 max attempts.
  - The default backoff is 15s·2^(n-1), capped at one day.
- **What Grind does not support.** Grind has no priority, no per-job execution timeout (the lease renews indefinitely), and no cron.
- **Admission.**
  - `SubmitError` includes `CommitUnknown` and `CommitUnknownWithoutId`. A plain `submit` retried after a lost reply can duplicate the job.
  - **There is no enqueue inside a caller's pog transaction.** Grind owns its `Database` and pool, and `postgres.connection` is `@internal` (postgres.gleam:2703-2711). An atomic "persist Fabric state + enqueue" is therefore impossible. The workaround is `submit_with_id` with a deterministic id.
- **Uniqueness.**
  - Keys: `unique.full_input()` or `selected(name, fn(input) -> key, Codec(key))`.
  - Scope: `WithinQueue` or `AcrossQueues`.
  - Period: `within_milliseconds` or `while_retained`.
  - State sets:
    - `Incomplete` is queued, scheduled, retryable, executing, and uncertain (`unique.gleam:196`).
    - Also `ScheduledOnly`, `IncompleteOrSucceeded`, and `AllRetained`.
  - On conflict: `KeepExisting` or `RescheduleScheduledTo`.
  - Admission takes an advisory lock with a 2s wait, then returns `AdmissionContended`.
- **Delivery.**
  - Documented as at-least-once, fenced by attempt id, epoch, and owner.
  - A crash, panic, or lease loss **quarantines the job as `uncertain`**. It is not retried automatically: it needs `resolve_uncertain(ConfirmSuccess | ConfirmBusinessFailure | AuthorizeReplay)`.
  - Cancelling a running job is cooperative. The worker is not interrupted, and its result is committed as `cancelled`.
  - Snooze re-schedules the job with the same input, refunds the attempt, and has no limit (`internal/attempt.gleam:1113`).
- **Lifecycle.**
  - `queue.start` builds its own supervisor, and the caller process owns it. `stop` from any other process fails with `ConsumerOwnedByAnotherProcess`.
  - There is **no `supervised` child spec** for the queue or for `postgres.start`. Only `pruner.supervised` exists.
- **PostgreSQL is required, including for tests.**
  - There is no in-memory store or inline mode; that is backlog in `docs/IMPLEMENTATION-SCOPE.md:381`.
  - Database tests are guarded by the environment variables `GRIND_TEST_DATABASE_URL` and others. When those are unset, the tests are no-ops.
  - `scripts/test-postgres.sh` runs `initdb` on a throwaway postgresql_16 cluster.
  - `queue.Manual` + `process_one` gives deterministic stepping against a real database.
- **Migrations.** Use either `postgres.migrate(db)` (forward-only, schema v12) or cigogne with `priv/migrations/*grind_v11.sql` and `*grind_v12.sql`. Never use both on the same database. `with_schema` isolates the tables.
- **Best reference.** `grind/consumer/test/grind_consumer_test.gleam` (1183 lines) is a public-API-only example covering:
  - typed workers,
  - idempotent dedup,
  - cancellation,
  - uncertain resolution,
  - uniqueness,
  - `submit_with_id`.
- **Sketched Fabric integration.** The job carries a run reference only, `TurnArgs(run_id)`, with codec `"fabric.turn/1"`:
  1. `perform` loads the continuation record from Fabric's store and runs one turn.
  2. It persists the result using compare-and-set, keyed by turn sequence.
  3. It returns `WorkerSnoozed(0ms)` for "more turns", `WorkerSnoozed(poll)` while awaiting approval, or `WorkerSucceeded` when done.
  4. Submission uses `submit_unique` with `selected("run_id")`, `WithinQueue`, `while_retained`, `Incomplete`, and `KeepExisting`, plus `submit_with_id("run:<id>")`. At most one active job exists per run.
  - Re-enqueueing a follow-up job from inside `perform` would hit the job's own `executing` row under `Incomplete` and return `Existing`. Snooze avoids this problem.
  - Alternatively, submit an approval job when the approval arrives, instead of polling.
- **Gaps Fabric must cover itself:**
  - no job context,
  - no transactional enqueue,
  - no child spec,
  - no execution timeout,
  - no interrupting cancel,
  - no lookup by unique key (the job id must be persisted),
  - a sweeper to auto-resolve `uncertain` jobs from Fabric receipts,
  - PostgreSQL for integration tests,
  - an unpublished package with a path dependency on sinal and tight pog pins (`pog >=4.1 <4.2`, `pgo >=0.20 <0.21`).

## 7. warden

- HEAD is `a594edd`, a single commit that bootstraps the package skeleton.
- It is meant to be a typed OIDC / OAuth 2.0 relying party over oidcc (FFI).
- Its public API is only `version()` (`src/warden.gleam`).
- It is **not relevant** to the agent runtime. It might matter later for identity in the authorization seam.

## 8. Cross-cutting takeaways for Fabric

1. **Persistence is Fabric's job.**
   - llm_wire continuations are opaque, hold an Erlang ref, config, and closures, and cannot be serialized.
   - Saga has no journal or suspension.
   - Grind carries only a reference.
   - Fabric therefore needs its own versioned continuation record: transcript as `List(Message)` plus `ToolCall` records including `provider_id`/`provider_state`, outstanding call ids, results, approval state, and budgets.
   - It also needs a JSON codec for llm_wire's public types. On resume it rebuilds the request with `session.prepare`. The live `Continuation` serves only within one process lifetime.
2. **Fake models need a Fabric-owned port.** llm_wire custom providers still require HTTP/SSE. Define a Fabric model port with an llm_wire implementation and a pure scripted implementation. Use a mist/TCP SSE fake only for adapter integration tests.
3. **Tool contract.** Use Blueprint `Codec(i)` for input. With llm_wire `tool_from_codec`, Fabric still decodes `arguments_json` itself with the same codec (`codec.decode_json`). Tool results are `String`. Field descriptions are not supported anywhere in the codec/llm_wire path.
4. **Per-turn execution.**
   - Define a Saga workflow at runtime for each batch of tool calls, and run it with `execution.start`, `await`, `cancel`, and `progress`.
   - Approval gating happens _before_ the workflow, in Fabric: split the calls into approved and gated, and persist the pending approvals.
   - Retry of model calls should be decided on llm_wire `RetryEvidence.classification`, at one layer only.
5. **Approval pauses and resume** are not provided by Saga (design only). Implement them in Fabric's store. Grind snooze or re-submit can drive durable resume, and Grind needs PostgreSQL.
6. **Dependencies.**
   - Use path deps `../llm_wire`, `../json_blueprint`, `../sinal`, and `../saga`. `../relay` is optional; it brings mist 6.0.2 and gun 2.6.0 pins. `../grind` is optional; it brings pog, pgo, and the Postgres requirement.
   - These resolve and compile with the cached hex packages under gleam 1.18.1 and OTP 28 (probe verified).

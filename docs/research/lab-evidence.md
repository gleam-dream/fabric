> Research evidence produced 2026-09-27 by read-only inspection and execution of sibling repositories and BeamWeaver; the scratchpad paths it references (`/private/tmp/claude-501/...`, `$SP/...`) were ephemeral and may no longer exist.

# Fabric: digest of the oversight design evidence and interface laboratory

- Source: `/code/gleam-dream/oversight` at `f3c373d805e6cd6d4021df9c8cff6b483c58f86a`. The laboratory is `playground/interface_lab/` (abbreviated `lab/` below; `src/lab/*` and `src/consumers/*` are relative to it).
- Delivered sibling packages were checked only where they contradict the lab: `llm_wire@36dbc25`, `sinal@f4622b6`, `saga@f241395`, `grind@9eeb9ad`, `relay@c0510b3`.
- "Inference" marks my own conclusions. Everything else cites a file.
- The lab is pure. Every Fabric claim below is type evidence plus pure scripted probes. No process, store, clock, or transport is exercised (`lab/README.md`, "What the evidence can establish").

---

## 1. Proven decisions to reuse

Each decision is demonstrated by a positive consumer probe (`let assert` chains run by `stress_checks`), a compile-failure fixture (`negative/*.gleam` + `.expect`), or both.

### D1. Heterogeneous registry holding typed handlers, with per-call context

- **Decision.** A tool captures its typed handler together with its input, output, and error codecs, then erases them into one opaque invocation closure. This requires no `Dynamic`. The registry is built once and context-free. Request context is supplied at dispatch and is not part of the encoded business input. The registry rejects duplicate names and tools whose schema is unavailable. Declarations are derived from the same codec that decodes the input.
- **Shape** (`src/lab/fabric.gleam`):
  ```gleam
  pub opaque type ContextTool(context)
  pub fn context_tool(name: String, input: Codec(i), output: Codec(o), error: Codec(e),
                      handler: fn(context, i) -> Result(o, e)) -> ContextTool(context)
  pub opaque type Registry(c)
  pub fn registry(tools: List(ContextTool(c))) -> Result(Registry(c), RegistryError)
  pub type RegistryError { DuplicateName(String)  InvalidDeclaration(String, blueprint.SchemaError) }
  pub fn declarations(registry: Registry(c)) -> List(Declaration)
  pub type Declaration { Declaration(name: String, input_schema: blueprint.Schema) }
  pub fn dispatch(registry: Registry(c), context: c, name: String, input: Value) -> Result(Value, DispatchError)
  pub type DispatchError { UnknownTool(String)  InvocationFailed(ToolError) }
  pub type ToolError { InputRejected(DecodeError) OutputRejected(EncodeError) ErrorRejected(EncodeError) ActionFailed(Value) }
  ```
- **Evidence.**
  - `consumers/derived_catalog.gleam` builds a registry of unrelated tools. It asserts that the declaration schema equals the codec schema and that `dispatch(fr, 20, "lookup", {id:7}) == Ok(Int(27))`. It also asserts `DuplicateName("lookup")` and `InvalidDeclaration("custom", UnknownSchema)`.
  - `consumers/shared_registry.gleam` shows the same application function bound as both a Relay and a Fabric context tool. Contexts stay independent, and a policy error arrives as `ActionFailed`.
  - Negatives: `negative/registry_context` (a `Registry(Int)` dispatched with a `String` context), `negative/wrong_tool_context` (a `ContextTool(WriteContext)` invoked with a `ReadContext`), and `negative/tool_codec` (a codec that disagrees with the handler).
- **Keep:** the `ToolError` split between input decode, output encode, and error encode failures on one side and domain `ActionFailed` on the other. D6 maps that split onto host failure versus model-visible failure.

### D2. Action identity is scoped to the run, the controller start, and the turn

- **Decision.** The identity is `(run, incarnation, turn ordinal, provider call id)`. A provider call id alone is insufficient because providers reuse ids on later turns. The host issues a distinct trusted `Incarnation` for every independently started controller, including a restart of the same logical `RunId`.
- **Shape** (`src/lab/fabric_agent.gleam:16-66`):
  ```gleam
  pub opaque type RunId            pub fn run_id(value: String) -> RunId
  pub opaque type Incarnation      pub fn trusted_incarnation(value: String) -> Result(Incarnation, IncarnationError)  // rejects ""
  pub type ActionIdentity { ActionIdentity(run: RunId, incarnation: Incarnation, turn: Int, call_id: model.CallId) }
  pub type ActionDescription { ActionDescription(identity: ActionIdentity, name: String, arguments: Value, registration: ActionRegistration) }
  pub type ActionRegistration { Registered(fabric.Declaration)  Unregistered(String) }
  ```
- **Correction to the brief.** The exact arguments are **not** a field of `ActionIdentity` in the lab. They are carried by `ActionDescription`, by the internal `ActionSlot.call`, and by `PreparedInvocation.call`. Issued reports are matched by full-value equality (D5).
  - `fabric-design.md:31` does say "Action identity includes … exact arguments". That is a design/lab disagreement Fabric must settle.
  - Inference: include an argument digest in the persisted identity, or keep the arguments in the slot and require equality at acceptance.
- **Evidence.**
  - `consumers/agent_policy.gleam` `mixed_batch_probe`: call id `"reused"` appears in turn 1 and again in turn 2. The probe asserts `ActionIdentity(_, _, 2, CallId("reused")) != lookup_identity`, and the turn-1 report is rejected on turn 2 with `ForeignReport`.
  - `incarnation_and_issued_report_probe`: two incarnations of one `RunId` with identical call ids. A cross-incarnation report is rejected with `ForeignReport`, an approval reference with `WrongApprovalReference`, and an effect reconciliation with `UnknownEffectIdentity`.
- **Analogous negatives (other packages, same principle).** `negative/wire_id_as_exchange` (Relay: an untrusted wire `RequestId` cannot stand in for the owned `ExchangeId`) and `negative/attempt_id_as_epoch` (Grind: an `AttemptId` is not an `OwnershipEpoch`). Inference: Fabric should likewise keep the provider `CallId` distinct from the controller-minted `ActionIdentity`/`Incarnation`.

### D3. Policy is explicit, fails closed, and has three decisions

- **Shape** (`fabric_agent.gleam:102-123`):
  ```gleam
  pub type ApprovalRequirement { ApprovalRequirement(identity: String, version: Int) }
  pub type PolicyDecision { Allow  Deny(reason: String)  RequireApproval(ApprovalRequirement) }
  pub type PolicyError { PolicyUnavailable  PolicyRejected(String) }
  pub type Policy(context) = fn(context, ActionDescription) -> Result(PolicyDecision, PolicyError)
  ```
- **Rules.**
  - There is no default or implicit allow. `start` requires a `Policy(context)`.
  - `fabric-design.md:30` allows an explicitly named `always_allow` for parity tests only. ECOSYSTEM-PLAN says an allow-all policy "must not be described as evidence that approval and denial behavior works".
  - Policy runs before decoding, so predecode policy does not validate native argument types. Input-dependent authorization stays inside the typed handler.
  - `PolicyError` becomes a **host failure**, never a model-visible denial.
- **Evidence.**
  - `agent_policy.gleam`: the `panic_delete` tool uses a codec whose decoder panics ("policy denial happened after input decoding") and a handler that panics. `Deny` still yields a `ReportReady` without reaching either.
  - `rejection_and_policy_failure_probe`: `policy_available: False` produces `HostFailure(PolicyFailed(PolicyUnavailable))`, then `continue_model` returns `HostStoppedAdvance`.
  - Negative `agent_policy_context`: `inspect_action` with a context of the wrong type fails to compile.

### D4. Inspection, prepared invocation, execution, and report acceptance are four separate steps

- **Shape** (`fabric_agent.gleam`):
  ```gleam
  pub fn inspect_action(controller: Controller(context, continuation), context: context, identity: ActionIdentity)
    -> Result(#(Controller(context, continuation), Inspection(context)), InspectionError)
  pub type Inspection(context) { InvocationPrepared(PreparedInvocation(context))  ReportReady(ActionReport)
                                 ApprovalRequired(ApprovalRequest)  BudgetBlocked  InspectionBlocked(ControllerBlocker) }
  pub type InspectionError { UnknownAction(ActionIdentity)  ActionAlreadyInspected(ActionIdentity) }
  pub opaque type PreparedInvocation(context)   // retains registry, the exact context, the exact call, identity
  pub fn execute_prepared(prepared: PreparedInvocation(context)) -> ActionReport   // ONLY place a tool runs; does not advance the model
  pub fn report_unknown_effect(prepared: PreparedInvocation(context), evidence: String) -> ActionReport
  pub fn accept_report(controller, report: ActionReport) -> Result(Controller(context, continuation), ReportAcceptanceError)
  ```
- **Rules.**
  - Inspection never executes a tool.
  - The host chooses execution order and may run prepared invocations concurrently. Inspection imposes no serial order.
  - Only a `PreparedInvocation` can produce an `UnknownEffect`, so an uncertain effect cannot be issued for an action that was never dispatched.
- **Evidence.** Negative `approval_reference_is_not_invocation`: `execute_prepared(reference: ApprovalReference)` fails with "Type mismatch PreparedInvocation / ApprovalReference".

### D5. Report acceptance rejects foreign, repeated, premature, and substituted reports

- **Shape:**
  ```gleam
  pub opaque type ActionReport   // (identity, outcome)
  pub type ReportOutcome { ModelVisible(model.ToolResult, ModelVisibleKind)  HostFailure(HostFailure)  OutcomeUnknown(UnknownEffect) }
  pub type ModelVisibleKind { ToolSucceeded  DomainToolFailed(Value)  AuthorizationDenied(String)  ApprovalRejected  UnknownTool(String)  EffectReconciled }
  pub type HostFailure { PolicyFailed(PolicyError)  BoundaryFailed(BoundaryFailure)  RegistryMismatch(String) }
  pub type ReportAcceptanceError { ForeignReport(ActionIdentity)  ReportCallIdMismatch(ActionIdentity)  DuplicateReport(ActionIdentity)
    ReportDoesNotMatchIssued(ActionIdentity)  ReportNotReady(ActionIdentity)  ReconciliationMismatch(ActionIdentity)  UnknownEffectIdentity(ActionIdentity) }
  ```
- **Internal slot state machine** (`fabric_agent.gleam:221-229`): `Uninspected → Prepared | AwaitingApproval(req, rev) | ReportIssued(report)`, then `→ Accepted | HostHalted | ReconciliationRequired(effect)`.
  - A report produced by the controller itself (denial, unknown tool, policy failure, rejected approval) is stored as `ReportIssued`. Acceptance then requires `issued == report`, so an issued denial cannot be replaced by a success produced through another policy path.
- **Evidence.**
  - `mixed_batch_probe` accepts a report, then re-accepts it and gets `DuplicateReport`.
  - `incarnation_and_issued_report_probe` deliberately reuses one incarnation. A deny-all controller issues a denial, an allow-all twin executes, and the executed report gets `ReportDoesNotMatchIssued` against the issued state.
  - `package_observations.gleam` makes Sinal emission fail, then re-accepts and still gets `DuplicateReport`.

### D6. Disposition taxonomy: model-visible failure, host failure, uncertain effect

- **Model-visible (the model continues):** tool success, typed domain failure (`ActionFailed`), policy `Deny`, approval `Reject`, and an unregistered tool name. The unregistered-tool case reports `ToolFailed(id, Text("unknown_tool"))` and does **not** invent an uncertain effect.
- **Host failure (the controller halts with `HostStoppedAdvance`):**
  - policy error;
  - codec boundary failure (`InputDecodeFailed`, `OutputEncodeFailed`, `ErrorEncodeFailed`);
  - `RegistryMismatch`, where a tool known at inspection is missing at dispatch.
- **Outcome unknown:** blocks `continue_model` (`ReconciliationRequiredAdvance`) until `reconcile_unknown_effect(controller, effect, model.ToolResult)`. That call checks incarnation, call id, and slot, and requires `current_effect == effect`. It never authorizes a retry, and ordinary continuation or cancellation cannot clear it.
- **Evidence.**
  - `boundary_and_domain_failure_probe`: an output codec that cannot encode produces `HostFailure(BoundaryFailed(OutputEncodeFailed))` and then `HostStoppedAdvance`. A domain failure produces `DomainToolFailed` and the run finishes.
  - `reconciliation_probe`: `execute_prepared` runs, its result is discarded, and `report_unknown_effect(prepared, "dispatch reply timed out")` is accepted. `continue_model` returns `ReconciliationRequiredAdvance`. After reconciliation, `model_turns_used == 1`, so reconciliation does not consume a turn.

### D7. Approval: a reference with a revision, and a policy recheck against current context

- **Shape:**
  ```gleam
  pub opaque type ApprovalReference   // (identity, requirement, revision)
  pub opaque type ApprovalRequest     // requirement + reference
  pub type ApprovalAnswer { Approve  Reject }
  pub fn answer_approval(controller, current_context: context, reference: ApprovalReference, answer: ApprovalAnswer)
    -> Result(#(Controller(context, continuation), ApprovalResolution(context)), ApprovalAnswerError)
  pub type ApprovalResolution(context) { ApprovalInvocationPrepared(PreparedInvocation(context))  ApprovalReportReady(ActionReport)
                                         ApprovalRequiredAgain(ApprovalRequest)  ApprovalBlocked(ControllerBlocker) }
  pub type ApprovalAnswerError { WrongApprovalReference  StaleApprovalReference  ApprovalAlreadyAnswered }
  ```
- **Rules.**
  - An answer is checked against the latest controller state. Reference outcomes are distinct: wrong incarnation or run gives `Wrong`, a same-run revision or requirement mismatch gives `Stale`, and a slot no longer awaiting gives `AlreadyAnswered`.
  - The approval triggers a **policy recheck with the current context**. A current `Deny` or policy error wins over `Approve`. If the requirement changed and the answer is `Approve`, the result is `ApprovalRequiredAgain` with a new revision. `Reject` stays a model-visible `ApprovalRejected`.
  - The approved `PreparedInvocation` carries the **context used for the recheck**.
  - The revision is a controller-global monotonic `Int` (`approval_revision`).
- **Evidence.**
  - `mixed_batch_probe`: requirement `("purchase",1)`. Approving under `customer_a(2)` gives `ApprovalRequiredAgain`. The old reference then gets `StaleApprovalReference`. The new reference gives `ApprovalInvocationPrepared`, and repeating it gives `ApprovalAlreadyAnswered`.
  - `customer_b_recheck_probe`: approving under a context now denied gives `ApprovalReportReady(AuthorizationDenied)`. The purchase codec panics on `"panic-sentinel"`, which proves the denied action is never decoded.
  - Related Saga-lab negatives: `approval_loses_input` (an approval result must retain the original proposal; see `consumers/approval_context.gleam`) and `approval_answer`.

### D8. The continuation stays bound to the provider that produced it

- **Decision.** A pending turn keeps the originating provider together with its continuation, and `resume` accepts results but **no provider argument**. Two providers that share a continuation type cannot be swapped. Result-set validation (missing, duplicate, or unknown ids) runs **before** the provider is contacted.
- **Lab shape** (`src/lab/fabric_turn.gleam`, `src/lab/llm_turn.gleam`):
  ```gleam
  pub opaque type Pending(c)   // provider: model.Provider(c), continuation: c, calls: List(model.ToolCall)
  pub fn resume(pending: Pending(c), results: List(model.ToolResult)) -> Result(Next(c), TurnError)
  pub type TurnError { ModelFailed(llm.CallError) EmptyToolBatch DuplicateCallId(CallId) UnknownToolResult(CallId) DuplicateToolResult(CallId) MissingToolResult(CallId) }
  ```
- **Evidence.**
  - `agent_policy.gleam` `effect-provider-a/b` share the native type `SingleState`, and each still finishes with its own provider's output.
  - `consumers/tool_turns.gleam` runs two continuation shapes: `PreviousResponseId` (server-state style) and `Transcript` (replay style). `invalid_results_probe` rejects missing and duplicate results before continuation.
  - Negatives: `wrong_continuation` and `agent_continuation` (`Controller(String, Int)` is not `Controller(String, Bool)`).
  - LLM side: `PROVIDER-STRUCTURED-TURNS.md`, `STREAM-OWNERSHIP.md`, and the negatives `prepared_stream_source` and `owner_as_pending`.
- **Delivered form.** `llm_wire/session.gleam` realizes this without a type parameter. `pub opaque type Continuation { Continuation(source: PreparedCall, replay: api.Continuation) }` and `pub fn prepare_continue(pending: Continuation, results: List(types.ToolResult)) -> Result(PreparedCall, types.WireError)`. It rejects missing, duplicate, extra, wrong-provider, and stale results before transport (`docs/implementation/relay-llm-wire/llm-wire-wave2-work-order.md`).
  - Inference: Fabric's `Controller(context, continuation)` collapses to `Controller(context)`.

### D9. Model-turn budget

- **Shape:**
  ```gleam
  pub opaque type MaxModelTurns
  pub fn max_model_turns(limit: Int) -> Result(MaxModelTurns, LimitError)   // ModelTurnLimitMustBePositive
  ```
- **Rules.**
  - The count includes the initial request and **every attempted continuation**, including provider failures and protocol failures.
  - Tool execution and approval waiting do not reset it.
  - When the budget is exhausted, inspection returns `BudgetBlocked` (no new effects) and `continue_model` returns `BudgetExhausted` while retaining the outstanding state. Repeated terminal inspection does not increment the count.
- **Evidence** (`budget_and_provider_failure_probe`, `malformed_provider_probe`):
  - `limit(1)` gives `model_turns_remaining == 0`, then `BudgetBlocked`, then `BudgetExhausted`.
  - A provider `TransportUnavailable` leaves `used == 2`, and calling `ProviderCallFailedAdvance` again keeps it at 2.
  - A duplicate call id and an empty batch in the next reply each give `ProviderProtocolFailedAdvance` with `used == 2`, idempotent on repeat.
  - Providers built with `panic_continuation_provider` show that blocked states never call the model.

### D10. Controller advance outcomes are explicit

- **Shape** (`fabric_agent.gleam:780-800`):
  ```gleam
  pub type Advance(context, continuation) { AgentFinished(_, Value) MoreActions(_) BudgetExhausted(_) HostStoppedAdvance(_, ActionReport)
    ReconciliationRequiredAdvance(_, UnknownEffect) ProviderCallFailedAdvance(_, llm.CallError) ProviderProtocolFailedAdvance(_, fabric_turn.TurnError) AlreadyFinishedAdvance(_, Value) }
  pub type AdvanceError { ActionReportsOutstanding  ModelAdvanceRejected(fabric_turn.TurnError) }
  pub fn continue_model(controller) -> Result(Advance(context, continuation), AdvanceError)
  ```
- `continue_model` is legal only when every slot is `Accepted` with a model-visible result. Otherwise it returns `ActionReportsOutstanding`.

### D11. Tool schemas pass explicit admission before they reach a provider

- **Decision.** An admitted catalog is a distinct type from a raw catalog, and only the admitted one renders. The policy sees the full schema AST and returns located, native-typed rejections. Standalone LLM and the Fabric adapter derive identical entries.
- **Evidence.**
  - `consumers/schema_admission.gleam`: nested optional property rejected, tagged alternatives rejected, primitive root rejected. Admission does not change dispatch behavior.
  - `consumers/provider_structured.gleam`: the configured provider's schema policy runs before a sentinel transport, and output schemas are located separately from tool inputs.
  - Negative `unadmitted_catalog`.
- **Delivered.** `llm_wire/types.gleam` has `tool_from_codec`, `tool_from_contract` (schema-only tools), `admit_tool_catalog`, and `validate_tool_arguments`. Fabric should use these, not the lab catalog.

### D12. Package observation is emitted only after acceptance and never controls state

- **Shape** (`src/lab/fabric_observations.gleam`): event `["fabric","action","report","accepted"]`. `AcceptedActionMeasurements(turn: Int)`, `AcceptedActionMetadata(call_id: CallId, disposition: ActionDisposition)`, with `ActionDisposition { ModelVisible HostFailure OutcomeUnknown }`, wire strings `model-visible|host-failure|outcome-unknown`.
- **Rules.** The fact is emitted only after `accept_report` returns `Ok`. A failed emit neither rolls back the acceptance nor makes the report acceptable again. The turn and call id subset is **not** a unique identity.
- **Evidence.** `consumers/package_observations.gleam` (`fabric_action_facts`). Negative `package_observation_shapes`: a Grind fact cannot be emitted through the Fabric emitter.

---

## 2. Incidental complexity to leave behind

1. **`lab/value.Value`** is a six-case JSON stand-in. Real packages use `json_blueprint` codecs and JSON **strings**: `llm_wire.ToolCall.arguments_json: String`, `ToolResult(call_id, content: String)`. Do not port `Value` as a Fabric type.
2. **`lab/blueprint`, `lab/blueprint_runtime`, `lab/blueprint_requirements`** simulate `json_blueprint`. Use the released package.
3. **`lab/llm.gleam`, `lab/llm_turn.gleam`, `lab/llm_structured.gleam`, `lab/llm_catalog.gleam`, `lab/llm_stream_events.gleam`, `lab/llm_stream_owner.gleam`** all simulate `llm_wire`, which now exists (`config`, `session`, `types`, `pool`, `telemetry`, `provider`). The `Provider(continuation)` type parameter, `llm.CallError`, `Reply { Final RequestsTools }`, and `ToolSucceeded`/`ToolFailed` are lab-only.
   - **Real mismatch:** `llm_wire.ToolResult` has no success/error flag (verified by grep). Fabric must keep the disposition on its own `ActionReport` and render failures as content. Inference: define one canonical Fabric encoding for model-visible failure content.
   - `llm_wire.RunResult` adds `RunOutputLimited` and `RunRefusal`, and `Terminal` adds `Failed(WireError, RetryEvidence)` and `Cancelled`. The lab controller does not model these.
4. **`fabric_llm.gleam`** converts registry declarations into LLM declarations with an **empty description `""`**. That is a lab artifact: `fabric.Declaration` has no description field. The agent controller also calls `fabric_llm.declarations` (the **unadmitted** raw path) and so bypasses D11. The real controller should build `llm_wire.ToolDefinition`s through `tool_from_codec` and admit them.
5. **`fabric.Tool` (context-free), `Agent`, `bounded`, `invoke_agent`** only wrap a callback. `AGENT-POLICY.md` and `fabric-design.md:105` state that they implement no loop guarantees. Drop them. Keep only the contextual registration, since a context-free tool is `ContextTool(Nil)`.
6. **`fabric_turn.Pending` beside `Controller.pending`** duplicates the result-id validation that `llm_wire.prepare_continue` already performs. Inference: Fabric should keep its own per-action accounting (D5) and let `llm_wire` own call and result correlation, as `PROVIDER-STRUCTURED-TURNS.md` states ("Fabric delegates to those checks").
7. **Controller blocker encoding.** `Controller` holds three independent `Maybe` fields (`model_call_failure`, `protocol_failure`, `finished_output`), plus per-slot statuses scanned by `controller_blocker`. This allows unrepresentable combinations. Inference: use one closed controller-phase sum type.
8. **Stringly types.**
   - `Deny(reason: String)` becomes model-visible text.
   - `PolicyRejected(String)` and `UnknownEffect.evidence: String` stay string-typed.
   - The magic payload strings `"unknown_tool"` and `"approval_rejected"` are model-facing text.
   - `ApprovalRequirement(identity: String, version: Int)`.
   - Inference: parameterize the reason and evidence types, or make them opaque, where the application owns them.
9. **Hand-rolled list helpers and private `Maybe`** (`reverse`, `contains`, `append`, `find_*`) reflect the lab's zero-dependency rule. Use `gleam_stdlib`.
10. **`let assert Found(...) = replace_status(...)`** internal panics in `fabric_agent.gleam` are acceptable in a lab but not in a library. Prefer total transitions.
11. **The injected Sinal `Backend`** (`lab/sinal`) and its `BackendFailed` error do not exist in delivered `sinal`. There, `emit(event, m, d) -> Result(Nil, EmitError)` goes straight to `:telemetry`, `event(...)` returns `Result`, and bounded delivery is `sinal/forwarder`. The api-control contract removed `BackendFailed`.
12. **Saga lab modules** (`lab/saga`, `saga_grind`, `saga_checkpoint`, `saga_child_link`) and `consumers/workflow.gleam` model a `Definition`/`ChildContract`/`DurableOwner` API. Delivered `saga` exposes `Workflow(i,o,e,u)`/`Port`/`Step` with **local execution only**; children, approvals, and durability are deferred (`PUBLIC-API.md`, Saga section). Nothing Fabric-facing from these modules is available today.
13. **Laboratory-only data.** Caller-asserted "structural signature" strings, synthetic node versions, and `probe_direct`/`probe_compensation` hooks (`EXECUTION-OWNERSHIP.md`, `UNIFIED-WORKFLOWS.md`) are explicitly lab policy.

**Worth keeping as a test technique (not as runtime design):** panic sentinels inside codecs, handlers, and provider continuations. They prove that a path is never reached.

---

## 3. Limitations the lab states it does not establish

- **Linearity and ownership.** The controller, `PreparedInvocation`, `ApprovalReference`, and pending continuations are copyable. The lab cannot prevent reuse of an old controller or replay of a prepared invocation, and it cannot enforce atomic policy (`AGENT-POLICY.md`, Remaining obligations; `STREAM-OWNERSHIP.md`).
- **Incarnation freshness and approval authenticity.** Both are host obligations. The pure prototype "does not generate or prove its freshness" (`fabric_agent.gleam:24-26`).
- **Durable storage.** There is no continuation store, compare-and-set, restart, migration, or process-loss test. `lab/README.md` lists the restart experiment only as the "Next executable question", and it was not performed.
- **Real streaming and transport.** The stream owner is a pure reducer. It does not prove shared ownership across copies, serialized commands, owner death, socket cleanup, backpressure, or remote cancellation (`STREAM-OWNERSHIP.md`, `research/llm-stream-ownership-contract.md`). A cleanup command is intent, not proof.
- **Provider behavior.** Scripted providers make "no claim about a commercial provider" (`PROVIDER-STRUCTURED-TURNS.md`). Local admission does not guarantee remote acceptance (`SCHEMA-ADMISSION.md`).
- **Trusted callbacks.** Provider and tool callbacks are trusted. The lab tests no foreign-exception containment, crash isolation, timeouts, or cancellation (`AGENT-POLICY.md`).
- **Budgets.** Only model turns are covered. Token, elapsed-time, combined, and streaming-interruption budgets are absent (`API-COVERAGE.md`, Fabric budget row).
- **Package boundaries.** The lab is one package. Source-isolated builds check import direction but "do not prove independent Hex package builds" (`API-COVERAGE.md`, Evidence rules).
- **Compiler limits.** Compiler checks "cannot prove codec laws, graph validity, persistence safety, authorization, idempotency, or correct scheduling" (`lab/README.md`).
- **Child lifecycle.** The owner is a trusted adapter, and namespace equality is not authentication. The lab proves no monotonic revisions, retention, or linear handle use (`CHILD-ATTACHMENT.md`).
- **Recovery.** The recovery interpreter is serial and local. Durable timers, process loss, parallel attempts, and in-flight timeout settlement are out of scope (`ACTIVITY-RECOVERY.md`).
- **Scoped observation.** Scope exit does not establish callback quiescence (`SCOPED-LIFETIME.md`).

---

## 4. Open contracts Fabric must still resolve

| Contract                           | What is pinned                                                                                                                                                                                                                                                                          | What is open                                                                                                                                                                                                                                                                                                                                          | Source                                                                                                         |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Continuation store                 | Fabric-owned versioned record: transcript, originating provider continuation, outstanding calls, accepted reports, budget counters, approval state, definition version, child links, ambiguous effects. Compare-and-set on the expected revision. A Grind job carries only a reference. | Record schema, codec and versioning, store port signature, migration-failure outcomes, duplicate-command identity                                                                                                                                                                                                                                     | `fabric-design.md:57-58`, `ECOSYSTEM-PLAN.md` ("Execution and durability ownership"), `workflow-boundaries.md` |
| Provider continuation encoding     | Must keep adapter identity and version or return explicit incompatibility. No secrets or sockets.                                                                                                                                                                                       | `llm_wire.Continuation` is opaque in memory. The only accessor is `continuation_response_id/1`. **No persistable envelope exists** (API-COVERAGE LLM row: "Open"; `llm-design.md:92`). Fabric cannot persist a pending turn until LLM Wire adds one, or Fabric must persist the transcript and re-prepare (inference).                                | `API-COVERAGE.md` LLM section; `llm-design.md`                                                                 |
| Approval authentication and expiry | Reference = (identity, requirement, revision). Stale and repeated answers are rejected.                                                                                                                                                                                                 | Authenticated answer commands, expiry, cancellation of a pending approval, compare-and-set commit of the review revision, release of worker capacity while waiting                                                                                                                                                                                    | `AGENT-POLICY.md`; `fabric-design.md:38`; API-COVERAGE "Approval suspension"                                   |
| Historical review forks            | Baseline requirement retained                                                                                                                                                                                                                                                           | Effect policy for resuming an earlier revision with a different answer                                                                                                                                                                                                                                                                                | `fabric-design.md:56`; `workflow-boundaries.md` (deferred)                                                     |
| Uncertain effects                  | Stop continuation until reconciliation. Never auto-retry. A tool may promise at-most-once only with a downstream idempotency or fencing key, or an atomic effect+completion.                                                                                                            | How a key is passed to tools (`workflow-boundaries.md`: "pass a stable idempotency or fencing key to a tool that honors it"). Typed evidence instead of a `String`. Classifying a post-effect worker loss as prevented, committed, or ambiguous. Handler-crash disposition "based on whether an effect could have occurred" (`fabric-design.md:108`). | as cited                                                                                                       |
| Cancellation settlement            | Fabric resolves pending model, tool, and review work at an agent boundary, and delegates job interruption to Grind and plan rollback to Saga. Child cancellation goes through the child owner (`RunAlreadyTerminal` race).                                                              | Live cancellation of an in-flight turn and tool, closing the stream through `llm_wire` (`CloseOutcome` distinguishes `ConsumerClosed` from `ProviderCancellationConfirmed`), settling prepared-but-unreported actions                                                                                                                                 | `workflow-boundaries.md`; `child-lifecycle-contract.md`; `fabric-design.md:111`                                |
| Budget dimensions                  | Model turns (D9)                                                                                                                                                                                                                                                                        | Tokens (depends on `Option(Usage)`, where missing is not zero), elapsed time (needs a trusted clock), combined limits. Unsupported dimensions must be rejected or reported, never ignored.                                                                                                                                                            | `fabric-design.md:106-107`                                                                                     |
| Streaming agent                    | LLM owns partial tool-call assembly. Only a terminal `RequestsTools` becomes policy work (`llm-streaming-contract.md:165-170,220`).                                                                                                                                                     | Approval interruption points (between turns or mid-stream), partial transcript commits, backpressure, restart boundaries                                                                                                                                                                                                                              | API-COVERAGE "Streaming agent execution: Open"                                                                 |
| Sub-agents                         | Pre-effect spawn policy                                                                                                                                                                                                                                                                 | Everything else: input, tool access, budget partitioning, depth, completion, cancellation, effect ownership. "Prefer Saga child semantics."                                                                                                                                                                                                           | API-COVERAGE; `fabric-design.md:151-155`                                                                       |
| Saga suspension                    | Approval waiting is neither completion nor failure. The first durable composition approves in Fabric **before** starting a side-effecting Saga child.                                                                                                                                   | A suspending agent **inside** a Saga step (one continuation owner, a resume token). Delivered Saga has no suspension or approval node (`Recovery` has `Hold`, but no approvals).                                                                                                                                                                      | `composition-contracts.md` ("Agent as a Saga step"); `PUBLIC-API.md`                                           |
| Tool visibility vs permission      | Separate decisions                                                                                                                                                                                                                                                                      | Tool metadata that policy needs; a visibility filter                                                                                                                                                                                                                                                                                                  | `fabric-design.md:70`; API-COVERAGE Fabric row 1                                                               |
| Schema-only / discovered tools     | `llm_wire.tool_from_contract` exists                                                                                                                                                                                                                                                    | The lab registry requires `Codec(i)`. Inference: Fabric needs a schema-only tool variant for Relay-discovered MCP tools (the api-control pilot composes "discovered-schema tool composition").                                                                                                                                                        | `docs/implementation/api-control/contract.md`                                                                  |
| Retry ownership                    | One retry layer per effect                                                                                                                                                                                                                                                              | Mapping `llm_wire.RetryEvidence{classification: NoRequestSent / RequestMayHaveReachedProvider / EffectUnknown}` into the Fabric turn count and the retry decision                                                                                                                                                                                     | `ECOSYSTEM-PLAN.md` "Composition rules"; `llm_wire/types.gleam`                                                |

---

## 5. Composition contracts and ownership

### Fabric ↔ LLM (`llm_wire`)

- **LLM owns:** provider requests, adapters, transport, deadlines, stream cleanup, safe pre-output retry, tool-call and result correlation, provider-origin continuation, and schema admission.
- **Fabric owns:** tool execution, action policy, approval, loop budgets, transcript, and agent continuation. LLM must not import Fabric (`llm-design.md:25-26`; `llm-provider-boundary.md` responsibility table; wave2 work order).
- **Agreement:** the continuation is bound to its origin, and exact result coverage is checked before transport. The delivered `Continuation(source: PreparedCall, ...)` matches lab D8.
- **Stale or divergent:**
  - `llm-provider-boundary.md` (2026-09-19) recommends first trying `anthropic_gleam` reuse. The delivered package uses its own adapters over Gun and exposes public `provider.Spec`/`Reducer`/`Replay` (api-control contract; migration.md).
  - The lab's `Provider(continuation)` type parameter is superseded: provider state is "typed inside closures", and Config/PreparedCall/Continuation carry no reducer-state parameters.
  - `llm-stream-ownership-contract.md` still describes a proposal. `llm_wire` now ships `Stream`, `next`, and `close` with `ReadError{StreamClosed, ConcurrentReadConflict, OwnerUnavailable, ReadTimeout}`.
  - The lab's success/failure `ToolResult` has no counterpart in `llm_wire`.

### Fabric ↔ Saga

- **Saga owns** workflow authoring, dependency semantics, compensation, and the child journal (in the durable runner). **Fabric owns** only its parent continuation, approval policy, child links, and the typed adaptation of child results (`composition-contracts.md`, durable runner ownership table; `child-lifecycle-contract.md`).
- **Integration shape.** The integration must live in an optional unit. The Fabric core never depends on Saga (`composition-contracts.md`, "Dependency direction"; `ECOSYSTEM-PLAN.md`).
- **Child lifecycle.** A Fabric parent stores a `ChildLink` and reattaches through a configured `DurableOwner` with a fresh `ChildContract`. It observes `DurableChildState` (`ChildQueued/Running/Waiting/Completed/Failed/Cancelled/NeedsReconciliation`) and compare-and-set commits the result. Compensation authority comes only from a claimed receipt (negatives `plain_compensation`, `compensation_reference_is_not_receipt`, `prepared_child_is_not_admitted`, `uncertain_child_is_not_admitted`, `child_handle_output`, `child_handle_undo`).
- **Stale or divergent:**
  - `workflow-boundaries.md` uses the older `Plan(value, error, undo_error)` and says Fabric "should compose those engines" and "build a fresh Saga plan after every durable boundary". `composition-contracts.md` refines this: Fabric core stays graph-free, and a Saga run is an opaque node or child.
  - `child-lifecycle-contract.md`, `CHILD-ATTACHMENT.md`, and `UNIFIED-WORKFLOWS.md` describe `Definition`/`ChildContract`/`DurableOwner`, but delivered Saga (`PUBLIC-API.md`) has `Workflow`/`Port`/`Step`, is local-only, and defers independent children, durable approvals, and `saga_grind`. **The Fabric↔Saga child contract therefore cannot be built against a real API today.** Only "agent as a local Saga step" (a typed function in a `Step`) is possible.
  - `composition-contracts.md` still speaks of a "Fabric graph". `fabric-design.md` §1 has reassigned the DAG to Saga.
  - **The fabric repo's own `CLAUDE.md` ("typed DAG compiler, durable OTP execution") contradicts `fabric-design.md` §1/§2 and API-COVERAGE ("Reassigned to Saga and `saga_grind`"; "Fabric must not claim a second workflow journal or queue scheduler").** That line is stale.

### Fabric ↔ Grind

- **Grind owns** durable admission, claims, leases, attempts, delayed retry, cancellation intent, and abandoned-job recovery. It does **not** own exactly-once business effects. A Grind job carries only a Fabric continuation **reference** and dispatches start/resume. Fabric reloads its versioned state and builds fresh in-memory work (`ECOSYSTEM-PLAN.md` ownership table; `workflow-boundaries.md`).
- **Waiting.** Waiting must release worker capacity; otherwise a single-slot queue deadlocks (`composition-contracts.md`, "Resource and cancellation rules").
- **Shared function.** One application function can be a Grind worker and a Fabric tool through separate adapters (`consumers/adapters.gleam`).
- **Disagreement:** none substantive. Grind is delivered (its observations run through `sinal/forwarder`). No Fabric-specific Grind contract exists in the lab beyond "carry a reference".

### Fabric ↔ Sinal

- **Sinal dispatches observations only.** Each package defines its own descriptors and fact types. There is no shared lifecycle enum, and observation never drives state (`ECOSYSTEM-PLAN.md`; `PACKAGE-OBSERVATIONS.md`; `fabric-design.md` "Package observations").
- **Stale:** the lab uses an injected `Backend` with `BackendFailed`. Delivered sinal emits to `:telemetry` directly and removed `BackendFailed`. API-COVERAGE says Fabric should "follow Grind's and Saga's precedent" (`grind/observation`, `saga/observation`, built on `sinal/forwarder`). Inference: ship `fabric/observation` with typed descriptors and use the forwarder for bounded delivery.

### Fabric ↔ Relay

- **No dependency either way.** The same application function and codecs can be registered as a Relay tool and as a Fabric tool. Each adapter keeps its own authorization, retry, error, and lifetime policy, and "no application must import Fabric merely to expose a function" (`composition-contracts.md`, "Reuse outside the workflow stack"; `consumers/shared_registry.gleam`, `request_scoped_tools.gleam`).
- **Relay semantics differ.** Relay treats an unknown tool as a _protocol error_ (`relay-server-contract.md:173`). Fabric makes it a _model-visible_ failure. Both are package-specific mappings, so there is no conflict.
- **Open (inference):** exposing Relay-discovered remote MCP tools _to_ a Fabric agent needs schema-only tools (see §4). Warden identity reaches a Fabric tool only through application-owned context.

---

## 6. Lab scenarios Fabric's real tests should reproduce

All scenarios are in `src/consumers/agent_policy.gleam` unless stated otherwise. Scripted providers should be real `llm_wire` custom adapters or local scripted transports, as the api-control contract prescribes.

1. **Mixed batch** (`mixed_batch_probe`). One turn carries lookup, delete, purchase, ghost, and panic_delete. Assert:
   - `Registered` vs `Unregistered("ghost")` descriptions;
   - lookup `InvocationPrepared` → `ToolSucceeded` → accepted → re-accept `DuplicateReport`;
   - delete `Deny` → `ReportReady(AuthorizationDenied)` without invocation;
   - purchase `ApprovalRequired(("purchase",1))`;
   - ghost → `UnknownTool` model-visible, not uncertain;
   - panic_delete denied **before decode** (panicking codec).
2. **Approval evolution** (same probe). An approve under changed context gives `ApprovalRequiredAgain`. The old reference gives `StaleApprovalReference`, the new one gives `ApprovalInvocationPrepared`, and a repeat gives `ApprovalAlreadyAnswered`. The prepared call executes with the recheck context.
3. **Call-id reuse across turns.** Turn 2 reuses `"reused"`: the turn-1 report is rejected with `ForeignReport`, the identities differ, `model_turns_used` goes 2 then 3, and a repeat advance gives `AlreadyFinishedAdvance` without incrementing.
4. **Current-context denial wins over approval** (`customer_b_recheck_probe`). The denied purchase is never decoded (sentinel).
5. **Reject and policy failure** (`rejection_and_policy_failure_probe`). Reject gives `ApprovalRejected`, and the run finishes. A policy that is unavailable gives `HostFailure(PolicyFailed(PolicyUnavailable))` then `HostStoppedAdvance`, and the continuation is never called.
6. **Boundary vs domain failure** (`boundary_and_domain_failure_probe`). An output-encode failure gives `HostFailure(BoundaryFailed(OutputEncodeFailed))`, which halts. A domain error gives `DomainToolFailed`, and the run finishes.
7. **Uncertain effect** (`reconciliation_probe`). `report_unknown_effect` → accepted → `ReconciliationRequiredAdvance` → `reconcile_unknown_effect` succeeds, and the turn count is unchanged.
8. **Budget** (`budget_and_provider_failure_probe`).
   - `max_model_turns(0)` errors.
   - With limit 1: `BudgetBlocked` on inspect, then `BudgetExhausted`.
   - A provider transport failure consumes a turn (`used == 2`) and is idempotent on repeat.
9. **Malformed provider reply** (`malformed_provider_probe`). A duplicate call id or an empty batch on continuation gives `ProviderProtocolFailedAdvance`, consumes a turn, and is idempotent. Against `llm_wire` these arrive as `WireError`/`ProtocolError`; the Fabric mapping must be decided.
10. **Incarnation isolation** (`incarnation_and_issued_report_probe`). Same `RunId`, different incarnations:
    - `ForeignReport`, `WrongApprovalReference`, `UnknownEffectIdentity`;
    - each reconciled effect finishes with **its own** provider;
    - with a reused incarnation, an executed report against an issued denial gives `ReportDoesNotMatchIssued`.
11. **Provider-bound continuation** (`consumers/tool_turns.gleam`). Server-state and transcript continuation shapes both complete approve and deny loops. Denial never runs the sensitive write. Missing and duplicate results are rejected before the provider is contacted. Against `llm_wire`, reproduce these through `session.prepare_continue`.
12. **Registry** (`consumers/derived_catalog.gleam`, `shared_registry.gleam`, `schema_admission.gleam`).
    - A codec-derived declaration equals the schema.
    - Dispatch with context gives `Int(27)`.
    - Registry errors: `DuplicateName` and `InvalidDeclaration(UnknownSchema)`.
    - Two contexts on one registry stay independent.
    - Admission rejects located schema features, and admitted rendering equals the registry declarations.
13. **Observation** (`consumers/package_observations.gleam` `fabric_action_facts`).
    - The fact is emitted only after acceptance.
    - Fields are `turn` / `call_id` / `disposition` with strings `model-visible|host-failure|outcome-unknown`.
    - A failed emit leaves re-acceptance at `DuplicateReport`. With delivered sinal, force failure through an encoding error or a forwarder drop, since `BackendFailed` no longer exists.
14. **Stream terminal and origin** (`consumers/stream_ownership.gleam`). This is LLM-owned; Fabric should reproduce only the composition. A partial tool call is not an action until the terminal `RequestsTools`. Close after progress yields no action. The continuation opens a second stream from the original provider.
15. **Compile-fail cases to keep as negative tests** (inference: Gleam has no built-in compile-fail harness, so replicate the lab's `check.py` approach or an external-package probe like `llm_wire`'s `test/external_package_boundary.sh`):
    - `approval_reference_is_not_invocation`
    - `agent_policy_context`
    - `agent_continuation`: moot once `Controller` has no continuation parameter.
    - `wrong_tool_context`
    - `registry_context`
    - `tool_codec`
    - `unadmitted_catalog`
    - `package_observation_shapes`
    - Add for Fabric: an `ActionReport` cannot be constructed outside the module, and a provider `CallId` cannot be used where an `ActionIdentity` or `Incarnation` is expected (analogues of `wire_id_as_exchange` and `attempt_id_as_epoch`).
16. **Durable scenarios specified but never run** (`lab/README.md` "Next executable question"; `ECOSYSTEM-PLAN.md` "Durable review application"; `workflow-boundaries.md` minimum proofs).
    - Approval suspend, encode, drop the process, restore from fresh code.
    - Race duplicate approvals against a compare-and-set store so that exactly one revision advances.
    - Crash after a fake ledger effect and before completion: requires reconciliation unless an idempotency key resolves it.
    - Continuation migration failure returned as data.
    - Stale-revision rejection.

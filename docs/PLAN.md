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
  `await`, which then returns `NoRunner`. A command is first checked against
  the stored record, so a refusal is reported as such; a valid command that
  needs the absent runner returns `OwnerUnknown` and changes nothing;
  `cancel` needs no runner. Recovery is an explicit `fabric.recover`,
  because a store knows only the runners of its own VM: taking a run over
  automatically could steal it from a live runner driven through another
  `Store`. An older runner cannot commit after a takeover (its revision is
  stale), so the takeover is safe; it is not a lease.
- **Transient store failures are retried, not taken as a takeover.** After an
  `Unavailable` write the store reads the run back and confirms a write
  that landed; a runner tries an `Unavailable` commit again (six times,
  backoff doubling from 10 ms) and stops only on a conflict. Backend calls
  run in worker processes, serialised per run and bounded by 5000 ms, so a
  hung call holds up only its own run.
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
  application passes, still allows the action. That context is for the
  recheck only: the approved action runs with the run's own context (from
  `start` or `recover`) whether or not a runner was live. This departs from
  the design line "approved invocation retains the same context used by the
  recheck" (oversight `fabric-design.md` §0), which the two paths did not
  honour consistently; the design owner should confirm or restore it.
- **A superseded answer is kept.** When the recheck asks for another
  requirement, the answer stays in the action's approvals (it authorizes
  nothing) and the new request is issued.
- **A sub-agent is a delegation, gated like a tool.** `agent.with_sub_agent`
  declares a typed definition whose call starts a child run; the policy sees
  `policy.StartAgent(name, version)` as the action's target. The child shares
  the parent's context type and store and has its own agent, budgets, and
  policy. An allowed delegation is committed `Running` with its child run id
  (`<parent id>-<n>`, deterministic) before the child is stored, then
  `Delegated` once it is: the child record never exists before the start is
  allowed, and a crash in between leaves a named, missing child that
  recovery starts.
- **No second owner of a child's state.** The child owns its approvals and
  effects. Nothing is mirrored into the parent's record; `status`, `await`,
  and `pending` read the family (the parent and its active children), so a
  child's pause is the parent's pause (anti-oracle B1) and `answer` routes by
  the reference's run. A delegated action needs no runner; the child delivers
  its end to its parent's delegation, keeping its store registration until
  it has, so a family is never seen ended, unreported, and ownerless. A child
  that ended with an unreconciled uncertain effect, or cannot be read or
  continued, makes the delegation an uncertain effect.
- **A parent ends after its children.** Cancelling (or a host fault) moves a
  run with active children to `Stopping` and cancels each child through the
  store, from a separate process (the child's runner may be delivering to
  the parent at that moment); the run ends once no tool runs and no child is
  active. An end that arrives after that is refused.
- **Observations are derived from committed transitions.** The runtime
  compares the state before and after every successful commit and emits
  Sinal events from the committing process; the controller emits nothing.
- **Saga stays optional.** A Saga workflow becomes a tool through the
  separate package `integrations/fabric_saga`, so Fabric does not depend on
  Saga (oversight `fabric-design.md`, package ownership).

## Public API (slice 2b)

Slice 2b adds, beside the slice 2a API below: `agent.with_sub_agent(agent,
definition, to: child, prompt:, result:)`, `agent.with_max_children` (default
4), `agent.with_max_depth` (default 1), the `ConfigError` variants
`MaxChildrenNegative`, `MaxDepthNegative`, `InvalidChild(name, errors)`;
`policy.Target { InvokeTool  StartAgent(name, version) }` and the field
`Action.target`; `run.Parent(run, action)`, the field
`ActionRecord.child: Option(String)`, the field `UncertainAction.run`, the
field `Snapshot.parent`, the action states `Delegated` and
`LimitReached(Budget)`, the budgets `ChildLimit(limit)` and
`DepthLimit(limit)`; `fabric.child(run, id) -> Result(Run(c), RecordError)`
and `fabric.cancel_stored(store, id) -> Result(Status, CommandError)`;
`CommandError.OwnerUnknown` (replacing `RecoveryRequired`); the module
`fabric/observation` (event descriptors and their typed metadata); and, in
the separate package `fabric_saga`, `fabric_saga.tool(definition, workflow,
config, explain:) -> Result(Tool(c), List(execution.ConfigError))`. Adding
fields and variants is a breaking change for code that constructs or
exhaustively matches these types.

## Public API at slice 2a

The slice 2b additions and changes are listed in the previous section.

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
- **Cancel of an incompatible record** (resolved: `fabric.cancel_stored`
  needs no agent, and `cancel` skips the compatibility check). Every command, `cancel` included,
  requires the record to be compatible with the agent; a run whose pending
  tool was removed cannot be cancelled under the new agent.

## Slice 2a review fixes

An independent review of slice 2a found no double execution or lost fence
under process or VM loss. Its findings were fixed test-first:

| Finding                                                                                                          | Resolution and evidence                                                                                                                                                                                                                                                       |
| ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Unparseable Anthropic or Google tool arguments failed the next turn                                              | Replayed as `{"unparsed_arguments": text}`; the record keeps the original (`unparseable_arguments_replay_to_anthropic_as_an_object_test`). llm_wire itself should replay arguments it reported as invalid (proposed sibling change).                                          |
| A second `Store` over one directory answered `RecoveryRequired` and advised a takeover                           | Commands are checked against the stored record first; `OwnerUnknown` replaces `RecoveryRequired` (`a_second_store_checks_commands_before_reporting_an_unknown_owner_test`).                                                                                                   |
| An agent change stranded paused runs                                                                             | `fabric.cancel_stored(store, id)` needs no agent; `cancel` through a handle skips the compatibility check (`a_stranded_run_is_cancelled_without_an_agent_test`, `cancel_stored_stops_a_live_run_through_its_runner_test`).                                                    |
| One transient `Unavailable` stalled the run                                                                      | Store read-back and runner retry (`a_runner_retries_a_commit_the_store_could_not_make_test`, `a_write_the_backend_made_despite_an_error_is_confirmed_test`).                                                                                                                  |
| A hung backend froze every run of a Store                                                                        | Per-run worker calls with a deadline (`a_hung_backend_call_blocks_only_its_run_until_its_deadline_test`).                                                                                                                                                                     |
| Cancelling an orphaned stopping record did nothing                                                               | `controller.cancel_abandoned` (`cancelling_a_record_a_lost_runner_left_stopping_ends_it_test`).                                                                                                                                                                               |
| Cancel through another Store left tool bodies running                                                            | Documented on `fabric.cancel`.                                                                                                                                                                                                                                                |
| Directory store: directory entry not fsynced; O(n²) disk; stray temporary files; `ok = file:close`               | "Never retried" scoped in the `fabric` module documentation; old revisions emptied, stale temporary files swept (`the_directory_store_empties_revisions_older_than_the_previous_test`, `opening_a_directory_store_sweeps_stale_temporary_files_test`); close errors reported. |
| The answer's context became the run context only without a live runner                                           | The answer's context is for the recheck only (`the_answer_context_is_for_the_recheck_and_the_tool_keeps_the_run_context_test`); see the decision above.                                                                                                                       |
| A changed requirement left no audit trail                                                                        | The superseded answer is kept (`a_changed_requirement_demands_a_new_answer_test`).                                                                                                                                                                                            |
| A backend that committed then reported `Unavailable` gave `StartFailed`/`StoreFailed`                            | Store read-back, as above.                                                                                                                                                                                                                                                    |
| ORACLE A13 said "VM restart"; CAPABILITIES excluded multi-node while the store claims cross-VM safety            | Relabelled and reconciled in ORACLE.md and CAPABILITIES.md.                                                                                                                                                                                                                   |
| Nits: dead `registry.is_registered`; foreign run ids gave a store error; the runner ignored outside exit signals | Removed; `RunNotFound` (`a_run_id_that_fabric_never_issues_is_not_found_test`); the runner stops (`an_exit_signal_from_outside_stops_the_runner_test`).                                                                                                                       |

Deferred, with reasons:

- **The default identity `agent/1`** makes the identity check vacuous for
  applications that never name their agent. Requiring a name changes the one
  ordinary path (`agent.new`); deriving one from the tools would refuse
  compatible changes. Kept, pending an API decision.
- **Rejecting a stranded run.** `recover` still refuses an incompatible
  record, so a stranded run can be cancelled (`cancel_stored`) but not
  rejected: a rejection would continue the run under an agent that recovery
  refused.
- **A lease or heartbeat** for runs driven through several Stores (see the
  cross-VM backlog item above).
- **Unknown record fields** are ignored when decoding; strict decoding would
  make every added field a version bump.
- Ergonomics (five error types, `answer` needing a context for a rejection,
  a Store linked to its opener, an opaque run id) are recorded for an API
  review; none was changed here.

## Slice 2b — sub-agents, observations, Saga workflows as tools

Implemented. Acceptance, each with its executed evidence
(`test/fabric/delegation_test.gleam`, `delegation_controller_test.gleam`,
`observation_test.gleam`, `integrations/fabric_saga/test`,
`consumers/app`):

1. **Approval before a sub-agent starts.** The parent's policy sees the start
   as an action with its target and may require an approval; no child
   record exists before it is approved, also across a restart; a rejected
   start never creates the child and the model sees the rejection
   (`a_sub_agent_starts_only_after_approval_even_across_a_restart_test`,
   `a_rejected_sub_agent_never_starts_test`,
   `an_allowed_delegation_names_its_child_before_the_child_exists_test`).
2. **Child pauses surface (anti-oracle B1).** A child's pending approval is
   the parent's, its reference names the child run, answering it through the
   parent resumes the child, and the child's completion feeds the parent's
   delegation (`a_child_pause_surfaces_to_the_parent_and_is_answered_through_it_test`).
3. **Cancellation.** Cancelling the parent cancels paused and active
   children through the store; a child cancelled while a tool ran makes the
   delegation uncertain; a child's model reply after the cancel is
   discarded; a child that ended while its parent was stopping is recorded
   and the parent still ends cancelled; a later end is refused;
   `cancel_stored` cancels children first with no agent
   (`cancelling_the_parent_cancels_a_paused_child_test`,
   `cancelling_the_parent_stops_an_active_child_test`,
   `a_child_reply_after_the_parent_was_cancelled_is_discarded_test`,
   `a_stopping_run_waits_for_its_children_and_ends_cancelled_test`,
   `cancel_stored_cancels_the_children_first_test`).
4. **Restart.** Recovering the parent recovers the child (its running tool
   becomes the child's uncertain effect, reported through the parent and
   reconciled on `fabric.child`'s handle); a child record that cannot be
   read makes the delegation uncertain; a runner lost while starting a
   child leaves it delegated, and recovery starts or reattaches the child
   (`recovering_the_parent_recovers_its_child_test`,
   `an_unreadable_child_is_an_uncertain_effect_of_the_parent_test`,
   `recovery_keeps_delegations_waiting_on_their_children_test`).
5. **Budgets.** `max_children` counts started children and those awaiting an
   approval; `max_depth` counts levels below the root and a child is bounded
   by what its parent has left; both refuse before the policy with a
   model-visible `limit_reached`
   (`delegations_beyond_the_child_limit_are_refused_test`,
   `nested_delegation_is_bounded_by_the_root_depth_test`,
   `the_child_limit_counts_started_and_awaiting_children_test`). A child is
   validated with its parent (`a_delegation_is_validated_with_its_child_test`).
6. **Record version 2** with a tested reading of version 1 records
   (`a_version_1_record_is_read_as_a_root_run_without_sub_agents_test`).
7. **Sinal observations** after each commit, from the committing process,
   documented per event in `fabric/observation`; a failing or crashing
   handler is detached without affecting the run
   (`a_run_is_observed_after_each_commit_test`,
   `a_failing_handler_does_not_affect_the_run_test`,
   `sub_agents_cancellation_and_recovery_are_observed_test`).
8. **A Saga workflow as a tool** (`fabric_saga`), tested with the `book_trip`
   shape: completion, a hotel failure that releases the flight (typed,
   definite), a release that fails (uncertain), Fabric cancellation that
   cancels the Saga run and lets Saga undo the hotel and the flight
   (uncertain in Fabric), and an invalid configuration refused up front.
9. **Consumer**: a purchasing sub-agent gated by the committee whose own
   order approval surfaces at the front desk, cancelling the desk with the
   purchaser paused, an interlibrary loan as a Saga tool, and application
   Sinal handlers (`consumers/app/test/app_test.gleam`).
10. **Oracle**: the `task` gate (approve runs the child once, reject never
    starts it) matches BeamWeaver fixtures; B1 is executed
    ([ORACLE.md](ORACLE.md#slice-2b-results)).

Backlog from this slice:

- **Shared budgets.** Each child has its own turn and token budgets; there is
  no budget shared across a family (a parent's token budget does not count
  its children's tokens), and no elapsed-time budget.
- **Child context.** A child shares its parent's context type and receives
  the parent's run context; a delegation cannot derive a narrower context.
- **Cooperative cancellation.** Cancelling kills tool tasks, so a Saga tool's
  clean compensation is still recorded as an uncertain effect (see the Saga
  friction below).
- **Recovery of a child alone.** `recover` on a child id works, but the child
  then has no parent link in that handle; its end reaches the parent only
  when the parent is recovered or its runner delivers it.
- **Answer routing cost.** Reading a family reads every active descendant's
  record; deep or wide trees make `status` and `await` proportionally more
  expensive.

## Slice 3 — streaming, structure, durable stores

- Supervision: a supervision tree instead of starter-owned stores and
  unsupervised runners, with the runner stopping on a supervisor's exit
  signal (slice 2a review) as its starting point.
- A lease or heartbeat for runs driven through several Stores, so that
  recovery can wait for a live owner; a Grind-driven recovery that carries
  only a run reference.
- Streamed model progress through llm_wire `session.stream`, with
  cancellation closing the stream.
- Cooperative cancellation (a grace period before tool tasks are killed),
  so a Saga tool can report a definite compensation.
- Budgets shared across a sub-agent family.
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
- **sinal** is used directly since slice 2b; see the slice 2b friction.

## Slice 2b friction

No sibling was changed. Proposed, with evidence:

- **llm_wire should replay arguments it reported invalid.** With
  `ReportInvalidToolCalls`, llm_wire returns calls whose arguments are not
  JSON and then refuses to prepare a request that replays them
  (`canonical_json` in `internal/api.gleam`, for Anthropic and Google), so a
  caller must rewrite them. Fabric replays `{"unparsed_arguments": text}`
  (`unparseable_arguments_replay_to_anthropic_as_an_object_test`); llm_wire
  could do the same for the calls it reported.
- **Saga: learn an outcome after the owner is gone.** A Saga run is awaited
  only by the process that started it (`execution.await`, `NotOwner`), and
  it is cancelled when that owner exits. A Fabric tool runs the workflow in
  its task, so cancelling the Fabric run kills the owner: Saga compensates
  correctly (`cancelling_the_run_cancels_the_workflow_test` observes the
  hotel and flight released) but nobody can learn that it did, and Fabric
  must record an uncertain effect. A start option that reports the outcome
  to a given `Subject` (or lets a named process await) would let a
  supervising process record a definite compensation. A settle window
  (`settle_timeout`, default 5000 ms) also delays that compensation.
- **Sinal: a handler that blocks holds up the emitter.** `sinal.emit` runs
  handlers synchronously; Fabric documents that a slow handler delays the
  run and points to `sinal/forwarder`, whose supervised name and capacity
  are application configuration. An emit option that routes through a
  forwarder when one is configured would let a library emit safely without
  owning that configuration.

## Tested sibling revisions

Fabric resolves its siblings as `../` path dependencies. The gates of slice 2b
(and of 2a, at the same revisions) passed against these revisions, each with
a clean working tree:

| Package        | Revision  | Relationship                                                                  |
| -------------- | --------- | ----------------------------------------------------------------------------- |
| llm_wire       | `3b126fe` | Direct dependency (`fabric/llm`, `llm_wire/testing` in tests)                 |
| json_blueprint | `ecf5c60` | Direct dependency (tool codecs)                                               |
| sinal          | `f4622b6` | Direct dependency since slice 2b (`fabric/observation`)                       |
| saga           | `f241395` | Dependency of `integrations/fabric_saga` and the consumer only; not of Fabric |

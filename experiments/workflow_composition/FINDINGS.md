# Workflow composition experiment: findings

THROWAWAY experiment, run 2026-09-27 on gleam 1.18.1 / OTP 28 against Saga `f241395`. It is not production code; absorb fragments only through the normal implementation path.

## Question

Should Saga orchestrate Fabric's agent workflow (C), should Fabric own its controller with Saga optional (A), or something in between (B)? What would Saga need to change to make C work?

## Answer

**Fabric should own the agent controller (variant A), and Saga should stay an optional tool implementation.**

- Only A passes every scenario row, and it does so with the smallest executor.
- B passes the scripted rows, but three executed tests expose its costs:
  - its concurrency budget is per Saga run, not per agent run;
  - on a restart it loses results that had already finished;
  - it needs an extra owner process for every batch.
- C cannot express a durable pause, a pause cancellation, reconciliation followed by continuation, or per-call concurrency.
- The smallest Saga change that helps C is an in-memory suspend and resume. It was prototyped in about 210 source lines, and it still leaves durability unsolved.
- Making Saga fit C durably is an estimated 15 to 25 working days. That is well beyond the "couple of days" threshold.

## How to run

```sh
cd experiments/workflow_composition
nix develop ../.. -c gleam test          # 29 tests, about 0.9 s
nix develop ../.. -c gleam format --check src test
```

The Saga prototype lives in `saga-suspend-prototype.patch`, a patch against Saga `f241395`. To apply it:

1. Copy Saga somewhere.
2. Point its `sinal` path at `/code/gleam-dream/sinal`.
3. Run `git apply`.
4. Run `gleam test` (114 tests).

It was executed in an ephemeral scratchpad copy. No sibling repository was modified.

## What was built

All variants share one application (`src/wc/app.gleam`):

- **Typed tools:**
  - `lookup_weather(city) -> Forecast | WeatherError`
  - `transfer_funds(Transfer) -> Receipt | TransferError`, which can report an uncertain effect
  - `book_trip`, a real three-step Saga workflow with dependencies and compensation
  - `delegate`, which starts an inline sub-agent
- **External policy:** `transfer_funds` and `delegate` require approval; everything else is allowed.
- **Model:** a transcript-pure scripted model.
- **Test instruments** (`src/wc/probe.gleam`), owned by the test process so they survive a simulated restart:
  - a synchronous effect ledger, whose order is the causal order;
  - barriers, which hold a tool body until the test releases it.
- **Restart model:** "restart" kills the runtime process and, through links, every runner, executor, model task and tool task. Only the store survives.

| Module                                                                                   |                                  Lines | Role                                                                                                   |
| ---------------------------------------------------------------------------------------- | -------------------------------------: | ------------------------------------------------------------------------------------------------------ |
| `wc/agent.gleam`                                                                         | 703 (about 525 without the JSON codec) | Pure controller `step(config, state, event) -> Result(#(state, effects), rejection)`; the record codec |
| `wc/runtime.gleam`                                                                       |                                    497 | OTP runtime, shared by A and B                                                                         |
| `wc/exec_tasks.gleam`                                                                    |                                    126 | Variant A executor: linked tasks, one budget per run                                                   |
| `wc/exec_saga.gleam`                                                                     |                                    213 | Variant B executor: one runtime-defined Saga run per dispatched batch                                  |
| `wc/variant_c.gleam`                                                                     |                                    167 | Variant C: the whole loop as one Saga workflow, unrolled                                               |
| `wc/saga_tool.gleam`                                                                     |                                     55 | Saga-as-tool adapter, used by A, B and C                                                               |
| `wc/tool.gleam`, `wc/store.gleam`, `wc/model.gleam`, `wc/codec.gleam`, `wc/inline.gleam` |               100 / 110 / 81 / 36 / 87 | Shared plumbing                                                                                        |

The OTP runtime works as follows:

- A runner process exists only while work is in flight.
- The runner commits every accepted transition to the store (compare-and-set) **before** it performs that transition's effects.
- Commands go to the live runner, or, when none is live, are applied to the stored record.
- An executor must call a **fence** before a tool body runs. The fence commits the action as `Running` first.

## Scenario matrix (executed)

Legend: **pass**, **partial**, **break** (the test passes by demonstrating the failure), **n/e** (not expressible).

| Row                                                                                                       | A: Fabric controller + tasks                                                     | B: Fabric controller + Saga per batch                                                          | C: Saga-orchestrated                                                                                                                                                                     |
| --------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. Two typed calls with distinct ids                                                                      | pass `a_row1_4_durable_pause_restart_resume_test`                                | pass `b_row1_4_durable_pause_restart_resume_test`                                              | pass, in process only: `c_row1_2_4_in_process_approval_completes_test`                                                                                                                   |
| 2. Policy gates the transfer, allows the lookup                                                           | pass (same tests)                                                                | pass (same tests)                                                                              | pass, in process only: the step blocks on a Subject (`WaitInStep`)                                                                                                                       |
| 3. Durable pause; restart; stale, wrong and duplicate answers rejected; concurrent answers                | pass `a_row1_4_…`, `a_row3_concurrent_answers_single_winner_test`                | pass `b_row1_4_…`, `b_row3_concurrent_answers_single_winner_test`                              | **break** `c_row3_restart_breaks_pause_and_repeats_effects_test`: the lookup and the model call run twice. **break** `c_row3_hold_breaks_resume_test`: `Hold` is a terminal `Unresolved` |
| 4. Results keep call ids and feed turn 2, which finishes                                                  | pass (exact transcript string)                                                   | pass                                                                                           | pass, in process only                                                                                                                                                                    |
| 5a. Cancel while a tool is blocked: unknown effect, not retried                                           | pass `a_row5_cancel_while_running_test`                                          | pass `b_row5_cancel_while_running_test` (after the 50 ms Saga settle window)                   | **partial** `c_row5_cancel_reports_batch_not_call_test`: only the whole batch step is reported interrupted                                                                               |
| 5b. Cancel while paused, after a restart                                                                  | pass `a_row5_cancel_while_paused_test`                                           | pass `b_row5_cancel_while_paused_test`                                                         | n/e: there is no paused state to cancel                                                                                                                                                  |
| 6. Typed failure visible to the model; uncertain effect blocks until reconciled                           | pass `a_row6_failure_and_uncertain_effect_test`                                  | pass `b_row6_failure_and_uncertain_effect_test`                                                | **break** `c_row6_uncertain_effect_breaks_continuation_test`: `Hold` ends the run                                                                                                        |
| 7a. Three tools, budget of 2 in flight                                                                    | pass `a_row7_concurrency_budget_test` (peak 2)                                   | pass `b_row7_concurrency_budget_test`                                                          | n/e: the batch is one step                                                                                                                                                               |
| 7b. Model-turn budget                                                                                     | pass `a_row7_turn_budget_test`                                                   | pass `b_row7_turn_budget_test`                                                                 | pass by unrolling: `c_row7_turn_budget_by_unrolling_test`                                                                                                                                |
| 7c. Budget of 1 shared across batches (an approval lands mid-batch)                                       | pass `a_row7_budget_shared_across_batches_test` (peak 1)                         | **break** `b_row7_budget_not_shared_across_batches_test` (peak 2 with a limit of 1)            | n/e                                                                                                                                                                                      |
| 8a. `book_trip` Saga workflow as a tool: success, and a hotel failure that releases the flight            | pass `a_row8_saga_workflow_as_tool_test`                                         | pass `b_row8_saga_workflow_as_tool_test`                                                       | pass, in process: `c_row8_saga_tool_and_delegate_in_process_test`                                                                                                                        |
| 8b. Durable approval before a sub-agent starts; the child does not start before it, even across a restart | pass `a_row8_delegate_needs_durable_approval_test`                               | pass `b_row8_delegate_needs_durable_approval_test`                                             | in process only (same test); durability n/e, as in row 3                                                                                                                                 |
| Restart mid-batch: the first result is done, the second tool is blocked                                   | pass `a_restart_mid_batch_keeps_completed_results_test` (only `c2` is uncertain) | **cost** `b_restart_mid_batch_loses_completed_results_test` (`c1` and `c2` are both uncertain) | n/e                                                                                                                                                                                      |

The Saga prototype tests below are scratchpad executions; the patch is kept in this directory:

| Test                                                | What it shows                                                             |
| --------------------------------------------------- | ------------------------------------------------------------------------- |
| `suspend_then_resume_skips_completed_steps_test`    | Resuming does not re-run completed steps                                  |
| `journal_survives_suspension_test`                  | A failure after resume undoes a step that completed before the suspension |
| `checkpoint_does_not_fit_a_redefined_workflow_test` | A checkpoint cannot be resumed with a re-defined workflow                 |
| `duplicate_resume_repeats_effects_test`             | A copied checkpoint resumed twice runs the transfer twice                 |

## Evaluation

Each point is marked **[executed]** when a test or run shows it, or **[reasoning]** when it follows from code reading only.

### State ownership

- **A and B.** One Fabric record per run owns the whole agent state: transcript, actions and their statuses, turns used, approvals issued, and a closed `Phase`.
  - The record is plain JSON with a revision. A paused run has no process: tests await `Released` and assert `is_live == False` **[executed]**.
  - Compare-and-set is the only ownership fence. The loser of two concurrent answers re-validates against the newer record and gets `AlreadyAnswered`; the transfer runs once **[executed]**.
  - A runner whose commit conflicts stops (`Superseded`) **[reasoning: no test forces it]**.
- **C.** The state lives in Saga's in-memory, type-erased store and in a blocked step process. Nothing survives the owner **[executed]**.

### Scheduler

- **A** (`exec_tasks`, 126 lines) keeps one FIFO queue and one budget per run, across every batch the run dispatches **[executed, 7a and 7c]**.
- **B** gets Saga's admission control, but only within one Saga run **[executed, 7c]**.
  - `execution.await` is owner-only and cannot join another selector, so every batch needs its own helper owner process.
  - As a result, `exec_saga` (213 lines) is larger than the plain executor it replaces.
- **C** schedules turns and batches as static steps. Tool calls inside a batch are invisible to Saga.

### Cancellation

- **A and B share the controller path:** `Cancel`, then `Cancelling`, then `StopTools`, then the executor confirms `ToolsStopped`. At that point, `Running` actions become uncertain effects and never-started actions become `NotStarted`.
  - A kills its tasks and waits for each `DOWN`. A report sent before a task died is always forwarded first **[executed]**.
  - B calls `execution.cancel`. Saga waits `settle_timeout`, then kills and reports the step as `interrupted` **[executed]**.
  - A cancelled Saga run also discards the outputs of steps that had already completed. B maps those to "completed, result discarded" uncertain effects **[reasoning: code path present, not exercised by a test]**.
- **C** reports `interrupted: ["tools-1"]`. It cannot say which call's effect is unknown **[executed]**.

### Suspension

- **A and B:** a pause is data. Answering it needs no process, and the answer is applied to the record by whichever runtime receives it **[executed]**.
- **C:** Saga has no suspension. The two stand-ins, a blocking step and `Hold`, are respectively not durable and not resumable **[executed]**.

### Retry semantics

- Neither A nor B ever retries a tool. A crash, a reported uncertainty, a cancel in flight, or a lost runner all produce `Unknown`. Only `reconcile` clears it, and reconciliation does not consume a model turn **[executed]**.
- A model call lost with its runner is re-issued on `recover` and counts against the turn budget, following lab rule D9 **[reasoning]**.
- Retry and compensation remain available _inside_ a Saga-as-tool workflow, where the workflow author owns them. That keeps one retry layer per effect **[executed for compensation]**.

### Concurrency limits

- A's single per-run budget holds even when an approval dispatches a second batch mid-flight (peak 1 with a limit of 1) **[executed]**.
- B exceeds the same limit (peak 2). Saga documents budgets shared across runs as Deferred **[executed]**.

### Restart recovery

- **Mechanism shared by A and B.** The fence commits `Running` before a tool body runs. After a restart, `recover` therefore classifies actions exactly:
  - `Queued` actions are safe to dispatch again;
  - `Running` actions become uncertain;
  - `Answered` actions are kept.
- **A** commits each result as it arrives, so a finished sibling survives **[executed]**.
- **B** gets Saga outputs only when the run ends, so a finished sibling becomes uncertain **[executed]**.
- **C** has nothing to recover.

The BeamWeaver hazards were not copied:

- stale, duplicate and concurrent resumes are rejected **[executed]**;
- a kill during a tool call leaves `NeedsReconciliation`, not a wedged thread **[executed]**.

### Friction and cost

- The fence costs one store write per tool start **[reasoning]**.
- The "Running" classification is conservative. A tool killed before its first side effect is still reported uncertain **[reasoning]**.

## API ergonomics (call sites an application author writes)

A (Fabric-owned), taken from `app.gleam`, `support.gleam` and `scenarios.gleam`:

```gleam
// Typed tools: application types and codecs, erased behind one invocation.
let weather = tool.define("lookup_weather", city, forecast, weather_error, lookup)
let transfer =
  tool.define_reporting("transfer_funds", transfer_in, receipt, transfer_error, pay)
let trip = saga_tool.from_workflow("book_trip", city, itinerary, trip_error, wf, cfg)
let assert Ok(tools) = tool.registry([weather, transfer, trip])

// External policy gate (fails closed on Error).
fn policy(req: agent.ActionRequest) -> Result(agent.Decision, String) {
  case req.name {
    "transfer_funds" | "delegate" -> Ok(agent.RequireApproval)
    _ -> Ok(agent.Allow)
  }
}

// Start.
let env = runtime.Env(store:, model:, tools:, policy:,
  executor: exec_tasks.executor(), max_in_flight: 2, observer: None)
let rt = runtime.start(env)
let assert Ok(Nil) = runtime.start_run(rt, "r1", prompt, 3)

// Answer an approval: read it from the record, no process needed.
let assert Ok(#(_, state)) = runtime.load(store, "r1")
let assert agent.WaitingForApproval([pending]) = agent.status(state)
runtime.answer(rt, "r1", pending.ref, agent.Approve)   // Stale/Wrong/AlreadyAnswered/RunEnded
runtime.reconcile(rt, "r1", action, content)          // clears an uncertain effect

// Cancel (live or paused), restart.
runtime.cancel(rt, "r1")
let rt = runtime.start(env)
runtime.recover(rt, "r1")
```

B is the same code with one line changed: `executor: exec_saga.executor(exec_saga.Settings(step_timeout: 10_000, settle_timeout: 50))`. Saga's benefit is therefore invisible at the call site, while its costs are internal.

C (Saga-orchestrated):

```gleam
let assert Ok(wf) = variant_c.define(model, tools, policy, WaitInStep(approver), 3)
let assert Ok(run) = execution.start(wf, variant_c.begin(prompt), config)
let assert Ok(ApprovalRequest(call, reply)) = process.receive(approver, 5000)
process.send(reply, True)         // raw Bool on a Subject owned by the starter
execution.cancel(run)             // interrupts the whole batch step
// restart: none — start over and repeat completed effects
```

How the variants compare:

- **Surface.** A and B expose about 15 names: `tool.{define, define_reporting, registry}`, `agent.{Policy, ActionRequest, Decision, Answer, ApprovalRef, status}`, and `runtime.{Env, start, start_run, answer, reconcile, cancel, recover, load}`.
- **A's friction:**
  - the `Env` record has 7 fields, and the executor should have a default;
  - finding the pending reference takes `load` plus `status`, where a `runtime.pending` would be more direct;
  - `recover` is explicit, and needs a boot scan or a Grind job in production.
- **C's friction:**
  - the application, or a library layer, must hand-write the roughly 130-line unrolled loop in `variant_c.gleam`;
  - the approval answer is untyped (no reference or revision);
  - `Unresolved` must be interpreted as "paused";
  - restart cannot be expressed at all.

## Saga changes C would need, with estimates

This section is grounded in `saga/src` at `f241395` and in the executed prototype.

- **S1. `Recovery.Suspend` and an in-memory `execution.resume(workflow, checkpoint, config)`.**
  - Prototyped: +209 source lines and +149 test lines. Saga's 110 existing tests and 4 new ones pass.
  - Production work remains: observation and progress vocabulary for a suspended state, linear or revisioned checkpoint use, and suspension during settling.
  - Estimate: **1.5 to 2 days.**
  - This step alone does **not** meet row 3:
    - the checkpoint holds the erased `Store` and the undo closures;
    - it fits only the identical `Workflow` value, because node ids come from `ffi.unique_integer()` at `define` (`saga.gleam` `perform`);
    - a copied checkpoint resumed twice repeats effects.
- **S2. Stable step identity.** Key the store and journal by `StepAddress`, and fingerprint the definition by name, version and descriptors so that incompatible checkpoints are rejected. Estimate: **1 to 2 days.**
- **S3. Serializable checkpoint.** Estimate: **3 to 5 days.**
  - Every persisted step output and the root input need versioned codecs, which is a `Step` API change.
  - Undo must be rebuildable from the decoded `(input, output)`. The public `Undo.UndoWith(fn() -> …)` and the `Continue(output, UndoWith(closure))` form are closures, so this is a breaking change.
- **S4. Durable journal through a store port.** Estimate: **3 to 5 days.**
  - Write-ahead "attempt started" commits inside the coordinator's admission, which today is pure in-memory, so that a step lost in flight becomes unknown and is never re-run.
  - Expected-revision (compare-and-set) commits with conflict outcomes.
  - Resume ownership, so that stale or duplicate resumes are rejected.
- **S5. Typed signals.** Deliver an approval answer into a suspended step with identity, revision, deduplication and a codec. The prototype instead re-attempts the step, which reads application state. Estimate: **2 to 3 days.**
- **S6. Dynamic subgraphs (`and_then` / `traverse`)** with deterministic addresses, so that each tool call is its own step and the loop is not unrolled. Saga lists these as Deferred and has only a sketch in `saga-design.md`. Estimate: **4 to 6 days.**
- **S7. A concurrency budget shared across runs** (Deferred). Needed only for B. Estimate: **1 to 2 days.**

The total for C to pass rows 3, 5, 6 and 7 durably is S1 to S6: **about 15 to 25 working days** plus review. This is **not** within a couple of days. The only couple-of-days piece, S1, gives in-memory pauses that Fabric does not need, because A already pauses as data.

Saga changes that would help A's optional Saga-as-tool path are small, and none of them is required:

- a selectable `await`, for example `execution.select(selector, execution, mapping)`, would remove B's per-batch owner process: **about 0.5 day**;
- S7, only if B is ever wanted.

## Workflow tag

The experiment considered three meanings for a workflow tag. No scenario needed any of them, so none was introduced.

1. **Diagnostic metadata.** Saga already emits the workflow name and `run_id` on Sinal events, and Fabric's run id serves the same purpose.
2. **Routing identity for resume or Grind jobs.** Resume routed exactly on `(run id, ActionId(turn, call_id), approval revision)`, and a Grind job needs only the run id. A free-form tag adds nothing.
   - The real gap is compatibility, not routing. A stored record must be decoded with the agent definition it was created by: its registry, policy and model.
   - That calls for a typed `definition: (name, version)` field, checked on load, as `fabric-design.md` §2 already asks. It is needed only once several agent definitions share a store. The experiment has one definition and did not exercise this **[reasoning]**.
3. **Semantic workflow kind.** Policy decided on the tool name and arguments. No scenario branched on a kind.

**Conclusion:** introduce no tag. Add definition identity and version to the persisted record when a second definition shares a store.

## Recommendation

The smallest supported choice is **A: a Fabric-owned pure controller plus a thin OTP runtime.** Saga stays optional:

- Ship `saga_tool.from_workflow` (a Saga workflow as one typed tool) in an optional module or companion package. Fabric's core must not depend on Saga, per `fabric-design.md`.
- Do not adopt B. It adds a process per batch and loses finished results on restart or cancel. Its budget is also per batch, not per run. Its only gain over A is Saga's per-step timeout, and A can add a timer per task in a few lines.
- Do not change Saga for Fabric now. Revisit S1 to S6 only if a _workflow_ (not an agent) needs durable human steps. That need belongs to Saga's own `saga_grind` backlog.

Limitations of this evidence:

- **Test setup:**
  - the store is in-memory, standing in for PostgreSQL, Grind or ETS;
  - the model is scripted, not `llm_wire`;
  - execution is single-node.
- **Controller semantics not yet covered:**
  - policy is a synchronous function; an external policy service should become an effect with a timeout that fails closed;
  - the only budgets are model turns and in-flight tools, with no token or elapsed-time budgets;
  - A has no per-tool timeout;
  - `BoundaryFailure` is mapped conservatively to an uncertain effect, where the lab halts on it.
- **Recovery and sub-agents:**
  - `recover` is explicit and is not triggered by a supervisor or a Grind job;
  - the sub-agent runs inline inside the `delegate` tool, and only the parent's approval is durable. A child that itself needs approval returns an error that becomes a model-visible failure: it is not escalated, and no test covers it.
- **Values and messaging:**
  - controller values stay copyable, and the store's compare-and-set is the only enforcement;
  - causal message order across different senders relies on single-node BEAM delivery (exec_tasks forwards a report before it spawns the next task).

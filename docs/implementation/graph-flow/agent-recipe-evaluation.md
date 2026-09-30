# Ordinary agent graph recipe evaluation

This evaluation implements G11 of the [six-stage program](wave-tracker.md).
The question is whether replacing the ordinary agent controller/runner with a
graph recipe preserves its observable behavior and reduces responsibilities.
Drawing a cycle or wrapping an agent in a graph node does not prove replacement.
Stage-5 live-provider acceptance remains pending independently.

## Candidates and decision criterion

The existing `fabric/graph/agent` operation composes the ordinary agent as a
managed child. It deliberately leaves transcript, tool policy, approvals,
settlement and agent record compatibility with the agent runtime. This is the
baseline for composition and does not duplicate the agent loop.

The first executable replacement probe has two graph nodes: a model turn and
a tool batch, looping over an encoded agent state. It reuses the pure agent
controller, registry and existing agent record reader so the experiment tests
the execution boundary rather than a new interpretation of tool semantics.
It lives only under `test/`; it is not a supported consumer API or a migration.
It admits sequential immediate tools and checks unsupported delegated/settling
work before dispatch. It refuses pending per-action approvals rather than
turning a graph-level approval into permission for all of a model's tools.

The probe must demonstrate provider replay data, usage, typed tool outcomes,
transcript order and turn/token limits on ordinary paths. Then it must expose
what is retained if a process dies after one tool succeeds and before its batch
returns. This is a falsifiable boundary: if the graph only records a batch
receipt, it cannot recover individual successful tool outcomes from that batch.
No lost effect may be replayed automatically to hide the mismatch.

A finer recipe can put every tool in a managed map member. It must then retain
per-action approval references, original tool-call order and provider replay
metadata; preserve independent uncertainty without canceling unrelated healthy
tools; recheck fresh context; propagate child-agent waits; accept late settlement;
and count retries as model attempts. These are obligations to assess against the
existing graph APIs, not claims that map composition already supplies parity.

## Required comparison

| Behavior                         | Evidence to collect                                                                                                                                  |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Model turns and typed tools      | Compare final status, full transcript, usage and action outcomes with ordinary runs and retained oracle scenarios.                                   |
| Provider metadata                | Carry assistant data, provider call IDs and replay state through a second request and receipt restoration.                                           |
| Approval and fresh context       | Show where the graph and per-action approval identities differ; preserve the existing managed-agent evidence.                                        |
| Partial batch loss               | Kill the store while the second sequential tool waits; inspect recorded first result and unreconciled work after restart.                            |
| Cancellation and late settlement | Compare scope ownership and the ability to settle individual effects without resuming canceled business work.                                        |
| Children, drain and discovery    | Reuse the managed-child lifecycle only where it preserves the same public agent handle and durable ownership.                                        |
| Versioned records                | Existing agent readers/writer window and graph envelopes remain independent; no implicit record-format conversion.                                   |
| Complexity                       | Count remaining effect-driving responsibilities, additional persisted copies and public lifecycle concepts; do not infer simplicity from node count. |

The gate is the root warnings-as-errors build and behavioral suite, including
existing oracle, agent, graph, recovery and lifecycle scenarios, followed by
relevant separate consumer/integration and formatting checks. A justified
negative evaluation may retain separate controllers over shared mechanisms.
It must name demonstrated mismatches and avoid claiming an incomplete recipe
as a compatible replacement.

## Findings and implementation decision

Keep the ordinary agent controller and runner, and compose it through
`fabric/graph/agent`. The executable two-node recipe matches its supported
round trips but fails the lifecycle equivalence criterion. No production
replacement or record conversion is justified by these results. This is a
negative evaluation of the proposed execution boundary, not a claim that a
more elaborate graph implementation could never model an agent.

The five differential/counterexample tests in
[`agent_recipe_test.gleam`](../../../test/fabric/agent_recipe_test.gleam) establish:

1. Full assistant replay data, provider call IDs/signatures, typed success and
   model-visible failures, call order, usage and the final transcript survive
   model → batch → model. Saved receipt decoding preserves the provider data.
2. Refusal, output limits, turn limits, token exhaustion and missing usage under
   a token bound have the same status as ordinary runs on supported paths.
3. An ordinary run exposes a per-action approval and rechecks fresh caller
   context. The batch recipe retains that request as inner data but has no
   equivalent public approval command; it stops before any tool body. A blanket
   approval of the batch would not resolve the missing action lifecycle.
4. After tool A succeeds and tool B starts, store loss leaves the ordinary run
   with A's saved success and only B uncertain. The recipe's last committed
   inner state still has both queued; its outer graph correctly blocks the
   whole batch and never replays it. A's completed result is unavailable to
   recovery even though the effect ledger proves A completed exactly once.
5. Canceling at that same point gives the recipe scope-level uncertainty, with
   no individual success/settlement receipt. No canceled successor runs.

Two additional tests in [`oracle_test.gleam`](../../../test/fabric/oracle_test.gleam)
execute the recipe against the three captured basic BeamWeaver scenarios:
`two_tool_calls`, `tool_error_visible`, and `model_call_limit`. The first two
match their retained comparison rules; the third preserves Fabric's deliberate
choice not to run a tool whose result cannot reach another allowed model turn.
The eight existing oracle tests still exercise the ordinary runtime, including
approval, cold restart and delegated-agent approval. No new BeamWeaver capture
or broader oracle parity is claimed.

The probe is retained at
[`support/agent_recipe.gleam`](../../../test/fabric/support/agent_recipe.gleam)
only to keep these findings executable. It rejects managed delegation, pending
per-action lifecycle and late-settling tools, and does not implement the agent's
model retry/backoff policy. These refusals mark missing implementation; they are
not evidence of equivalent behavior for those cases. Recovery of an interrupted
probe operation remains conservative and does not resubmit the model or batch.

## Why finer graph nodes are a separate design

Moving every tool to a map member would preserve individual child receipts,
but the current structured fork contract differs from an agent batch:

| Concern                    | Ordinary agent                                                                                  | Existing graph primitives                                                      | Consequence for a replacement                                                                                                          |
| -------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| Identity and review        | `ActionId(turn, call_id)` and per-action approval revision/requirement                          | Node activation/attempt and graph approval identity                            | Keep or deliberately migrate action references and audit records. A routing callback cannot supply this by itself.                     |
| Partial uncertainty        | An uncertain action blocks the next model turn; other admitted or queued actions can settle/run | Uncertainty prevents new fork admission and join; failure stops the scope      | Define the agent-specific admission policy. Treating uncertainty as a successful value loses native reconciliation/retention behavior. |
| Model failure              | Retryable attempts consume turns, with cancelable backoff                                       | Explicit replay repeats an activity under the same activation/attempt contract | Preserve attempt accounting, transcript requests and retry delay; a transient error is not sufficient replay authorization.            |
| Late tool settlement       | A stopped invocation can settle within its own retained window                                  | Graph activity uncertainty is reconciled at its operation boundary             | Retain per-invocation delivery and deadline ownership instead of discarding it at a generic join.                                      |
| Children and budgets       | Delegations retain their agent parent, action identity and inherited family budget              | Map members add managed graph children and activation identities               | Preserve child links, depth/work accounting and outward completion/cancellation observation.                                           |
| Records and public handles | Agent reader/writer window, snapshot, approval, reconciliation and recovery APIs                | Graph envelope, manifest, receipts and graph commands                          | Reusing an encoded agent record inside graph state does not make existing agent rows or handles graph records.                         |

The fork behavior is specified in [the parallel contract](parallel-composition.md)
and executed in `graph_parallel_test`, `graph_parallel_family_test` and the
PostgreSQL parallel tests. The ordinary partial-recovery behavior is executed
in `durable_test.restart_keeps_results_and_takes_over_running_and_queued_tools_test`.
These are current semantics, not implementation accidents to erase through an
adapter.

The two-node probe still needs the complete agent controller, registry and
record codec. It adds graph state and receipts containing earlier full agent
states. A finer recipe must additionally drive the action lifecycle described
above. Neither alternative currently removes the responsibilities that make the
ordinary runner necessary. No performance or storage-size benchmark is claimed.

## Supported composition and retained guarantees

Application graphs own their explicit typed routes, decisions, signals, jobs,
subgraphs and forks. When a node needs an ordinary tool-using conversation,
`fabric/graph/agent` creates or reconnects to the same managed agent child.
The ordinary handle remains available for approval and reconciliation; the
parent observes durable completion and cleanup through the shared store.

| Guarantee retained by this decision                                        | Executable evidence                                                                                                   |
| -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Fresh approval context and refusal of stale references                     | `approval_test`, `answer_test`, and the new approval counterexample                                                   |
| Completed result reuse and per-action uncertainty                          | `durable_test` and the new interrupted-batch comparison                                                               |
| Managed child approval/restart, nested delegation and lost acknowledgments | `graph_agent_test` and `delegation_test`                                                                              |
| Cancellation and late settlement without resumed routing                   | `cancellation_test`, `settlement_test`, `terminal_settlement_test`, `graph_agent_test`                                |
| Shutdown/drain, handoff and retry backoff                                  | `drain_test`, `leased_suite_test`, `ancestry_test`                                                                    |
| Agent and graph record versions, migration refusal and compatible recovery | `record_test`, `graph_record_test`, `graph_fork_record_test`, `write_version_test`, PostgreSQL record/migration tests |

The program's stage-6 implementation outcome is therefore to retain separate
controllers over the shared execution mechanisms. This preserves the complete
ordinary agent API while permitting it inside arbitrary application graph
routes. Saga and Grind remain outside core; an application may bind them through
ordinary operations or external-job adapters without changing this conclusion.

## Gate and remaining goal

Focused differential tests: five pass. Oracle suite: ten pass, including the
two new recipe comparisons. The root warnings-as-errors build and all 623 tests
pass. Graph/app/decision consumers pass 5/15/2; jobs pass 19 Gleam scenarios and
five independent service tests; the temporary PostgreSQL gate passes 57.
MCP/TypeSafe packages pass 22/18 scenarios, with four/three independent service
or fixture checks. No production controller, dependency or storage format is
changed by this evaluation.

Logs: `/tmp/fabric-agent-recipe-focused.log`,
`/tmp/fabric-agent-recipe-oracle.log`, `/tmp/fabric-agent-recipe-root-gate.log`,
`/tmp/fabric-agent-recipe-consumers.log`, `/tmp/fabric-agent-recipe-postgres.log`,
`/tmp/fabric-agent-recipe-adapters.log`. `nix fmt`, `nix flake check` and
`git diff --check` pass on this host. Stage 6 is accepted as a negative
replacement evaluation; the supported composition remains the managed agent.

Stage 5 subsequently passed actual OpenAI and TypeSafe inference with the
user-provided local configuration. The [completion audit](completion-audit.md)
records that separate live evidence and accepts the full six-step program.
This does not change the stage-6 decision to retain managed ordinary agents.

# Agents retain their own controller and compose as managed graph children

<a id="adr-0002"></a>

Ordinary agents retain transcript, per-action approval, individual tool results, model retry budgets and late settlement in their existing controller and runner. `fabric/graph/agent` creates or adopts the same independently stored agent child. Graphs retain activation/state/route control. They share confirmed effect fencing, backend ownership, supervision, family reservations and ancestry checks.

A two-node model-turn/tool-batch graph recipe matched supported round trips, provider replay data, ordering and basic outcomes. It failed the interrupted-batch criterion: after tool A completed and B started, the ordinary run retained A's result and only B's uncertainty; the outer graph had no per-tool durable receipt. It conservatively blocked the batch, but could not recover A's result. Blanket graph approval also did not resolve individual action references. The experiment is retained in `test/fabric/agent_recipe_test.gleam` and `test/fabric/support/agent_recipe.gleam`; it is not a supported migration.

A finer map recipe could persist individual members, but fork admission under uncertainty, scope failures, model retries, per-action approvals, settlement and record compatibility still differ. No evidence demonstrated a smaller complete replacement. Sharing mechanisms while retaining two controllers preserves meaningful lifecycle distinctions.

Historical provenance: `docs/implementation/graph-flow/agent-recipe-evaluation.md` records the executed counterexamples and negative replacement acceptance on 30 September 2026, retained at Fabric `ab678abe3b49b2d8dedc8b63845c35a60e6f918f`. Its associated transcript is unavailable here; no additional historical rationale or performance improvement is inferred. The current public graph/agent and per-action source contracts independently confirm the selected boundary.

The evaluation prose is retired after this rationale capture. Executable probes, oracle fixtures and supported consumers remain. The layer's agent lifecycle, tools/settlement and managed-child units carry the resulting behavior.

The earlier workflow-composition experiment favored a Fabric-owned controller
with tasks over one Saga per batch or a Saga-orchestrated loop. Executed
Saga-per-batch counterexamples lost finished results on restart and exceeded
the per-agent concurrency bound across batches. The fully Saga-owned loop could
not retain tested pause/reconciliation and individual-call cancellation.
Its in-memory suspend patch proved neither durable linear checkpoints nor
codec-compatible restart. Effort estimates were not an accepted work program.

That experiment used a scripted model, surviving in-memory CAS store and
single-node barriers against Saga `f241395` on 27 September 2026. It did not
prove PostgreSQL, current durable Saga, tokens/time, streaming or nested approval
escalation. The full [historical findings](https://github.com/gleam-dream/fabric/blob/ab678abe3b49b2d8dedc8b63845c35a60e6f918f/experiments/workflow_composition/FINDINGS.md)
remain in pinned history. Executable alternatives/prototype patch remain with
concise run/evidence-limit guidance, not as production dependencies.

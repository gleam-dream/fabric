# Graph program completion audit

2026-09-30. The complete six-step objective is satisfied. The final missing
acceptance was actual LLM and TypeSafe inference; both configured live consumers
now complete successfully. No production correction or retry was needed.
The unchanged original scope and governing rules G1–G11 remain in the
[wave tracker](wave-tracker.md).

## Actual provider execution

The user supplied credentials through the ignored root `.env.local`. Only the
named provider/model settings were loaded as environment data, without shell
evaluation or displaying credentials. Each entry point made one bounded adapter
invocation with synthetic input `2 + 2 = 4`. Both commands exited with status 0
and asserted graph completion, the selected terminal route and decoding of the
retained receipt. Neither used the offline fixture or an automatic retry.

| Provider              | Requested / resolved model                                   | Validated native result                                  | Route                           | Reported tokens              |
| --------------------- | ------------------------------------------------------------ | -------------------------------------------------------- | ------------------------------- | ---------------------------- |
| OpenAI structured LLM | Requested `gpt-4.1-nano-2025-04-14`; no resolved-model claim | `{"decision":"approve"}`                                 | `publish`, completed `approved` | 77 input, 6 output, 83 total |
| TypeSafe System One   | Requested `jev-latest`, resolved `jev-1.13.0`                | Noul yes 0.99; Choice `Approve`; Score 2.0 on levels 0–2 | `publish`, completed `approved` | 384 input, 62 output         |

TypeSafe's Choice distribution was `approve: 1.0, revise: 0.0`, with confidence
1.0. Its score distribution was `0: 0.0, 1: 0.0, 2: 1.0`, with confidence 1.0.
The retained rubric was `Incorrect`, `Partially correct or unclear`, `Correct`.
These are observed answers to this synthetic input, not classifier-accuracy or
confidence-calibration claims.

Commands executed with the loaded settings:

```sh
nix develop -c sh -c 'cd consumers/decision && gleam run'
nix develop -c sh -c 'cd consumers/decision && gleam run -m fabric_decision_classifier'
```

The LLM request had a 64-output-token cap and a 20-second deadline; TypeSafe had
one three-question batch and a 20-second deadline. The commands exercise the
same [application routing definition](../../../consumers/decision/src/fabric_decision_demo/routing.gleam).
Their producer bindings and receipt codecs remain distinct. Full sanitized
command output is retained in [live-adapters-2026-09-30.txt](live-adapters-2026-09-30.txt).
No credential or `.env.local` content is retained there.

## Requirement-by-requirement result

| Original requirement                                           | Authoritative implementation and behavioral evidence inspected                                                                                                                                                                                                                                                                                                                                                                                                                                   | Verdict                                                 |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------- |
| 1. Typed authoring, scripted decisions and bounded review loop | `experiments/graph_authoring/check.py` was rerun: 12 library and six external-consumer tests pass; the example accepts draft 3 in six activations; a fresh valid consumer compiles and both input/output type mismatches are rejected. `consumers/graph` and `graph_runtime_test` exercise the production API and exact activation bound.                                                                                                                                                        | Complete                                                |
| 2. Durable routing, cycles, activation identities and policy   | `fabric/graph`, its controller/record/runner and `graph_runtime_test` retain accepted branches through directory-store loss, separate queued/started effects, reject stale or incompatible work, gate dispatch with committed starts, preserve fresh approval context, and bound retries/cycles. PostgreSQL scenarios exercise persistent lease and commit ownership.                                                                                                                            | Complete                                                |
| 3. Managed agents/subgraphs, signals and external jobs         | `graph_agent_test`, `graph_child_test`, signal/deadline tests and shared family-budget tests cover retained identities, nested waits, lost acknowledgments, restart, cancellation and uncertainty. The separate HTTP/SQLite job consumer covers actual submission, accepted receipt versus completion, restart, scheduled observation and owned cancellation.                                                                                                                                    | Complete                                                |
| 4. Typed fork/map/join and explicit failure                    | `graph.both`/`graph.map`, `graph_parallel_test`, family/fork/deadline tests and PostgreSQL cases cover heterogeneous pairs, bounded maps, isolated members and visits, declared result order, partial restart, failure/uncertainty, cancellation and retained cleanup.                                                                                                                                                                                                                           | Complete                                                |
| 5. Real classifier, LLM and MCP adapters                       | The two actual-provider runs above close the live inference requirement. The MCP package's 22 scenarios and four independent server tests exercise a real local SQLite effect over stdio, schema pinning, approval, cancellation and receipt recovery. LLM/classifier protocol tests separately cover invalid output, failure classification, bounds and offline restart; the separate decision consumer proves both business routes for each producer.                                          | Complete                                                |
| 6. Evaluate an ordinary agent graph recipe                     | Five differential/counterexample tests and two comparisons against three retained oracle cases execute the proposed recipe. The [evaluation](agent-recipe-evaluation.md) records supported parity and demonstrated loss of per-action durable outcomes in an interrupted batch. The selected result retains ordinary agents as managed graph children, preserving their complete action lifecycle and public records. The original program explicitly allowed a negative replacement evaluation. | Complete as evaluated; no controller migration selected |

The audit inspected these contracts and relevant test bodies, rather than using
suite counts alone. No required feature is represented solely by a plan or an
unexecuted adapter. No optional future feature was relabeled as completed.

## Gate evidence

The preceding implementation checkpoint passed the root warnings-as-errors
build and 623 tests, including all ten oracle tests; the PostgreSQL gate passed
57 tests against a temporary real database. Graph/app/decision consumers passed
5/15/2 tests. External jobs passed 19 Gleam and five independent Python tests.
MCP and TypeSafe packages passed 22/18 scenarios, with four/three independent
service/fixture checks. Those source inputs are unchanged during this final
live-validation turn. The retained authoring/compiler-negative gate was rerun
successfully, and both live commands compiled and ran the current consumer.

Relevant command logs are `/tmp/fabric-agent-recipe-root-gate.log`,
`/tmp/fabric-agent-recipe-postgres.log`, `/tmp/fabric-agent-recipe-consumers.log`,
`/tmp/fabric-agent-recipe-adapters.log`, `/tmp/fabric-classifier-final.log`,
`/tmp/fabric-final-authoring-audit.log` and
`/tmp/fabric-live-acceptance-20260930.log`. The last is reproduced in the retained
sanitized output above. Final documentation checks passed: `nix fmt`,
`nix flake check` and `git diff --check`.

## Scope and remaining repository work

Saga and Grind remain outside Fabric core. MCP acceptance covers the selected
modern stdio protocol and supported closed schema subset. Live inference proves
this bounded integration path; it is not exhaustive provider/model certification.
The agent recipe is retained only as an executable evaluation, not a substitute
for the ordinary agent's recovery guarantees. Graph/agent/backend record versions
are unchanged by the live checks.

Full LangGraph compatibility, shared mutable channels, quorum/streaming joins,
arbitrary runtime code generation and automatic compensation were outside this
six-step program. The separate repository backlog remains in `docs/REMAINING.md`.
No unrelated design-ledger entry or backlog item is cleared by this acceptance.

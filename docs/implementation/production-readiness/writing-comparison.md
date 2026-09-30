# Writing workflow: live comparison and authoring findings

Measured on 2026-09-30. Both real reviewer adapters completed the same frozen
12-case corpus and a full generation → review → approval → saved-artifact
workflow across separate VMs. On this corpus, TypeSafe matched 12/12 expected
labels; the configured GPT-4.1 nano reviewer matched 6/12. These results support
the interchangeable decision boundary; they do not establish a general model
ranking or production accuracy.

## Method and retained evidence

The [consumer](../../../consumers/writing/README.md) uses the existing public
graph, LLM and TypeSafe APIs. Both reviewers receive identical source, brief
and draft values with the same approve/revise/reject rubric. Each uses its
adapter's native protocol: a structured LLM response or a TypeSafe choice
question. Their complete billable payloads and tokenizers therefore differ.
The TypeSafe question includes the shared rubric and descriptions for each
alternative. No prompt or case was tuned after seeing these results.

The [corpus](../../../consumers/writing/fixtures/cases.json) was frozen before
the run: four correct drafts, four repairable drafts and four briefs whose
required facts are absent from the source. Synthetic local facts and explicit
rationales define the labels. Labels/rationales are not sent to either provider.
These are developer-authored examples, without independent human adjudication.
The sample is deliberately small and has no repeated trials, calibration
estimate or statistical generalization.

- Start: `2026-09-30T15:31:24.894689+00:00`.
- Corpus SHA-256: `1ad083bdb7a6dd4898de7b4e6577c8e40023aefd4c90dada21977b58be18a207`.
- LLM requested model: `gpt-4.1-nano-2025-04-14`. Its adapter receipt records
  the requested model; a separate resolved model was not available.
- TypeSafe requested model: `jev-latest`; every receipt resolved it to
  `jev-1.13.0`.
- One attempt per provider per case, alternating provider order. No automatic
  retries, failed-case exclusions or scripted replacement responses.
- Monotonic elapsed time covers graph start through recorded decision,
  including adapter, network and graph overhead. Generation, compilation and
  VM startup are excluded. Every sample uses a fresh VM/connection; this is not
  a warmed production throughput measurement or provider-only inference time.
- [Retained JSON](evidence/writing-20260930.json) includes all 24 samples,
  original receipts, usage, requested/resolved models, both workflow snapshots,
  artifact content/digests and source-file hashes. Raw local logs remain in
  `/tmp/fabric-writing-live-20260930-verified`. Credentials are absent from the
  retained evidence. Paths inside raw receipts describe that local run.

## Results

| Measure                      |     GPT-4.1 nano | TypeSafe Jev 1.13.0 |
| ---------------------------- | ---------------: | ------------------: |
| Expected labels matched      |       6/12 (50%) |        12/12 (100%) |
| Valid typed decisions        |            12/12 |               12/12 |
| Failed or invalid results    |                0 |                   0 |
| Median decision elapsed      |       2,698.5 ms |              465 ms |
| Minimum / maximum            | 1,110 / 4,576 ms |        425 / 506 ms |
| Reported input tokens        |            2,779 |               7,101 |
| Reported output tokens       |               74 |                 472 |
| Estimated cost of 12 reviews |     $0.000307500 |        $0.000298242 |
| Measured billing             |      Unavailable |         Unavailable |

TypeSafe's median was about 5.8 times faster in this run. Estimated review
costs were close because its measured input token count was higher. Both
outputs were structurally valid on every case; that did not guarantee a
correct decision.

| Case                     | Expected | LLM     | TypeSafe |
| ------------------------ | -------- | ------- | -------- |
| library_complete         | approve  | approve | approve  |
| park_complete            | approve  | approve | approve  |
| workshop_complete        | approve  | approve | approve  |
| tram_complete            | approve  | approve | approve  |
| library_missing_price    | revise   | approve | revise   |
| park_wrong_count         | revise   | reject  | revise   |
| workshop_invented_meal   | revise   | revise  | revise   |
| tram_wrong_scope         | revise   | reject  | revise   |
| library_missing_capacity | reject   | revise  | reject   |
| park_wrong_topic         | reject   | reject  | reject   |
| workshop_missing_access  | reject   | approve | reject   |
| tram_missing_fare        | reject   | approve | reject   |

The LLM approved three drafts that should not pass review: one omitted a
requested price, and two asserted facts absent from the source. It also
confused a repairable draft with an unsupported brief. The graph correctly
recorded and routed those decisions; runtime correctness and reviewer quality
are distinct requirements. Human approval remains a separate gate.

Price assumptions checked on 2026-09-30: OpenAI lists $0.10 per million input
tokens and $0.40 per million output tokens for this model; the estimate treats
all input as uncached. [Official model pricing](https://developers.openai.com/api/docs/models/gpt-4.1-nano).
TypeSafe lists $0.042 per million input tokens and free output tokens.
[Official Jev announcement](https://typesafe.ai/blog/introducing-system-one-models-and-jev).
The estimates use reported usage times those public rates. They exclude the
separate generation workflows, account credits, discounts, taxes and any
account-specific terms. Neither provider's billing statement was inspected.

## Complete application and recovery

Both live configurations produced an accepted first draft. Each stopped for
approval, exited its VM and reattached in another VM with identical state,
revision and provider receipts. A third VM supplied approval through Fabric's
public API and saved one Markdown file. The demonstration runner supplied this
approval; no real person's review is claimed. Previously completed receipts
were unchanged, and the saved file matched its SHA-256 receipt:
`CF90532F753189C588F808F7FCE8C7CA9D66C29DE7B6720D4A72DB6B95B84B4C`.

Both artifacts contain: “Riverside Library opens on 12 May 2027, with free
admission, at 8 Willow Lane.” Each workflow made one real generation request
and one real review request. The live examples did not require revision;
offline scenarios exercise revision, exhaustion and rejection explicitly.

Eight Gleam scenarios also prove missing-source behavior, invalid/refused/
incomplete review handling, stale approval refusal, identical/conflicting file
saves, store restart and an interrupted save whose result was lost. Replay of
the latter requires a fresh approval and acknowledges the existing identical
file without another model call. Directory storage proves process/VM restart,
not power-loss durability. Seven Python scenarios check corpus validation,
credential loading, measured values and failed-attempt accounting.

## Authoring findings

1. **The operation boundary composes well.** A small application-owned
   `Reviewer(receipt)` pairs an operation with a typed interpretation function.
   Swapping it preserves the graph's native decision and each adapter's richer
   receipt. No new core API, Saga dependency or workflow engine was needed.
2. **Codecs are the largest source of repetitive code.** Domain declarations
   and codecs occupy 196 lines, compared with 138 for the graph. Record helpers
   help, but tagged states and output variants still need mappings. The
   example also builds nested codecs inside callbacks to avoid copying large
   combinator environments into operation tasks. A separately measured
   json_blueprint improvement would be more appropriate than a Fabric codec
   wrapper; this wave does not alter that library.
3. **State selection remains explicit.** Node input/output types compose
   correctly, but state-to-input selectors still reject the wrong stage at
   runtime. Keep that visible in examples. A helper should be justified by a
   second real consumer before adding another public abstraction.
4. **Save recovery belongs to the application tool.** A stable run/activation
   key, exact-content check and atomic file creation make bounded replay safe.
   Fabric supplies admission, stored progress and fresh approval. A recovery
   test initially expected the original approval to authorize another attempt;
   the corrected test now verifies the existing per-attempt policy contract.
5. **The decision producer can improve independently.** A follow-up evaluation
   could compare decomposed factual questions or a stronger LLM on a larger,
   separately labeled holdout corpus. Do not tune the frozen cases and present
   the new score as independent evidence. The current graph requires no change
   to support another producer.

The only live-run setup repair was credential precedence: an empty inherited
OpenAI variable initially hid the populated `.env.local` entry. That attempt
sent no requests. The loader now uses nonempty environment values first and
falls back to the file for empty values, with a regression test. The successful
run above made 24 review requests plus four workflow requests, without retries.

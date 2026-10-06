# Review quality varies independently of typed control and authorization

<a id="adr-0012"></a>

The writing consumer's application-owned Reviewer pairs an operation with typed
interpretation. Receipts remain native to each producer; the graph owns accepted
routes, state and publication approval. Substitution needs no Fabric DSL or
workflow engine. A valid typed decision does not prove quality or permission.

On 30 September 2026 a frozen twelve-case corpus compared a structured GPT-4.1
nano reviewer with TypeSafe Jev. Both returned twelve valid typed decisions;
expected labels matched 6/12 and 12/12. Four complete drafts, four repairable
drafts and four unsupported briefs used developer-authored labels without
independent adjudication or repeated trials. Corpus digest:
`1ad083bdb7a6dd4898de7b4e6577c8e40023aefd4c90dada21977b58be18a207`.
Requested models were `gpt-4.1-nano-2025-04-14` and `jev-latest`; Jev resolved to
`jev-1.13.0`, while a separately resolved LLM model was unavailable.

Both received the same source/brief/draft/rubric through distinct native
protocols, so payloads/tokenizers differed. One attempt per case alternated
provider order without retries or failed-case exclusion. Fresh-VM
graph-start-to-decision medians were 2698.5 ms and 465 ms, including
adapter/network/graph overhead and excluding generation/VM startup. Historical
cost estimates were close despite different reported tokens; no billing
statement was inspected. This proves neither current prices, throughput,
calibration nor general model ranking. Raw evidence remains in
[writing-20260930.json](../evidence/writing-20260930.json).

Recorded workflows paused for approval, reattached across VMs with unchanged
earlier receipts/state, then saved one artifact after demonstration-runner
approval. No real person's review was established. Live paths accepted their
first draft; offline tests supply revision/rejection/exhaustion/interrupted-save
scenarios. Directory storage proves process/VM restart, not power-loss
durability. Stable logical keys, exact-content comparison and atomic creation
make the application's declared save replay safe. Prior approval does not
authorize another attempt.

Authoring supports native state and explicit selectors; a shared state type
does not prove phase reachability. Repetitive codecs belong to the codec
library/application. A state-selection helper or classification DSL needs a
second concrete consumer. A stronger model or decomposed review questions can
be evaluated on a separately labeled holdout; tuning frozen cases is not
independent evidence.

Provenance: [original comparison](https://github.com/gleam-dream/fabric/blob/ab678abe3b49b2d8dedc8b63845c35a60e6f918f/docs/implementation/production-readiness/writing-comparison.md)
at Fabric `ab678abe3b49b2d8dedc8b63845c35a60e6f918f`, public source/tests, corpus
and sanitized raw captures. Milestone prose is retired after rationale capture.
No live providers, credentials, current pricing or new quality trial were
accessed during this migration.

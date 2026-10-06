# Classification operation versions fix pure wire meaning and receipt bounds

<a id="adr-0006"></a>

Each graph classification operation version fixes questions, pure provider wire and finite receipt bounds. After admission, its request callback derives current client, credential and execution settings from fresh context. Changing protocol requires another operation version; endpoint or credential settings cannot change historical interpretation.

The alternative of capturing live Config at definition time retained stale approval/recovery context. A per-call protocol selector or decoder registry would multiply compatibility choices without a demonstrated caller need. A fixed pure wire makes stored receipts decode offline without network activity, credential reveal or current live settings. Application deployment must retain compatible earlier definitions.

Live request and response byte limits above fixed receipt bounds fail during typed preparation before credential access or I/O. Limits are never silently reduced. Stricter future live limits do not prevent older receipt decoding; transport admission and durable-record bounds retain independent responsibilities. Complete distributions remain mandatory and confidence/usage preserve omission. Concentration is not answer-correctness probability.

Generation and classification share llm_wire provider capability ownership but produce different receipts. Application routing interprets them into a business decision, while policy independently admits effects. No classification-as-agent-tool abstraction was added because ordinary typed binding can use the port.

Provenance: owner-approved typed composition decisions recorded on 5 October 2026 in Oversight `3baff7030a96d5b6cf78b2335c16d8c203727da5`, `DECISIONS.md` and `PLAN.md` typed follow-up. Fabric `509ebef` implements fresh-context settings; `d2471db` records fixed protocols and reporting rationale. Genuine pre-Round-9 graph/receipt fixtures remain under `test/fixtures/records`; current `graph/classify.gleam` independently confirms boundary timing. No live-provider parity is inferred from this documentation migration.

Destinations: provider adapter and compatibility units; classification tests and frozen offline fixtures remain. Former TypeSafe bridge exploration and provider-specific API sketches are retired.

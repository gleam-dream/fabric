# Core ports and compiled consumer recipes own ecosystem composition

<a id="adr-0003"></a>

Fabric core owns protocol-neutral invocation and graph decision receipts. llm_wire owns provider-neutral classification. Saga owns full workflow reports and surviving cancellation reporting. Relay owns protocol output/evidence and metadata. Warden owns identity verification. Applications translate those independent meanings through compiled public recipes. `fabric_typesafe`, `fabric_saga` and `fabric_relay` stay retired. The PostgreSQL adapters remain separate because their substantial infrastructure and dependencies warrant packages.

The owner selected this scope on 5 October 2026, recorded in Oversight Round 9. A bridge solely shortening mappings adds dependencies and another surface without supplying a new owner. Conversely, moving request admission, waiting and cancellation into each transport recipe would duplicate real runtime responsibilities. A universal error, retry, task or durability protocol was not selected because package invariants differ.

Invocation idempotency scopes include service, runtime family and authenticated principal. Tuple parts are framed before hashing, preventing the old free-form joins from aliasing distinct keys. Action/activation idempotency stays independent of attempt and correlation. Legacy records remain readable by their original ids; applications must preserve established old mappings or finish/reconcile old keyed work before changing mappings. The general `run.id_from_parts` helper still documents fixed-shape-part requirements and hyphen-join aliases.

Recipes are compiled verbatim and checked for drift. The later typed-reporting follow-up permits a 60-line Saga recipe; its current 59 lines retain operational cause versus execution outcome. Other ceilings remain 50. Approximate recipe size is a maintenance constraint, not a semantic capability reduction. Promotion requires observed copy drift or growing mapping cost, rather than a desired shorter example.

Provenance: Fabric `d0f3eb9` removes the classification bridge, `c57af7c` replaces the Saga bridge, `137d3fd` adds invocation and replaces the Relay bridge, `f917cb8` updates the typed Saga projection. Oversight `3baff7030a96d5b6cf78b2335c16d8c203727da5`, `DECISIONS.md` Round 9 and `PLAN.md` Round 9/follow-ups record authorization and alternatives. New inferred historical dates are not assigned.

Layer destinations: provider/recipe and invocation units, plus preserved README code and `consumers/saga_tool`, `relay_tools`, `approvers_warden` modules/tests. Former-package rows receive no current coverage entries.

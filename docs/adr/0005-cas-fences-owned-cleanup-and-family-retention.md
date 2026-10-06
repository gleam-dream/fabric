# Confirmed CAS fences and retained ownership govern recovery and cleanup

<a id="adr-0005"></a>

One expected revision can advance once. Fresh write tokens and exact-byte/target-revision readback distinguish confirmation of an unavailable write from another writer storing equivalent state. Leases separately choose the live execution driver; their expiry and scheduling use the backend clock. A successful lease claim does not replace record validation, policy, ancestry or quota authority.

Body-start fences distinguish unstarted work from possibly performed effects. Lost runners recover accepted results, but unresolved started effects require reconciliation or an explicit replay contract. Cancellation and expiration close routing before cleanup and preserve actual results, stop-request progress and unresolved children. Stopping a local task or accepting a remote stop request does not prove an external effect stopped. Late settlement can update the same action once without resuming terminal business work.

Managed children retain reciprocal attachments and reserved identities. Missing unacknowledged creation can recover the same child; missing acknowledged child is data loss. Structured forks retain ordered membership, private state and deterministic joins. Family budgets use a separate monotonic claim ledger; grants are not refunded implicitly, initialized lost ledgers do not reset capacity, and cleanup uses existing admission. These contracts differ from a job queue or compensating workflow and do not justify a shared runtime superclass.

Idle discovery is a scheduling hint. Versioned dependency/poll/deadline metadata must be refreshed without changing source execution data, ages or same-key schedules. Family pruning requires complete reciprocal membership, authoritative settlement, sufficient age and no live leases atomically. Ended does not mean settled. Pruning ends the reopening evidence window.

The directory backend intentionally omits directory-entry flush and therefore promises no power-loss durability. Production database backend correctness belongs to the nested adapter layer; no pool ownership or SQL behavior is inferred from the parent port. Application supervision orders migrations/projection refresh, store, sweeper and admission; shutdown reverses admission and recovery before store drain.

Provenance: Fabric `docs/PLAN.md` S2–S7 and graph serial/managed/parallel contracts, retained at `ab678abe3b49b2d8dedc8b63845c35a60e6f918f`, record implemented contracts and accepted refinements. They do not supply one single original decision date; this record consolidates rationale without inventing one. Current backend port, controllers, budget modules, drain and projections are independently inspected. Fabric `dd61bca` preserves invocation uncertainty/answers across cancellation and expiration. Original transactional admission/outbox intent for external queue delivery remains unresolved in ADR 0008.

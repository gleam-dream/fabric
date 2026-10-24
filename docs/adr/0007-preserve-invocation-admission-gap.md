# Invocation's unconfirmed admission remains an explicit unresolved contract gap

<a id="adr-0007"></a>

Native `fabric.StartUnconfirmed` means the initial record write was not confirmed and may still commit. It retains the attempted RunId and supports same-id retry or stored cancellation. Current `invoke` agent and graph start-error paths instead produce `Refused` with `start_failed` and safe description. Operational read/await failures also use `Refused` with `unavailable` in current paths. This record describes the implementation and does not accept its classification as the intended outcome model.

The 6 October 2026 public-API fake backend probe reports native `Unavailable`, invocation `Refused`, and an unconfirmed-write description. It proves typed distinction loss, not a committed insert, duplicate effect or actual write completion. Current invocation response already retains run id; no additional id field is needed.

Mapping native StartUnconfirmed to existing OutcomeUnknown is a proposed correction. Separately deciding whether read/await operational causes need typed accessors avoids conflating that proposal with a broad response redesign. Invalid configuration and key reuse should remain true refusals. No runtime fix, API change or external issue is authorized by this design migration.

The useful discriminating test would retain an initial record after acknowledgement loss, keep readback unavailable until a barrier, then retry the same principal/key and prove one logical run and at most one admitted tool effect. It must exercise both graph and agent invocation. This requirement is an unresolved evidence/behavior task, not a claimed passing probe.

Provenance: current Fabric `ab678abe3b49b2d8dedc8b63845c35a60e6f918f`, `src/fabric.gleam` Error and invoke start branches; the preceding ecosystem review reported the disposable probe described above. The probe was not installed as a retained test; the source branches are the durable evidence for the mapping. This ADR records its bounded result and the native pending ruling retains the actionable uncertainty.

## Accepted correction — 7 October 2026

- The owner authorized the admission correction with TDD after ecosystem review. The earlier paragraphs retain the evidence and authorization limits at capture time.
- An unavailable admission cannot establish refusal. Agent StartUnconfirmed and admission StoreUnavailable therefore use the existing OutcomeUnknown kind. This includes unavailable keyed reopen and input verification. Graph callback or input preparation failures remain definite refusals.
- Preserve the attempted run id, existing response codes and response shape. No persisted format changes or automatic retry are needed. A retry retains service, principal and key; recovery remains explicit.
- General operational read/await failure classification remains outside this correction. The retained `consumers/relay_tools/test/invoke_admission_test.gleam` consumer commits initial bytes before losing acknowledgement and blocks readback until a barrier. Its agent and graph cases failed with Refused before the correction and pass with OutcomeUnknown afterward. Same-key recovery retains one record and executes one effect. Definite preparation failure, invalid wait and key reuse remain refusals. The fixture establishes public backend behavior, not PostgreSQL fault or power-loss evidence.

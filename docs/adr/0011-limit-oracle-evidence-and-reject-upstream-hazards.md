# A pinned partial oracle supplies evidence without supplying authority

<a id="adr-0011"></a>

BeamWeaver is a partial agent-loop oracle. The selected fork is
`d0aa1f90d31c55d49be2f7b5a24224b5e18145a1`, upstream v0.1.23 `60fdcd7` plus four
durability commits. Its package version alone cannot identify those fixes.
September research reported identical examined non-durable probes across the
fork, v0.1.23 and v0.1.29; fork differences concerned checkpoint identity,
atomic checkpoint/write boundaries and cold replay. This is attributed
historical execution evidence, not a new comparison run during migration.

The original probes observed tool/sub-agent-start review surviving separate-VM
restart in ETS/SQLite scenarios. Those pauses came from upstream interrupts,
not new fork authorization. They do not establish Fabric's authenticated policy.
Current source/fixtures own each present claim. ORACLE separates executed
differential, inspired, original, anti-oracle and unverified behavior.

Executed upstream hazards justify differences: nested sub-agent interruption
became a successful-looking result string; stale/duplicate resumes restarted
work; concurrent answers duplicated a tool effect; invalid answers consumed
a pause; and tool loss required explicit checkpoint replay that could repeat
the tool. Fabric retains once-only CAS answers, child waiting/uncertainty and
original-effect reconciliation. Killing a task does not prove external rollback.
Human review and execution authorization remain separate.

Historical execution used Elixir 1.19.5/OTP 28.5. The report described passing
fork/upstream suites with PostgreSQL/docker exclusions and SQLite cold-restart
probes. PostgreSQL concurrent double resume, nested-worker cancellation and some
nil/duplicate-call behavior stayed unverified. Fresh-VM lazy loading produced
an atom-decode failure; embedded-release immunity was not proved. Ephemeral
logs are not present dependencies. Current fixture captures own exact commands,
toolchains, normalization exclusions and license provenance.

Pure interface-lab evidence demonstrated typed heterogeneous registration,
scoped reports, explicit policy, revisioned approval, provider-origin
continuation, finite turns and accepted-action observations. It could not prove
linear use, authentication, isolation, durable CAS, leases, cancellation,
tokens/time, streaming or independent child recovery. The sibling survey
described its captured revisions, not current APIs. Current source/consumers
resolve later changes; retained gaps remain in ADR 0008.

These observations support a normalized partial oracle and negative tests,
without importing upstream middleware/channels/atom serialization or a universal
runtime. Fixtures are recaptured rather than edited. Operational instructions
remain in [ORACLE](../ORACLE.md).

Provenance: research dated 27 September 2026 at Fabric
`ab678abe3b49b2d8dedc8b63845c35a60e6f918f`:
[beamweaver-oracle](https://github.com/gleam-dream/fabric/blob/ab678abe3b49b2d8dedc8b63845c35a60e6f918f/docs/research/beamweaver-oracle.md),
[lab-evidence](https://github.com/gleam-dream/fabric/blob/ab678abe3b49b2d8dedc8b63845c35a60e6f918f/docs/research/lab-evidence.md),
[package-apis](https://github.com/gleam-dream/fabric/blob/ab678abe3b49b2d8dedc8b63845c35a60e6f918f/docs/research/package-apis.md).
Scratchpad prose is retired after capture. Historical execution claims are
attributed to that report and were not independently rerun here.

## Differential capture history

The 27–28 September 2026 capture produced eight ordinary-runtime fixtures at the
pin: two-tool dispatch, visible tool failure, model-call exhaustion, approve,
reject, cold restart, and sub-agent-start approve/reject. Reported matches used
exact transcript order and multiset concurrent effects, excluding protocol error
wording and final answers that embed it. The model-call-limit comparison asserted
a deliberate difference: Fabric did not start the final tool when its result
could not be consumed by another allowed model call.

The cold-restart oracle used two additional VMs and SQLite; Fabric's comparison
killed its processes over directory storage. The approval protocols differed:
Fabric answered an individually referenced policy requirement, while BeamWeaver
answered a batch interrupt. The sub-agent protocol and durable child ownership
also differed. Normalization did not establish equivalence for those structures,
edit/respond answers, authorization, all timeouts or arbitrary child recovery.

The [original ledger and result tables](https://github.com/gleam-dream/fabric/blob/ab678abe3b49b2d8dedc8b63845c35a60e6f918f/docs/ORACLE.md)
retain the exact recorded comparison details. The working-tree oracle guide now
owns current reproduction rules and evidence limits; dates and capture chronology
are retained here and in the immutable raw fixture metadata.

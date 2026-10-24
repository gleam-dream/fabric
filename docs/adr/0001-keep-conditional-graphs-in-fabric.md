# Conditional graphs remain part of Fabric's package contract

<a id="adr-0001"></a>

Fabric owns both bounded model-turn agents and application-defined conditional graphs. The graph runtime shares Fabric's failure, policy, approval, context, cancellation, storage and family vocabulary. Its public modules carry the same package semver promise as agent modules.

The September graph exploration selected typed state with bound operations, exclusive declared routes, bounded cycles and isolated structured forks. A model supplies typed judgments within the application protocol; it does not install code or grant itself permission. Shared channels, shared sibling state, quorum/streaming joins and automatic compensation were not selected. Typed heterogeneous ports were considered but feedback would require explicit initialization, occurrence and token ownership; native state plus pure selection/acceptance was the smaller cyclic protocol. Dynamic JSON state was rejected as the ordinary authoring model because it moves business type errors out of Gleam.

The owner decision recorded on 3 October 2026 selected graph-in-Fabric for 1.0 over a separate `fabric_graph` 0.x package. Calling graph modules unstable inside 1.0 would not remove their semver obligation. This supersedes the original Oversight ownership table assigning all durable graph execution to Saga and the earlier blanket exclusion of cyclic graphs. Saga retains independent workflow and compensation authority. Similar lease fields do not establish a shared durability abstraction.

Historical provenance: the graph exploration cites Fabric `c375d60` and BeamWeaver fork `d0aa1f90d31c55d49be2f7b5a24224b5e18145a1`; source inspection was not a new parity run. `23ae7183dbf8adf4768eeef173bf16184959b19e` retains the Fabric graph doc after vocabulary changes. Owner acceptance is recorded in Oversight `3baff7030a96d5b6cf78b2335c16d8c203727da5`, `docs/release-api/DECISIONS.md` decision 2 and `PLAN.md` Fabric rows. Exact original discussion timestamps beyond those records are unknown.

Retired inputs and destinations: `docs/GRAPH-FLOW.md`, the graph implementation tracker and serial/parallel contract docs now land in the native graph authoring, serial control, signal/deadline, child/family and fork units. Original broader intent not implemented is retained through [ADR 0008](0008-carry-unbuilt-capability-intent.md).

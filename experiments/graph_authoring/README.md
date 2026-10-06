# Graph authoring experiment

This retained prototype exercises typed heterogeneous operations, native state,
declared routes, cyclic visits and encoded receipts through a separate consumer.
Its driver is synchronous and is not the production Fabric runner.

From the Fabric root:

```sh
nix develop -c python3 experiments/graph_authoring/check.py
```

The check builds the prototype and external consumer, runs their tests/example,
and checks that incompatible input and acceptance types fail to compile. The
example can also run with:

```sh
nix develop -c sh -c 'cd experiments/graph_authoring/consumer && gleam run'
```

These probes establish only their tested authoring/selection/codec contracts.
They do not prove effect fencing, process isolation, cancellation, deadlines,
restart, leases, durable acknowledgements, parallel children or live providers.
The production behavior is specified by the [native graph design](../../docs/design/design.typ#graph-authoring-and-serial-control).
Alternative authoring rationale is captured in [ADR 0001](../../docs/adr/0001-keep-conditional-graphs-in-fabric.md);
the separate agent-controller decision is [ADR 0002](../../docs/adr/0002-retain-agent-controller-and-managed-composition.md).

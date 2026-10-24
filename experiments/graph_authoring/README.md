# Graph authoring experiment

A retained prototype of typed heterogeneous operations, native state, declared
routes and encoded receipts with a synchronous driver. It is not the production
runner.

```sh
nix develop -c python3 experiments/graph_authoring/check.py
```

The check builds the prototype and an external consumer, runs their tests and
confirms that incompatible input and acceptance types fail to compile. The
rationale is in [ADR 0001](../../docs/adr/0001-keep-conditional-graphs-in-fabric.md)
and [ADR 0002](../../docs/adr/0002-retain-agent-controller-and-managed-composition.md).

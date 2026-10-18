# Workflow composition experiment

A retained comparison of three alternatives with a scripted model and an
in-memory store: a Fabric controller with tasks, that controller with one Saga
per batch, and a Saga-orchestrated loop. It is no production dependency.

```sh
nix develop ../.. -c gleam test
```

The rationale for keeping it is in
[ADR 0002](../../docs/adr/0002-retain-agent-controller-and-managed-composition.md)
and [ADR 0008](../../docs/adr/0008-carry-unbuilt-capability-intent.md).

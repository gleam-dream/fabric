# Workflow composition experiment

This retained comparison uses a scripted model and an in-memory CAS store to
exercise three alternatives: a Fabric-owned controller with tasks, that
controller with one Saga per batch, and a Saga-orchestrated loop. It is an
experiment and is not a production dependency or public Fabric API.

From this directory:

```sh
nix develop ../.. -c gleam test
nix develop ../.. -c gleam format --check src test
```

The tests preserve the alternative's counterexamples as passing assertions.
They cover the named pause/restart/result/cancellation/concurrency scenarios;
they do not prove current durable Saga, PostgreSQL, multi-node execution,
streaming, token/time bounds or nested approval propagation.

`saga-suspend-prototype.patch` is an experimental patch against Saga `f241395`.
Inspect it only in a disposable compatible copy; it is not a supported upgrade
or a completed durable-suspension contract. Source-based rationale is captured
in [ADR 0002](../../docs/adr/0002-retain-agent-controller-and-managed-composition.md),
and retained integration gaps in [ADR 0008](../../docs/adr/0008-carry-unbuilt-capability-intent.md).

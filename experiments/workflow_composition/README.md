# Workflow composition experiment

[![CI](https://github.com/gleam-dream/fabric/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/fabric/actions/workflows/ci.yml)
[![fabric on Hex](https://img.shields.io/hexpm/v/fabric?label=Hex%3A%20fabric)](https://hex.pm/packages/fabric)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A retained comparison of three alternatives with a scripted model and an
in-memory store: a Fabric controller with tasks, that controller with one Saga
per batch, and a Saga-orchestrated loop. It is no production dependency.

```sh
nix develop ../.. -c gleam test
```

The rationale for keeping it is in
[ADR 0002](../../docs/adr/0002-retain-agent-controller-and-managed-composition.md)
and [ADR 0008](../../docs/adr/0008-carry-unbuilt-capability-intent.md).

# Graph authoring experiment

[![CI](https://github.com/gleam-dream/fabric/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/fabric/actions/workflows/ci.yml)
[![fabric on Hex](https://img.shields.io/hexpm/v/fabric?label=Hex%3A%20fabric)](https://hex.pm/packages/fabric)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

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

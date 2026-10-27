# Usage examples

[![CI](https://github.com/gleam-dream/fabric/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/fabric/actions/workflows/ci.yml)
[![fabric on Hex](https://img.shields.io/hexpm/v/fabric?label=Hex%3A%20fabric)](https://hex.pm/packages/fabric)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

Small programs using only Fabric's public modules. Each covers one topic offline
against a scripted model. `test/fabric_usage_test.gleam` checks their behavior;
changed signatures fail the gate (`bash scripts/test.sh`).

| Topic                                          | Module                                                 |
| ---------------------------------------------- | ------------------------------------------------------ |
| The README summarizer, verbatim                | [`usage/summarize`](src/usage/summarize.gleam)         |
| Bounds, defaults and `InvalidLimit` reports    | [`usage/limits`](src/usage/limits.gleam)               |
| Failure classification                         | [`usage/failures`](src/usage/failures.gleam)           |
| Correlation of a run's requests and tool calls | [`usage/correlation`](src/usage/correlation.gleam)     |
| `await_with` and `cancel_when_down`            | [`usage/waiting`](src/usage/waiting.gleam)             |
| A family budget                                | [`usage/family_budget`](src/usage/family_budget.gleam) |
| Uncertain effects and `reconcile_stored`       | [`usage/reconcile`](src/usage/reconcile.gleam)         |
| A sweeper over a leased store                  | [`usage/recovery`](src/usage/recovery.gleam)           |

```sh
nix develop -c sh -c 'cd examples/usage && gleam test && gleam run'
```

The other usage topics live in the larger examples listed in the
[README](../../README.md#examples): the payment desk (typed tools, approval,
restart), the application consumer, the graph, decision, jobs and writing
consumers, and the Saga, Relay and Hellhound recipes.

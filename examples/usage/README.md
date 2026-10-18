# Usage examples

Small programs built from Fabric's public modules only. Each module shows one
topic, runs offline against a scripted model, and is asserted by
`test/fabric_usage_test.gleam`, so the usage stays true to the library: a
changed signature fails the gate (`scripts/check.py fast`).

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
consumers, and the Saga, Relay and Warden recipes.

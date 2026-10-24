# Usage lives as compiled examples, and the oracle and measurement references stay as linked docs

<a id="adr-0016"></a>

- On 17 October 2026 the owner decided against standing prose guides for usage, and for keeping the oracle ledger and the measurement record as documents. The package is unpublished, so no reader depends on the former paths. This revises the earlier decision of the same day, which had folded the oracle ledger into the design layer and dropped usage as a separate home.
- A usage guide written as prose drifts from the library; the 1,175-line `USAGE.md` repeated rules the design layer owns and pinned a copy of one example by hand. Code that compiles and runs fails the gate when an API moves. `docs/OPERATIONS.md`, `docs/VERIFICATION.md` and both `CHANGELOG.md` files stay removed: their rules live in the design layer and their chronology in ADRs.

## Homes

- **Usage** is compiled and run. The README keeps a short usage section and an examples table. [`examples/usage`](../../examples/usage/README.md) holds one module per topic with no larger example: bounds and `InvalidLimit` reports, failure classification, correlation, `await_with` and `cancel_when_down`, a family budget, uncertain effects with `reconcile_stored`, and a sweeper over a leased store. The payment desk (`test/fabric/readme_example.gleam`), the application, graph, decision, jobs and writing consumers, and the Saga, Relay and Hellhound recipes cover the rest. The PostgreSQL adapter's usage is its README and its compiled tests, listed in its README.
- **`docs/ORACLE.md`** is the oracle ledger: the BeamWeaver pin, the fixture rules, the comparison tables, the recapture procedure and the limits, plus the frozen version-2 reader and the classifier protocol fixture. It is restored from the revision cited by [ADR 0011](0011-limit-oracle-evidence-and-reject-upstream-hazards.md), with the local path removed.
- **`docs/BENCHMARKS.md`** retains the dated live-provider measurements with their method, the rerun commands and the limits. Fabric has no runtime benchmark harness, and the file says so. [ADR 0017](0017-retain-live-provider-evidence-as-dated-sanitized-captures.md) records why the captures are kept.
- `AGENTS.md` lists both references in a References section, the README links both, and each links the other. The design layer states the rules they check and links them; it does not repeat the tables or the method.
- ADRs hold rationale and chronology. The construction diary of the removed changelog is condensed in [ADR 0010](0010-preserve-format-and-lifecycle-history.md).

## Consequences

- The usage examples run in the fast gate profile and the full profile, so a changed public signature fails the edit loop.
- The module documentation describes each recipe in prose and names its compiled consumer module. No copy of the code exists in documentation to compare.
- The test that pinned the first guide block to the compiled payment example is removed, because the README no longer repeats that block.
- This decision supersedes the documentation-home paragraph of [ADR 0009](0009-native-layer-and-evidence-homes.md).

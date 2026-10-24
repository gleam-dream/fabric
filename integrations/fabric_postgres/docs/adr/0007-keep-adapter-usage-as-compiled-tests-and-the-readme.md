# Adapter usage lives in the README and in compiled tests, not in a usage guide

<a id="adr-0007"></a>

- On 17 October 2026 the owner decided to keep no standing usage guide and no changelog for this package, following the parent decision on usage as compiled examples. The package is unpublished, so no reader depends on the removed `USAGE.md` and `CHANGELOG.md`.
- The settings bounds, forward migration, metadata refresh, pruning, discovery and diagnostics contracts belong to this design layer. The README carries the accepted setting ranges, the refresh and diagnostics procedure and the location of the migration statements. Each topic has a compiled test that the README lists, and the disposable-cluster harness runs them, so a changed signature fails the full gate.
- The retained cigogne migrations and the runtime migration statements remain the executable schema definitions, and their equality test is unchanged.
- The Unreleased capability list of the removed changelog restated the design layer, and its unpublished API history is preserved by [ADR 0006](0006-consolidate-design-and-retain-executable-evidence.md).

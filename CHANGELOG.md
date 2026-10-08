# Changelog

## Unreleased

- Bounded agents retain typed tool inputs, results and final answers, explicit
  policy, authenticated approval, token observations and durable conversation.
- Conditional graphs retain typed state, committed routes, bounded cycles,
  signals, external jobs, managed children and isolated forks.
- Named stores provide supervised runners, compare-and-set records, recovery,
  leased ownership, shutdown draining and complete-family retention.
- Protocol-neutral invocation serves agents and graphs with scoped idempotency
  keys, finite waiting and caller-owned cancellation. Unconfirmed admission and
  unavailable admission readback retain `OutcomeUnknown` and the attempted run id.
- Generation and classification use caller-owned HTTP clients. Classification
  receipts retain a fixed protocol while live settings come from fresh context.
- Saga, Relay and Warden composition uses compiled public recipes. The
  PostgreSQL adapter remains a separate package with its own changelog.

Architecture and retained gaps live in the [native design](docs/design/design.typ).
The unreleased construction history and compatibility decisions are captured in
[ADRs](docs/adr/0009-native-layer-and-evidence-homes.md), including the
[format and lifecycle refinements](docs/adr/0010-preserve-format-and-lifecycle-history.md).

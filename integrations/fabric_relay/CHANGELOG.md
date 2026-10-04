# Changelog

All notable changes to `fabric_relay` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- The package, which replaces `fabric_mcp` (wave 5, FABRIC-R10).
- `fabric_relay.tool(definition, peer:)`: a Relay tool definition as a
  Fabric agent tool; `discover(connected, peer:)` and
  `discovered(declaration, peer:)` for listed tools; `operation(definition,
version:, peer:)` as a graph activity. `isError` is `tool.Explain`; a call
  that may have reached the server is `tool.Uncertain` unless the tool is
  read-only. Every call carries the run's correlation and an idempotency
  key named by the run and the action.
- `fabric_relay.serve(definition, service(runs, agent, start:))`: a Fabric
  agent as a Relay tool. A run takes the call's correlation; a call with an
  idempotency key names its run (`run_id`), so a retry reaches the same
  run. `with_wait` sets how long a call waits (25 s).
- `DiscoveryError` (`ListingFailed`, `UnsupportedName`,
  `UnsupportedSchema`) and `describe_discovery_error`.

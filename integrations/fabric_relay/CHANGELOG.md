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
- `fabric_relay.serve(service(definition, runs:, agent:, start:))`: a
  Fabric agent as a Relay tool. A run takes the call's correlation; a call
  with an idempotency key names its run (`run_id`), so a retry reaches the
  same run. `with_wait` sets how long a call waits (25 s). Every result's
  text block names the run in `_meta` (`io.github.gleam-dream/run-id`).
- `run_of(result)`: the run a served call's result names in its `_meta`,
  as a `RunId`, for a client that opens the run (`fabric.open`).

### Changed (round 6)

- **Breaking:** `with_wait` only stores the wait, which may come from
  configuration; `serve(service)` checks it and returns
  `Result(relay_tool.Tool(server_context), List(ConfigError))` instead of
  `with_wait` panicking. `ConfigError` is `InvalidLimit(limit: Wait,
value:, minimum:, maximum:)`, the shape of `agent.InvalidLimit`;
  `describe_config_error(s)`.

### Changed (slice F6, for code written against slice F4)

- **Breaking:** `service` takes the definition first, so `start`'s input
  type is inferred, and `serve(service)` takes no definition.
- **Breaking:** `start` returns a `Start`, not a `Result`; `refuse(error)`
  refuses a call. `start(context, prompt:)` runs for the `anonymous`
  principal; `with_principal(start, principal)` names one.
- A completed call's text block names its run in `_meta`, as an `isError`
  result's does.
- `serve` documents what bounds a keyed run whose client never retries.
- `DiscoveryError` (`ListingFailed`, `UnsupportedName`,
  `UnsupportedSchema`) and `describe_discovery_error`.

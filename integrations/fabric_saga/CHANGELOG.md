# Changelog

All notable changes to `fabric_saga` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- A README with the outcome mapping and the lifecycle.
- `fabric_saga.tool(definition, workflow, config, input:, explain:,
rollback_within:)`: a Saga workflow as one typed Fabric tool, settled
  late through `tool.bind_settling` when its task is stopped.

### Changed

- **Breaking:** `input: fn(context, tool.Call, input) -> workflow_input`
  builds the workflow's input from the run's context and the call, and
  `rollback_within` is a `Duration`. Each Saga run carries the Fabric run's
  correlation.
- **Breaking:** `tool` returns the tool instead of a `Result`: Saga checks
  the configuration when a call starts the workflow and fails that call
  definitely, naming every violation.
- An attempt that returned an error its step marks with `saga.unknown_when`
  is an uncertain effect, never a definite failure.
- Failures are Fabric's one `tool.Failure` (`Explain`, `Uncertain`).

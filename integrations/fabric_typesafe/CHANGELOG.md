# Changelog

All notable changes to `fabric_typesafe` are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
package uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Changed

- **Breaking:** `client.new(http, key:)` takes the caller's
  `http_gun.Client`. The request goes through that view: its timeout
  (`http_gun.with_timeout`; the client's default is 30 s), body and header
  limits, destination policy and telemetry are HTTP Gun's, and it carries
  the graph run's correlation. The Erlang transport and the `gun`
  dependency are gone (FABRIC-R12).

### Removed

- **Breaking:** `client.Bounds`, `client.bounds` and `client.with_bounds`
  (use HTTP Gun's settings), and `client.post`, `client.Error` and
  `client.Response` (the operation posts).

### Changed (earlier in wave 5)

- **Breaking:** the TypeSafe binding classifies its failures with
  `fabric/tool.Failure` (`Explain`, `Uncertain`), Fabric's one failure
  type for agent tools and graph operations; `operation.Failure` is gone.
- **Breaking:** `question.placeholder` is no longer public: the receipt
  codec reads the batch's placeholder through
  `fabric_typesafe/internal/batch`.

### Added

- Non-generative TypeSafe System One questions (`fabric_typesafe/question`):
  yes/no (`noul`), choices mapped to native values, rubric scores, and
  batches of independent questions.
- `fabric_typesafe.new` binds a batch to a policy-gated graph operation
  whose durable `Receipt` keeps the typed answer, usage and the original
  request and response JSON.
- A bounded HTTPS client (`fabric_typesafe/client`) that never follows
  redirects and admits plain HTTP only on loopback.

- **Breaking:** `client.Bounds.timeout` is a `Duration` (default 20 s).
- Builds on json_blueprint wave 2: classifier JSON is parsed with
  `value.parse` and written with `value.to_string`, which writes a decimal
  with an exponent from -7 to 20 in plain form (`12.5`, not `1.25e1`). A
  receipt compares parsed values, so `fabric.typesafe.receipt.v1` receipts
  written before still decode.

### Fixed

- `client.Config` keeps the API key as a closure, so `string.inspect` of a
  config, and crash reports or logs that contain one, no longer print the
  key.

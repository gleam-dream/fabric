# Changelog

All notable changes to `fabric_typesafe` are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
package uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Non-generative TypeSafe System One questions (`fabric_typesafe/question`):
  yes/no (`noul`), choices mapped to native values, rubric scores, and
  batches of independent questions.
- `fabric_typesafe.new` binds a batch to a policy-gated graph operation
  whose durable `Receipt` keeps the typed answer, usage and the original
  request and response JSON.
- A bounded HTTPS client (`fabric_typesafe/client`) that never follows
  redirects and admits plain HTTP only on loopback.

### Fixed

- `client.Config` keeps the API key as a closure, so `string.inspect` of a
  config, and crash reports or logs that contain one, no longer print the
  key.

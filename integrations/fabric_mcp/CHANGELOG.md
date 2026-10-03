# Changelog

All notable changes to `fabric_mcp` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- A bounded, application-owned MCP `2026-07-28` stdio client
  (`fabric_mcp/client`) with classified errors (`BeforeSend`, `AfterSend`,
  `InvalidResponse`, `RemoteError`) and no automatic retry.
- `fabric_mcp.discover` pins a tool's input and output contracts, and
  `tool_codec` saves the descriptor so a graph can be rebuilt while the
  server is unavailable.
- `fabric_mcp.bind` turns a discovered tool into a policy-gated graph
  operation whose `Receipt` keeps the native value and the original RPC
  response, and restores without another call.

### Changed

- **Breaking:** `client.Options.timeout` and
  `client.request_with_timeout`'s timeout are `Duration`s (default 10 s).
- The placeholder tool's empty contract comes from
  `contract.from_codec(codec.success(Nil))`, after json_blueprint made
  `codec.Schema` opaque.
- Builds on json_blueprint wave 2: tool contracts are `contract.Contract`
  values (was `runtime.RuntimeContract`), loaded with `contract.load`. The
  saved descriptor and receipt formats (`fabric.mcp.tool.v1`,
  `fabric.mcp.receipt.v1`) are unchanged.
- `client.Options.environment` is now `fn() -> List(#(String, String))`,
  called once when `start` opens the server process. Server environment
  variables often carry credentials; `string.inspect` of an `Options` or a
  `Client` now prints a function reference instead of their values.
  Callers that set `environment: [..]` write `environment: fn() { [..] }`.

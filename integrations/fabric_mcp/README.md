# fabric_mcp

An optional typed MCP integration for Fabric graphs, with an application-owned
stdio client for MCP `2026-07-28`. Fabric core has no dependency on this package.

Start the connection from an application process that will outlive its graph
tasks. Put the client in fresh graph context. `client.request` sends one request
with protocol metadata and returns a correlated result or a classified error.
`request_with_timeout` overrides the default deadline for a single request,
including queue time. Explicit stop or owner exit closes the port.

Before dispatch, invalid parameters, oversize requests, expired queued requests
and a known closed connection return `BeforeSend`. Loss after dispatch remains
`AfterSend`; a malformed response is `InvalidResponse`. `RemoteError` retains the
JSON-RPC code, message and optional data. Neither a remote error nor a cancellation
notification proves that the external operation had no effect. There are no
automatic retries or reconnects.

Use `fabric_mcp.discover` to pin a tool's input and optional output contracts.
Save that descriptor with `tool_codec` in application configuration so a restart
can rebuild the graph even while the server is unavailable. `fabric_mcp.bind`
accepts a separately versioned operation identity, native input/output codecs,
a connection lookup from fresh context and a pure result conversion. Its output
is a `Receipt(output)` containing the native value and original RPC response.

The graph's ordinary policy gate runs before the effect. Each invocation checks
the configured server identity, rediscovers the tool and refuses changed or
unsupported schemas before calling it. The input codec must match the tool's
schema. Supported schema forms are Blueprint's closed Draft 2020-12 subset;
open objects, other dialects and remote references fail explicitly. Content and
structured content are available to the converter. Saved receipts restore
without discovery or another tool call; invalid results and unresolved effects
release no successor and never trigger an automatic retry.

The raw `client` API only validates JSON and RPC envelopes. Applications using
it directly must enforce method-specific contracts and discover the server
before invoking a tool. HTTP, legacy initialization, subscriptions and
multi-round-trip interactions are outside this first scope.
Port closure closes stdin; an uncooperative server may continue an external
effect. Applications remain responsible for their server process supervision.

The [counter example](examples/counter_server.py) is a separate Python process
with a persistent SQLite counter. Reopening the same database reads earlier
effects. Fault scenarios add malformed frames, delayed replies and process loss
at the byte-stream boundary; they do not replace the counter with a mock.

From the repository root:

```sh
nix develop -c sh -c 'cd integrations/fabric_mcp && gleam build --warnings-as-errors && gleam test && python3 -B -m unittest discover -s test/support -p "test_*.py"'
```

See the [adapter contract](../../docs/implementation/graph-flow/mcp-adapter.md)
for selection evidence, boundaries and acceptance. The package gate includes
12 client scenarios, 11 graph/descriptor scenarios and four independent service
tests. [The graph consumer tests](test/binding_test.gleam) show native counter
operations, policy approval, cancellation and recovery with the server closed.

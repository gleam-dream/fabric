# fabric_mcp

An optional MCP integration for Fabric. The first checkpoint provides an
application-owned stdio client for MCP `2026-07-28`; the typed graph binding is
the next slice. Fabric core has no dependency on this package.

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

This low-level client checks JSON and RPC envelopes. It does not yet validate
method-specific schemas, negotiate older protocol revisions or interpret tool
results. Call `server/discover` before invoking tools. The forthcoming binding
will enforce discovery and pin the tool contracts. HTTP, legacy initialization,
subscriptions and multi-round-trip interactions are outside this first scope.
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
for selection evidence, boundaries and remaining graph acceptance.

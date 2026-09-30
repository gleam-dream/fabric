# MCP graph adapter

This optional package implements the MCP boundary selected by
[GRAPH-FLOW](../../GRAPH-FLOW.md#mcp-stays-an-adapter-boundary) and G10. Fabric
core acquires no MCP, Saga or Grind dependency. The complete stage-5 acceptance
still requires a typed graph binding and a real local-server exercise.

## Client selection

The published [`mcp_client` 0.1.0](https://hex.pm/packages/mcp_client) archive was
inspected on 2026-09-30 (Hex internal checksum
`23F98BFF4B2022C4210F2F40EB235FEA08738311B8071F1682659C7B30AB3374`). Its manager
supports only `2024-11-05`, discards input/output schemas from discovered tools,
and flattens JSON-RPC errors to strings. Its transport accepts the first line
containing the text `"id"`, without matching a response ID, and assembles long
lines without a total byte bound. These are gaps at this adapter's required
boundary; this package is not adopted or forked.

`fabric_mcp` uses a small native stdio connection with the existing Gleam,
Erlang and Blueprint dependencies. The selected protocol revision is
[`2026-07-28`](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning).
It carries version/capability metadata on each request and uses
[`server/discover`](https://modelcontextprotocol.io/specification/2026-07-28/server/discover),
not an initialization session. The first adapter supports tool discovery and
complete tool results. It advertises no client capabilities or extensions;
it does not claim legacy-version, HTTP, sampling, elicitation or subscription
support. Unsupported versions and result forms must fail explicitly.

## Application-owned stdio connection

The application starts a connection and puts its handle in fresh graph context.
It outlives individual graph operations, as required by the protocol's
statelessness model. Its owning process or an explicit stop closes the server
port. A server process is never a durable workflow receipt.

The connection serializes requests and assigns increasing JSON-RPC IDs. Queue
time counts against the caller's absolute request deadline. Before sending, it
checks the caller is alive, the deadline remains, and the encoded request fits
the byte bound. No reconnect or retry is implicit. A reply must match the
outstanding ID; stale replies from previously canceled requests cannot satisfy
a later request. JSON syntax, duplicate keys and message envelopes are checked.
Line size, ignored notifications and request duration are bounded.

Failure before dispatch is distinct from failure after dispatch. A matching
remote JSON-RPC error retains its code, message and data. A tool's error result
does not prove that no effect occurred. Classification at the graph binding
must preserve this uncertainty rather than infer idempotency from annotations.

When a request's caller dies or its deadline expires, the connection sends
[`notifications/cancelled`](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)
for that ID. This is a request to stop, not evidence of rollback or successful
cancellation. The connection remains available; late messages for the retired
ID are discarded. A broken frame or invalid correlation closes the connection.
The first transport gate must prove real process ownership, dispatch evidence,
cancellation, timeout and response isolation, not merely string construction.

The connection's low-level request API admits JSON and JSON-RPC envelopes.
Method-specific discovery, tool contracts and result conversion belong to the
following typed binding. The raw API therefore requires its caller to discover
the server before a tool call. Port closure closes stdin; it does not prove that
an uncooperative server or an already dispatched external effect has stopped.

### Transport evidence

Eleven public client scenarios run against a separate Python process backed by
SQLite. They prove a retained counter effect across connection restart; required
per-request metadata; error code/data retention; rejection of nested duplicate
outbound keys; stream closure for malformed JSON, invalid versions and wrong IDs;
byte and notification bounds; deadline cancellation; caller loss with connection
reuse; stale response isolation; a committed effect after server exit; expired
queued work that never dispatches; application owner loss; and invalid settings
and oversized request refusal. Four independent service tests prove its real
stdio/discovery contract, durable effect, bad-input refusal and EOF shutdown.

The first gate exposed two production defects: nested duplicate keys could
reach the service, and malformed responses did not close the connection. Strict
outbound admission and synchronous response admission in the port owner correct
both before another request can run. Response parsing counts against the request
deadline. Process aliases discard late request acknowledgments after a caller
stops waiting. No backend or graph record format changes in this checkpoint.

This accepts the connection boundary only. It does not accept the typed MCP
graph adapter or stage 5.

## Typed binding to follow the connection gate

The binding retains separate application operation identity, server identity
and remote tool name. Discovery retains its input contract and optional output
contract. Before invocation, revalidate those contracts and validate the native
input with Blueprint. Reject changed or unsupported schemas before `tools/call`.
Do not convert arbitrary MCP names into graph node IDs.

Tool results retain the original protocol content and structured content.
A pure application conversion produces the native graph result; invalid results
release no successor. A saved receipt must restore without resubmitting the
tool. Cancellation and restart use the ordinary graph activity fence and
reconciliation contract. Tests must cover typed success, optional output schema,
schema drift, scoped names, tool/protocol errors, canceled or lost replies and
restart with a retained receipt against an independently running local server.

## Gate

Build this package with warnings as errors, run its public client/binding
scenarios and the independent Python service tests, then run relevant graph
consumer/root regressions and repository formatting. The local server must
perform a real operation with independently retained state so loss of a reply
can be distinguished from absence of the effect. No live LLM/classifier
credential is needed for this work.

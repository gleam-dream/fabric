# MCP graph adapter

This optional package implements the MCP boundary selected by
[GRAPH-FLOW](../../GRAPH-FLOW.md#mcp-stays-an-adapter-boundary) and G10. Fabric
core acquires no MCP, Saga or Grind dependency. The selected stdio binding is
implemented and exercised against a real local service. Stage 5 remains open
for classifier implementation and live LLM acceptance.

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

These scenarios accept the connection boundary. The graph binding has the
additional acceptance evidence below; stage 5 remains open.

## Typed graph binding

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

The first typed surface discovers one tool and binds its retained descriptor
to a separately versioned application operation. Discovery probes protocol and
tool capability, follows at most 16 catalog pages, rejects duplicate names and
uses Blueprint's closed Draft 2020-12 subset. Omitted schema dialect defaults to
2020-12; an unsupported dialect or schema is a refusal, not a relaxed validator.
The native input codec must describe the same validation shape as the tool.
Descriptions may change without changing that shape. The application supplies
a pure conversion from retained content/structured content to its native output;
that output needs a persistence codec, not necessarily a provider schema.

Each admitted invocation obtains the connection from fresh context, checks its
configured server identity, rediscovers the tool and compares the complete
input/optional output validation contracts before `tools/call`. Pre-call
refusals are definite tool failures; interrupted or invalid post-call results,
remote errors and `isError` results remain uncertain. They are not converted to
successful native values. The first binding accepts only complete responses;
absent `resultType` means complete as specified by MCP. Other result forms fail
explicitly. Tool descriptions and annotations never authorize effects.

The `fabric.mcp.receipt.v1` envelope retains the configured server, remote tool,
input and optional output schemas, and original RPC response. Restoration
checks those contracts against the deployed binding, validates the original
result and redoes only the pure conversion. Encoding a receipt checks that its
native value agrees with that conversion. No live client is captured by the
receipt codec or contacted during restoration.

Applications can persist a discovered descriptor with `tool_codec`'s
`fabric.mcp.tool.v1` format and restore it without a live server. This keeps
definition reconstruction independent of remote availability after a complete
application restart. Descriptors, prompt/conversion meaning and server routing
belong to the application's deployment configuration; changes to operation
meaning require a new application operation version. Revalidation detects
observed schema drift; it cannot lock a remote deployment between discovery
and invocation. Invalid post-call results still remain uncertain.

## Graph binding evidence

Eleven public graph/descriptor scenarios prove native results and matching
receipt roundtrips, policy approval before the counter effect, schema/server
refusal before invocation, optional output contracts, description changes,
paged catalogs, text-only conversion, the absent complete discriminator,
post-effect failures without routing or retry, cancellation with a retained
uncertain effect, pure conversion failure, content preservation, invalid
receipts and invalid descriptor formats/identities/dialects. The restart
scenario kills the store's owner and closes the MCP connection, restores the
pinned descriptor from JSON, then recovers the saved graph outcome. A fresh
server process reads the original counter effect exactly once.

The first graph scenario failed at unimplemented discovery. The current gate
passes 22 Gleam tests (11 connection, 11 graph/descriptor) and four independent
Python service tests, with warnings as errors. No graph/backend record format
changes were needed. This accepts the selected optional stdio adapter under
G6/G10, not every MCP transport, extension or JSON Schema form.

## Gate

Build this package with warnings as errors, run its public client/binding
scenarios and the independent Python service tests, then run relevant graph
consumer/root regressions and repository formatting. The local server must
perform a real operation with independently retained state so loss of a reply
can be distinguished from absence of the effect. No live LLM/classifier
credential is needed for this work.

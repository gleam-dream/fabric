# Decision adapters

Stage 5 implements [G10](wave-tracker.md#governing-contracts-and-coverage) and
[decisions independent of chat](../../GRAPH-FLOW.md#decisions-are-independent-of-chat).
It leaves graph routing, policy, ownership and persistence unchanged. This
document records the adapter contracts as their vertical slices are built;
it does not accept stage 5 before real boundaries have been exercised.

## Structured LLM slice

`fabric/graph/llm` binds one llm_wire structured request to an ordinary graph
activity. Its native input codec persists the application request. Its output
codec asks llm_wire to validate the provider answer and restores the same native
type from a saved receipt. The binding's identity/version owns the provider,
prompt, output meaning and request options. Changing those semantics requires
a new identity/version under the existing graph compatibility contract.

The application supplies its started HTTP Gun client, configuration and a
request from fresh context plus the retained input. Credentials and live
transports stay in context; Fabric neither starts nor stops the client. The
callback must describe the request without additional effects. Policy admits
the graph operation before the request is built or sent. llm_wire owns HTTP,
SSE, provider schema projection, cancellation and transport bounds; Fabric
owns the committed start and the durable result.

The first binding is a single decision request with no tool catalog. Supplying
tools fails before network I/O. A caller needing tool rounds composes a managed
agent node. An unexpected provider tool response is retained as failure
evidence and never executed by this adapter.

A successful receipt retains the requested model, validated native answer,
original output JSON and optional reported usage (including the provider's
total). A refusal or output limit is a distinct typed outcome retaining its
reason or partial text and usage; neither masquerades as an answer. The
application explicitly accepts or rejects those outcomes in its pure routing
function. Missing usage remains absent. The requested model is not a claim
about a provider's resolved model revision.

Receipt encoding checks that the native answer and raw JSON agree. Decoding
checks the receipt format, outcome tag, model and usage, then validates the
answer with the deployed output codec. A saved result is reused after restart;
restoration does not make another provider request. A graph definition must
be versioned when its answer codec's meaning changes.

Preparation failures and `NoRequestSent` failures are definite. A request that
may have reached the provider or whose effect is unknown requires
reconciliation. Invalid structured output follows llm_wire's failure evidence
and releases no successor. Diagnostics retain error kind and retry evidence;
HTTP diagnostics retain status and retry hint without copying response bodies.
This adapter makes one request and does not retry automatically. A transient
error or retry hint alone is not authorization to repeat an uncertain request.
The ordinary activity replay override remains an explicit application promise.

### Acceptance scenarios and gate

The public graph scenarios must prove a typed decision and receipt; no I/O
before policy approval; no tool catalog sent; refusal/limit distinction;
invalid output and interrupted transport block without routing or retry;
receipt corruption is rejected; and recovery reuses the saved decision across
store-process loss. Protocol fixtures test provider schema projection and
error cases. A separate opt-in consumer must exercise the actual provider
with existing credentials, a small token bound and no hidden live fallback.

Run the adapter scenarios, then the root warnings-as-errors build and tests,
graph/app/job consumers, and repository formatting gate. No storage format or
backend contract changes are planned in this slice. Record real-provider
acceptance separately from scripted protocol evidence. Classifier, MCP and
agent-recipe evidence have their own linked contracts.

### Initial evidence, 2026-09-30

Nine public scenarios cover the contract above, including OpenAI Responses SSE
and its projected structured schema. The separately built
[decision consumer](../../../consumers/decision/README.md) selects actual graph
routes using a native enum and the same producer binding. Its offline test
covers both choices; these are protocol fixtures, not live model judgments.

An initial nested codec implementation copied 5,072,863 words for the receipt
envelope and caused public graph scenarios to exceed their five-second waits.
Loading modules earlier did not resolve it. Constructing the envelope fields
inside each codec callback keeps only the application output codec in the
transported closure: the same receipt measured 1,884 copied words. All nine
scenarios then passed in 0.16 seconds with their original waits. This is a
measured boundary cost, not a provider-speed claim or a fixed performance SLO.
The package's general combinator capture behavior is not changed by this slice.

The opt-in live command was attempted after the consumer's offline gate passed.
It stopped before I/O because `OPENAI_API_KEY` was absent or empty. The current
session also has no non-empty `ANTHROPIC_API_KEY` or `TYPESAFE_API_KEY`.
No provider request was sent and no real-provider acceptance is claimed. The
user has been asked to identify an existing provider setup; independent MCP
and classifier adapter work can continue while that information is pending.

## Classifier and MCP reconnaissance

The [TypeSafe SDK catalog](https://docs.typesafe.ai/sdk) lists Python and
JavaScript/TypeScript clients and documents direct HTTP access. Its default SDK
retry policy must not become an implicit Fabric retry policy. The
[Choice contract](https://docs.typesafe.ai/primitives/choice) returns a selected
label, full probability distribution and concentration-based confidence.
Keep that evidence separate from application routing and effect admission.

The [official MCP SDK catalog](https://modelcontextprotocol.io/docs/2026-07-28/sdk)
does not list Gleam. The [2026-07-28 tool contract](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)
must be checked alongside a chosen client's actual supported version before
selecting a transport subset. No classifier/MCP library has been selected and
no live classifier/MCP acceptance is claimed by this initial reconnaissance.

## Current adapter evidence

The optional [Relay recipe](../../../README.md#composing-with-relay)
replaces the earlier `fabric_mcp` package (wave 5): MCP tools reach agents and
graph activities through Relay's client. The earlier package's evidence is
recorded in [the MCP contract](mcp-adapter.md).
The [classification family](https://github.com/gleam-dream/llm_wire)
provides typed heterogeneous classifier batches and native HTTP. Its
[contract and evidence](classifier-adapter.md) retain protocol-fixture checks
separately from actual Jev inference. Both decision producers use the same
application routing definition in the decision consumer. The
[2026-09-30 live validation](completion-audit.md) now proves actual OpenAI and
TypeSafe answers reaching the same business route, with validated receipts and
reported usage. Stage-5 acceptance is complete.

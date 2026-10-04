# TypeSafe classifier adapter

This slice implements G10 and [decisions independent of chat](../../GRAPH-FLOW.md#decisions-are-independent-of-chat).
The optional `fabric_typesafe` package asks typed questions through TypeSafe's
System One HTTP API. Fabric core gains no classifier dependency or chat-model
variant. An application composes the resulting native values with existing
routing, policy and recovery.

## Retained provider contract

The [HTTP API](https://docs.typesafe.ai/api),
[Noul](https://docs.typesafe.ai/primitives/noul),
[Choice](https://docs.typesafe.ai/primitives/choice),
[Score](https://docs.typesafe.ai/primitives/score), and
[confidence](https://docs.typesafe.ai/confidence) documentation were inspected
on 2026-09-30. The endpoint is `POST https://api.typesafe.ai/v1/systemone` with
Bearer authentication and a model, state and question map. State and question
instructions may be text, objects or arrays. The public SDK catalog has Python
and JavaScript clients; the native Gleam integration uses the same HTTP
contract over the caller's `http_gun.Client` (wave 5; it opened Gun directly
before), whose timeouts, limits and destination policy apply. SDK retry defaults are
not adopted.

A Noul preserves the yes probability. A Choice preserves its native selected
label, the complete labeled distribution and the provider confidence. A Score
preserves the fractional position, distribution, confidence and ordered rubric;
it is not normalized to zero through one. Confidence is retained as provider
concentration evidence, not recast as a probability of correctness.

Questions have checked nonempty identities, unique choice labels and bounded
criteria. A choice supports 2–255 options and a score 2–10 ordered levels.
A batch combines different native answer types for the same input; duplicate
question IDs are rejected. All questions in one request are independent.
A later question that needs an earlier answer belongs in another graph step.

## Protocol and native-value admission

The exact sent question definitions own each answer's meaning. Incoming answers
must have exactly the requested IDs, match their question kinds, and contain
all expected probability labels or level indices. Numbers are range-checked as
JSON numbers before projection to native floating point. Distributions must sum
to one within `0.00001`; a selected label must have maximal probability within
that tolerance. A score must fit its actual rubric and agree with its weighted
position within `0.00001 * number_of_levels`. These tolerances accommodate
numeric wire rounding, not incomplete distributions or unknown categories.
The response's rubric must agree with the sent levels. Confidence is checked
in [0,1], without recomputing a vendor-specific formula. Unknown, malformed,
non-finite, duplicate-key and incompatible results release no successor.

The binding retains requested and resolved model identities, full request and
response JSON, token usage and the native answer. Its versioned receipt codec
reconstructs only the pure checked answer and compares it with the native value
when encoding. Restoring compares the saved questions with the deployed batch;
changed meanings require a new application operation version. Credentials and
live connections are not persisted, and restoration performs no request.

## HTTP ownership and failure

Configuration is fresh context. Request construction is pure and happens only
after the ordinary graph policy admits the operation and commits its start.
The request goes through the caller's HTTP Gun client view: its verified TLS,
request/response body and header limits, request timeout and destination
policy apply, it carries the graph run's correlation, and HTTP Gun follows no
redirect and retries nothing. Explicit loopback HTTP
supports protocol tests; remote endpoints require HTTPS. The request owner
owns the connection, so graph cancellation closes local work without claiming
that remote inference stopped or was never billed.

Local preparation or proven pre-dispatch connection failure is definite.
After dispatch, transport loss, malformed output and unknown status remain
uncertain. HTTP errors retain status and retry hints without copying the body
or credentials to diagnostics. A retry hint does not authorize resubmission.
The caller may opt into ordinary activity replay only with its own explicit
interrupted-effect guarantee.

## Evidence required

Public tests must prove all three typed question kinds and heterogeneous
batching; invalid local definitions and incoming evidence; approval before I/O;
HTTP dispatch classification, cancellation, deadline and bounds; native routing
that can be shared with scripted and LLM producers; and offline receipt reuse
across store-process loss. A loopback protocol service may exercise transport
failure but is not a real Jev inference. A separate opt-in entry point must
exercise the actual provider with an existing credential and synthetic input;
missing credentials cannot be called acceptance or silently replaced by a stub.

Run the package warnings-as-errors build, public tests and independent HTTP
fixture checks, then relevant consumer and formatting gates. Record the live
provider result separately. Stages 5–6 remain open until their complete evidence
exists; this contract and offline protocol tests alone do not finish the goal.

## Checkpoint evidence, 2026-09-30

The package warnings-as-errors build and all 18 public scenarios pass. Three
independent HTTP-fixture tests and both decision consumer tests pass. The
consumer shares one typed routing definition between LLM and classifier
production; both enum choices reach their expected business routes. Tests
retain raw protocol evidence and reuse completed receipts after store loss
with the server stopped. Cancellation/deadline checks observe the closed TCP
connection and preserve uncertainty rather than claiming remote cancellation.

The opt-in live classifier command stopped before I/O because
`TYPESAFE_API_KEY` was missing or empty. No actual Jev answer was observed.
The package's numeric tolerances and structured rubric support are backed by
primary documentation and fixtures, not a live compatibility claim.

Logs: `/tmp/fabric-classifier-final.log`,
`/tmp/fabric-classifier-consumer-gate.log`,
`/tmp/fabric-classifier-live.log`. The last log is the expected missing-key
failure; it is not a passing live gate. `nix fmt`, `nix flake check` and
`git diff --check` pass on this host. Core/backend source and durable formats
are unchanged.

## Actual provider acceptance, 2026-09-30

The user subsequently supplied `.env.local` settings. The existing live consumer
completed without a production change or retry: `jev-latest` resolved to
`jev-1.13.0`, with yes probability 0.99, Choice `Approve`, Score 2.0 on the three
requested levels, and usage of 384 input / 62 output tokens. The graph reached
`publish` and decoded its retained receipt. The [completion audit](completion-audit.md)
retains the exact observed distributions and sanitized command output alongside
the independent offline recovery/error evidence. This closes the prior live
blocker without treating fixture output as inference.

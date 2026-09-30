# Typed graph authoring proof

## Question and result

Can Fabric express a bounded generation/review loop with heterogeneous native
operation types, serializable receipts and ordinary typed routing, without
depending on Saga or making application state a JSON dictionary?

**Yes, for the tested sequential authoring contract.** The separate consumer
uses `Int → Draft` for generation and `Draft → Review` for evaluation. Both
bind into one `Graph(Context, State, Draft)` where the application owns the
`Drafting | Reviewing` state type. The resulting loop revises twice and
finishes with the third draft. A limit of five activations stops before the
third review; six permits completion.

This is step 1 of the [implementation program](../../docs/implementation/graph-flow/wave-tracker.md).
The prototype is retained as evidence; it is not the production graph runner.

## Reproduce

From the Fabric root:

```sh
nix develop -c python3 experiments/graph_authoring/check.py
```

The command builds the library and an external consumer with warnings treated
as errors, runs both test suites, runs the example, and builds a fresh external
package with one valid and two deliberately ill-typed consumers. Python 3 and
the Gleam/OTP/compiler dependencies come from Fabric's Nix shell.

The separate example can also run directly:

```sh
nix develop -c sh -c 'cd experiments/graph_authoring/consumer && gleam run'
```

Its observed output is:

```text
Accepted: draft 3
1: draft.generate => [1,"draft 1"]
2: draft.review => "revise"
3: draft.generate => [2,"draft 2"]
4: draft.review => "revise"
5: draft.generate => [3,"draft 3"]
6: draft.review => "accept"
```

## Evidence

The initial compiled consumer had two failing tests against a driver that
returned an explicit not-implemented result. Implementing the local driver
made both behaviors pass. Additional public-contract checks cover the
following:

| Program rule                | Evidence                                                                                                                                    | Result                                                              |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| G1, native types            | External consumer combines generation and evaluation with different inputs/results.                                                         | Compiles without casts or internal imports.                         |
| G1, type mismatch refusal   | Fresh package first builds a valid node, then tries a String input for an Int operation and an Int acceptance callback for a String result. | Both rejected with compiler type mismatches.                        |
| G1, schema independence     | Custom Blueprint codec deliberately has no JSON Schema.                                                                                     | Graph builds/runs and all receipt values decode.                    |
| G1, decision substitution   | Boolean, checked 0–4 integer score and native enum drive the same decision graph.                                                           | Same selected route and typed completion.                           |
| G2, definition validation   | Invalid identities/bounds, duplicate nodes, missing entry and missing destination.                                                          | Rejected before execution.                                          |
| G2, dynamic routing         | A node returns a destination outside its own declared set.                                                                                  | Refused without applying its state update or releasing a successor. |
| G3, cyclic control          | Six visits revisit the same two definitions; pure self-cycle has no model call.                                                             | Fresh ordinal per visit and explicit activation-limit stop.         |
| G4, failure boundaries      | Selection, input/output encoding and decoding, transition, state and answer encoding.                                                       | Distinct outcomes and no successor.                                 |
| G4, typed handler errors    | Application error distinguishes rejection from a timeout after sending.                                                                     | Explicit definite/uncertain classification is retained.             |
| G1–G4, state representation | Native phase variants encode at every accepted transition.                                                                                  | All six stored state receipts decode to the expected phase.         |

At first successful full proof run: **12 library tests and 6 external consumer
tests passed**, plus both negative compiler checks. No source module imports
Saga, Grind or an unchecked Dynamic conversion. The manifests contain only
the existing standard library/Blueprint dependencies and the test runner.

## Interface findings

1. **Binding hides type parameters at the correct boundary.** `node` accepts a
   typed operation, input selector and result acceptance function, then retains
   three closures over those types. Only the resulting receipt is serialized.
   There is no universal application event or result type.
2. **State variants are practical.** `Drafting(Int)` and `Reviewing(Draft)` avoid
   a record of optional fields. A selector still needs to reject an invalid
   phase; common-state typing does not prove reachability.
3. **Routes are runtime-checked capabilities.** Node IDs are opaque but are not
   indexed by a particular graph. Construction validates references, while
   acceptance checks the source's declared destination set. Do not advertise
   compile-time proof of all routing.
4. **Graph identity is independent of tool naming.** The example deliberately
   uses dotted node IDs (`draft.generate`). A model tool's naming restrictions
   belong to its export adapter.
5. **Serializing a receipt must preserve failure stages.** Encoding may fail
   even for a native typed value when a codec imposes bounds. A score of five
   against a 0–4 rubric must never be routed as a successful judgment.
6. **Commands combine state and control.** This prevents a separate result and
   route API from becoming two independently accepted updates. The production
   implementation still has to make that one durable commit.

## What this proof does not establish

- The driver runs callbacks synchronously and has no policy admission, start
  fence, process isolation, deadline enforcement or cancellation. Only scripted
  operations were exercised; do not use it to execute external effects.
- Reports are local data, not durable ownership. The trace is not a restart
  journal and the ordinal is unique only inside one run.
- An encoded state is not proof of version compatibility or restart safety.
  The production runtime must validate/rebind deployed definitions and codecs.
- No retries occur. Uncertain failures stop immediately. Callback panics are
  not contained by this driver.
- Failed-step output retention, atomic writes, lost acknowledgements, stale
  owners and replay are not implemented. The production record must retain
  the evidence needed for post-effect codec/transition failure.
- No parallel fork, signal, child agent, external job or real provider runs in
  this experiment. Those remain required in steps 2–6.

## Consequences for the next wave

Keep the typed operation/node binding pattern, typed state variants, explicit
failure stages and checked destination lists. Do not promote the synchronous
driver into the runtime. Build a pure serial graph controller around encoded
activation records and one atomic state/control transition, then connect it
to Fabric's existing ownership and fenced-execution mechanisms.

The source review for that extraction found two small concrete seams:

- `store.Live` currently hardcodes the agent runner mailbox, which agent
  callers retrieve to deliver commands. The store itself only carries that
  endpoint as registration data; runners detect store loss through a process
  monitor. Decouple shared registration from each runtime's typed control
  endpoint while preserving command routing and incarnation checks. Verify
  every caller before selecting the exact refactor.
- The executor already carries bound body functions and fences them. Its
  message types currently fix `ActionId` and tool `Outcome`; parameterizing
  identity/result while keeping crash/fence semantics is a candidate shared
  mechanism. Preserve the current agent suite during that extraction.

Neither seam has been changed by this experiment. The next wave must prove
them against the existing runtime and then exercise real durable graph work.

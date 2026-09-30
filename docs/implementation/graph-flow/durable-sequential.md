# Durable sequential graph contract

This records the concrete G3–G6 contract for wave 2 of the authorized graph
program. The typed authoring proof remains in `experiments/graph_authoring`.
This contract governs production implementation, not that synchronous driver.

## Native authoring and compatibility

`fabric/graph/operation` binds native input and output codecs to a body and an
application-specific error classifier. The body receives context plus an
invocation containing the run id, activation ordinal and attempt. Run id and
activation form the stable logical identity; an external idempotency key must
not become a new logical request merely because the attempt changed. Replay
requires the application's explicit `with_replay` contract.

`fabric/graph/definition` binds each operation into a typed state graph with
pure input selection and acceptance callbacks. Different nodes retain different
native input/output types. A command either continues with new state and one
declared destination, or finishes with new state and a typed answer. No provider
JSON Schema is required for internal values. The initial state, selected input,
next state and final answer must be decodable after encoding.

The definition retains a canonical structural manifest of entry, nodes,
operation identities/versions, execution modes, destinations and recovery contracts. Ordering
the supplied node list differently does not change it. A record must match the
graph identity/version, manifest and activation bound. Every saved input,
output, state and answer is checked with the deployed native codecs; saved
routes must still be allowed. These checks never rerun selection, operation or
acceptance callbacks. The manifest does not identify callback implementations:
applications must bump versions for changes to code or codec meaning.

The graph record uses format `fabric.graph`, currently version 4. Wave 3's
signal support added an explicit execution mode and waiting phase; managed
subgraphs add initial input, reciprocal parent links and child lifecycle phases,
including a stored wait that releases the parent runner and lease.
Earlier unreleased versions are refused rather than guessed or migrated. It is independent of
the existing chat record writer window. Both encoding and decoding check
control invariants: counters, contiguous receipts, route linkage, pending
activation identity, approval correlation and terminal dispositions. Accepted
payloads are JSON. Unusable output retained as reconciliation evidence may be
arbitrary text; an unencodable native result retains diagnostic text, not a
claim that its value can be restored.

Signal waits and their retained consumption use the separate
[managed composition contract](managed-composition.md).

## State and ownership

The graph controller is pure. Its record contains graph identity/version and
definition signature, run id, owner incarnation, activation reservation count,
approval sequence, encoded application state, completed receipts and one phase.
The backend's compare-and-set revision serializes accepted transitions. Each
encoding carries a fresh write token; ambiguous acknowledgements are handled
by the existing store's exact-byte/revision confirmation.

A prepared node retains its node identity, operation identity/version, encoded
input and interrupted-execution contract. Activations reserve a run-local
ordinal before admission. A retry preserves that ordinal and increments its
attempt. Live reports also carry the owner incarnation; a previous owner's
report cannot satisfy current work.

| Phase            | Meaning                                                          | Recovery                                                               |
| ---------------- | ---------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Ready            | Prepared input awaits policy inspection.                         | Inspect with current context.                                          |
| Queued           | Policy admitted the body; start is not committed.                | Return to Ready; old context grants no authority.                      |
| Running          | Body start is committed; a task may have acted.                  | Block as uncertain, or create a bounded replay attempt if declared.    |
| AwaitingApproval | A particular requirement/revision needs an answer.               | Keep the question; answering must recheck policy with current context. |
| Blocked          | Effect is uncertain or a returned result/transition is unusable. | Keep evidence; never dispatch a successor automatically.               |
| Stopping         | Cancellation accepted while the body may still act.              | Retain cancellation and the unresolved effect.                         |
| Ended            | Completion, definite failure, budget exhaustion or cancellation. | No new work; uncertain cancellation remains visible.                   |

The task executor is shared with the agent runtime. It is parameterized by
identity and returned value. `Crashed` and `Lost` are separate reports, not
fabricated application values. The agent runner maps a crash back to its
existing uncertain-tool outcome; the graph runner uses its activation contract.

## Transitions

- Starting reserves activation 1 and emits inspection only after the run is
  committed. Graph names/versions, signatures and limits must be valid.
- Allowing policy queues the activation. Denial or policy failure stops the
  graph without starting its body. A requirement with an invalid identity or
  version is a policy failure.
- The executor's fence requests `Queued → Running`; the runner replies yes
  only after that transition is committed. An old incarnation/attempt is refused.
- A successful result supplies a validated pure control decision. The next
  application state, output receipt, route and next prepared activation are
  accepted together. A next activation beyond the bound is retained as
  unstarted work in the exhaustion outcome, never dispatched.
- A completed activation has exactly one recorded receipt. Duplicate, reordered
  or stale completion cannot allocate another successor.
- An operation's declared definite failure stops the graph. An uncertain
  failure blocks. A malformed result or failed transition retains the raw
  returned result and reason for reconciliation; no successor is released.
- `RequireReconciliation` never replays an interrupted body. A declared
  `ReplayInterrupted(max_attempts)` permits re-execution only up to that bound.
  This declaration is an application effect contract, not an inference from a
  timeout or a provider's label. A saved successful decision is never replayed.
- An approval answer names the activation, attempt, requirement and approval
  revision. Approval uses a fresh policy decision; a changed requirement creates
  a new question. Old or duplicate references are rejected.
- Cancellation before the start fence ends without an uncertain effect.
  Cancellation after the fence first records Stopping and requests task stop;
  a result already in flight is retained, and no successor is dispatched.
  Stopping without a definite result ends with explicit uncertainty.
- Reconciliation must validate the result against the original node contract
  and match the blocked activation. It then uses the same atomic completion
  transition. Reconciliation after cancellation records the result while keeping
  cancellation terminal.

Native callbacks, policy and codecs are not serialized. The authoring adapter
validates input/result/state codecs and allowed destinations before providing
a transition to the controller. The runner bounds callback execution and
classifies crashes; codec/transition errors after an effect never authorize an
automatic retry. Restoring rejects incompatible definitions and malformed
control records before inspection or dispatch.

## Required evidence

The pure tests establish legal transitions and refusals. Codec tests establish
that data and recovery state survive encoding without closures. Neither alone
establishes durability. Wave 2 also requires the public graph runner on a real
persistent backend: restart around a decision and the start fence, lost commit
acknowledgment, fresh approval context, cancellation/drain, stale ownership and
lease loss. The shared agent suite must remain green during extraction.

## Public runtime

`fabric/graph.new` binds a definition, store, current-context function and
explicit policy. `start` confirms the initial record and returns a handle;
`attach` creates a handle for an existing identity without starting work.
`read` returns native state, status, the retained current action and encoded
receipts. `await` stops at completion, approval, reconciliation, unattended
work or its deadline. It never recovers a run implicitly.

`recover` respects a live foreign lease and any live local runner. Otherwise
it restores only the recorded work. `approve` and `reject` name the exact
run, activation, attempt, requirement and approval revision. Admission fetches
current context and the admitted body receives that same context. A changed
requirement creates a new question. Public approval and reconciliation
references are data that an application can retain across requests.

`reconcile` checks the original operation's output codec. For an active blocked
run it accepts a new control decision; after cancellation it records the output
without calling a routing callback. Public problems retain unusable output
separately from the reason. `cancel` can cancel a readable record even when the
current deployed definition no longer fits it. A responsive owner settles its
executor; an unresponsive or lost owner is fenced through the store and leaves
any started effect unresolved.

The runner shares the store's CAS, leases and watcher mechanism, the fenced
executor, bounded callback execution and supervised startup with the existing
agent runner. Startup is released only after its owning commit is confirmed.
During shutdown it admits no new bodies; an in-flight body may finish within
the store's drain window, and its saved successor is handed off. A store loss
or expired/lost lease stops the runner and its local tasks. External effects
may still require reconciliation.

`with_timeouts` sets separate callback, operation and command deadlines. A
command withdrawn before the runner claims it cannot be applied later. Native
selection, codec and routing callbacks are bounded; operation timeout is an
uncertain effect, not a definite failure or an inferred replay permission.

Executable public scenarios are in `test/fabric/graph_runtime_test.gleam`.
They include changing a decision producer's answer after restart while proving
that the saved branch still wins. The independent `consumers/graph` package
builds and runs the typed review loop without Saga or Grind. PostgreSQL
integration tests also restart and complete a graph using only public APIs.

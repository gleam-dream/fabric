# Fabric graph flow: design exploration

2026-09-29. **Serial runtime and manual signals implemented; managed children,
deadlines and jobs remain open.**
The user has authorized the six-step implementation program. Progress,
executable contracts and acceptance evidence are retained in the
[wave tracker](implementation/graph-flow/wave-tracker.md). The API sketches
below remain sketches until their implementing wave verifies them.
The [durable sequential contract](implementation/graph-flow/durable-sequential.md)
records the implemented authoring, record and public runtime boundaries.
The [public consumer](../consumers/graph/README.md) runs the production API.
Source baseline: Fabric `c375d60`; local BeamWeaver fork
`d0aa1f90d31c55d49be2f7b5a24224b5e18145a1`. Findings below come from source
inspection and published documentation, not a new behavioral parity run or
provider benchmark.

## Direction established by the user

Fabric should support flexible agentic graphs: conditional routing, model
decisions, tools, MCP calls, agents and other composable operations. Saga is
separate; its current improvement is durability, with branching deferred.
Neither Saga nor Grind should become a dependency of Fabric core. Consumers
may compose them with Fabric through ordinary operations.

This changes the earlier blanket exclusion of graph control from Fabric.
It does not select BeamWeaver's entire API, LangGraph compatibility, a specific
parallel state model, or the detailed interfaces proposed here. Breaking
public APIs are acceptable; clarity takes priority over compatibility shims.

## Recommendation

Build a **typed state graph** with its own pure controller, using execution
mechanisms extracted from Fabric's current runtime. Bind typed operations into
nodes. A pure transition accepts an operation's result, changes graph state,
and chooses the next activation. Persist that decision before running its
successors.

The first target is **serial cyclic graphs with structured fork/join**.
Start with sequential routing and bounded cycles. Then add managed children,
durable waits, and explicit parallel fork/join scopes. Keep branch state
private and merge typed results at a join. This makes concurrency useful
without introducing a global channel/reducer language first.

The graph runs an application-defined protocol. Models supply judgments and
plans within that protocol. They can choose among admitted capabilities and
create a bounded number of invocations; they do not install executable code
or bypass policy by returning a destination string.

## What this enables

One graph could process a support request as follows:

```text
Receive request
    → Classify intent and urgency
        → Routine: retrieve through an MCP tool → draft answer
        → Investigation: run a specialist agent → draft answer
        → Refund: submit external workflow → wait for its result
    → Evaluate answer
        → Accept: finish
        → Revise: return to drafting, within a budget
        → Unsure: wait for human input
```

The classifier might be Jev, a structured LLM call, or a deterministic rule.
The refund operation might use Saga plus Grind, another service, or ordinary
application code. None changes the graph's control semantics.

Other useful compositions follow from the same pieces:

- A router selects one model or specialist from a checked enum.
- A planner returns a bounded list of research tasks; a fork runs a child
  agent for each task and a join passes ordered results to a synthesizer.
- A generator and evaluator loop until a rubric passes or a limit stops them.
- An application exposes an entire graph as one agent tool, or invokes an
  agent inside a graph. Both directions need explicit input/output adapters.

These are proposed capabilities. Fabric currently implements the chat-agent
loop, not this general scheduler.

## Four concepts at the authoring boundary

| Concept          | Responsibility                                                                                       |
| ---------------- | ---------------------------------------------------------------------------------------------------- |
| Graph definition | Names nodes, entry point, allowed destinations, state/output codecs, version and limits.             |
| Operation        | Describes typed work, its input/output contracts and execution/recovery behavior.                    |
| Node             | Projects state into an operation's input and accepts its result into a state/control transition.     |
| Command          | Describes the requested state update and next control step; the controller validates and commits it. |

A decision is an ordinary typed operation result, not a fifth scheduler.
A tool is an operation advertised to an agent with a name, description and
schema; not every graph operation needs to be advertised as a tool.

An illustrative type boundary is:

```gleam
Graph(context, state, answer)
Operation(context, input, output)
Node(context, state, answer)
```

Binding an operation supplies two pure functions:

```gleam
select: fn(state) -> Result(input, InputError)
accept: fn(state, output) -> Result(Command(state, answer), TransitionError)
```

For sequential control, a command could begin with:

```gleam
pub type Command(state, answer) {
  Continue(state, NodeId)
  Finish(state, answer)
}
```

These are sketches, not compilable API examples. Constructors must also
provide stable operation identity, codecs, allowed destinations, failure
classification and effect/retry contracts. Input selection and transitions
must be pure and bounded; encode/transition failures must not release work.
An application error intended for routing belongs in the typed output, such
as `Result(Answer, RejectedRequest)`. Runtime failure and uncertain effects
remain separate from ordinary business outcomes.

Different operation input/output types can disappear behind closures when
bound into the common `Node(context, state, answer)` type. Fabric already uses
this technique in [`tool.bind`](../src/fabric/tool.gleam). Native Gleam values
remain native inside application functions; serialization belongs at stored
receipts and external boundaries. This does not require unchecked `Dynamic`
casts or a universal JSON state dictionary.

Use custom state variants to represent valid phases when appropriate, rather
than a large record of unrelated optional values. A shared state type does
not prove that every node is reachable with its required data: `select` must
check that precondition. Graph construction validates references and declared
destinations; runtime validation checks that a returned destination belongs
to the source node's declared set.

### Why not typed data ports first?

| Authoring model                       | Benefit                                                     | Main cost                                                                   |
| ------------------------------------- | ----------------------------------------------------------- | --------------------------------------------------------------------------- |
| Typed state plus bound operations     | Small cyclic control model; ordinary Gleam pattern matching | Phase-specific input requirements need explicit checks.                     |
| Typed events plus application reducer | Exhaustive handling and explicit state changes              | More authoring plumbing; useful as a helper over state graphs.              |
| Heterogeneous typed ports             | Strong data wiring for acyclic flows                        | Feedback needs initialized values, occurrence identity and token ownership. |
| Dynamic JSON maps                     | Easy runtime construction                                   | Ordinary business mistakes move out of Gleam's type checker.                |

The first option is the recommended initial surface. A typed-port builder
could eventually compile to the same runtime. It is not necessary to solve
cyclic control before that runtime exists.

## Decisions are independent of chat

The Jev article illustrates a useful split: a non-generative classifier can
produce a structured judgment while a generative model handles drafting or
open-ended reasoning. That is a suitable operation boundary for Fabric.
No performance or accuracy claim is established by this investigation.
See [Building a Harness with Jev](https://www.langchain.com/blog/building-a-harness-with-jev).

| Requested decision | Typed result in the application                                 | Pure routing rule                                         |
| ------------------ | --------------------------------------------------------------- | --------------------------------------------------------- |
| Yes/no             | Boolean, or a probability retained until a threshold is applied | Continue, stop, or take an uncertainty fallback.          |
| Score              | Checked domain score with its rubric                            | Select a band, revise, or ask for review.                 |
| Choice             | Enum, optionally with supporting probabilities                  | Exhaustive pattern match to registered destinations.      |
| Plan               | Validated list of admitted tasks                                | Reserve a bounded fork with one invocation per list item. |

For Jev specifically, Noul returns a probability of yes. Choice includes a
label and distribution. Score is an expected position over authored levels;
it is not necessarily a zero-to-one scale. Keep the rubric and distribution
when they matter to a decision. See the primary
[Noul](https://docs.typesafe.ai/primitives/noul),
[Choice](https://docs.typesafe.ai/primitives/choice) and
[Score](https://docs.typesafe.ai/primitives/score) contracts.

TypeSafe's confidence measures distribution concentration, not an independent
probability that an answer is correct. Thresholds and fallback routes require
application evaluation. Batched questions see the same input independently;
a question depending on an earlier answer needs another step.
See [confidence](https://docs.typesafe.ai/confidence) and
[question composition](https://docs.typesafe.ai/primitives).

Keep three separate decisions:

1. **Inference:** what did the classifier or model conclude?
2. **Routing:** what does this application do with that conclusion?
3. **Admission:** may this operation act with these arguments and this context?

A high model score is not permission to perform an effect. Classifier output
may inform application policy, but cannot bypass Fabric's gate. Record the
accepted result, relevant model/rubric version and input identity so the
route can be explained. Preserve provider-specific evidence in its adapter's
typed output rather than imposing Jev's response shape on every operation.

The existing [`Model`](../src/fabric/model.gleam) is a chat interface containing
messages, tool requests and assistant replies. Keep it honest. A classifier
operation should return `ReviewDecision`, not a fabricated `FinalAnswer`.
Replacing a scripted function with an LLM or Jev should change the producer,
not routing, waits, recovery or cancellation.

## One control decision per activation

A node definition is reusable; an **activation** is one visit to it. A loop
creates new activations. An **invocation attempt** is one execution attempt
within an activation. Run ownership and store revision are different again.

Each activation has one routing authority. A fixed edge is a shorthand for
`Continue`. A conditional chooses a permitted target. A fork explicitly
creates several members. A command from one branch cannot redirect a sibling.
Avoid mixing additive static edges with an implicit overriding `goto`.

Graph definitions remain immutable during a run. Models can select known
nodes, provide typed arguments and propose bounded task lists. Runtime graph
code generation, arbitrary cross-ancestor jumps and mutation of definitions
are separate features, outside this proposal's first implementation.

Limits must count graph activations as well as model attempts. Pure routing
can loop forever without a model turn. Reserve activation/fan-out budgets
before creating work, and define child depth/count, active work and resource
accounting. Shared family work/child/depth budgets are implemented through
root `start_with_budget` APIs and one persistent reservation ledger. These are
additional to per-run activation and chat limits; elapsed-time limits remain
wave 3 work. See the [reservation contract](implementation/graph-flow/managed-composition.md#shared-family-reservations).

## Parallel composition without shared writes

First deliver a serial graph. For parallelism, add a structured fork whose
members have private state and return typed results. The parent waits; one
join function receives its saved state and the identified results, then
produces the next parent state and route.

Homogeneous fan-out can run one typed child operation over a list of inputs.
Heterogeneous branches can compose through a typed pair operation:

```gleam
both(
  Operation(context, input, left),
  Operation(context, input, right),
) -> Operation(context, input, #(left, right))
```

This illustrative combinator returns the two different result types without
adding type parameters to `Graph`. Input projections adapt the common input
for each branch; a result mapper can name the tuple fields. It must describe
a managed fork scope, not launch tasks inside an opaque blocking handler.

Record the expected members of each fork occurrence. Two equal payloads still
mean two invocations. An unselected conditional branch is not an expected
member. Results from iteration N cannot complete iteration N+1. Fold results
in declared member order, independent of finish timing.

This initial model deliberately serializes parent state changes at joins.
It does not support siblings continuously editing shared state, streaming
partial results into a running parent, or starting follow-up work from the
first useful result while another member continues. Slow members delay the
parent. Those needs could justify more general concurrent routing, channels
or explicit reducers later. This is a real initial expressiveness limit.
A database revision check alone cannot define a correct merge of concurrent
whole-state replacements.

Failure behavior also belongs to the fork contract. Recommend waiting for
all successful members initially; a definite failure stops new dispatch and
settles accepted work, while an uncertain effect suspends for reconciliation.
Races, quorum joins and continuing unrelated branches through uncertainty
need separate policies. `Finish` must not silently abandon admitted work.

## Waits and children are execution states

Not every node is a synchronous function. The public data boundary can stay
typed while execution distinguishes local work, managed children and external
waits. Do not implement child execution as an opaque blocking `start + await`
handler: Fabric needs to see its approvals, cancellation, limits and outcome.

A durable wait records an identity, expected signal contract, originating
activation, continuation data, optional deadline and consumed signal receipt.
It holds no suspended stack or permanent task. Resume validates that identity
and input, commits consumption once, and schedules a named next activation.
Work performed before a wait belongs in an earlier committed activation.

Start with an explicit signal/resume API. Durable timers then require a due
wait index or scan and a wakeup owner. An in-memory timer is only a wakeup
optimization. After downtime, due work may run late but cannot disappear.

Managed agent/graph children get parent-reserved IDs and separate records.
The parent retains references, adopts the same child after a lost start
acknowledgment, and reads committed outcomes after lost notifications. Child
approvals and uncertainty remain visible. A subgraph exposes typed input and
output while keeping its internal state private. An existing chat agent's
reply needs an explicit output adapter; it is not automatically a validated
business result.

### External workflows: three deliberate contracts

| Composition                        | What completion means                                  | Recovery                                                                |
| ---------------------------------- | ------------------------------------------------------ | ----------------------------------------------------------------------- |
| Call and await a bounded operation | The business result is known.                          | Follow the operation's effect contract if interrupted.                  |
| Submit and return a receipt        | Submission was accepted; the job may still be running. | Resolve the same submission identity; do not claim business completion. |
| Submit, attach and wait            | The external job has reached the required outcome.     | Reload the receipt, query or receive a signal, and continue.            |

A consumer adapter can implement these with Saga, Grind or another service.
Submission uses a persisted invocation identity as an idempotency/lookup key
where supported. Remote acceptance followed by loss of the receipt remains
uncertain if the external service cannot resolve that key.

Attached versus detached lifetime is explicit. Canceling Fabric may request
external cancellation only when the adapter supports it and that ownership
was selected. Stopping local observation is not proof the job stopped.
Saga owns its workflow progress and compensation; Fabric owns the agentic
graph and its attachment. Automatic Saga-style rollback is not a graph
runtime responsibility.

## Recovery is part of graph control

Commit one transition containing the accepted output, state change, route,
new activation identities/inputs, fork membership, waits and budget changes.
Only after that commit may successors be dispatched. Thus a saved classifier
decision survives restart even if a newly called model would answer differently.

Definitions and codecs are deployed code. Records contain data and stable
references to compatible versions, never closures. Reject incompatible
restoration before effects. Introduce an explicit graph record format rather
than interpreting a graph as the existing v4 chat transcript. Breaking source
APIs does not make silent reinterpretation of stored work safe; migrations or
an explicit unsupported-record result remain necessary.

| Interruption                                            | Required behavior                                                                                                      |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Decision returned, transition not committed             | A declared retry may recompute it and incur another provider charge; no successor has run.                             |
| Route committed, successor not dispatched               | Recover the recorded activation; do not ask the decision source again.                                                 |
| Commit reply lost                                       | Confirm the exact write token and revision; ambiguous acknowledgement releases no effects.                             |
| Effect queued, body not admitted                        | Recover and recheck policy/context as required.                                                                        |
| Body start committed, external result absent            | Mark uncertain; resolve through the effect contract or wait for reconciliation.                                        |
| Output cannot be decoded or encoded after an effect     | Retain the failed result/uncertainty as appropriate; never infer that the effect did not happen and blindly repeat it. |
| Duplicate or stale result/signal                        | Match invocation and wait identity; it cannot advance a newer activation.                                              |
| Child started or finished, parent missed acknowledgment | Adopt its reserved ID or read its committed result.                                                                    |
| Process dies during a wait                              | Restore wait data; no stack replay.                                                                                    |
| Ownership lost or cancellation accepted                 | Stop new dispatch and settle or classify accepted work honestly.                                                       |

Pure work can have a replayable contract. A model call may also be retried
under a bounded policy, but it has cost and potentially different output.
MCP, tools and remote submissions must classify uncertainty. Retrying merely
because an exception occurred is not a valid effect contract.

Durability depends on the selected backend. Fabric's directory store is for
one-host development/tests and does not promise power-loss durability. A
durable graph also does not promise exactly-once effects in an external
system.

## What to take from BeamWeaver

The pinned local fork provides valuable examples and regression scenarios:

| Source behavior                                            | Proposed Fabric choice                                                         |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Compiled node/edge declarations with cycles                | Keep validated immutable definitions and bounded cycles.                       |
| Every matching guarded edge fires; static edges add routes | Make exclusive choice and explicit fan-out different constructs.               |
| Command combines update and route                          | Keep the combination, scoped to its originating activation.                    |
| Equal `Send` payloads remain distinct tasks                | Give every emission its own identity.                                          |
| Native joins remember sets of upstream node names          | Correlate actual members of one fork occurrence.                               |
| Supersteps merge sibling updates in stable frontier order  | Begin with isolated branches and a typed join, before a shared reducer system. |
| Interrupt resumes by rerunning a node with stored answers  | Use explicit wait boundaries and continuation data.                            |
| Child checkpoint namespaces and parent routing             | Keep child identity; prefer explicit input/output over ancestor jumps.         |

The fork's current collection of `Command.goto` can also affect ordinary
routing of sibling completions. That interaction should not be carried over.
LangGraph documents a different interaction: static edges still run alongside
command destinations. Neither behavior should become an accidental contract
in Fabric. See the [LangGraph graph API](https://docs.langchain.com/oss/python/langgraph/graph-api).

Local source anchors: BeamWeaver
[`scheduler.ex`](/code/edgar/forks/beam_weaver/lib/beam_weaver/graph/execution/scheduler.ex),
[`collection.ex`](/code/edgar/forks/beam_weaver/lib/beam_weaver/graph/execution/collection.ex),
[`named_barrier_value.ex`](/code/edgar/forks/beam_weaver/lib/beam_weaver/graph/channels/named_barrier_value.ex),
[`scratchpad.ex`](/code/edgar/forks/beam_weaver/lib/beam_weaver/graph/execution/scratchpad.ex)
and
[`atomic_checkpoint_boundary_test.exs`](/code/edgar/forks/beam_weaver/test/beam_weaver/graph/atomic_checkpoint_boundary_test.exs).
These links assume the local reference checkout. The commit pin above is the
reproducible reference; this is not a claim about every upstream release.

## MCP stays an adapter boundary

An MCP adapter handles server-scoped identity, input validation, optional
output schema, protocol content, cancellation and error classification.
Dynamic discovery can use Blueprint runtime contracts locally. It should not
force every graph to use dynamic JSON state. MCP annotations alone do not
establish trustworthy effect behavior. See the
[MCP tools specification](https://modelcontextprotocol.io/specification/2026-07-28/server/tools).

Keep graph node IDs and operation IDs independent of model-facing tool names.
An adapter may need to map remote names into provider-compatible aliases.
Pin or revalidate remote schema contracts at admission/recovery rather than
silently accepting a changed tool. The first adapter should state its supported
protocol subset; the graph interface does not imply full MCP support.

## Implementation impact in Fabric

Fabric has valuable execution mechanisms, but they are not a generic graph
kernel today:

| Current code                                          | Reusable mechanism                                           | Coupling to remove or keep separate                                |
| ----------------------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------ |
| [Controller](../src/fabric/internal/controller.gleam) | Pure transitions describing effects                          | Chat phases, transcript, turn batches and model replies.           |
| [Runner](../src/fabric/internal/runner.gleam)         | Commit before effects, drain, result delivery                | Agent setup, chat events and tool-call dispatch.                   |
| [Executor](../src/fabric/internal/executor.gleam)     | Body-start fence, linked tasks, bounded execution            | Chat-specific invocation outcomes.                                 |
| [Store](../src/fabric/store.gleam)                    | Revision CAS, ownership leases, exact write confirmation     | Encoding currently accepts the chat controller's state.            |
| [Family](../src/fabric/internal/family.gleam)         | Child identity, reattachment and outcome redelivery          | Agent-only references and restoration.                             |
| [Policy](../src/fabric/policy.gleam)                  | Decode before admission, fail closed, fresh approval context | Action identity is turn/tool-call based; targets are tools/agents. |

Prefer a **new graph controller and record over narrow shared execution
mechanisms**. Initially, an existing agent can be a managed child. Eventually
the ordinary agent builder could produce a graph recipe, if doing so removes
duplication and preserves all current guarantees.

Two alternatives are less attractive: a separate maintained graph runtime
would duplicate recovery/policy semantics; immediately rewriting the entire
agent loop would combine too many changes before graph semantics are proven.
Extraction must be driven by both concrete controllers, not a speculative
framework of extension hooks.

Core already has no Saga/Grind dependency. Keep that property. Jev and MCP
clients can be optional integration packages. Moving the existing llm_wire
adapter out of core is a separate packaging choice, not required to achieve
this graph boundary.

## Proposed implementation sequence

1. **Prove the authoring shape.** Compile a small disposable Gleam experiment:
   typed state, heterogeneous bound operations, boolean/score/enum routes,
   a bounded revise loop and typed completion. Script decisions. Resolve the
   exact command, codec and error contracts before choosing public names.
2. **Deliver a durable sequential graph.** Extract only needed execution
   mechanisms while preserving existing agent behavior. Add graph records,
   activation identity, validated routing, budgets and policy-gated effects.
   Demonstrate recovery after a committed decision and an interrupted effect.
3. **Compose children and waits.** Add agent/subgraph input/output adapters,
   durable signals, parent references and explicit external job attachment.
   Prove lost start/result notifications and nested approvals. Add durable
   timer scheduling when its backend contract exists.
4. **Add bounded parallel composition.** Typed map/fork, identified members,
   isolated branch state and deterministic joins. Prove sibling child graphs
   using the same node definitions cannot mix their fork results; define
   failure/cancellation behavior.
5. **Exercise real decision/protocol adapters.** Structured LLM and classifier
   producers share a business result contract; MCP and an external job example
   exercise effect boundaries. Some adapter work can accompany earlier slices,
   but provider networking must not substitute for kernel acceptance tests.
6. **Evaluate one agent implementation.** Compare an agent-as-graph recipe
   against current policy, provider transcript, recovery, cancellation and
   mixed-version behavior. Converge if it simplifies the implementation.

No timescale is estimated yet. This is a runtime expansion, not a wrapper
around the existing loop. S7 operations and the retained backlog in
[REMAINING](REMAINING.md) still exist; their ordering against this work has
not been decided.

## Evidence needed before calling it ready

- Exchange a scripted producer, structured LLM stub and classifier stub without
  changing routes. Reject invalid enums and forbidden destinations before effects.
- Commit a decision, restart with a producer that would answer differently,
  and take the original recorded route.
- Lose the commit acknowledgement and prove no successor escapes an unconfirmed
  write. Replay a duplicate completion without duplicating activations.
- Revisit a node, then deliver a late result from its previous invocation;
  reject it. Exhaust a pure loop's activation budget before new work begins.
- Kill execution on both sides of the body-start fence; only unstarted work
  is automatically restartable. Recheck approval with fresh context.
- Restart a nested agent at an approval and after a child start/result
  notification is lost; reconnect to the same child.
- Resume an external wait twice and after cancellation; accept only its valid
  unconsumed signal. Submission success must not masquerade as job completion.
- Fork two identical inputs and retain two results. Interleave forks from
  two sibling child graphs using the same definitions and prevent cross-scope
  joins. Deliver a stale result from a completed loop iteration and reject it.
  Reverse completion order without changing the join result. Pipelining parent
  iterations remains a later control feature, not a capability of this test.
- Reject incompatible definitions/codecs before execution. Preserve provider
  continuation data when an agent is a child or a future graph recipe.
- Build and run the graph consumer without Saga or Grind installed.

## Choices still open

The recommendation is typed state, explicit control commands and isolated
parallel branches. Before implementation, validate the exact operation
lifecycle, serialized receipt/error representation, child result mapping,
definition compatibility rules and shared resource accounting in the small
authoring experiment. Public module names and eventual agent-as-graph
convergence remain open. Full LangGraph API compatibility, global channels,
arbitrary runtime code generation and automatic compensation are not needed
to prove this design.

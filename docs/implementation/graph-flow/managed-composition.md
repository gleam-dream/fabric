# Managed composition contract

Wave 3 implements G7–G8 from the [wave tracker](wave-tracker.md), continuing the
accepted [serial runtime](durable-sequential.md). This document distinguishes
the first concrete signal contract from the child/job contracts still being
refined. It is not evidence that all wave 3 behavior has shipped.

## Typed signals

A signal is a versioned native output contract. A node binds its existing
typed input selection and output acceptance around that contract. Its mode is
part of the definition manifest and prepared activation. The runtime applies
policy before publishing the wait, then commits `WaitingSignal` and releases
its runner. It starts no operation task and needs no replay contract.

The public wait reference contains run, activation, attempt and signal
identity/version. It is durable correlation data, not a process handle or an
authorization token. Applications authenticate and authorize external callers
before delivering signals, just as they do before approving graph actions.
The native delivery API encodes through the signal's codec; a JSON delivery
boundary supports HTTP or other transport adapters. Both validate the saved
contract and deployed output codec before routing.

Concrete surface: `fabric/graph/signal.new` declares the output contract,
`operation.await_signal` binds it to a native input codec, and the ordinary
`definition.node` binds selection and routing. A snapshot exposes
`AwaitingSignal(SignalReference)`. `graph.deliver` accepts native values and
`graph.deliver_json` accepts encoded transport data. Retries must preserve the
encoded payload exactly, including JSON whitespace; acknowledgement uses the
saved bytes rather than rerunning codecs to normalize historical results.

Record version 2 introduced execution modes and the waiting phase. The current
version 5 also retains subgraph and agent attachments, initial input and idle child waits. Earlier versions
are rejected explicitly; no migration or compatibility shim is provided for
unreleased formats. The mode participates in definition
compatibility, preventing a stored wait from becoming an executable activity.

Consumption commits the output receipt, new state, route and next activation
together. A second delivery with the same reference and encoded payload is
acknowledged from the retained receipt without invoking routing again. A
different payload, wrong contract, old unconsumed reference or canceled wait
is refused. Duplicate delivery of a consumed earlier visit cannot consume a
later visit to the same node. Concurrent cancellation and delivery are decided
by the record's CAS revision: at most one can release successor work.

Malformed values or rejected transitions do not consume the wait. These are
command rejections, not ambiguous external effects. Delivery is allowed only
after the wait is committed; Fabric does not buffer unsolicited early signals.
Work before the wait is a separate activation with its own committed receipt.
Recovery does not rerun that work or ask for a signal already consumed.

## Managed children

The parent must reserve a stable child identity and attachment before starting
the child. A child is a separately stored agent or graph with its own compatible
definition. Starting and observing it are runtime actions; no operation body
blocks on `start + await`. Missing start acknowledgements adopt the reserved
child, and missing completion notifications are repaired by reading the child.

Child approval and uncertainty remain observable through the parent's current
attachment. Typed graph results are decoded at the child boundary; agent
replies require an explicit business-result adapter. Mapping a child outcome
must not obscure uncertain effects. The parent cannot finish while it owns
unsettled child work. Cancellation intent, pre-start tombstones, ancestral
admission checks, depth and child-count bounds must cover both runtime kinds.
The shared parent reference is `run.Parent`: `AgentParent(run, ActionId)` or
`GraphParent(run, activation)`. Graph activations never become chat action IDs.
Family retention and shared budgets still need a contract against PostgreSQL's
existing agent-family metadata.

Both controllers retain this parent sum. Agent record version 5 writes tagged
parent variants; older agent records decode to `AgentParent`. Writers 2–4 keep
their historical shape for ordinary agents and refuse graph attachments before
writing or releasing work. Graph records keep their current wire shape and
accept graph parents only; graph-as-agent-tool authoring is not implemented.
The public agent snapshot now exposes `Option(run.Parent)`; uncertain effects
continue to use `ActionRef`.

Shared ancestry checks read each saved parent and require its active reservation
to name the exact descendant and action/activation. A stopped, unrelated,
unreadable or excessively deep chain admits no new work. Agent model attempts
(including retries), tool fences, child starts and approval commands use this
contract, as do graph admission and effect fences. The existing agent sweeper
stops at a graph parent: graph recovery owns that boundary. Automatic graph
recovery remains separate work.

The first managed-child implementation is a subgraph in the same store. Its
typed operation is constructed from a child graph runtime, with the child
state codec as input and answer codec as output. The parent applies policy
before reserving a child identity. The identity derives from parent run and
activation, never an attempt or a node name, and is stored with the attachment.
The committed attachment is the durable scheduling admission. Recovery may
finish creating its absent child; each child operation still passes its own
current policy and ancestry checks before starting an effect.
The child records the reciprocal parent run/activation link. Admission and
effect fences check that ancestry remains open. An existing record is adopted
only when its parent attachment, definition and initial input match.

Child observation is separate from activity execution. Its bounded start,
read and cancel commands never hold the operation executor. A working child
is observed by its parent's supervised runner; approvals, signal waits and
uncertainty remain visible through the child reference. Recovery reads the
same child's committed outcome before deciding whether work remains.
Canceling an attachment retains intent until child cancellation is recorded;
an absent child gets a terminal record before a competing start can win.
No parent continuation follows an uncertain child. Each graph's activation
bound limits the children it can reserve, and ancestry checks cap nesting.
Family-wide budgeting/retention remains separate work in this wave rather
than being inferred from a passing child scenario.

The first subgraph checkpoint proves creation, lost acknowledgements,
recovery, child approval, child reconciliation and cancellation races through
public APIs, including a PostgreSQL restart. It does not complete managed
composition. Subsequent checkpoints implement idle child waits, local wakeups,
nested approval/signal propagation and cancellation settlement, including nested
cancellation across restart. Managed agent nodes are described below. Family
retention, shared budgets, jobs and deadlines remain unaccepted.

### Managed ordinary agents

`fabric/graph/agent.Definition` binds a validated ordinary agent, native input
and output codecs, a pure prompt builder and a pure final-reply converter.
`new` binds its store and context factory; `as_operation` makes a normal typed
graph node. The declared binding identity must change when its prompt, reply
meaning or deployed agent changes. Construction rejects agent trees whose
declared descendant IDs could exceed 128 characters below a graph reservation.

The parent commits the agent activation and reserved child ID before dispatch.
The child stores an ordinary agent record with `GraphParent`; repeated start
adopts only the same attachment, compatible agent and prompt. Context is rebuilt
for start/recovery. Models, tools and delegated agents use the existing agent
runner and its ancestry fences. Parent scheduling and child tool policies both
apply. Managed operations cannot request activity replay.

`agent.child(parent, activation, runtime)` returns the child's ordinary Fabric
handle after checking the store and reciprocal attachment. It also opens
completed visits. An idle family is exposed as
`child.AgentInput(approvals, uncertain)`, preserving every agent action reference,
including references to delegated descendants. Applications use ordinary
`fabric.approve`, `reject`, `pending`, `child` and `reconcile` APIs. The graph
parks while the family needs input and wakes on its root's committed progress.
Nested graph observation preserves these references and each graph's own route.

A completed agent's raw reply stays in its transcript. The pure adapter converts
that reply into the node's native output; encoding, acceptance and routing use
the normal graph contract. An invalid conversion records `InvalidResult` and
releases no successor. Recovery never repeats the model merely to parse its
saved answer. Agent refusals, limits and failures remain definite child failures;
a terminal agent retaining uncertain effects remains uncertain.

Cancellation uses stored agent state and can insert a never-started tombstone
without running prompt, answer or context callbacks. It propagates through the
agent's existing cancellation path. A known completed child can settle a canceled
graph even when its answer adapter is broken: settlement observes the retained
outcome and never invokes application reply conversion or parent routing.
A canceled agent with uncertain tool effects remains `ChildUnresolved`.
`fabric.reconcile_stored(store, effect, content)` records evidence for a
finished agent's direct tool. It needs no deployed agent definition and never
resumes execution. Repeating the same content acknowledges the saved evidence;
different content, a definite action or a delegation is refused. An active
agent returns `RunNotFinished`; its existing `fabric.reconcile` command can
continue execution under the usual ancestry checks.
Both terminal commands return the updated run snapshot, including unresolved
actions; a successful read and commit is not a claim that every effect settled.

`fabric.settle_stored(store, agent_root)` propagates settlement through a
finished delegated family. It follows retained uncertain child links and checks
each child's reciprocal parent action. A definite saved child outcome becomes
`run.ChildSettled(outcome)`; a saved never-started tombstone becomes `NotStarted`.
An absent or unreadable child is an error. An active or uncertain child leaves
the parent uncertain. Callers cannot supply a result on a parent's behalf.

Each record commits independently from descendants outward. Repeating the walk
repairs a failed parent write after successful child writes, and unchanged
records are not rewritten. Compare-and-set resolves competing writes; the
store's exact write-token readback handles lost acknowledgements. These updates
change only history: outcome, transcript, counters and usage are preserved. No
model, tool, policy, prompt, reply converter or delegation mapper is invoked.
After settling the agent root, `graph.recover(parent)` reads its saved outcome
and changes `ChildUnresolved` to `ChildSettled`, preserving canceled graph state
and receipts. Observation alone does not implicitly amend either family.

Graph format version 5 adds the `agent` operation kind. Earlier unreleased graph
formats are refused explicitly. Agent record version 6 adds terminal child
settlement; readers accept 1–6, writers 2–5 refuse this new evidence. The
version-5 parent representation is unchanged. Upgrade readers before changing
the store's writer setting.

### Cancellation settlement

While cancellation is committed but its child has not yet settled, the parent
exposes `CancellingChild(reference)`. `await` continues through that state
until the child settles or the caller's deadline expires; an old child approval
or uncertainty does not hide the parent's accepted cancellation intent.

A canceled subgraph attachment with uncertain effects exposes its child
reference as `Cancelled(ChildUnresolved(reference, problem))`. An application
reconciles the uncertain operation in that child. It cannot replace the
child's recorded outcome by supplying an answer to the parent.

`graph.recover` on this canceled parent checks the same child's retained
outcome. A completed or definitely failed child, or a canceled child whose
effects are settled, permits a conditional parent commit to
`Cancelled(ChildSettled(reference))`. This is terminal bookkeeping: it invokes
no child start/cancel command, policy, body or routing callback, and changes
neither parent state nor receipts. An uncertain, absent or nonterminal child
leaves cancellation unresolved; an unreadable or foreign child is an error.
Repeated recovery of a settled parent is a read-only acknowledgement.

For nested cancellations, reconcile the leaf and recover canceled attachments
from the leaf outward. Lost or failed settlement acknowledgements use the
ordinary CAS confirmation/retry contract. They cannot turn cancellation into
successful graph completion or release successor work. This adds no persisted
variant: the existing canceled and child-settled outcomes retain the result.

Deployed graph callbacks retain each descendant runtime once. Codec, input
selection and route callbacks carry only the parent's native contracts; they
do not capture managed children. This matters on the BEAM, where passing work
to a process copies closure environments. Nested composition must not multiply
copies of the complete descendant graph at every callback boundary.

### Idle child waits and wakeups

When an owned child awaits approval or a signal, its parent commits
`WaitingChild(activation, child)` and releases its runner and lease. The parent
still exposes the child's reference and current wait. A chain of subgraphs
propagates a descendant's approval, signal or uncertainty through its immediate
child attachments; a descendant's result never bypasses intermediate routing.

The confirmed parent wait installs a transient, store-owned dependency wakeup.
It retains deployed recovery code, without a process per waiting parent. Child
commits through that store trigger a bounded worker. Concurrent notifications
coalesce; a notification during recovery requests one additional check. A
parent write invalidates the previous registration. Recovery always reads the
stored parent and child before committing anything. A check immediately after
registration closes the race between observing the child and parking the
parent. While the child still waits, the check performs no parent write.

The wait and reciprocal attachment are durable; the notification is only a
local hint. Store loss, a failed wakeup or a child write through another store
can lose that hint. `graph.recover(parent)` restores the registration and
checks the child, without requiring another child notification. It can recover
nested attachments through their deployed runtimes. `read` and `await` remain
observation APIs and do not start recovery. Automatic graph-wide scanning is
separate work; these local wakeups do not claim distributed notification.

Cancellation closes the waiting attachment through the same committed intent
as a working child. A stale notification or competing recovery cannot reopen
it. Store shutdown starts no wakeup work after draining begins; any lost wakeup
remains repairable from the retained wait. Graph record version 4 introduces
the waiting-child phase and rejects earlier unreleased graph formats.

## External jobs and deadlines

Submission intent, accepted receipt and business completion are distinct
retained facts. A submit-and-return operation may finish with a receipt. A
managed attachment instead retains that receipt and waits for a checked
business outcome. The external adapter resolves submission by the stable
invocation key where supported. Remote acceptance without a saved receipt is
uncertain if the service cannot look it up or deduplicate it.

Attached versus detached lifetime is explicit. An attached adapter can request
cancellation only if it supports that operation; the stored outcome must say
whether cancellation was requested, confirmed or unresolved. Ending local
observation never implies that the remote job stopped. Saga and Grind remain
consumer choices with no Fabric core dependencies.

An optional due time is durable data. Timers are wakeup hints only; a due-wait
scan or index plus an explicit wakeup owner must recover overdue waits after
downtime. This is later wave 3 work, separate from manual signal delivery.

## Required evidence

Signal scenarios cover store-process loss, correct native decoding, changed
contracts, policy approval, duplicate/conflicting delivery, repeated visits,
concurrent delivery/cancellation, failed or lost commit acknowledgement, and
absence of a live runner during a wait. Child scenarios cover lost start and
result acknowledgement, nested approval, uncertainty, cancellation before
creation, ancestral closure and bounds. Job acceptance uses an independently
retained local service, including acceptance followed by lost receipt and
cancellation ambiguity. Due waits must survive restart. Wave 3 is accepted
only after all of these boundaries are exercised.

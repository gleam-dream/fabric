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
version 9 also retains subgraph and agent attachments, initial input, idle child
waits, optional root budget declarations and job observations with explicit
cancellation ownership. Versions 5–8 remain readable for states they can represent;
versions 1–4 are rejected.
Job observations require version 7; scheduled observations require version 8.
Owned cancellation requires version 9.
The mode participates in definition
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
Family retention uses the saved attachment contract described below. Shared
budgets still need a contract across both runtime kinds.

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
contract, as do graph admission and effect fences. The shared sweeper resolves
the registered root through checked mixed attachments; graph recovery owns a
graph-rooted family. Changed idle dependencies use the discovery contract below.

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
Family-wide budgeting and retention are verified separately below.

The first subgraph checkpoint proves creation, lost acknowledgements,
recovery, child approval, child reconciliation and cancellation races through
public APIs, including a PostgreSQL restart. It does not complete managed
composition. Subsequent checkpoints implement idle child waits, local wakeups,
nested approval/signal propagation and cancellation settlement, including nested
cancellation across restart. Managed agent nodes are described below. Family
retention and shared budgets are described below. Job observation is implemented;
owned remote cancellation and deadlines remain open.

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

Graph format version 5 adds the `agent` operation kind. Graph formats 1–4
are refused explicitly. Agent record version 6 adds terminal child
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
observation APIs and do not start recovery. Registered sweeping discovers
expired leases and changed free idle dependencies;
these local wakeups do not claim distributed notification.

Cancellation closes the waiting attachment through the same committed intent
as a working child. A stale notification or competing recovery cannot reopen
it. Store shutdown starts no wakeup work after draining begins; any lost wakeup
remains repairable from the retained wait. Graph record version 4 introduces
the waiting-child phase and rejects earlier unreleased graph formats.

### Registered recovery of expired work

The leased-store sweeper accepts ordinary agent registrations and graph
registrations in one bounded scan. Registrations are keyed by runtime kind
and definition identity/version, so an agent and a graph may share a name.
A graph registration rebuilds the complete runtime, including child bindings,
against the supplied pinned store; the factory is bounded and its definition
and store must match before recovery begins.

Each claimed candidate follows decoded reciprocal attachments to its root.
A graph-owned agent is recovered through its graph registration, never through
an independently registered agent with the same identity. Corrupt, unknown,
misfiled, mismatched or overlong ancestry dispatches nothing. Root recovery
uses the existing per-run leases, definition checks, policy, budget and effect
rules; competing scans cannot repeat a fenced body. Terminal candidates release
their retry lease only when their parent has acknowledged them. Scan observations
count a candidate as recovered only after its incarnation advances or its
acknowledged terminal lease is released.

Expired-lease recovery and idle-dependency discovery share registrations and
attachment validation. A graph parked on a free child wait uses the discovery
path below when local wakeups and child retry cues disappear. Manual
`graph.recover` remains available for an explicitly selected run.

### Durable discovery of idle dependencies

An idle graph attachment must remain discoverable without a live process,
local notification or expired execution lease. The storage integration derives
an index from validated records through `fabric/discovery`. A waiting or blocked
child attachment identifies its dependency and observation key. Unresolved
cancellation of a managed child identifies the same dependency with a settlement
key. Approval waits, external signals without a due time, finished attachments,
ordinary operations and budget ledgers have no automatic dependency to inspect.

The observation key contains the activation and attempt identity, dependency
identity and observation/settlement mode. Root incarnation and record revision
are excluded: recovering the same idle wait does not create new work. A new
visit, retry, child or cancellation mode changes the key. Unknown/corrupt records
and a mismatch between stored and declared run IDs produce no usable index.
Projection versioning lets a backend refuse stale metadata and refresh it in
bounded batches without changing execution records or retention ages.

A backend tracks the dependency revision last observed for each key separately
from the execution record. A free wait is eligible if it has never been checked,
its key changes or its dependency revision changes. The initial check is needed
even when the child finished before the parent parked. Claiming the wait records
the observed dependency revision and obtains its ordinary per-run lease in one
atomic transaction. A concurrent child change therefore remains discoverable.
Successful recovery releases that lease or launches ordinary fenced work; failed
recovery leaves a lease retry cue. A claim changes neither execution revision nor
retention age. Concurrent claims are disjoint, bounded and ordered fairly.

Rewriting the same wait preserves its observation checkpoint, including a
brief return to active child observation. Leaving the wait removes scheduling
eligibility; its old checkpoint may remain as inert metadata. A later visit
has a new activation key. An old writer that cannot maintain the index invalidates its source
revision; it cannot leave apparently current metadata behind. Neither the index
nor a scan result authorizes execution: the registered root is rebuilt and its
saved attachment, definition, policy, budgets and ownership are checked again.

The shared sweeper claims up to 50 expired leases and 50 changed idle waits
per batch. Recovery of a claimed family member may inspect free relatives;
unchanged, unclaimed waits are read without rewriting them. This prevents
recovery itself from creating an endless chain of new dependency revisions.
Explicit recovery can still restore a local wakeup. An existing retained wait
never recreates a missing child.

PostgreSQL schema version 3 maintains the projection and source revision on
writes. `refresh_discovery` projects old rows in bounded, concurrent batches
without changing execution data, leases or ages. Unknown records are examined
once per projection version. End-to-end tests cover missed wakeups, cancellation
settlement, unchanged nested waits, concurrent claims and old-writer invalidation.
Durable due-time selection remains open until deadline states are implemented.

### Family retention

`fabric/retention` derives metadata through the current agent, graph and budget
record decoders. Projection version 2 also links the ledger to its root with
matching immutable limits. It retains all immediate child reservations, including historical
graph receipts and agent actions, with an opaque attachment key that a child
must repeat. A record is settled only when it is terminal with no unresolved
effects. Declared run IDs and stored IDs must match. Unsupported or corrupt
records produce no usable metadata, and no application code participates.

PostgreSQL schema version 2 stores that projection and its source revision in
the same insert/CAS as the record. An indexed parent reference replaces the
old `run-…` prefix assumption, so arbitrary graph root IDs and hashed children
belong to the same family. Pruning checks both directions of every attachment,
all named children, all terminal evidence, every member's age and every lease.
Missing, unexpected, mismatched, unreadable, stale or unresolved members retain
the entire family. A completed child cannot be removed independently.

The prune transaction uses serializable isolation and bounded retries. Parent
foreign keys prevent delayed child insertion after parent deletion; concurrent
pruners lock distinct roots, and a member change or renewed lease must be
revalidated. A terminal evidence update resets that member's retention age.
Pruning ends the family's replay window; run IDs must not be reused for new
executions that may receive messages from the pruned family.

After migration, existing records remain retained until bounded
`fabric_postgres.refresh_retention` batches project them. Refresh does not
change bytes, revisions, leases or record timestamps. Old backend writes leave
a source-revision mismatch. Unreadable records and missing-parent orphans are
indexed as unknown and remain retained. Normal record writes or a projection
version change refresh metadata again. This establishes PostgreSQL retention,
not a pruning API for the development directory backend or shared execution
budgets.

## Shared family reservations

One ledger per root retains monotonically spent capacity separately from the
execution records. Updating the ledger must not invalidate a live parent
runner's execution revision. A successful compare-and-set is the reservation
boundary; an unconfirmed write grants no permission to dispatch. The existing
ancestry, ownership and policy checks remain necessary after a grant.

The initial dimensions are work admissions, child starts and nesting depth.
A graph activation attempt, agent model attempt or agent tool action spends
one work unit. Child starts spend a separate child unit, with root depth zero.
Graph attempts use run/activation/attempt identity; model attempts also include
the runner incarnation and turn; tool actions use run/turn/call identity. A
child identity retains its checked depth. Repeating exactly the same claim
acknowledges its original grant, including when capacity is exhausted; reusing
a child identity with a different depth is a conflict. Explicit activity
retries, new model attempts and new cycle visits spend new capacity. A failed,
uncertain or unused reservation is not refunded implicitly. These bounds do
not predict token charges or bound concurrent in-flight slots.

Limits are nonnegative, with depth at most 63 under the existing 64-hop ancestry
guard. Zero denies the corresponding new work. Limits cannot change once the
ledger exists. Stored usage is reconstructed from validated claims; duplicate,
invalid or excessive claims, future formats and mismatched roots fail closed.
Independent stores share the same CAS record. A lost acknowledgment is confirmed
by exact write-token readback; a later retry adopts an already persisted claim.
CAS conflicts retry at most five times, then report contention without granting
capacity. Missing or unreadable ledgers never become unlimited admission.

Public `fabric.start_with_budget` and `graph.start_with_budget` declare
`fabric/budget.Limits` on a root. Existing starts have no shared limit. Both
runtimes require agent writer 7 before accepting budgeted starts, including
pure graphs that could later start an agent.

Graph admission reserves work before evaluating policy; waiting for approval
and its fresh recheck share the same attempt claim. A managed graph/agent node
also reserves its child's identity and depth before committing the attachment.
Ordinary agent models reserve before calling their provider; local tool actions
reserve at their committed-start fence. Agent delegations reserve the action
and child before creation, including recovery of a missing child.

A refused reservation becomes `graph.FamilyBudget` or
`run.BudgetExhausted(run.FamilyLimit(...))`, with typed work/child/depth reasons.
Stopping an agent withdraws unstarted calls, preserves started tools as uncertain
and settles delegated children, including tombstones for children never created.
Infrastructure failures grant no capacity and leave recoverable work; they do
not masquerade as a model error or a quota outcome. A restart retains an
interrupted model's charge and spends a new unit for a new model attempt.

The record boundary stores an optional `family_budget` only on the
family's root execution. Descendants inherit through verified saved attachments
and cannot declare replacement limits. Agent format 7 and graph format 6 require
the field, with `null` meaning no family budget. Earlier supported records mean
no family budget and must refuse a non-null budget field rather than silently
drop it. Older agent writers refuse root budget configuration. Root and ledger
retain reciprocal bookkeeping links under the retention projection; a missing
or unexpected ledger therefore prevents pruning, as do mismatched limits.
The ancestry reader resolves actual family depth and limits across graph and
agent attachments; a child's local depth counter cannot reset either one.

Initialization is a retained root transition. A declaration starts with
`initialized: false`. After the root execution is stored, bootstrap creates or
adopts its ledger, then commits `initialized: true` on the root before handing
work to a runner. A crash before either acknowledgment can repeat those steps;
an existing ledger is adopted with all claims intact. Once the marker is true,
a missing ledger is data loss and recovery refuses to dispatch. It must never
create a replacement ledger with fresh capacity. Failure to confirm the marker
also releases no work. Descendants refuse an uninitialized root. The marker is
required on non-null declarations; preliminary internal budget records that
lacked it are refused. Ordinary pre-budget records remain readable. If
cancellation commits before initialization can finish, recovery seals the
bookkeeping without restarting the canceled execution. Retention projection 3
validates the marker and typed quota outcomes; existing projections require
refresh before pruning. The later discovery migration advances the PostgreSQL schema to version 3.

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

### Submission receipt boundary

The first external-job checkpoint exercises the submit-and-return contract with
an independently running local service. It uses a normal fenced graph activity;
its typed answer is an acceptance receipt, not a business result. This is a
prerequisite for managed attachment, not a replacement for it.

- **J1 — stable submission:** a logical submission key identifies the graph run
  and activation. An attempt is diagnostic data, never part of the deduplication
  key. The external service atomically binds that key to the original input and
  receipt; the same key with different input is refused.
- **J2 — ambiguous acceptance:** after admission and a committed start, process
  loss may hide a successful remote acceptance. Automatic replay is enabled only
  for an adapter whose external service guarantees deduplication by that key.
  The next attempt recovers the same receipt. Otherwise the graph stays uncertain
  until explicit reconciliation; an unconfirmed submit is never definite failure.
- **J3 — accepted is not complete:** a submission graph may complete while the
  external job remains queued or running. A receipt identifies accepted work;
  only a separate checked observation establishes its business outcome.
- **J4 — saved receipt:** once Fabric records the receipt, recovery uses that
  result without submitting again. Stopping or losing Fabric does not stop this
  detached job. This checkpoint owns no remote cancellation rights.
- **J5 — independent progress:** the service persists acceptance before replying
  and processes actual work independently of Fabric. A restarted Fabric process
  can query the same job and result. Deterministic artifact creation permits the
  example service to resume interrupted local work without creating another job;
  this is a service-specific guarantee, not general exactly-once execution.

The retained consumer in `consumers/jobs` is the evidence owner for J1–J5.
It uses a loopback-only HTTP service and a temporary SQLite database using
Python's standard library, already provided by the development environment.
These are example-service implementation choices, not Fabric dependencies.
Acceptance requires real HTTP submission, stored receipts, actual artifact
creation, concurrent duplicate submission and Fabric process loss across the
acceptance/receipt boundary. The next section adds a retained observation wait;
owned remote cancellation and general deadline outcomes remain open.

### Retained job observation

Submission and attachment are separate activations. `job.observe` binds a typed
receipt and business-output codec to a bounded, repeatable, read-only observation.
`operation.await_job` makes that binding a managed wait. Its first lifetime
contract is explicitly observation-only: canceling it detaches local observation
and grants no authority to cancel the external job. Scheduled observation is
described below; an owned-cancellation binding remains subsequent work.

- **J6 — admission and retention:** policy and shared work budget admit the job
  wait before any observation. The committed activation input is the accepted
  receipt. Waiting owns neither an executor nor a lease; observation never submits
  work or changes the remote job. An incompatible definition/receipt is refused
  before calling the observer.
- **J7 — correlated observation:** `graph.poll_job` targets a run, activation,
  attempt and versioned operation. A stale reference never observes another visit.
  Pending progress or an observer/transport/decode failure consumes no result and
  releases no route. Repeating a completed reference reuses its committed receipt.
- **J8 — checked completion:** completed output, native state, route and successor
  activation commit together through the ordinary conditional write. A definite
  remote failure ends the node without calling its success route. Invalid output
  or a refused route leaves the job wait available for correction and observation.
- **J9 — detached cancellation:** cancellation records that observation ended;
  it does not imply the remote job stopped. Completion and cancellation contend
  on the same graph revision. A completion that loses that race releases no
  successor. A retained canceled wait cannot be polled into live work again.
- **J10 — restart and composition:** a job wait survives store-process loss and
  keeps the original reference and receipt. Its containing managed subgraphs park
  too. Explicit polling works after restart without resubmitting the job; a saved
  completion survives further recovery without observing the service again.

The first vertical path used explicit polling of retained job waits against the
real service in `consumers/jobs`. Polling is a bounded command, not an opaque
blocking operation or a permanent runner. Scheduled observation adds the
automatic path below. External cancellation requests/confirmation and deadline
outcomes remain unbuilt, so this cannot close managed external-job acceptance
or wave 3.

An optional due time is durable data. Timers are wakeup hints only; a due-wait
scan or index plus an explicit wakeup owner must recover overdue waits after
downtime. Scheduled job observation implements this for its interval. General
deadlines remain later wave 3 work, separate from manual signal delivery.

### Scheduled job observation

Opt-in `job.with_poll_interval(observer, milliseconds)` enables this path.
Manual observation remains the default. A positive bounded interval is part of
the saved operation contract and definition compatibility. A leased backend
owns the observation schedule; the existing registered sweeper owns recovery.
No in-memory timer is authoritative and no new scheduling service is required.

- **J11 — retained schedule:** an admitted scheduled wait is eligible for its
  first observation immediately. Each successful claim records its activation
  key and claim time atomically with the lease. Further claims for that wait
  require the interval to have elapsed according to the backend's clock. Metadata
  refresh preserves the last claim time for the same key. A new
  activation has a new key. Pending observations release execution ownership;
  reads spend no additional work grant. Explicit `poll_job` remains available
  and does not move the automatic schedule.
- **J12 — discovery and ownership:** due observation shares the bounded ready
  scan with changed child dependencies. Concurrent scanners claim disjoint work.
  Recovery validates the registered root and saved contracts, and observes a job
  only when this store holds its claim. Reaching an unclaimed or foreign-owned
  relative never polls it early. Process loss or callback failure retains a
  lease-expiry retry path. Sweep progress includes a committed observation route,
  even when it does not restart the run. Backend metadata refresh cannot authorize
  an effect.
- **J13 — completion after downtime:** a restarted sweeper finds due waits,
  reuses their saved receipts and records the actual external outcome. Manual,
  canceled and completed waits are never automatic polling candidates. A child
  completion still wakes or becomes discoverable to its parent. Scheduling
  changes neither cancellation rights nor the definite/uncertain outcome rules.

This interval is a minimum between successful ready claims, not a promised
completion latency: scan intervals, bounded batches and unavailable services
can delay observation. Failed recovery retries after lease expiry. General
deadlines and owned remote cancellation remain separate contracts.

### External cancellation boundary

Before an owned job binding can interpret `graph.cancel`, the consumer's remote
service must distinguish an accepted stop request from a confirmed terminal
outcome. The boundary proof uses an explicit cancellation graph against
the retained artifact service. This graph is a request-and-observe workflow;
it does not change the read-only binding's `JobDetached` contract or claim that
the managed owned-cancellation lifecycle is complete.

- **J14 — cancellation admission:** requesting a remote stop is an external
  effect. Its activation passes policy and a committed start fence before the
  service is called. A denied or unapproved request changes no remote job.
  Read-only observation of an existing job grants no cancellation authority.
- **J15 — accepted stop request:** the service durably records acceptance before
  acknowledging it. An acknowledgment proves a request, not that the job stopped.
  Duplicate requests for the same accepted job are idempotent in this service.
  Lost acknowledgments may use interrupted replay only under that explicit
  service guarantee; returned transport uncertainty retains the existing
  reconciliation requirement.
- **J16 — terminal evidence:** observing a confirmed cancellation proves that
  this service exposes no artifact for that job. If completion wins the
  race, cancellation reports the existing completion and preserves its artifact.
  A cancellation acknowledgment cannot overwrite a completed result. A saved
  cancellation request and its final outcome survive service restart.
- **J17 — retained cancellation workflow:** Fabric commits the stop-request
  receipt before waiting for terminal evidence. Store loss reuses that receipt
  rather than requesting again. The final typed result distinguishes canceled
  work from work that already completed. Stopping the local observation never
  silently changes that remote result.

The service serializes stop admission and artifact publication through its own
storage transaction. That is a property of this example service, not a promise
that arbitrary external effects are exactly once or always cancelable. The
subsequent owned binding must retain intent, request progress and uncertainty
and must not route success after graph cancellation.

### Owned job cancellation

The managed binding extends the proven J14–J17 boundary. `operation.own_job`
binds an observer to a typed stop-request callback. Its distinct `OwnedJob`
policy action admits the lifetime obligation, including cancellation authority.
The read-only `await_job` binding remains available. Admission reserves the wait's
work grant; cleanup uses that existing grant even after family admission closes.

- **J18 — retained ownership:** the operation kind, receipt and deployed contract
  retain cancellation ownership. Cancellation before admission starts no remote
  request. Cancellation of an admitted owned wait commits intent before dispatch,
  suppresses all success routes, and retains the family until the job settles.
- **J19 — fenced request:** queued and started requests are distinct durable
  states. The executor calls the stop callback only after the start fence commits.
  Compatible deployed code must be validated even when cancellation was recorded
  without that code. Cleanup requires the saved owned admission, not an open
  ancestor; it cannot start new business work or spend fresh family capacity.
- **J20 — acknowledgment and uncertainty:** a successful callback records request
  acceptance, never terminal cancellation. A definite refusal and an uncertain
  response remain distinguishable. Loss after the start fence retains uncertainty;
  recovery never repeats that request automatically. A compatible queued request
  can recover because its effect never started. Repeated local cancellation cannot
  erase uncertainty or dispatch another request.
- **J21 — terminal observation:** manual or scheduled reads may resolve accepted,
  refused or uncertain requests. Remote cancellation settles as `JobStopped`;
  completion retains its checked output with a canceled route, and remote failure
  retains its reason. No route callback runs. Read failure preserves the pending
  state. Store loss retains both the request state and receipt. A parent exposes
  unresolved cleanup and subsequently settles through saved child evidence.

The first owned binding deliberately requires reconciliation of interrupted stop
effects through authoritative job observation. The service-specific replay in
the explicit cancellation workflow remains available; owning a job alone does
not assert that its stop request is repeatable. These rules add graph record 9,
retention projection 6 and discovery projection 4; PostgreSQL schema stays 4.
Acceptance covers public API restart, fences, refusals, cancellation/completion
races, managed ancestry, scheduled discovery, family retention and the real HTTP
service. Deadlines remain the next contract.

### Durable deadline clock

Deadlines need one durable time domain before wait expiration can be recorded.
The backend that judges leases and due-work eligibility owns that clock. This
boundary is a prerequisite for deadline-bearing waits; adding it alone does not
implement expiration or close wave 3.

- **D1 — authoritative time:** `LeasedBackend.now` returns UTC Unix milliseconds
  from the same clock used for leases and scheduled discovery. `store.now` reads
  that backend through the currently selected store process. A restarted store
  or another node using that backend observes the same time domain. Persisted
  deadlines must never use a VM's monotonic epoch. Wall-clock corrections can
  delay or advance eligibility; the API does not promise monotonic samples.
- **D2 — failure and isolation:** unavailable, crashed or timed-out clock calls
  return `Unavailable`. They never fall back to the caller's clock. Calls are
  bounded and do not hold the store actor or block unrelated run access. Reading
  time changes no records, revisions, leases, discovery times or retention ages.
- **D3 — backend implementations:** PostgreSQL reads `clock_timestamp()` and
  returns milliseconds as an integer. Unleased memory/directory stores use the
  host's UTC system clock. The leased test backend uses UTC time plus its explicit
  test offset for both clock reads and lease/discovery decisions. Offset survives
  store-process restart while that test backend remains alive; it is not a
  persistent database substitute.

The next deadline slice must retain each wait's due time, scope expiration to its
activation, arbitrate late delivery/completion through the record revision, and
schedule overdue idle waits after downtime. Owned-job expiration must preserve
stop-request progress and terminal evidence. Clock support cannot stand in for
those lifecycle and recovery scenarios.

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

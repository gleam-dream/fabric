# Fabric implementation plan

Fabric is a bounded, typed LLM agent runtime. It owns the agent loop, tool
execution policy, budgets, the run record, and cancellation. It consumes
llm_wire for providers and json_blueprint for tool codecs. Typed workflows
with compensation belong to Saga, durable delivery to Grind, observations to
Sinal. Chat-agent and serial graph controllers share execution mechanisms.

**Graph direction, 2026-09-29:** Fabric provides its own composable agentic
graph layer, including conditional decisions and cycles. This supersedes the
earlier blanket exclusion of graph control. Saga remains independent, with
branching deferred there; Saga/Grind integrations stay optional. The
[graph-flow exploration](GRAPH-FLOW.md) records the requested boundary and a
design. The user has now selected its six-step implementation program; the
[wave tracker](implementation/graph-flow/wave-tracker.md) records progress and
evidence. Step 1 proved typed authoring in a separate experiment. Step 2 now
provides public serial execution on the persistent store: typed definitions,
conditional routes, cycles, recovery, approval, reconciliation and cancellation.
Step 3 now supports typed durable signals with optional deadlines, managed
subgraphs and agents, shared family budgets/retention, and external-job
submission, scheduled observation, owned cancellation and job/child deadlines.
Step 4 implements typed fork/map/join with private results, failure handling,
shared bounds and retained deadlines/cleanup. Step 5 implements structured LLM,
TypeSafe classifier and MCP adapters, with actual OpenAI/TypeSafe inference
and real local MCP boundary evidence. Step 6's [executed evaluation](implementation/graph-flow/agent-recipe-evaluation.md)
retains ordinary agents as managed graph children because the simpler batch
recipe does not preserve per-tool recovery. The full six-step program is
accepted; see the [completion audit](implementation/graph-flow/completion-audit.md).

The architecture follows variant A of
[experiments/workflow_composition/FINDINGS.md](../experiments/workflow_composition/FINDINGS.md):
a Fabric-owned pure controller, a thin OTP runner, and a plain task executor
with one concurrency budget per run. Every accepted transition is committed
before its effects run, a fence commits `Running` before a tool body runs, and
an idle run is data in the store with no process holding it.

## Decisions carried into every slice

- **One ordinary path.** `agent.new(name, model, tools, policy)`, then
  `agent.build`, then `fabric.start(store, agent, context, prompt)`, then
  `fabric.await`. Advanced capabilities are distinct functions
  (`fabric.approve`, `fabric.reject`, `fabric.recover`, `fabric.reconcile`,
  `fabric.child`, `fabric.cancel_stored`, `tool.bind_settling`,
  `store.new`), not flags; bounds default in one `agent.Limits` record.
- **Policy is a required argument.** There is no implicit allow; the named
  `policy.always_allow()` exists for tests and deliberate choices. A policy
  error, crash, or missing decision within `agent.Limits.policy_timeout` is a
  host failure (fail closed).
- **One action shape for the gate.** `policy.Action` identifies the run, turn
  ordinal, provider call id, target name, and exact validated arguments. Slice
  2 adds a sub-agent start as another target of the same gate without changing
  existing fields.
- **Arguments are validated before policy.** An unknown tool or malformed
  arguments are model-visible outcomes and never reach the policy or the
  handler. This diverges from lab decision D6, which treats an input decode
  failure as a host failure: here the model produced the bad input and can
  correct it, and no effect is possible.
- **Arguments rejected after admission are a host failure.** The arguments
  are decoded again when the tool starts. If they no longer decode, or no
  tool of that name is registered, the host's tool changed between admission
  and start; the model's arguments were valid. The run stops with
  `ToolChanged`, the handler never ran, and nothing is uncertain. Both
  causes share that one variant because both mean the same thing to the
  application. Recovery refuses such a record up front
  (`ToolNotRegistered`, `ArgumentsNotAccepted`), so the host failure remains
  only for a codec that changes behaviour within one runner.
- **Every typed failure is classified.** `tool.bind` requires a classifier
  from the handler's typed error to `Explain(text)` (model-visible) or
  `Uncertain(evidence)` (blocks until reconciled). There is no default: a
  timeout after a request was sent must not look like a clean failure.
- **Crash after the fence is an uncertain effect**, never a retry and never a
  model-visible failure. Output that cannot be encoded is a host failure.
- **Caller-owned conversation.** Fabric keeps each assistant turn as one
  value: text, calls and optional opaque provider data. The adapter translates
  llm_wire's response into this value; the controller stores it unchanged
  before dispatching effects. Once each call has a result, the adapter submits
  the full conversation through ordinary `session.prepare`. This is the same
  path before and after restart. llm_wire validates result coverage and
  provider data; Fabric owns persistence, effect identity and recovery.
- **Budgets.** The model-turn limit counts every attempt, including failed and
  retried calls. Exhaustion retains outstanding state and dispatches no tool
  whose result could not be continued. A token budget counts observed `Usage`;
  a reply without usage under a token budget stops the run with
  `BudgetUnverifiable`; without a token budget, missing usage is counted in the
  snapshot. There is no elapsed-time budget API, so it cannot be silently
  accepted.
- **Ownership.** The application names a `Store` (in memory, a directory, or
  its own backend through `store.new`) and runs its subtree (the store's
  process and the factory its runners start under) under its own
  supervisor (`store.supervised`), or linked to the caller (`store.start`)
  in a script or test; any process uses the same value, so a run outlives
  the process that started it. A runner exists only while model or tool
  work is in flight; it is a temporary child of the factory, monitors the
  store process that was running when it was claimed, and stops when that
  process goes. A restarted store process knows no runner: its runs with
  work in flight are `Unattended` until recovered. On shutdown a runner
  drains and hands its run off before the store's process stops (S2,
  below). The runner
  traps exits; the executor and the model task are linked to it, and tool
  tasks to the executor, so killing the runner kills them all and a task that
  dies becomes a message to the runner. The model task is linked rather than
  monitored for exactly that reason: a monitor would let it outlive a killed
  runner.
- **Claim in the commit that hands out work.** A runner is registered in the
  same store step that commits the state giving it work, and released in the
  commit that leaves nothing in flight. There is never a moment where the
  record needs a runner the store does not know, and a watcher woken by the
  idle commit already sees no runner. A command that loses a commit to a
  newer owner reads the newer record and is validated again.
- **Runner loss is reported, not waited on.** When a runner dies while its
  record still needs one, the store drops its registration and wakes every
  `await`, which then returns `Ok(Unattended)`. A command is first checked
  against the stored record, so a refusal is reported as such; a valid
  command that needs the absent runner returns `RunUnattended` and changes
  nothing;
  `cancel` needs no runner. Unleased stores require explicit recovery when
  the previous owner is known to be gone. Leased stores coordinate through
  per-run leases; the S5 sweeper recovers expired work automatically.
- **Transient store failures are retried, not taken as a takeover.** After an
  `Unavailable` write the store reads the run back and confirms a write
  that landed; a runner tries an `Unavailable` commit again (six times,
  backoff doubling from 10 ms) and stops only on a conflict. Backend calls
  run in worker processes, serialised per run and bounded by 5000 ms, so a
  hung call holds up only its own run.
- **A task that dies without a report** (killed from outside) is recorded as an
  uncertain effect, whether or not its fence was committed.
- **Model retries back off.** A retryable model failure is retried after
  `agent.Limits.model_retry_delay` (default 200 ms), doubling per consecutive
  failure up to 64 times; the wait is inside the model task, so a cancel ends
  it. Every attempt counts against the turn limit.
- **Answers are authenticated by the application.** `fabric.approve` and
  `fabric.reject` record the `reviewer` they are given as is. The
  application authenticates and authorizes the reviewer before calling
  them; Fabric checks only that the reference is current and, for an
  approval, that the policy, run again with the context the application
  passes, still allows the action. A rejection runs nothing and is not
  rechecked, so it takes no context.
- **An approved action runs with the context that passed the recheck**
  (oversight `fabric-design.md` §0, "approved invocation retains the same
  context used by the recheck"). The approved tool's body, or the approved
  sub-agent's child run, receives exactly the context given to `approve`,
  whether a runner was live or the answer started one. It never becomes the
  run's context: the run's other actions, and its later model turns, keep
  the context the run was started or recovered with. Mechanism: the effects
  of a step run with that step's context (`live.Work`); the runner applies
  its own events with the run's.
- **An approved action not yet started when its runner is lost is asked for
  again.** The context is a live value and is never stored, so after a
  restart an approved-but-queued tool, or an approved sub-agent start whose
  child was never stored, has no context that passed a recheck. Recovery
  does not run it with the `recover` context (a stored approval alone does
  not authorize a later incarnation, §0): it becomes a new approval request
  under the requirement last answered, the old reference is stale, and the
  earlier answer stays in the action's approvals, authorizing nothing. This
  was chosen over rechecking with a context passed to `recover`, which would
  let whoever recovers stand in for the reviewer.
- **A sub-agent's context after its first runner.** A child started by an
  approved start runs with the approved context while its first runner
  drives it. Work later started through a handle (an answer to the child's
  own approval, a reconcile) runs with that handle's context, which for a
  child is its parent handle's, as for any run whose runner a command
  starts. Keeping the approved context for the child's whole life would
  need a stored context, which the design excludes.
- **A superseded answer is kept.** When the recheck asks for another
  requirement, the answer stays in the action's approvals (it authorizes
  nothing) and the new request is issued.
- **A sub-agent is a delegation, gated like a tool.** `agent.with_sub_agent`
  declares a typed definition whose call starts a child run; the policy sees
  `policy.StartAgent(name, version)` as the action's target. The child shares
  the parent's context type and store and has its own agent, budgets, and
  policy. An allowed delegation is committed `Running` with its child run id
  (`<parent id>-<n>`, deterministic) before the child is stored, then
  `Delegated` once it is: the child record never exists before the start is
  allowed, and a crash in between leaves a named, missing child that
  recovery starts.
- **No second owner of a child's state.** The child owns its approvals and
  effects. Nothing is mirrored into the parent's record; `await`,
  `snapshot` and `pending` read the family (the parent and its active
  children), so a child's pause is the parent's pause (anti-oracle B1) and
  `approve`, `reject` and `reconcile` route by the reference's run. A delegated action needs no runner; the child delivers
  its end to its parent's delegation, keeping its store registration until
  it has, so a family is never seen ended, unreported, and ownerless. A child
  that ended with an unreconciled uncertain effect, or cannot be read or
  continued, makes the delegation an uncertain effect.
- **A parent ends after its children.** Cancelling (or a host fault) moves a
  run with active children to `Stopping` and cancels each child through the
  store, from a separate process (the child's runner may be delivering to
  the parent at that moment); the run ends once no tool runs and no child is
  active. An end that arrives after that is refused.
- **Observations are derived from committed transitions.** The runtime
  compares the state before and after every successful commit and emits
  Sinal events with `sinal.emit`, which follows forwarder routes; the controller emits
  nothing. Handlers run in the committing process unless the application
  routes `[fabric]` through a forwarder. A command is answered before its
  commit's events are emitted, and a runner that does not take a command
  within the command timeout refuses it (`RunnerBusy`).
- **A tool may settle its result after its task was stopped.** A tool
  bound with `tool.bind_settling` receives a typed `Settlement(output)`. A
  stopping run waits for the settlement of each stopped settling tool, up to
  its bound; an uncertain action accepts one definite settlement, like a
  reconciliation of exactly that action. The first accepted settlement is
  the only one; anything else is `NotAwaited` and changes nothing.
- **Saga stays optional.** A Saga workflow becomes a tool through the
  separate package `integrations/fabric_saga`, so Fabric does not depend on
  Saga (oversight `fabric-design.md`, package ownership).

## Production runtime: limits, supervised runners, leases

The [production-readiness program](implementation/production-readiness/wave-tracker.md)
implements a complete local verification command, S7 operations and a
realistic [application comparison](implementation/production-readiness/writing-comparison.md).
The user deferred library publication and
hosted CI activation; [verification](VERIFICATION.md) records the prepared gate
and the remaining activation steps.

The accepted production-runtime design (2026-09-28, at `7901edb`; user
decisions D1 to D5) is built in slices. This section records the slices
built so far (S1 to S7). The optional Grind integration follows in S8.
S7 acceptance and operational procedures are linked below. [Remaining work](REMAINING.md) consolidates the
current backlog; the earlier slice sections retain their historical findings.

### S1: limits

- **Timer-fed limits are validated.** Erlang crashes a receive whose
  timeout is 2^32 ms or more (`timeout_value`). `agent.build` reports
  `PolicyTimeoutTooLarge(value, limit)` and `CommandTimeoutTooLarge(value,
limit)` above 2^32 - 1, and `ModelRetryDelayTooLarge(value, limit)` above
  (2^32 - 1) / 64, since the delay doubles up to 64 times
  (`timer_fed_limits_must_fit_a_timer_test`, runner_test). Every other
  value that feeds a timer was checked: the settlement bound was already
  validated (`SettlementBoundTooLarge`), `fabric_saga`'s `rollback_within`
  is that bound, the store's backend timeout is internal, and the store
  retries use constants.
- **`await` waits in parts.** A `within` of 2^32 ms or more is waited at
  most 2^32 - 1 ms at a time until its deadline; no API change
  (`an_await_longer_than_a_timer_returns_the_outcome_test`, durable_test).
- **The directory store is for development, tests and one host** (D4). It
  survives a process or VM crash, not a power loss or an operating-system
  crash: flushing the directory entry needs a NIF (`file:open` of a
  directory is `eisdir` in every mode), which Fabric does not ship.
  Production uses a database backend through `store.new`; the Postgres
  adapter is slice S4. The `store` and `fabric` module documentation, the
  README and CAPABILITIES say so.

S1's gates passed against llm_wire `a822ea4`, json_blueprint `ecf5c60`,
sinal `858dfa3` and saga `4a93b04`, each with a clean working tree. Sinal
`858dfa3` counts sends dropped while a forwarder is down (`Dropped`'s new
`unavailable`); Fabric names no `Dropped` field, so only the
`fabric/observation` documentation changed.

### S2: supervised runners and graceful drain

One node, the directory store; D3: a draining node finishes running tools
and hands off. Leases come in S3, so here "hand off" means committed and
runner-less, ready for `fabric.recover`.

- **Runners run under the store's subtree.** `store.supervised(store)`
  keeps its signature and returns a supervisor (3 restarts in 5 s) of the
  store's process (a permanent worker given 5000 ms to stop) and, after it,
  a `factory_supervisor` whose temporary children are the runners, each
  given the drain window to stop. Runners start under the factory instead
  of `spawn_unlinked`. Kept: a runner is pinned to the store process it
  was claimed through and stops when that process goes; the claim
  protocol; the held-runner kill on cancel; the cancellation committed to
  the record (X2).
- **The drain window** is a validated setting on the store:
  `store.with_drain(store, milliseconds) -> Result(Store, DrainError)`,
  1 to 2^32 - 1 ms, default 25 000. A setting on the `Store` value, like the
  backend, keeps `supervised` and `start` unchanged; a `Result` rather than
  a list of errors because it checks one value.
- **Drain.** The factory's `shutdown` makes a runner start nothing new (no
  model call, tool body or child; a tool task at its fence is refused and
  its action stays queued), while it keeps applying tool reports, a model
  reply in flight and commands. Once no tool body runs and no reply is
  awaited it commits `controller.hand_off` of its state, giving the run
  up in that commit (`Release`), and exits. The handoff gives back the turn
  of a model call never issued (`turns_used = turn - 1`; `recover` issues
  `turns_used + 1`, the same turn), keeps queued tools queued, and asks
  again for an approved tool that never started. The record's shape is
  unchanged (version 3): `turns_used` and the awaiting turn are separate
  fields, which every reader (versions 1 to 3) decodes independently, and
  recovery has always recomputed the turn from `turns_used`
  (`a_handoff_before_the_model_call_gives_the_turn_back_test`,
  controller_test). A runner still busy at the end of the window is killed
  by the factory; its running tools become uncertain at recovery, as before.
- **Settling tools and children (decided here).** A stopped tool awaiting
  its late settlement is waited for like a running body, within the
  window. A child run is its own run, drained by its own runner; the
  parent's delegation stays `Delegated`, and recovering the parent
  recovers the child. A child start the drain withheld leaves its
  delegation `Running` with a child id and no child record, which
  recovery handles as after a crash (starts it, or asks again for an
  approved start).
- **Commands during a drain** are taken and committed, but start nothing:
  an approval the draining runner takes is asked for again at the
  handoff. A launch while the store's runners drain commits its work
  with no runner, which reads `Unattended`; this keeps a runner delivering
  its end to an idle parent from waiting on the factory that waits for it.
  (Fixed after review, below: the store now learns of the drain before
  any runner is signalled.)
- **Suspended and finished runs** have no process and are untouched.
- **`store.start`** starts the same subtree through a keeper process linked
  to the caller: a subtree that fails to start is `Unavailable` rather than
  an exit signal to the caller, and a caller that exits stops it. Its
  store's process stops at once when the caller exits, so its runners stop
  without draining, as when a node stops: tests and scripts that simulate
  a crash by killing the starter keep that meaning.
- **Observation.** `run_handed_off` (`[fabric, run, hand_off]`, run and
  incarnation) follows a handoff's commit. The aggregate `drain` event
  (handed off, killed) is deferred to S7: a killed runner cannot report,
  and the store's process has no terminate step to count them.

Tests: drain_test
`a_stop_lets_a_running_tool_finish_and_hands_the_run_off_test`,
`a_tool_past_the_drain_window_is_uncertain_and_never_rerun_test`,
`an_approved_queued_tool_is_asked_for_again_after_the_handoff_test`,
`a_stop_waits_for_the_model_reply_in_flight_test`,
`a_suspended_run_is_untouched_by_a_stop_test`,
`a_store_stops_after_its_draining_runners_test`,
`a_child_run_drains_on_its_own_and_is_recovered_with_its_parent_test`;
`a_restarted_store_leaves_its_runs_unattended_until_recovered_test`
(supervision_test, now also starting a run after the restart);
`a_drain_window_must_be_positive_and_fit_a_timer_test` (store_test);
`a_drained_run_is_observed_handed_off_test` (observation_test).

Deviations from the accepted design, each the smallest safe variant:

- **One for one, not rest for one.** A rest-for-one restart of a crashed
  store's process terminates the factory with the drain window, so one
  runner busy in a synchronous call (a policy decision, a command to
  another runner) delayed the store's restart, and with it every `await`
  and command, by up to the window
  (`a_runner_never_commits_through_a_restarted_store_test`, whose runner
  is suspended, saw no restart within its 5 s).
  Runners already stop when their store process stops, so restarting the
  factory adds nothing. The shutdown order, factory before store, is the
  same under both strategies.
- **The factory's name is derived from the store's name**
  (`<name>$runners`), not made with `process.new_name` when the `Store` is
  built: two `Store` values built with one name (one for the supervisor,
  one for requests) would otherwise name two factories, and every launch
  through the second would find none and leave its run `Unattended`.
- **The handoff does not release a lease** (none exists before S3) and
  emits `run_handed_off` rather than a `drain` summary (above).
- **An in-flight model call includes its retry wait.** A model task
  sleeping before a retry is waited for like a call in flight, up to the
  window, rather than distinguished from an issued call.

After S2, public items per module (types and functions, `@internal`
excluded): `fabric` 17, `fabric/agent` 11, `fabric/llm` 1, `fabric/model`
9, `fabric/observation` 33, `fabric/policy` 5, `fabric/run` 22,
`fabric/store` 11, `fabric/testing` 1, `fabric/tool` 10: 120 in all.

S2's gates passed against the same sibling revisions as S1's.

### Review of S1 and S2

An independent review of `7901edb..03fd943` found S1 sound and these in
S2; each is fixed test-first or deferred:

- **Fixed: a start during the drain could deadlock it (major).** The
  store learned of a drain only when the first runner handled its own
  shutdown; until then a runner could call `factory_supervisor.start_child`
  (a child start, a delivery to an idle parent, a handler's `start`),
  which waits for the stopping factory that waits for that runner, until
  the window killed it and a finished tool's result was lost. A sentinel
  child stopped before the factory now tells the store's process first,
  and a runner that already holds the factory starts through a helper and
  gives the start up on its own shutdown (`823e407`;
  `a_delegation_approved_ahead_of_the_stop_does_not_hold_up_the_drain_test`,
  `a_delegation_decided_during_the_stop_does_not_hold_up_the_drain_test`).
  A draining runner also applies the reports of effects it performed (a
  child it started) before its handoff.
- **Fixed: a retry backoff during the drain (minor).** The model task
  takes a claim before calling the model; a draining runner that withdraws
  it first stops the task, and the handoff gives the turn back (`484570d`;
  `a_retry_backoff_is_not_waited_for_and_its_turn_is_given_back_test`).
- **Documented, event deferred to S7: a failed handoff (minor).** A
  handoff whose commit fails leaves the record as a lost runner does; an
  unissued model call then keeps its turn charged, and recovery counts one
  turn more. The runner and `store.supervised` documentation say so; S7's
  drain summary will count failed handoffs.
- **Fixed: `fabric.recover` documentation (nit):** approved queued tools
  ask again rather than being dispatched.
- **Fixed: the factory's name (nit)** is made when the subtree starts,
  never for a request-only `Store` value, and the `$runners` suffix is
  documented as reserved.
- **Fixed: missing tests (nit):** two `Store` values of one name
  (`two_store_values_of_one_name_share_the_runners_test`) and a start
  racing the shutdown (the two drain tests above).

### S3: the leased store contract, with an in-memory leased backend

D1: several nodes share one database and coordinate only through per-run
leases (an owner and an expiry judged by the backend's clock); D2: a
command that needs another node's live runner is `RunUnattended` with
nothing changed; D3: a drained handoff releases the lease as already
expired. Two leased stores of distinct node ids over one in-memory leased
backend simulate two nodes in one VM.

- **The contract** (`fabric/store`, Leases). A `LeasedBackend` adds
  `renew(owner, runs, ttl)` and `claim_expired(owner, ttl, limit)` to get,
  insert and compare-and-set, whose writes carry a `Lease` checked in the
  same atomic step as the revision (revision first): `Hold(owner)` only
  while `owner` holds it (live or expired), `Claim(owner, ttl)` only while
  it is free, `owner`'s or expired, `Seize` and `Release` always. `get`
  reports the `Holder` (`Free`, or `Held(owner, live)`). Renewal and
  `claim_expired` change no revision; concurrent `claim_expired` calls
  never return the same run. `fabric/testing.leased_backend_checks(new)`
  is the conformance suite (nine checks), which the Postgres backend will
  run too (`the_in_memory_leased_backend_conforms_test`,
  `a_backend_that_ignores_live_leases_fails_the_claim_check_test`,
  lease_backend_test).
- **A leased store** (`store.leased(name, node:, lease:, backend:)`)
  identifies its process as `<node>/<store name>/<random>`, new at each
  start. A commit that gives work to a new runner claims the lease (a
  cancellation seizes it); every commit that keeps work in flight holds
  it, the tool fence included, so a runner whose lease another owner
  claimed starts no body
  (`a_tool_start_is_refused_once_another_owner_claimed_the_lease_test`); a
  commit that leaves nothing in flight releases it with the revision check
  alone; work committed with no
  runner (a draining store) and a handoff claim it as already expired
  (`a_handoff_releases_the_lease_as_already_expired_test`)
  (`a_runner_holds_its_runs_lease_while_it_works_test`).
- **Renewal and fencing.** The store's process renews its runners' leases
  every lease/3 in one batch; a run the renewal no longer returns has its
  runner killed with its model task and tool bodies, through the kill a
  held runner gets on cancel (`a_lost_lease_kills_the_runner_and_its_running_body_test`,
  `a_cancellation_from_another_node_wins_over_a_live_lease_test`). It
  fences itself on its monotonic clock: a lease is surely held until the
  last successful claim or renewal was sent, plus the lease, minus a fifth
  of it; a runner still alive then is killed
  (`a_store_that_cannot_renew_kills_its_runners_before_their_leases_expire_test`,
  `renewals_keep_a_lease_live_past_its_duration_test`).
- **Across nodes.** A live lease elsewhere reads `Working`
  (`a_live_lease_elsewhere_reads_working_test`); `Unattended` only when work
  is in flight and the lease is free or expired. `recover` never takes a
  live lease and returns the handle unchanged, so it is safe at any time
  (`recover_does_not_take_a_live_lease_test`); racing recoveries take an
  expired lease exactly once
  (`an_expired_lease_is_taken_over_once_by_racing_recoveries_test`); a store
  restarted on the same node and name takes its earlier process's lease at
  once (`a_restarted_store_takes_its_earlier_processes_lease_at_once_test`).
  An approval of an idle run works from any node, which claims the lease
  (`an_approval_of_an_idle_run_on_another_node_claims_the_lease_test`); one
  that needs the other node's runner is `RunUnattended`, nothing changed
  (`an_approval_needing_another_nodes_runner_is_unattended_test`); a
  cancellation from another node wins and the old owner kills its runner
  at its next renewal. `await` reads a leased run again at least every
  lease/3, 10 to 1000 ms (`an_await_on_another_node_sees_the_end_of_the_run_test`).
- **Observation.** `run_taken_over` (`[fabric, run, take_over]`) after a
  recovery commit that took a run from another owner's lease;
  `lease_lost` (`[fabric, lease, lose]`, `Revoked` or `Unrenewed`) after a
  kill; `renewal_failed` (`[fabric, lease, renew, fail]`) after a failed
  renewal. The last two are emitted by the store's process.
- **Unleased stores** (`new`, `in_memory`, `directory`) are unchanged: one
  node, no lease. Twenty durable, approval, cancellation and delegation
  tests run again on a leased store (`leased_suite_test`, through
  `support.leased`), and every earlier test still runs unleased.
- **Settings** (`a_leased_store_checks_its_settings_test`):
  `LeaseConfigError` is `InvalidNodeId` (1 to 128 of letters, digits and
  `._-@:`, not `nonode@nohost`), `LeaseTooShort(value, minimum)` below
  100 ms, `LeaseTooLong(value, limit)` above 2^32 - 1 ms.

Deviations from the accepted design, each the smallest safe variant:

- **`LeaseRefused(holder: Holder)`, not `LeaseHeld(owner: String)`.** A
  `Hold` can fail on a free lease, which has no owner; the holder says both
  cases. It is a new `StoreError` variant (a breaking change for
  exhaustive matches).
- **No `Lease.Keep`.** Every write Fabric makes holds, claims, seizes or
  releases the lease. The internal ownership kinds of a commit were renamed
  (`Leave`, `HandOff`, `Launch`, `Detached`) so the public constructors keep
  the design's names.
- **"Released as already expired" is `Claim(me, 0)`,** keeping the owner
  and setting the expiry to now, not `Release`: a free lease has no owner,
  and `claim_expired` (the sweeper's query) looks only at held, expired
  leases. Work committed with no runner is claimed the same way.
- **The boot fast path** is a `Seize` at the same revision, retried by the
  store's process when a `Claim` is refused by a lease of the same node and
  store name with another random part. `process.new_name` uses a
  VM-local positive integer suffix, which can repeat across VMs and after
  a restart. The fast path covers a restarted process with the same name;
  after a VM restart it applies only if that name is reused. Otherwise
  recovery waits for expiry. Node ids must be unique across live VMs: a
  duplicate node id can cause a live store to be mistaken for an earlier
  process. S4 retains this contract without adding a store-id setting.
- **A lease this store holds, with no runner of it here** (its runner
  crashed), reads `Unattended` on this node, which knows its runner is
  gone, and `Working` on other nodes until it expires; `recover` here takes
  it at once (owner = me).
- **`recover` of a run another node drives** originally left its children
  alone too. S5 refines this: leases belong to individual runs, so an
  expired child can recover beneath a live foreign parent (see S5).
- **The self-fencing margin is a fifth of the lease**, and a renewal is
  bounded by a third of the lease; `renewal_failed` is included (cheap).
- **The conformance suite is in `fabric/testing`** (source, not a test
  module) so that `integrations/fabric_postgres` can run it; each check
  returns a `Result` rather than asserting.
- **The in-memory leased backend** is `testing.leased_memory()`, returning
  `LeasedMemory(backend, advance)`; its process stops when its creator
  exits.

After S3, public items per module (types and functions, `@internal`
excluded): `fabric` 17, `fabric/agent` 11, `fabric/llm` 1, `fabric/model`
9, `fabric/observation` 40, `fabric/policy` 5, `fabric/run` 22,
`fabric/store` 19, `fabric/testing` 3, `fabric/tool` 10: 137 in all.

Also in S3, a regression of the S2 review fix: `store.start` right after a
previous subtree of the same name stopped could find the factory's name
still taken (the sentinel stops before it); `start` now waits up to 5 s
for that factory (`eaa5dbb`).

S3's gates passed against llm_wire `a822ea4`, json_blueprint `ecf5c60`,
sinal `858dfa3` and saga `4a93b04`, each with a clean working tree.

The Postgres backend and its conformance checks are implemented in S4.
Notifications remain a later optimisation: cross-node `await` still polls.
Implemented in S5: the sweeper (`claim_expired`, the boot scan) and a
peer-VM test. Deferred to S7: the drain summary (with failed handoffs) and lease
gauges.

### S4: PostgreSQL store and leased shutdown coverage

Implemented in `integrations/fabric_postgres`, a separate package that
keeps `pog` out of Fabric core. The application owns the pool and passes
its `pog.Connection`; the pool precedes `store.supervised` in a
rest-for-one application supervisor. The store drains before the pool
stops. See the [package README](../integrations/fabric_postgres/README.md)
for the compiled and executed setup example.

The public API:

- `settings(connection, node:) -> Settings`, with a 30 000 ms lease and
  schema `public`; `with_lease(settings, milliseconds) -> Settings`.
- `with_schema(settings, schema) -> Result(Settings, SchemaError)` checks
  the schema identifier before any SQL is built.
- `migrate(settings) -> Result(Nil, MigrateError)` creates the schema and
  applies forward-only numbered migrations in one transaction, under a
  schema-specific advisory lock. `priv/migrations` carries the same
  statements in cigogne format.
- `store(name, settings) -> Result(Store, store.LeaseConfigError)` builds
  the store; `backend(settings) -> store.LeasedBackend` exposes its port
  for wrappers and the shared conformance checks.
- `prune(settings, ended_for:, limit:) -> Result(Int, PruneError)` removes
  whole finished families, oldest first. The limit counts families; the
  result counts rows, including children. Every member must be ended or
  never started, with no live lease. An ended child is never pruned alone.

The schema stores each run's exact record text, revision, phase, root id,
lease owner and expiry, and update time. The paired lease columns have a
CHECK constraint; indexes cover expired leases, ended runs and families.
Each write condition checks its revision and lease in one statement.
Renewal changes only the expiry of a live lease held by that owner.
`claim_expired` locks candidates with `FOR UPDATE SKIP LOCKED`.

Executed acceptance (`integrations/fabric_postgres/test/fabric_postgres`):

| Contract                                                               | Evidence                                                                                                                                               |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Shared leased backend contract, including renewal and competing claims | `conformance_test`: all ten `testing.leased_backend_checks`                                                                                            |
| Idempotent and concurrent migration; schema isolation                  | `migrate_test`, including concurrent callers and a newer schema left alone                                                                             |
| Conditional writes under READ COMMITTED and REPEATABLE READ            | `isolation_test`: a blocked statement produces 40001 under REPEATABLE READ; backend writes read back the committed row; racing writers have one winner |
| Exact record bytes, including escaped NUL                              | `record_test.records_come_back_byte_for_byte_test`                                                                                                     |
| Start, approval pause, store restart, answer, completion               | `fabric_run_test`                                                                                                                                      |
| Two stores and two pools on one database                               | `nodes_test`: a live foreign lease, one takeover of an expired lease, cancellation from the other node                                                 |
| Family-safe pruning and concurrent pruning                             | `prune_test`                                                                                                                                           |
| Documented application setup                                           | `readme_test`: example text matches the compiled module and runs on PostgreSQL                                                                         |

Deviations and scope:

- **`phase` is parsed by the adapter and written with the record.** The
  proposed PostgreSQL JSON-generated column rejects escaped NUL, which a
  model reply or tool result may contain. Record text retains the exact
  bytes; a record without a decodable phase stores NULL and is not pruned.
  `root_id` remains a generated column.
- **`with_schema` returns a checked result; `store` reuses
  `LeaseConfigError`.** A separate configuration error adds no distinction.
  `backend` is public so applications and conformance checks use the same
  implementation.
- **Pruning also checks every family member and its lease.** An ended
  root alone is insufficient evidence that deleting its children is safe.
- **Fresh storage per conformance check.** Each callback creates an empty
  schema; fixed claim limits cannot be consumed by another check's rows.
- **No notification listener or `stats` yet.** Cross-node waits use the S3
  polling path. Notifications are an optimisation; gauges remain S7.
  Sweeper recovery and peer-VM node-loss tests are implemented in S5.
  The write-version window remains S6.

The completion gates passed: core **302**, external consumer **15**, Saga
integration **35**, PostgreSQL integration **25**, with no failures. Each
package passed `gleam format --check src test` and
`gleam build --warnings-as-errors`. The first three ran `gleam test`; the
PostgreSQL package ran only through `scripts/test-postgres.sh`, which
creates and removes a private temporary cluster. Tested versions:
PostgreSQL **16.15**, `pog` **4.1.0**, `pgo` **0.20.0**; sibling revisions
are listed below. The core suite and existing CI do not start PostgreSQL;
`nix flake check` checks repository formatting only. CI still requires the
sibling path dependencies described under slice 1 friction.

### S3 review resolved during S4

The review of `03fd943..634e56a` found no blocker or major finding. Its
remaining findings are resolved as follows:

1. **A renewal could extend a handed-off lease.** Core and PostgreSQL now
   renew only live leases (`966be87`, `23cb7c3`).
   `a_renewal_applied_after_the_handoff_leaves_the_lease_expired_test`
   orders the renewal after the handoff and proves another node can
   recover immediately.
2. **Lease event handlers could block the store.** Events are emitted by
   separate processes (`6aaee83`);
   `a_slow_lease_event_handler_does_not_hold_up_the_store_test` checks a held
   handler. The observation module documents the emitting process.
3. **Shutdown could queue behind work.** The runner takes a queued shutdown
   before other messages (`1aa085a`);
   `a_shutdown_queued_behind_a_report_is_taken_first_test` proves the
   queued tool does not start before recovery.
4. **A tool starting a run could deadlock the drain.** Waiting starts
   check the store's drain state every 100 ms and give up when it stops
   accepting runners (`4e50f43`).
   `a_tool_body_starting_a_run_during_the_stop_does_not_hold_up_the_drain_test`
   preserves the tool's result and the unattended new run.
5. **Backend checks could claim each other's old rows.** The contract
   requires a fresh empty backend per check (`8684f6a`); the suite also
   checks a `Hold` racing `claim_expired`.
6. **The adjustable clock belonged in test support.** `LeasedMemory` and
   `leased_memory` now live in `fabric/testing` (`5d4e645`). This changes
   the unreleased API; callers use `testing.leased_memory()`.
7. **Drain coverage ran only on directory stores.** The twelve drain
   scenarios also run on a leased backend that survives the store's
   subtree. They cover children, reapproval, model replies, exhausted
   windows and shutdown races. A separate two-node test proves a start
   committed during drain is immediately recoverable elsewhere.
8. **Generated names were described as unique across restarts.** The S3
   deviation above now states their VM-local scope. The node-id contract
   stays unchanged; no store-id setting is added.
9. **Documentation overstated the lease condition.** A commit that keeps
   work in flight requires ownership; a final release uses the revision
   check alone. README, CAPABILITIES and `store.leased` now say this.
10. **Immediate local recovery was undocumented.** `store.leased`,
    `fabric.recover` and status documentation explain that this store's
    own lease can be taken at once when its runner is gone.
11. **An in-flight renewal could lose the next tick.** A tick received
    during renewal is made up when it completes (`c67cfec`);
    `a_tick_during_a_renewal_is_made_up_when_it_completes_test` verifies
    the next renewal starts without waiting another interval.

### S5: automatic recovery of expired leases

`fabric.recovery(agent, context_for_run)` retains a root agent and a typed
context constructor behind an opaque `Recovery`. `fabric.sweeper` validates
the interval, duplicate root identities and leased store, then returns an
OTP child specification. A rest-for-one application supervisor starts pool,
optional forwarder, store, then sweeper; shutdown reverses that order.

- **Bounded scans.** The first scan starts at boot; subsequent scans start
  `every` milliseconds after the previous scan finishes. Each claims at most
  100 expired runs, resolves their checked parent records to root identities,
  and groups candidates from one root into one recovery attempt.
- **Contained failures.** Context construction has 5 seconds and each root
  recovery has 30 seconds. Unknown identities, unreadable records, crashes
  and timeouts leave the claim to expire without preventing another root's
  recovery. A guardian kills a blocked callback on timeout or caller death,
  including callbacks that trap exit signals.
- **Store incarnation.** The sweeper pins the running store process and
  stops if that process dies. Restart obtains the new process; shutdown
  stops a pending context before the store drains.
- **Independent family leases.** An expired child can be claimed separately
  from its parent. Recovery traverses eligible children under a live foreign
  parent, and takes over an expired stopping child during cancellation.
- **Parent delivery.** A leased parent reads terminal child outcomes in one
  linked worker at a time and applies them with its own context. A slow read
  does not block its receive loop; a failed read changes nothing and reports
  arriving after drain starts are ignored.
- **Acknowledgement.** An ended child's retained lease lets a later scan
  retry delivery. Only after its parent no longer awaits that action does
  the sweeper release the lease with a revision check.
- **Observation.** `observation.sweep` reports claimed runs, recovered
  candidates, unmatched root identities and failures. A synchronous handler
  has 1 second; expired-lease age and the remaining operations gauges belong
  to S7 because the current backend contract returns ids without timestamps.

Refinements from the proposal:

- A live foreign root cannot imply ownership of every child: concurrent
  claims can split a family. Per-run recovery and parent polling preserve
  D1 without moving the parent's context or adding distributed messaging.
- The expired-only backend query cannot discover an unexpired prior local
  lease. Automatic recovery waits for expiry after a local restart too;
  explicit `recover` retains the immediate known-id boot fast path. No
  additional backend listing contract is introduced.
- Configuration also rejects unleased stores and intervals above 2^32 - 1.
  Counts include failures separately; recovery counts actual candidate
  incarnation changes or acknowledged terminal candidates, not a successful
  call that did no work.

Acceptance evidence: `sweeper_test` covers boot and periodic scans, live
lease protection, concurrent sweepers, unknown/corrupt records, crashing and
blocked contexts, store restart, shutdown and non-overlapping scans.
`family_lease_test` covers completion and cancellation beneath a live
foreign parent and acknowledgement cleanup. The PostgreSQL `peer_test`
starts a second VM over standard I/O, verifies its live lease, kills the VM
with SIGKILL, and recovers exactly once after expiry; the interrupted tool
is uncertain, never replayed, and reconciliation lets the run finish. A misfiled record is rejected before
context construction; the decoded run id must equal its storage key.

Completion gates: core **313**, external consumer **15**, Saga integration
**35**, PostgreSQL integration **26**, all passing. Every package passed
format checking and warnings-as-errors compilation; PostgreSQL ran only
against the temporary cluster. The repository formatting gate also passed.

### S6: record write-version window

This section records S6 as delivered. The later library adoption extends
the format to version 4 and guards writes to earlier formats.

`store.with_record_version(runs, version)` returns a configured `Store` or
`UnwritableVersion(requested, oldest, newest)`. Writers support versions
2 and 3, defaulting to 3; readers accept versions 1–3 independently of
that setting. Version 1 is outside the write window because it cannot
represent sub-agents.

Every runtime write uses the selected version: root and child starts,
answers, tool results, cancellation, missing-child tombstones, shutdown
handoffs, recovery and the sweeper's terminal-child acknowledgement. Each
logical write is encoded once, so retries and lost-reply confirmation
retain the exact text and write token.

Version 2 represents `NeverStarted` as `Ended(Cancelled)` with an empty
transcript. The current reader restores `NeverStarted`, while the frozen
old reader reads its original cancelled representation. Two states cannot
be written in version 2 without changing meaning: an ordinary cancelled
run with an empty transcript, and a never-started run with a nonempty
transcript. The encoder refuses them through the existing store-error
path before writing. The runtime does not produce either state.

Refinement from D5: configuration belongs to the `Store` value, like the
drain setting. Configure before startup and use the returned value for
all handles and the sweeper. It does not reconfigure existing runners,
change other values, or migrate rows. A rollout deploys writers set to 2,
then restarts with writer 3 after all readers understand it. Previously
written version-3 rows still prevent rollback to a version-2 reader.
Record compatibility does not establish compatibility between different
backend or lease protocols.

Acceptance evidence: `write_version_test` covers unsupported versions,
approval and tool execution, reads and writes across both writer settings,
missing-child cancellation, drain and restart, sweeper recovery without
tool replay, and `cancel_stored`. `record_test` checks every representable
phase and action state against the frozen version-2 decoder from
`570502e928496b0203909f164a5e8fd021b8ddc8`, with its original domain types
in `test/fabric/support/v2`. PostgreSQL tests exercise public configuration,
an upgrade from version 2 to 3, and exact-byte lost-reply confirmation with
each writer.

Completion gates: core **323**, external consumer **15**, Saga integration
**35**, PostgreSQL integration **28**, all passing. All four packages
passed format checking and warnings-as-errors compilation; PostgreSQL
used only its temporary cluster. The repository formatting gate passed.
An independent review found no encoding bypass and verified the frozen
decoder and domain declarations against their historical source.

### S7: production operations

Completed 2026-09-30 under the [production-readiness program](implementation/production-readiness/wave-tracker.md).
The [operations contract](implementation/production-readiness/operations.md)
records O1–O16; the [runbook](OPERATIONS.md) ties diagnosis and response to the
implemented APIs. Historical S2–S6 deferrals above are resolved by this slice.

- `store.readiness` performs a bounded backend probe and samples current
  admission and lease evidence afterward. Idle stores need no successful renewal;
  active runners need safe lease windows. Reporting changes no execution state.
- `fabric_postgres.stats` reports individual run groups and record-write ages,
  overlapping approval/reconciliation counts, explicit unknowns, budget records,
  live leases by node and oldest expired-lease backlog. One SQL read shares one
  snapshot and clock. Schema 7 stores a revision-matched diagnostic projection;
  bounded refresh leaves execution bytes, revisions, leases and ages unchanged.
- `observation.drain` reports the supervised shutdown cohort after the factory
  stops, while the store remains available. Confirmed, failed and pending handoffs
  are independent of forced and other exits; unavailable accounting is a distinct
  event. A killed runner need not report itself. Collection and emission are
  bounded, and reporting never grants effect authority.
- The runbook covers startup/migration order, node identity, gauge meanings,
  lease/sweep tuning, shutdown budgets, rolling format windows, unknown recovery
  identities, external reconciliation and complete-family retention.

Acceptance: the complete local gate passed all 41 checks at
`/tmp/fabric-shutdown-full-gate`, including 650 core and 64 PostgreSQL tests.
Twelve public shutdown scenarios supplement the readiness/statistics and existing
recovery suites. No execution record format or runtime dependency changed.
Hosted CI and publication remain explicitly deferred by the user. The realistic
application comparison has its own acceptance evidence, separate from S7.

## Library adoption: caller-owned conversations

Accepted on 2026-09-29 after review of llm_wire's
`docs/caller-owned-conversation.md` and `docs/fabric-migration.md`. Fabric
already owned its transcript; it never stored a wire continuation. This
change preserves the provider data that the previous adapter discarded.

- **One assistant value.** `model.AssistantTurn(text, calls, data)` is carried
  by `ToolRequest(turn, usage)` and `AssistantMessage(turn)`. Plain models use
  `None`; an adapter uses `ProviderData(format, value)`. The controller stores
  the whole turn before dispatch and appends results only after each call
  has a definite, model-visible outcome. Effect identities remain scoped by
  Fabric run and round, so provider call ids may repeat across rounds.
- **Adapter-owned meaning.** `fabric/llm` encodes the provider identity,
  response id and raw provider data under the versioned `llm_wire.turn.v1`
  tag, with llm_wire's `message.turn_replay_to_json` since llm_wire's wave 4
  (records written before also carry the reported call issues, which the
  decoder ignores). Text and calls have one authoritative copy in
  the assistant turn. Fabric's controller and store do not interpret the
  envelope; the adapter checks its format and reconstructs a wire turn,
  then llm_wire checks provider origin, result coverage and raw signed data.
  Invalid or unsupported envelopes fail before provider I/O. Credentials,
  configuration, output codecs and live handles are never stored.
- **Record version 4.** Each assistant message gains a required nullable
  `data` field. Readers accept versions 1–4; older transcripts have no data.
  Writers default to 4 and retain versions 2 and 3 for representable states.
  A transcript with provider data cannot be written as 2 or 3; even a record
  retagged as an older version is rejected if it carries provider data. A
  refused response commit dispatches no tool and leaves the run unattended,
  recoverable through a version-4 writer. Deploy compatible readers before
  enabling the new wire-backed tool turns. This expands S6's write window
  without silently removing previously supported settings.
- **Retry policy.** Preparation failures stop. For execution failures the
  adapter calls `retry.assess` with the prepared request's provider. Only
  `MayHelp` permits another attempt; `Unknown` and `WillNotHelpUnchanged`
  stop. Every attempt still spends a turn, and cancellation and uncertain
  tool effects retain their existing behavior. Reachability evidence remains
  separate from the prospect that retrying could help.
- **Blueprint and playback.** Schema descriptions reach provider requests
  without changing validation. Fabric already uses Blueprint's public
  decode-error renderer. Wire cassettes substitute transport in the same
  `llm.model` flow; a cassette is a test fixture, never a run checkpoint.

The public model constructors change directly; no compatibility wrappers
retain their former signatures. Legacy stored records remain readable.
Streaming and structured final answers remain separate backlog features.

Acceptance: `record_test` covers opaque data round trips, malformed envelopes
and downgrade refusal; `write_version_test` proves refusal before a tool
starts and recovery through writer 4 with one effect. `llm_test` covers
invalid call issues and refusal of unsupported or corrupt adapter data
before I/O. `llm_recovery_test` covers signed Google text, image and call
parts through an approval pause and a real directory-store restart;
repeated provider ids across distinct rounds; HTTP 501 versus 503 and
turn budgets; Blueprint descriptions; and a disk cassette through the
public Fabric flow. The PostgreSQL tests cover upgrade from 2 to 4 and
exact-byte lost-write confirmation with the current writer.

Completed on 2026-09-29. Formatting, warnings-as-errors builds and all four
package suites passed: Fabric **333**, consumer **15**, Saga **35** and
PostgreSQL **28** tests (**411** total). PostgreSQL used a throwaway 16.15
cluster. Provider tests used local transports and fixtures; no live provider
credentials were needed. See the tested sibling snapshot below.

## Public API (slice 3: ergonomics pass)

The current public surface. The sections after this one are the history
of earlier slices. The pass followed the accepted proposal (2026-09-28, at
`e5e27f2`): an agent is described by a `Spec` and checked once by `build`,
with every bound in `Limits`; one policy gate, which matches a tool with
`tool.input`; a named store that a supervisor can run. Principles: every
effect passes the one policy, every command names its run by a reference
checked against the stored record, a value is validated where it is made
(`agent.build`, `run.parse_id`), a result type lists only what can
happen, safety decisions are required arguments, and an advanced
capability is a distinct function, never a flag. The ergonomics pass itself did not change stored records. The later
library adoption above adds version 4 and changes the model reply surface.

```gleam
// fabric — runs and the commands on them
pub opaque type Run(context)
pub type StartError { StartUnconfirmed(id: RunId, reason: String)  StartRefused(reason: String) }
pub type RecordError { RunNotFound  StoreUnavailable(reason: String)  UnsupportedVersion(found: Int)
                       CorruptRecord(detail: String)  IncompatibleAgent(List(Incompatibility)) }
pub type CommandError { RunEnded  WrongReference  StaleReference  AlreadyAnswered
                        RequirementChanged(PendingApproval)  NotReconcilable  RunUnattended
                        RunnerBusy  Contended  Unreadable(RecordError) }
pub fn start(store: Store, agent: Agent(c), context: c, prompt: String) -> Result(Run(c), StartError)
pub fn open(store: Store, agent: Agent(c), context: c, id: RunId) -> Result(Run(c), RecordError)
  // reads and checks the record; never takes the run over or starts a runner
pub fn recover(store: Store, agent: Agent(c), context: c, id: RunId) -> Result(Run(c), CommandError)
  // takes over work whose runner is gone; a leased store leaves live foreign leases alone
pub opaque type Recovery
pub fn recovery(agent: Agent(c), context: fn(RunId) -> c) -> Recovery
pub type SweeperError { EveryNotPositive(Int) EveryTooLarge(Int, Int) DuplicateRecovery(run.Identity) StoreNotLeased }
pub fn sweeper(store: Store, recoveries: List(Recovery), every milliseconds: Int) -> Result(supervision.ChildSpecification(Nil), List(SweeperError))
pub fn id(run: Run(c)) -> RunId
pub fn child(run: Run(c), id: RunId) -> Result(Run(c), RecordError)
pub fn await(run: Run(c), within: Int) -> Result(Status, RecordError)   // Ok(Working) at the deadline
pub fn snapshot(run: Run(c)) -> Result(Snapshot, RecordError)
pub fn pending(run: Run(c)) -> Result(List(PendingApproval), RecordError)
pub fn approve(run: Run(c), reference: ApprovalRef, reviewer reviewer: Option(String), context context: c)
  -> Result(Status, CommandError)
pub fn reject(run: Run(c), reference: ApprovalRef, reason reason: String, reviewer reviewer: Option(String))
  -> Result(Status, CommandError)
pub fn reconcile(run: Run(c), effect: ActionRef, content: String) -> Result(Status, CommandError)
pub fn cancel(run: Run(c)) -> Result(Status, CommandError)
pub fn cancel_stored(store: Store, id: RunId) -> Result(Status, CommandError)

// fabric/agent — pure configuration, checked once
pub opaque type Spec(context)
pub opaque type Agent(context)   // only build makes one
pub type Limits { Limits(max_turns: Int, max_concurrency: Int, token_budget: Option(Int), max_children: Int,
                         max_depth: Int, policy_timeout: Int, model_retry_delay: Int, command_timeout: Int) }
pub type ConfigError { DuplicateToolName(String)  InvalidToolName(String)  ToolSchemaUnavailable(String)
                       SettlementBoundNotPositive(name, within)  SettlementBoundTooLarge(name, within)
                       MaxTurnsNotPositive(Int)  MaxConcurrencyNotPositive(Int)  TokenBudgetNotPositive(Int)
                       PolicyTimeoutNotPositive(Int)  ModelRetryDelayNegative(Int)  CommandTimeoutNotPositive(Int)
                       PolicyTimeoutTooLarge(value: Int, limit: Int)  CommandTimeoutTooLarge(value: Int, limit: Int)
                       ModelRetryDelayTooLarge(value: Int, limit: Int)   // added in S1
                       InvalidIdentity(name, version)  MaxChildrenNegative(Int)  MaxDepthNegative(Int)
                       MaxChildrenTooLarge(value: Int, limit: Int)  MaxDepthTooLarge(value: Int, limit: Int) }
pub fn default_limits() -> Limits   // 8 turns, 4 tools at once, no token budget, 4 children, depth 1,
                                    // 5000 ms policy and command timeouts, 200 ms first model retry
pub fn new(name: String, model: Model, tools: List(Tool(c)), policy: Policy(c)) -> Spec(c)   // version 1
pub fn with_version(spec: Spec(c), version: Int) -> Spec(c)
pub fn with_system_prompt(spec: Spec(c), text: String) -> Spec(c)
pub fn with_limits(spec: Spec(c), limits: Limits) -> Spec(c)
pub fn with_sub_agent(spec: Spec(c), definition: Definition(i, o), to child: Agent(c),
                      prompt prompt: fn(i) -> String, output output: fn(String) -> Result(o, String)) -> Spec(c)
pub fn build(spec: Spec(c)) -> Result(Agent(c), List(ConfigError))

// fabric/tool — typed application tools
pub opaque type Definition(i, o)   pub opaque type Tool(c)   pub opaque type Settlement(o)
pub type Failure { Explain(message: String)  Uncertain(evidence: String) }
pub type SettleError { AlreadyRecorded  NotAwaited  SettleUnconfirmed(reason: String) }
pub fn define(name: String, description: String, input: Codec(i), output: Codec(o)) -> Definition(i, o)
pub fn bind(definition: Definition(i, o), handler: fn(c, i) -> Result(o, e), classify: fn(e) -> Failure) -> Tool(c)
pub fn bind_settling(definition: Definition(i, o), handler: fn(c, i, Settlement(o)) -> Result(o, e),
                     classify: fn(e) -> Failure, within milliseconds: Int) -> Tool(c)
pub fn settle(settlement: Settlement(o), result: Result(o, Failure), summary summary: String)
  -> Result(Nil, SettleError)   // the summary reaches observation: no secrets
pub fn input(definition: Definition(i, o), action: policy.Action) -> Result(Option(i), String)
  // Ok(None): another tool; Error(detail): this tool's name, arguments this definition cannot read

// fabric/testing — for scripted models and tests
pub fn call(definition: Definition(i, o), id: String, input: i) -> Result(model.ToolCall, codec.EncodeError)

// fabric/run — plain data
pub opaque type RunId
pub fn parse_id(text: String) -> Result(RunId, Nil)   // 1 to 128 of [A-Za-z0-9_-]
pub fn id_to_string(id: RunId) -> String
pub type ActionId { ActionId(turn: Int, call_id: String) }
pub type ActionRef { ActionRef(run: RunId, id: ActionId) }
pub type Requirement { Requirement(name: String, version: Int) }
pub type Status { Working  Unattended  Suspended(approvals: List(PendingApproval), uncertain: List(UncertainAction))
                  Finished(Outcome) }
pub type ApprovalRef { ApprovalRef(run: RunId, id: ActionId, requirement: Requirement, revision: Int) }
pub type PendingApproval { PendingApproval(reference: ApprovalRef, tool: String, arguments_json: String) }
pub type UncertainAction { UncertainAction(reference: ActionRef, tool: String, evidence: String) }
pub type Answer { Approve  Reject(reason: String) }   // as recorded in an Approval
pub type Budget { TurnLimit(limit: Int)  TokenLimit(limit: Int, used: Int) }
pub type DelegationLimit { ChildLimit(limit: Int)  DepthLimit(limit: Int) }
// ActionState: ..., LimitReached(DelegationLimit); ActionRecord.child: Option(RunId);
// Snapshot.run: RunId, Snapshot.parent: Option(ActionRef). Approval, Identity, Incompatibility,
// Outcome, HostFailure, TokenUsage as in slice 2b.

// fabric/policy — the one gate
pub type Target { InvokeTool  StartAgent(name: String, version: Int) }
pub type Action { Action(run: RunId, id: ActionId, tool: String, arguments_json: String, target: Target) }
pub type Decision { Allow  Deny(reason: String)  RequireApproval(Requirement) }
pub type Policy(context) = fn(context, Action) -> Result(Decision, String)
pub fn always_allow() -> Policy(context)

// fabric/store — a named value that starts nothing
pub opaque type Store   pub opaque type Message
pub type StoreError { NotFound  AlreadyExists  Conflict(current: Int)  Unavailable(reason: String) }
pub type Stored { Stored(revision: Int, record: String) }
pub fn in_memory(name: Name(Message)) -> Store      // records live in the store process
pub fn directory(name: Name(Message), path: String) -> Store
pub fn new(name: Name(Message), get get: .., insert insert: .., compare_and_set compare_and_set: ..) -> Store
pub fn supervised(store: Store) -> supervision.ChildSpecification(Nil)   // S2: the store's subtree
pub fn start(store: Store) -> Result(Nil, StoreError)   // linked to the caller: scripts and tests
pub type DrainError { DrainNotPositive(Int)  DrainTooLarge(value: Int, limit: Int) }   // added in S2
pub fn with_drain(store: Store, milliseconds: Int) -> Result(Store, DrainError)       // added in S2
pub type UnwritableVersion { UnwritableVersion(requested: Int, oldest: Int, newest: Int) }   // S6
pub fn with_record_version(store: Store, version: Int) -> Result(Store, UnwritableVersion)  // S6

// fabric/observation — as in slice 2b, with model_turn() -> Event(Option(model.Usage), ModelTurn)
//   (None: no reply or no reported usage) and RunTotals.unreported_replies;
//   S2 adds run_handed_off() -> Event(Nil, RunHandedOff) and RunHandedOff(run: String, incarnation: Int)
// fabric/model — updated by the library adoption
pub type ProviderData { ProviderData(format: String, value: String) }
pub type AssistantTurn { AssistantTurn(text: String, calls: List(ToolCall), data: Option(ProviderData)) }
// Message: AssistantMessage(turn: AssistantTurn)
// Reply: ToolRequest(turn: AssistantTurn, usage: Option(Usage))
// fabric/llm.model(client, settings, model_id) — the caller-owned http_gun.Client since llm_wire 1c0ad61
```

Errors by operation: `agent.build` returns every `ConfigError` at once;
`start` `StartUnconfirmed`, whose run may land later and can then be
ended with `cancel_stored`, or `StartRefused` when a backend reports the
fresh id taken by a record the start did not write; `await`, `snapshot` and `pending` the four
read errors, `open` and `child` those and `IncompatibleAgent`; `recover` `Contended`
or `Unreadable`; `approve` every `CommandError` but `NotReconcilable`;
`reject` the same without `RequirementChanged`; `reconcile` `RunEnded`,
`WrongReference`, `NotReconcilable`, `RunUnattended`, `RunnerBusy`,
`Contended` and `Unreadable`; `cancel` and `cancel_stored` `RunEnded`,
`Contended` and `Unreadable`. `StoreError` reaches callers only through
`store.new`'s backend contract; a missing record is `RunNotFound`, a lost
race `Contended`, and only an unavailable store `StoreUnavailable`.

Cut: `fabric.status` (`await(run, 0)` reads the status now; `snapshot`
carries it), `fabric.answer`, `AwaitError`, `RecoverError`, `StartFailed`,
`InvalidAgent`, `UnknownAction` (now `WrongReference`), `WrongPhase` (now
`NotReconcilable`), `OwnerUnknown` (now `RunUnattended`), `run.Parent`,
`agent.validate`, the nine `agent.with_*` bounds and identity setters, the
`default_*`, `max_children_limit` and `max_depth_limit` constants,
`ConfigError.InvalidChild` (a sub-agent is a built `Agent`),
`tool.settle_summarized`, `tool.name` (internal), `observation.Tokens`,
`store.close`. Moved: `ActionId` and `Requirement` from `policy` to `run`.
After the review: added `fabric.open`, `StartError.StartRefused` and
`fabric/testing` (`tool.call` moved there); `tool.input` returns
`Result(Option(input), String)`.

### Deviations from the accepted proposal

Each is the smallest safe variant of an item the proposal reasoned
about but had not compiled against the real code; none changes the three
decisions (Spec, build and Limits; one policy gate with `tool.input`; a
named supervisable store).

- **`DelegationLimit` keeps its `limit`.** The proposal wrote
  `ChildLimit  DepthLimit` without payload; a stored `limit_reached` action
  carries the limit, and the model sees it, so both keep `limit: Int`. The
  tag `budget_exhausted`, written only for a delegation limit ending a run
  (which no run did), is still read for a run budget; `record_test` drops
  the one round trip of that unrepresentable outcome.
- **Temporary variants between steps.** Until agents were built once, `start`
  kept `InvalidAgent` and `recover` returned `CommandError.AgentInvalid`;
  both were removed with `agent.build`. The final surface has neither.
- **`Unattended` everywhere a status is reported.** Beyond `await` and
  `snapshot`, command results and `cancel_stored` report the family's
  status with the store's runner registry, so a lost runner's run reads
  `Unattended` there too. `cancel_stored` used to report the committed
  record's status alone.
- **A first write reported taken is read back.** Random ids do not
  collide, so `start` does not retry under another id. An `AlreadyExists`
  first write is read back: the start's own record (a backend that stored
  it and still reported it taken) is adopted and run; any other record is
  `StartRefused(reason)`, which names no id, since the id is someone
  else's. Only a write whose outcome is unknown is `StartUnconfirmed`.
- **Fabric names every other ending of a sub-agent.** With `output:`, a
  refused, output-limited, budget-exhausted, unverifiable, cancelled or
  failed child is a definite failure whose text names the ending (for
  example `the sub-agent was cancelled`), not one fixed text. A child with
  an effect of unknown status still makes the delegation uncertain first.
- **The store process is an OTP actor bound by instance.** A runner
  monitors the store process that was running when it was claimed and
  stops when it goes, so it never drives a run for a restarted process.
  Its store calls are pinned to that process: until it notices the stop,
  a commit fails as a stopped store's would and never reaches the new
  process under the same name. Backend workers report to the
  process's own subject, never to the name, so a late report cannot reach
  a later process of the same name. An `await` whose store process stops
  waits, within its own deadline, for the supervisor to register the next
  process and goes on through it, where work in flight reads `Unattended`;
  only a process that is not registered again in time is
  `StoreUnavailable`.
  `directory(name, path)` no longer fails when built: a directory that
  cannot be created, or a name already taken, fails `start`.
- **`run.issued`** is an `@internal` constructor of `RunId` for ids Fabric
  made or read from its own records; Gleam cannot hide it further.
  `runner.load` keeps the issued-shape check before any read.

### Guards added

`a_rejection_never_runs_the_policy_test` (approval_test),
`a_foreign_effect_is_not_reconciled_test` (command_test),
`a_child_effect_is_reconciled_through_the_parent_test` (delegation_test),
`a_request_process_that_exits_leaves_its_run_intact_test` and
`a_restarted_store_leaves_its_runs_unattended_until_recovered_test`
(supervision_test), `an_unconfirmed_start_names_its_run_test`
(durable_test), `a_child_without_a_usable_answer_is_a_definite_failure_test`
(delegation_controller_test), `a_policy_reads_the_typed_input_of_its_tool_test`
(registry_test), `a_store_that_is_not_running_is_unavailable_test` and
`a_store_that_cannot_open_does_not_start_test` (store_test),
`a_wrapped_budget_is_still_read_test` (record_test), `readme_test` (the
README's block is `readme_example.gleam` verbatim, and runs), and in
`consumers/app` `a_run_outlives_the_request_that_started_it_test`.

Resolved backlog: the ergonomics review items (below, slice 2b review
fixes), `reconcile` routed by run (m7), delegation limits apart from
`Budget` (m7), and starter-owned stores (slice 3). Runners were then still
started unsupervised, owned through their store process, whose calls they
are pinned to; S2 (above) supervises them.

### Slice 3 review fixes

An independent review of `e5e27f2..45fbc96` found no blocker and no
safety regression. Each finding, and what became of it:

| #   | Finding                                                                                          | Disposition                                        | Guard                                                                                                                                                                                      |
| --- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | `await` failed at once when its store process restarted, although documented to follow it        | Fixed                                              | `an_await_follows_a_restarted_store_test` (supervision_test); `await_reports_a_stopped_store_test` now waits 200 ms                                                                        |
| 2   | `recover` was the only way from a `RunId` to a handle, and through another `Store` it takes over | Fixed: `fabric.open`                               | `opening_a_live_run_through_another_store_leaves_it_running_test`, `opening_checks_the_run_and_its_agent_test`, `an_approval_through_an_opened_handle_runs_the_action_test` (durable_test) |
| 3   | A store started by a caller that exited normally stayed registered                               | Fixed: the store stops with its starter            | `a_started_store_stops_when_its_starter_exits_normally_test` (store_test)                                                                                                                  |
| 4   | `tool.input` returned `Error(Nil)` for another tool and for this tool's unreadable arguments     | Fixed: `Result(Option(i), String)`, fails closed   | `a_policy_reads_the_typed_input_of_its_tool_test`, `a_drifted_definition_fails_the_policy_closed_test` (registry_test)                                                                     |
| 5   | `snapshot` and command results read the family once and could report a spurious `Unattended`     | Fixed: `family.load_settled`                       | `a_family_that_moved_on_since_it_read_unattended_is_read_again_test` (durable_test); the snapshot interleaving itself cannot be forced (below)                                             |
| 6   | A runner committed through a restarted store process by name                                     | Fixed: store calls pinned to the monitored process | `a_runner_never_commits_through_a_restarted_store_test` (supervision_test)                                                                                                                 |
| 7   | The id-collision retry was dead, and `StartUnconfirmed(id)` could name someone else's run        | Fixed: read back, `StartRefused`                   | `a_start_the_backend_stored_despite_reporting_it_taken_runs_test`, `a_start_whose_id_holds_another_record_is_refused_test` (durable_test)                                                  |
| 8   | No `reconcile` twin of the cancelled-ancestor answer test                                        | Fixed                                              | `a_child_that_cannot_be_cancelled_can_no_longer_be_reconciled_test` (delegation_test)                                                                                                      |
| n1  | Stale comments (`with_max_depth`, `OwnerUnknown`, the rejection test's policy)                   | Fixed                                              | —                                                                                                                                                                                          |
| n2  | The README was pseudocode and `readme_test` a paraphrase                                         | Fixed                                              | `the_readme_shows_the_compiled_example_test`, `the_readme_example_runs_test` (readme_test)                                                                                                 |
| n3  | `@internal` items of `store` and `tool` into `fabric/internal/*`                                 | Deferred                                           | Not clean (below)                                                                                                                                                                          |
| n4  | `tool.call` into a `fabric/testing` module                                                       | Fixed: `testing.call`                              | The existing tests call it                                                                                                                                                                 |
| n5  | `Requirement` reachable without importing `run`                                                  | Deferred                                           | An import cycle (below)                                                                                                                                                                    |

Finding 5: a family is read record by record, and every hold on the
parent's read in the store also holds the child's delivery to the parent
(one request at a time per run), so the interleaving where a child ends
between the two reads of one `snapshot` cannot be forced. The rule is
tested directly: a family read as `Unattended` through a store that knows
no runner reads again after the run moved on.

n3: the client functions of `store` (`get`, `insert`, `commit`, `watch`,
`unwatch`, `pid`, `pin`, `with_backend_timeout`) need the opaque `Store`
and the `Message` constructors, and an internal module holding the store
process would need `StoreError` and `Stored`, whose constructors a backend
built with `store.new` uses, so `store` and that module would import each
other. The same holds for `tool`: its accessors need the opaque `Tool`, and
`Late` and `Kind` name the public `SettleError`. Moving them needs the
backend contract types in a module of their own (`fabric/store/backend`),
an API change left for a later pass.

n5: `run.ApprovalRef` and `run.Approval` hold a `Requirement`, and
`policy` imports `run` for `RunId` and `ActionId`, so `Requirement` cannot
live in `policy`; a type alias would not carry its constructor. A policy
author imports `fabric/run` for `run.Requirement`.

After the fixes, public items (types and functions, `@internal` items
excluded) per module: `fabric` 17, `fabric/agent` 11, `fabric/llm` 1,
`fabric/model` 9, `fabric/observation` 31, `fabric/policy` 5, `fabric/run`
22, `fabric/store` 9, `fabric/testing` 1, `fabric/tool` 10: 116 in all.
`@internal` items: `agent` 2, `model` 1, `run` 1, `store` 11, `tool` 11.

## Public API (slice 2b)

Slice 2b adds, beside the slice 2a API below: `agent.with_sub_agent(agent,
definition, to: child, prompt:, result:)`, `agent.with_max_children` (default
4), `agent.with_max_depth` (default 1), the `ConfigError` variants
`MaxChildrenNegative`, `MaxDepthNegative`, `InvalidChild(name, errors)`;
`policy.Target { InvokeTool  StartAgent(name, version) }` and the field
`Action.target`; `run.Parent(run, action)`, the field
`ActionRecord.child: Option(String)`, the field `UncertainAction.run`, the
field `Snapshot.parent`, the action states `Delegated` and
`LimitReached(Budget)`, the budgets `ChildLimit(limit)` and
`DepthLimit(limit)`; `fabric.child(run, id) -> Result(Run(c), RecordError)`
and `fabric.cancel_stored(store, id) -> Result(Status, CommandError)`;
`CommandError.OwnerUnknown` (replacing `RecoveryRequired`); the module
`fabric/observation` (event descriptors and their typed metadata); and, in
the separate package `fabric_saga`, `fabric_saga.tool(definition, workflow,
config, explain:) -> Result(Tool(c), List(execution.ConfigError))`. Adding
fields and variants is a breaking change for code that constructs or
exhaustively matches these types.

## Public API after the slice 2b review

Beside the slice 2b API: `tool.bind_settling(definition, handler, classify,
within:)`, whose handler takes a third argument `tool.Settlement(output)`;
`tool.settle(settlement, Result(output, Failure)) -> Result(Nil,
SettleError)` with `SettleError { NotAwaited  SettleFailed(detail) }`;
`agent.with_command_timeout` (default `agent.default_command_timeout`, 5000
ms); the constants `agent.max_children_limit` (999) and
`agent.max_depth_limit` (16); the `ConfigError` variants
`CommandTimeoutNotPositive`, `MaxChildrenTooLarge`, `MaxDepthTooLarge`, and
`SettlementBoundNotPositive(name, within)`; `CommandError.RunnerBusy`; and
`fabric_saga.tool(.., explain:, rollback_within:)`.

## Public API after the slice 2b re-review

Beside the API above: `tool.SettleError` gains `AlreadyRecorded` (a refused
settlement lost nothing; `NotAwaited` now means the action has no definite
result and needs a person); `tool.settle_summarized(settlement, result,
summary:)`; the event `observation.settlement_refused()` with
`SettlementRefused(action, offered, reason, summary)` and
`SettlementRefusal { AlreadyRecorded  NotAwaited  NotReached }`; and the
`ConfigError` variant `SettlementBoundTooLarge(name, within)`. `cancel` and
`cancel_stored` no longer return `RunnerBusy`. Run records move to version 3
(the phase `never_started`); version 1 and 2 records are still read.

## Public API at slice 2a

The slice 2b additions and changes are listed in the previous section.

```gleam
// fabric/tool — typed application tools
pub opaque type Definition(input, output)
pub fn define(name: String, description: String, input: Codec(i), output: Codec(o)) -> Definition(i, o)
pub opaque type Tool(context)
pub fn bind(definition: Definition(i, o), handler: fn(context, i) -> Result(o, e),
            classify: fn(e) -> Failure) -> Tool(context)
pub type Failure { Explain(message: String)  Uncertain(evidence: String) }

// fabric/testing — for scripted models and tests
pub fn call(definition: Definition(i, o), id: String, input: i) -> Result(model.ToolCall, codec.EncodeError)
pub fn name(tool: Tool(context)) -> String

// fabric/policy — the gate
pub type ActionId { ActionId(turn: Int, call_id: String) }
pub type Action { Action(run: String, id: ActionId, tool: String, arguments_json: String) }
pub type Requirement { Requirement(name: String, version: Int) }
pub type Decision { Allow  Deny(reason: String)  RequireApproval(Requirement) }
pub type Policy(context) = fn(context, Action) -> Result(Decision, String)
pub fn always_allow() -> Policy(context)

// fabric/model — the model port Fabric owns
pub type ToolCall { ToolCall(id: String, name: String, arguments_json: String,
                             provider_id: Option(String), provider_state: Option(String)) }
pub type Message { UserMessage(text: String)  AssistantMessage(text: String, calls: List(ToolCall))
                   ToolResultMessage(call_id: String, content: String) }
pub type ToolSpec { ToolSpec(name: String, description: String, schema: codec.Schema) }
pub type Request { Request(system: Option(String), messages: List(Message), tools: List(ToolSpec)) }
pub type Usage { Usage(input_tokens: Int, output_tokens: Int) }
pub type Reply { FinalAnswer(text, usage)  ToolRequest(text, calls, usage)
                 Refusal(reason, usage)  Truncated(partial_text, usage) }  // usage: Option(Usage)
pub type ModelError { ModelError(reason: String, retryable: Bool) }
pub opaque type Model
pub fn new(call: fn(Request) -> Result(Reply, ModelError)) -> Model

// fabric/llm — llm_wire adapter; Fabric neither starts nor stops the client
pub fn model(client: http_gun.Client, config: llm_wire.Config, model_id: String) -> Model

// fabric/agent — pure configuration
pub opaque type Agent(context)
pub fn new(model: Model, tools: List(Tool(context)), policy: Policy(context)) -> Agent(context)
pub fn with_identity(agent, name: String, version: Int) -> Agent(context)  // default agent/1
pub fn with_system_prompt(agent, text: String) -> Agent(context)
pub fn with_max_turns(agent, limit: Int) -> Agent(context)          // default 8
pub fn with_max_concurrency(agent, limit: Int) -> Agent(context)    // default 4
pub fn with_token_budget(agent, tokens: Int) -> Agent(context)      // default: none
pub fn with_policy_timeout(agent, milliseconds: Int) -> Agent(context)      // default 5000
pub fn with_model_retry_delay(agent, milliseconds: Int) -> Agent(context)   // default 200
pub fn validate(agent) -> Result(Nil, List(ConfigError))
pub type ConfigError { DuplicateToolName(String)  InvalidToolName(String)  ToolSchemaUnavailable(String)
                       MaxTurnsNotPositive(Int)  MaxConcurrencyNotPositive(Int)  TokenBudgetNotPositive(Int)
                       PolicyTimeoutNotPositive(Int)  ModelRetryDelayNegative(Int)
                       InvalidIdentity(name, version) }

// fabric/store — where runs live
pub opaque type Store
pub fn in_memory() -> Store
pub fn directory(path: String) -> Result(Store, StoreError)
pub fn new(get: fn(String) -> Result(Stored, StoreError), insert: fn(String, String) -> Result(Nil, StoreError),
           compare_and_set: fn(String, Int, String) -> Result(Nil, StoreError)) -> Store
pub fn close(store: Store) -> Nil
pub type Stored { Stored(revision: Int, record: String) }
pub type StoreError { NotFound  AlreadyExists  Conflict(current: Int)  Unavailable(reason: String) }

// fabric/run — what a run is and becomes (data only)
pub type Status { Working  Suspended(approvals: List(PendingApproval), uncertain: List(UncertainAction))
                  Finished(Outcome) }
pub type ApprovalRef { ApprovalRef(run: String, id: ActionId, requirement: Requirement, revision: Int) }
pub type PendingApproval { PendingApproval(reference: ApprovalRef, tool: String, arguments_json: String) }
pub type Answer { Approve  Reject(reason: String) }
pub type Approval { Approval(requirement, revision, answer: Answer, reviewer: Option(String)) }
pub type Identity { Identity(name: String, version: Int) }
pub type Incompatibility { OtherAgent(stored: Identity)  ToolNotRegistered(id, tool)
                           ArgumentsNotAccepted(id, tool, detail) }
pub type Outcome { Completed(text)  Refused(reason)  OutputLimited(partial_text)  BudgetExhausted(Budget)
                   BudgetUnverifiable(turn)  Cancelled  Failed(HostFailure) }
pub type ActionState { Queued  Running  AwaitingApproval(requirement, revision)  Succeeded(content)
                       ToolFailed(content)  Denied(reason)  Rejected(reason)  InvalidArguments(detail)
                       UnknownTool  Uncertain(evidence)  Reconciled(content)  NotStarted  Faulted(detail) }
pub type HostFailure { PolicyFailed(id, reason)  OutputEncodingFailed(id, detail)  ToolChanged(id, detail)
                       ModelFailed(ModelError)  ModelProtocolViolation(reason) }
pub type ActionRecord { ActionRecord(id: ActionId, call: ToolCall, state: ActionState, approvals: List(Approval)) }
pub type TokenUsage { TokenUsage(input_tokens, output_tokens, unreported_replies) }
pub type Snapshot { Snapshot(run, agent: Identity, incarnation: Int, status, turns_used, max_turns,
                             usage: TokenUsage, transcript, actions) }

// fabric — running
pub opaque type Run(context)
pub fn start(store: Store, agent: Agent(c), context: c, prompt: String) -> Result(Run(c), StartError)
pub fn recover(store: Store, agent: Agent(c), context: c, id: String) -> Result(Run(c), RecoverError)
pub fn await(run, within: Int) -> Result(Status, AwaitError)   // first non-Working status
pub fn status(run) -> Result(Status, RecordError)
pub fn snapshot(run) -> Result(Snapshot, RecordError)
pub fn pending(run) -> Result(List(PendingApproval), RecordError)
pub fn answer(run, reference: ApprovalRef, answer: Answer, reviewer: Option(String), context: c)
  -> Result(Status, CommandError)
pub fn cancel(run) -> Result(Status, CommandError)
pub fn reconcile(run, action: ActionId, content: String) -> Result(Status, CommandError)
pub fn id(run) -> String
pub type StartError { InvalidAgent(List(ConfigError))  StartFailed(StoreError) }
pub type RecordError { RunNotFound  StoreFailed(StoreError)  UnsupportedVersion(found: Int)
                       CorruptRecord(detail)  IncompatibleAgent(List(Incompatibility)) }
pub type CommandError { RunEnded  UnknownAction(ActionId)  NotReconcilable(ActionId)  WrongPhase
                        WrongReference  StaleReference  AlreadyAnswered  RequirementChanged(PendingApproval)
                        RecoveryRequired  Contended  Unreadable(RecordError) }
pub type AwaitError { StillWorking  NoRunner  AwaitUnreadable(RecordError) }
pub type RecoverError { RecoverInvalidAgent(List(ConfigError))  RecoverUnreadable(RecordError)
                        RecoverContended }
```

Model-visible failure content has one encoding: `{"error": text}` for typed
failures (`{"error":"tool_failed"}` when hidden) and unknown tools
(`{"error":"unknown_tool"}`), and `{"error": kind, "detail": text}` for
`denied`, `rejected`, and `invalid_arguments`. llm_wire's `ToolResult` has no error flag,
so the disposition lives on Fabric's `ActionState`, not in the wire result.

Internal (importable but unstable): `fabric/internal/controller` (pure
transitions), `record` (the versioned JSON codec and the compatibility
check), `registry`, `executor`, `runner`, `live`, `bounded`, `invocation`.

## Slice 1 — bounded agent execution

Acceptance:

1. Typed heterogeneous tools with a registry rejecting duplicate and invalid
   names and schema-less codecs; declarations and dispatch from the same
   definitions; per-invocation argument validation; outcomes success, typed
   failure (hidden or rendered), host failure, invalid arguments, unknown tool,
   uncertain effect.
2. Explicit policy gate (allow, deny, require approval, error fails closed)
   over a uniform `Action`.
3. Pure controller with a closed phase model, correlated report acceptance,
   turn and token budgets, and suspension as data. The per-run concurrency
   limit is enforced by the executor, not the controller.
4. Pure scripted model tests plus the llm_wire adapter tested against a local
   OpenAI Responses SSE stub with two tool calls and distinct ids.
5. Runner with commit-before-effect, fence, bounded executor, and cancellation
   of active and suspended runs; no sleeps in tests.
6. Pure, validatable configuration with defaults.
7. External consumer `consumers/app` using public imports only.
8. Two or three executed BeamWeaver differential fixtures, or an explicit
   unverified record.

## Slice 2a — durable pause, approval, resume, cancellation, restart

Implemented. Acceptance, each with its executed evidence:

1. Record codec (versioned JSON; another version is `UnsupportedVersion`,
   anything unreadable `CorruptRecord`) and a public store port over encoded
   records (`store.new(get:, insert:, compare_and_set:)`) with an in-memory
   store and a durable directory store whose compare-and-set holds across
   processes and VMs (`record_test`, `store_test`).
2. `fabric.answer` works with no live process, also after a restart; wrong
   reference, stale revision or requirement, already answered, and run ended
   are distinct refusals that leave the pause intact; eight concurrent
   answers have one winner and the tool runs once; the policy checked at
   answer time wins over an approval; a changed requirement issues a new
   request (`RequirementChanged`); the reviewer is recorded as given; the
   approved tool runs with the context the recheck passed, with or without
   a live runner, and the run's other actions keep the run's context
   (`approval_test`, `answer_test`, `approved_context_test`).
3. Restart against the directory store with every Fabric process killed:
   recovery bumps a trusted incarnation with compare-and-set; queued tools
   and a lost model call are issued again (the model call against the turn
   budget), except an approved queued tool, which is asked for again
   (`an_approved_tool_not_started_before_a_restart_is_asked_for_again_test`);
   a running tool becomes an uncertain effect that needs
   `reconcile` and is never retried, including when its effect happened and
   its result was never committed; completed results survive; a runner of an
   older incarnation cannot commit; duplicate and concurrent recoveries take
   the run over once; a finished run opens unchanged; another agent identity,
   a missing tool, arguments a changed codec no longer accepts, an
   unsupported version, corrupt data, and an unknown run are refused
   (`durable_test`).
4. Cancellation while paused needs no process and voids the pending
   approvals; cancel racing an answer always ends `Cancelled` with the tool
   run at most once; a run whose runner was killed can be cancelled without
   recovery (`approval_test`, `durable_test`, `runner_test`).
5. Runner loss is reported (`NoRunner`), a closed store is reported
   (`AwaitUnreadable(StoreFailed(Unavailable))`), and model retries back off
   (`durable_test`, `runner_test`).
6. BeamWeaver anti-oracle rows B2–B5 executed, and fixtures for approve (A1),
   reject (A3), and a cold restart across a pause (A13) compared
   ([ORACLE.md](ORACLE.md#slice-2a-results)).
7. Consumer: approval with its continuation, rejection, cancel while paused,
   and restart through the directory store (`consumers/app`).

Backlog from this slice:

- **Approval expiry.** Not implemented. An application can deny late answers
  through the policy recheck (its context carries the current time), but
  Fabric does not record when a request was issued. Expiry needs an injected
  clock and an issue time on `AwaitingApproval`, a record change.
- **Edit and respond answers** (BeamWeaver A2, A3 respond) are not offered.
- **Cross-VM ownership.** The directory store makes commits safe across VMs,
  but a store knows only its own runners, so `recover` in one VM takes over a
  run another VM still drives. A lease or heartbeat would let recovery wait
  for a live owner.
- **Cancel of an incompatible record** (resolved: `fabric.cancel_stored`
  needs no agent, and `cancel` skips the compatibility check). Every command, `cancel` included,
  requires the record to be compatible with the agent; a run whose pending
  tool was removed cannot be cancelled under the new agent.

## Slice 2a review fixes

An independent review of slice 2a found no double execution or lost fence
under process or VM loss. Its findings were fixed test-first:

| Finding                                                                                                          | Resolution and evidence                                                                                                                                                                                                                                                       |
| ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Unparseable Anthropic or Google tool arguments failed the next turn                                              | llm_wire `a822ea4` replays reported-invalid arguments for every provider; the adapter passes them through and the record keeps the original (`unparseable_arguments_replay_to_anthropic_as_an_object_test`, `unparseable_arguments_replay_to_openai_verbatim_test`).          |
| A second `Store` over one directory answered `RecoveryRequired` and advised a takeover                           | Commands are checked against the stored record first; `OwnerUnknown` replaces `RecoveryRequired` (`a_second_store_checks_commands_before_reporting_an_unknown_owner_test`).                                                                                                   |
| An agent change stranded paused runs                                                                             | `fabric.cancel_stored(store, id)` needs no agent; `cancel` through a handle skips the compatibility check (`a_stranded_run_is_cancelled_without_an_agent_test`, `cancel_stored_stops_a_live_run_through_its_runner_test`).                                                    |
| One transient `Unavailable` stalled the run                                                                      | Store read-back and runner retry (`a_runner_retries_a_commit_the_store_could_not_make_test`, `a_write_the_backend_made_despite_an_error_is_confirmed_test`).                                                                                                                  |
| A hung backend froze every run of a Store                                                                        | Per-run worker calls with a deadline (`a_hung_backend_call_blocks_only_its_run_until_its_deadline_test`).                                                                                                                                                                     |
| Cancelling an orphaned stopping record did nothing                                                               | `controller.cancel_abandoned` (`cancelling_a_record_a_lost_runner_left_stopping_ends_it_test`).                                                                                                                                                                               |
| Cancel through another Store left tool bodies running                                                            | Documented on `fabric.cancel`.                                                                                                                                                                                                                                                |
| Directory store: directory entry not fsynced; O(n²) disk; stray temporary files; `ok = file:close`               | "Never retried" scoped in the `fabric` module documentation; old revisions emptied, stale temporary files swept (`the_directory_store_empties_revisions_older_than_the_previous_test`, `opening_a_directory_store_sweeps_stale_temporary_files_test`); close errors reported. |
| The answer's context became the run context only without a live runner                                           | The approved action runs with the answer's context and the run keeps its own, with or without a live runner, and an approved action lost before it started is asked for again (`approved_context_test`); see the decisions above.                                             |
| A changed requirement left no audit trail                                                                        | The superseded answer is kept (`a_changed_requirement_demands_a_new_answer_test`).                                                                                                                                                                                            |
| A backend that committed then reported `Unavailable` gave `StartFailed`/`StoreFailed`                            | Store read-back, as above.                                                                                                                                                                                                                                                    |
| ORACLE A13 said "VM restart"; CAPABILITIES excluded multi-node while the store claims cross-VM safety            | Relabelled and reconciled in ORACLE.md and CAPABILITIES.md.                                                                                                                                                                                                                   |
| Nits: dead `registry.is_registered`; foreign run ids gave a store error; the runner ignored outside exit signals | Removed; `RunNotFound` (`a_run_id_that_fabric_never_issues_is_not_found_test`); the runner stops (`an_exit_signal_from_outside_stops_the_runner_test`).                                                                                                                       |

Deferred, with reasons:

- **The default identity `agent/1`** makes the identity check vacuous for
  applications that never name their agent. Requiring a name changes the one
  ordinary path (`agent.new`); deriving one from the tools would refuse
  compatible changes. Kept, pending an API decision.
- **Rejecting a stranded run.** `recover` still refuses an incompatible
  record, so a stranded run can be cancelled (`cancel_stored`) but not
  rejected: a rejection would continue the run under an agent that recovery
  refused.
- **A lease or heartbeat** for runs driven through several Stores (see the
  cross-VM backlog item above): built as leases in production S3.
- **Unknown record fields** are ignored when decoding; strict decoding would
  make every added field a version bump.
- Ergonomics (five error types, `answer` needing a context for a rejection,
  a Store linked to its opener, an opaque run id) are recorded for an API
  review; none was changed here. Resolved by the slice 3 ergonomics pass
  (see "Public API (slice 3: ergonomics pass)").

## Slice 2b review fixes

An independent review of slice 2b (at `a43018a`) found one blocker, three
major and eight minor findings, and nits. Fixed test-first, one commit each:

| Finding                                                                                                | Resolution and evidence                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| B1: one transient store failure left a parent's cancellation incomplete, and the child could still act | `cancel_child` retries until the child reads stopping or ended, else records `ChildLost`; cancelling a stopping run cancels its children again; `answer` and `reconcile` refuse with `RunEnded` when an ancestor is stopping or ended (`a_transient_store_failure_does_not_leave_a_child_uncancelled_test`, `a_child_that_cannot_be_cancelled_can_no_longer_act_test`, `cancelling_a_stopping_run_cancels_its_children_again_test`).                           |
| M1: a start or recovery racing a cancel ran a child under a cancelled parent                           | A canceller that finds no child inserts a cancelled tombstone (insert-if-absent), which reads as a missing child (`a_child_stored_after_its_parent_was_cancelled_never_runs_test`, `recovery_does_not_start_a_child_after_its_parent_was_cancelled_test`).                                                                                                                                                                                                     |
| M2: a synchronous handler could wedge its runner                                                       | A command is answered before its commit's events; commands carry an acceptance deadline (`agent.with_command_timeout`) and are refused as `RunnerBusy`, never applied late; a command from the runner's own process is refused at once; handlers that call Fabric should run in a forwarder (`a_handler_commanding_its_own_run_is_refused_test`, `a_command_returns_before_its_handlers_run_test`, `a_command_to_a_runner_held_by_a_handler_is_refused_test`). |
| M3: an identical record by another writer confirmed a lost write                                       | Every encoding carries a fresh write token; the runner retries a commit with the same text (`an_identical_record_by_another_writer_does_not_confirm_a_lost_write_test`).                                                                                                                                                                                                                                                                                       |
| m1: corrupt or cyclic child links; child ids past 128 characters                                       | Links must extend the run id (`family_links_must_extend_the_run_id_test`); `max_children <= 999` and `max_depth <= 16` (`delegation_limits_keep_child_ids_valid_test`).                                                                                                                                                                                                                                                                                        |
| m2: a transient child insert failure was ignored and reported started                                  | The insert is retried; a child that cannot be stored is a lost child, and `ChildStarted` is sent only for a stored one (`a_child_whose_first_insert_fails_still_starts_test`, `a_child_that_cannot_be_stored_is_uncertain_test`).                                                                                                                                                                                                                              |
| m3: `cancel_stored` on a child does not deliver its end                                                | Documented on `cancel_stored`: recovering the parent applies it.                                                                                                                                                                                                                                                                                                                                                                                               |
| m4: command-path writes reported `Unavailable` though they may land                                    | Documented on `StartFailed`, `Unreadable`, and the store contract as an unknown outcome; the write token makes read-back reliable.                                                                                                                                                                                                                                                                                                                             |
| m5: pruning empties a revision before the directory is flushed                                         | Documented on `store.directory`; deferred (below).                                                                                                                                                                                                                                                                                                                                                                                                             |
| m6: `RetryLimitReached(_, Returned(e))` was definite                                                   | Uncertain while Saga reported only the last attempt; since saga `4a93b04` definite exactly when Saga names no unknown effect and nothing is left in place (X1; `a_typed_failure_after_retries_is_definite_test`).                                                                                                                                                                                                                                              |
| m7: `reconcile` is not routed by run                                                                   | Deferred (below).                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| m8: delegations offered with no child allowed                                                          | Left out of the model request when `max_children` is 0 or no depth is left (`delegations_are_offered_only_when_a_child_may_start_test`).                                                                                                                                                                                                                                                                                                                       |
| Nit: a handle whose agent lost the delegation cancelled no children                                    | `cancel_child` falls back to the agent-less cancellation and applies the child's end unmapped (`cancelling_does_not_depend_on_the_current_delegations_test`).                                                                                                                                                                                                                                                                                                  |

Deferred, with reasons:

- **Flushing the directory before pruning (m5).** Erlang's `file` module
  refuses to open a directory (`eisdir`), so an `fsync` of the directory
  needs a NIF or a port; the loss is limited to power loss or an OS crash.
- **`reconcile` routed by run (m7)** (resolved by the ergonomics pass:
  `reconcile` takes an `ActionRef`). It takes an `ActionId` of the handle's
  run; routing it like `answer` needs a reference type (an
  `UncertainAction`, or a new one) and changes every caller. An API
  decision.
- **Typed child output (m7).** A delegation maps `run.Outcome` text; a
  typed child output needs a structured final answer (slice 3).
- **Delegation limits apart from `Budget` (m7)** (resolved by the
  ergonomics pass: `run.DelegationLimit`). `ChildLimit` and
  `DepthLimit` share `run.Budget` with turn and token limits.
- **Nits:** `run_recovered` is emitted for the cancel of an orphaned run
  (the cancel increments the incarnation); `child_started` is not emitted
  when a child's end is applied before its start report.

## Slice 2b re-review fixes

An independent re-review of `1b0178a..1d71bec` found two blockers and seven
minor findings; its executed probes are ported as regression tests. Fixed
test-first, one commit each:

| Finding                                                                                                                                                                             | Status | Resolution and evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| X1: `fabric_saga` reported definite failures while an effect was unknown (a crash its decider aborted, a sibling that crashed while settling, a crashed attempt retried to success) | Fixed  | `fabric_saga/internal/verdict` classifies from Saga's unknown-effect evidence (saga `4a93b04`): `Completed` is the output; `CompletedWithUnknownEffects` and `Unresolved` are uncertain; `Failed` and `Cancelled` are definite exactly when `execution.unknown_effects` is `[]`, nothing is left in place (an undo or cleanup that returned an error, a step without an undo, a held step), and the cause is a typed error, a missed deadline, or an output crash. The evidence names each unknown action (step, attempt, decision or undo, and how it ended) and never a crash reason or typed error. The mapping table is in the module docs (`a_crash_its_decider_aborted_is_uncertain_test`, `a_sibling_that_crashed_while_settling_is_uncertain_test`, `a_crash_retried_to_success_is_uncertain_test`, `a_crashed_recovery_decision_is_uncertain_test`, `a_crashed_undo_is_uncertain_test`, `a_completed_workflow_is_the_tool_result_test`, `verdict_test`). |
| X2: cancel depended on the runner cooperating; a "lost" child went on paying                                                                                                        | Fixed  | A cancellation the live runner does not take is committed to the record (the held runner's work abandoned, a new incarnation); the held runner's next commit conflicts, so it records no model turn and starts no tool. A fence is answered as soon as its start is stored, so no body starts after a later cancellation. `ChildLost` only on store failure (`a_held_child_is_cancelled_through_its_record_test`, `a_held_run_is_cancelled_through_its_record_test`, `a_handler_cancelling_its_own_run_commits_the_cancellation_test`).                                                                                                                                                                                                                                                                                                                                                                                                                           |
| X3: an answer committed after an ancestor's cancellation                                                                                                                            | Fixed  | A sub-agent reads its ancestors at every tool fence and before storing a child; one that finds an ancestor stopping or ended starts nothing and cancels itself. An answer may still commit; nothing it approved starts (`a_tool_under_a_stopping_ancestor_never_starts_test`, `a_sub_agent_under_a_stopping_ancestor_never_starts_test`, `an_answer_racing_the_parent_cancellation_starts_nothing_test`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| X4: a settlement was accepted twice                                                                                                                                                 | Fixed  | The first accepted settlement moves the action out of the state that awaits one (`a_settlement_is_accepted_once_per_action_test`, `a_settlement_is_accepted_once_test`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| X5: a settlement after the bound, or from a still-running handler, was accepted while stopping                                                                                      | Fixed  | `Stopping` records `tools_stopped`; a stopping run accepts a settlement only after that and within the bound. An earlier one waits for the confirming commit; a later one is refused. Decision: a late definite settlement of an action that became uncertain while the run was not stopping stays allowed, as the one accepted settlement (`a_settlement_after_the_bound_is_refused_while_stopping_test`, `a_settlement_before_the_tools_stopped_is_early_test`, `a_settlement_while_the_task_runs_waits_for_its_report_test`, `a_handler_settling_its_own_call_is_refused_test`).                                                                                                                                                                                                                                                                                                                                                                               |
| X6: the no-runner command path ran handlers before the runner started; `cancel_unattended` ignored the configured timeout                                                           | Fixed  | The runner receives its first state before the caller emits the commit's events; the agent-less child cancellation uses the parent's command timeout (`cancel_stored` has no agent and keeps the default); docs say a command with no runner emits its events in the caller (`a_runner_started_by_a_command_works_while_its_handlers_run_test`, `a_command_with_no_runner_emits_its_events_in_the_caller_test`, `a_handler_in_a_commands_caller_can_command_the_run_test`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| X7: `RunnerBusy` could leave a command applied                                                                                                                                      | Fixed  | Each command carries a claim (one atomics cell): the runner applies it only if it takes the claim, a caller withdraws it before reporting busy (`racing_sides_never_both_win_test`, `a_command_the_runner_took_is_waited_for_test`, `a_withdrawn_command_is_never_applied_test`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| X8: the Saga receiver swallowed settle errors                                                                                                                                       | Fixed  | `SettleError` splits `AlreadyRecorded` from `NotAwaited`; every refusal emits `settlement_refused` with a summary for a person (`tool.settle_summarized`); the receiver handles each answer and gives Saga's report summary (`a_refused_settlement_is_observed_test`, `an_outcome_after_the_run_ended_is_refused_test`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| X9: a tombstone recognised by an empty transcript; a settling child reported lost; a late-landing child insert left without a runner                                                | Fixed  | The phase `NeverStarted`, record version 3, a version 2 tombstone read as it (`a_child_that_never_started_is_explicit_test`); `ChildStopping` (`cancel_stored_of_a_parent_with_a_settling_child_test`); a start that finds its child stored gives it a runner or takes it over (`a_child_whose_insert_lands_late_still_runs_test`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Probe: a settlement bound past 2^32 - 1 ms left a cancelled run working forever                                                                                                     | Fixed  | `SettlementBoundTooLarge` (`a_settlement_bound_must_fit_a_timer_test`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |

Limits and follow-ups:

- **Workflows with a recovery decider were always uncertain (X1)**
  (resolved in saga `4a93b04`). Saga now names every step attempt,
  recovery decision and undo that ended without a result, whatever was
  decided afterwards, so the verdict is uncertain only for the actions
  that actually crashed, timed out or were interrupted, and for effects
  left in place.
- **A held runner's running bodies (X2)** (resolved by the focused review
  fixes below). A held runner is killed once the cancellation is committed
  to its record, and its tool bodies with it.
- **A model call in flight when a handler cancels its own run.** A runner
  cannot be killed from its own process: it starts no model call or child
  once its record moved on, but a model call it had already started runs
  until it answers, and the runner then stops at the conflicting commit.
- **The fence check is a read (X3)** (corrected by the focused review fixes
  below). A fence reads the ancestors before and after storing the start,
  and the body starts only if both find them open, so a body that starts
  was stored before any later ancestor cancellation, which reaches the
  child with the tool running and records it uncertain.
- **A child adopted after a late insert (X9)** emits no `run_started`: the
  insert that stored it reported a failure and emitted nothing.
- **Other timeouts past 2^32 - 1 ms** (`with_command_timeout`,
  `with_policy_timeout`) are not yet refused.

## Slice 2b focused review fixes

A focused review of `1d71bec..3bf19a1` found no blockers and four minor
findings; its probe of the held runner is ported as an asserting test.
Fixed test-first, one commit each:

| Finding                                                                                                                                                                                                                                                             | Status | Resolution and evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| X2: a held runner still called the model (or started a child) after its cancellation was committed to the record, and an in-flight model call of a run cancelled through its record kept running                                                                    | Fixed  | A cancellation committed to the record of a runner held by another process kills that runner once it is stored, and with it its model call and tool bodies. A runner performs a model call or child start only while the record is at its own commit, so one whose own handler cancelled its run does neither (`a_held_runner_calls_no_model_after_its_cancellation_test`, `a_held_runners_running_body_dies_with_it_test`, `a_runner_whose_handler_cancelled_its_run_calls_no_model_test`). |
| X3: the fence race was not always recorded uncertain: a fence read its ancestors open, an ancestor's cancellation committed, the start was stored, and a fast body finished before the child's cancellation arrived, so the parent took the child's end as definite | Fixed  | The fence reads the ancestors again once the start is stored, before answering; one that finds an ancestor stopping or ended starts nothing and cancels itself (`a_start_racing_an_ancestor_cancellation_never_runs_test`).                                                                                                                                                                                                                                                                  |
| Recovery reattached a child that was never stored (`family.reattach_child`) without reading the ancestors, so a recovered sub-agent under a stopping ancestor started its child                                                                                     | Fixed  | Reattaching reads the ancestors first, as a start does; one that finds an ancestor stopping or ended starts no child and cancels the run, whose cancellation buries the child (`a_reattached_sub_agent_under_a_stopping_ancestor_never_starts_test`).                                                                                                                                                                                                                                        |
| `runner.adopt_child` gave a stored child record equal to this start's first record a runner at the same incarnation, so an identical first record inserted by another writer, which may be running it, got a second runner making the same first model call         | Fixed  | A start writes its child with one encoding, and so one write token, across its insert attempts; only a record carrying that token is adopted as its own. Any other record, equal or not, is recovered as a new incarnation (`an_identical_child_record_by_another_writer_is_recovered_test`, `a_child_whose_insert_lands_late_still_runs_test`).                                                                                                                                             |

Limit noted by the review:

- **Record version 3 blocks a rolling upgrade.** Every write is record
  version 3 (the phase `NeverStarted`), and a binary from before it reads
  only versions 1 and 2, so an older node cannot read any record a newer
  one has touched, including a record it wrote itself and a newer node
  then committed. Upgrade every node that shares a store together.

## Slice 2b — sub-agents, observations, Saga workflows as tools

Implemented. Acceptance, each with its executed evidence
(`test/fabric/delegation_test.gleam`, `delegation_controller_test.gleam`,
`observation_test.gleam`, `integrations/fabric_saga/test`,
`consumers/app`):

1. **Approval before a sub-agent starts.** The parent's policy sees the start
   as an action with its target and may require an approval; no child
   record exists before it is approved, also across a restart; a rejected
   start never creates the child and the model sees the rejection
   (`a_sub_agent_starts_only_after_approval_even_across_a_restart_test`,
   `a_rejected_sub_agent_never_starts_test`,
   `an_approved_sub_agent_starts_with_the_recheck_context_test`,
   `an_allowed_delegation_names_its_child_before_the_child_exists_test`).
2. **Child pauses surface (anti-oracle B1).** A child's pending approval is
   the parent's, its reference names the child run, answering it through the
   parent resumes the child, and the child's completion feeds the parent's
   delegation (`a_child_pause_surfaces_to_the_parent_and_is_answered_through_it_test`).
3. **Cancellation.** Cancelling the parent cancels paused and active
   children through the store; a child cancelled while a tool ran makes the
   delegation uncertain; a child's model reply after the cancel is
   discarded; a child that ended while its parent was stopping is recorded
   and the parent still ends cancelled; a later end is refused;
   `cancel_stored` cancels children first with no agent
   (`cancelling_the_parent_cancels_a_paused_child_test`,
   `cancelling_the_parent_stops_an_active_child_test`,
   `a_child_reply_after_the_parent_was_cancelled_is_discarded_test`,
   `a_stopping_run_waits_for_its_children_and_ends_cancelled_test`,
   `cancel_stored_cancels_the_children_first_test`).
4. **Restart.** Recovering the parent recovers the child (its running tool
   becomes the child's uncertain effect, reported through the parent and
   reconciled on `fabric.child`'s handle); a child record that cannot be
   read makes the delegation uncertain; a runner lost while starting a
   child leaves it delegated, and recovery starts or reattaches the child,
   or asks again for an approved start whose child was never stored
   (`recovering_the_parent_recovers_its_child_test`,
   `an_approved_sub_agent_never_stored_is_asked_for_again_test`,
   `an_unreadable_child_is_an_uncertain_effect_of_the_parent_test`,
   `recovery_keeps_delegations_waiting_on_their_children_test`).
5. **Budgets.** `max_children` counts started children and those awaiting an
   approval; `max_depth` counts levels below the root and a child is bounded
   by what its parent has left; both refuse before the policy with a
   model-visible `limit_reached`
   (`delegations_beyond_the_child_limit_are_refused_test`,
   `nested_delegation_is_bounded_by_the_root_depth_test`,
   `the_child_limit_counts_started_and_awaiting_children_test`). A child is
   validated with its parent (`a_delegation_is_validated_with_its_child_test`).
6. **Record version 2** with a tested reading of version 1 records
   (`a_version_1_record_is_read_as_a_root_run_without_sub_agents_test`).
7. **Sinal observations** after each commit, from the committing process,
   documented per event in `fabric/observation`; a failing or crashing
   handler is detached without affecting the run
   (`a_run_is_observed_after_each_commit_test`,
   `a_failing_handler_does_not_affect_the_run_test`,
   `sub_agents_cancellation_and_recovery_are_observed_test`).
8. **A Saga workflow as a tool** (`fabric_saga`), tested with the `book_trip`
   shape: completion, a hotel failure that releases the flight (typed,
   definite), a release that fails (uncertain), a step that failed after
   retries (definite when every attempt returned a typed error), Fabric cancellation that cancels the Saga run and
   settles the stopped call with Saga's rollback (definite when every
   completed step was undone, uncertain when an undo failed or a step was
   interrupted, refused once the call's bound has passed), and an invalid
   configuration refused up front.
9. **Consumer**: a purchasing sub-agent gated by the committee whose own
   order approval surfaces at the front desk, cancelling the desk with the
   purchaser paused, an interlibrary loan as a Saga tool, and application
   Sinal handlers (`consumers/app/test/app_test.gleam`).
10. **Oracle**: the `task` gate (approve runs the child once, reject never
    starts it) matches BeamWeaver fixtures; B1 is executed
    ([ORACLE.md](ORACLE.md#slice-2b-results)).

Backlog from this slice:

- **Shared budgets.** Each child has its own turn and token budgets; there is
  no budget shared across a family (a parent's token budget does not count
  its children's tokens), and no elapsed-time budget.
- **Child context.** A child shares its parent's context type and receives
  the parent's run context; a delegation cannot derive a narrower context.
- **Recovery of a child alone.** `recover` on a child id works, but the child
  then has no parent link in that handle; its end reaches the parent only
  when the parent is recovered or its runner delivers it.
- **Answer routing cost.** Reading a family reads every active descendant's
  record; deep or wide trees make `status` and `await` proportionally more
  expensive.

## Slice 3 — streaming, structure, durable stores

- Supervision (done in S2, above): a supervision tree instead of starter-owned stores and
  unsupervised runners, with the runner stopping on a supervisor's exit
  signal (slice 2a review) as its starting point. The store is supervisable
  since the ergonomics pass (`store.supervised`); runners are still
  started unsupervised and owned through their store process.
- Leases for runs driven through several Stores are built (production S3,
  above); a Grind-driven recovery that carries only a run reference
  remains.
- Streamed model progress through llm_wire `session.stream`, with
  cancellation closing the stream.
- Budgets shared across a sub-agent family.
- Structured final output via llm_wire's structured session.
- Elapsed-time budget with a trusted clock and per-tool timeouts.
- PostgreSQL storage is implemented in production S4. Grind delivery
  carrying only a run reference remains.

## Slice 1 status and friction

Slice 1 is implemented: see the gates in the repository README and the
oracle results in [ORACLE.md](ORACLE.md#slice-1-results). Friction observed in
sibling packages, recorded for separate evidenced improvements (no sibling was
changed):

- **llm_wire validated tool calls while reading the response** (resolved in
  llm_wire `660370f`). An unknown tool name or schema-invalid arguments failed
  the whole turn with `ProtocolError`. `llm.model` now selects
  `types.ReportInvalidToolCalls`, and Fabric's registry answers each such call
  (`invalid_calls_through_llm_wire_get_per_call_feedback_test`).
- **llm_wire continuation and retry ownership** (resolved by the 2026-09-29
  library adoption, above). The old continuation held live values and could
  not be persisted. The replacement returns assistant turns as data; Fabric
  stores their provider metadata and rebuilds requests. `retry.assess`
  classifies failure causes without choosing Fabric's retry policy.
- **llm_wire had no public test transport** (resolved in llm_wire
  `5cf5232`). Fabric's loopback SSE stub is replaced by `llm_wire/testing`.
- **llm_wire accepted any non-empty tool name** (resolved: `types.tool_name`
  now enforces the providers' grammar). Fabric's registry uses it instead of
  its own copy of the grammar.
- **json_blueprint descriptions and decode-error rendering** (resolved in
  `129c963`). `codec.describe` annotates schemas without changing validation;
  llm_wire `cc79a69` preserves those annotations in provider schemas.
  Fabric used `codec.render_json_decode_error`, adopted in `dffdfda`; since
  json_blueprint wave 2 it uses `codec.describe_decode_error`.
- **Unpublished path dependencies.** json_blueprint reports version 1.7.1 on
  its unreleased 2.0 branch; llm_wire, json_blueprint, and sinal resolve only
  as `../` path dependencies, so `.github/workflows/ci.yml` cannot build Fabric
  without checking the siblings out beside it.
- **sinal** is used directly since slice 2b; see the slice 2b friction.

## Slice 2b friction

Each item was resolved by a sibling change made from this evidence and
adopted here:

- **llm_wire should replay arguments it reported invalid** (resolved in
  llm_wire `a822ea4`). Anthropic and Google now wrap non-object argument
  text as `{"unparsed_arguments": text}` and OpenAI replays it verbatim;
  `fabric/llm` passes the recorded arguments through
  (`unparseable_arguments_replay_to_anthropic_as_an_object_test`,
  `unparseable_arguments_replay_to_openai_verbatim_test`).
- **Saga: learn an outcome after the owner is gone** (resolved in saga
  `eb9e784`). `execution.start_reporting` delivers the outcome, after
  rollback, to a subject that may belong to another process. `fabric_saga`
  owns it in a receiver per call, and with the settlement seam
  (`tool.bind_settling`) a cancelled call records a definite failure when
  Saga's report proves every completed step undone and no effect unknown
  (`a_cancellation_that_undid_everything_is_definite_test`). The settle
  window (`settle_timeout`) still delays that settlement; `rollback_within`
  bounds how long Fabric waits.
- **Saga: name every action whose effect is unknown** (resolved in saga
  `4a93b04`). A crashed attempt whose recovery decider aborted, retried or
  continued, and a sibling that crashed in the settle window, left no
  trace Fabric could tell from a typed error, so every workflow with a
  recovery decider was uncertain. `execution.unknown_effects` now lists
  them for every outcome; `fabric_saga` classifies from it
  (`a_crash_retried_to_success_is_uncertain_test`, `verdict_test`).
- **Sinal: a handler that blocks holds up the emitter** (resolved in sinal
  `c886825`). `forwarder.emit_routed`, and since sinal wave 2
  `sinal.emit` itself, follows the application's routes; Fabric emits with it, and `consumers/app` routes `[fabric]` at start
  (`a_routed_handler_runs_in_the_forwarder_and_does_not_stall_the_run_test`,
  `an_unrouted_handler_runs_in_the_runner_test`).

## Tested sibling revisions

Round 9 local dependency revisions (refreshed at closeout):

| Package        | Revision  |
| -------------- | --------- |
| llm_wire       | `7fdaf86` |
| http_gun       | `c34a0f5` |
| json_blueprint | `4ed1d2e` |
| sinal          | `44c5395` |
| saga           | `380758a` |
| grind          | `eb7b173` |
| relay          | `166ddd6` |
| warden         | `f6120ef` |

Fabric resolves its siblings as `../` path dependencies, each checked out on
its default branch. The wave 3 migration gate on 2026-10-02 (HTTP Gun's
`testing.playback` and schema 2 cassettes, Saga's `unknown_when`, setters
and callback records, json_blueprint's `codec.placeholder` and Sinal's
`measurement_fields`) passed against these local revisions, each with a
clean working tree; the wave is pushed only after every package passes:

| Package        | Revision  | Relationship                                                                     |
| -------------- | --------- | -------------------------------------------------------------------------------- |
| llm_wire       | `576482e` | Direct dependency (`fabric/llm`, `fabric/graph/llm`); first client API `1c0ad61` |
| http_gun       | `1a5f5ef` | Direct dependency: the caller-owned client the LLM adapters run on               |
| json_blueprint | `74a9a7d` | Direct dependency (tool and output codecs); `codec.placeholder`                  |
| sinal          | `44c5395` | Direct dependency (`fabric/observation`); `measurement_fields`                   |
| saga           | `2ee5e0a` | Dependency of `integrations/fabric_saga` and the consumer only; not of Fabric    |

The wave 5 slice F4 gate on 2026-10-03 (`fabric_relay` and the corrective
answer turn) passed against llm_wire `2c32d5e`, http_gun `4a6eeb0`,
json_blueprint `07e64fc`, sinal `44c5395`, saga `9a0b1d8` and relay
`b83486b`, a dependency of `integrations/fabric_relay` only, not of Fabric.

The follow-up builder migration gate on 2026-10-02 (the Sinal record builder
and the json_blueprint `get:` getters) passed against llm_wire `ea7c90b`,
http_gun `056536b`, json_blueprint `bb4da39`, sinal `6de2b69` and saga
`d4eef94`.
The Sinal and Blueprint wave 2 migration gate on 2026-10-02 passed against
llm_wire `bc5d626`, http_gun `1dc20a1`, json_blueprint `f55ec09`, sinal
`5aef827` and saga `43ae141`.
The HTTP Gun client migration gates on 2026-10-01 passed against llm_wire
`220b134`, http_gun `369da4f`, json_blueprint `129c963`, sinal `8acec45` and
saga `2c9992e`.
The 2026-09-29 library adoption gates passed against llm_wire `cc79a69`
plus then-pending working-tree changes (SHA-256
`250c885b15ba7d61371105e76cde10b5d8b8dec54ce609e144df70d92ff3f84d`), with
json_blueprint `129c963`, sinal `858dfa3` and saga `4a93b04`. llm_wire later
committed its caller-owned conversation API as `bbde1d9`. Fabric did not
modify any sibling source.

Historically, the completion
gates through production S6 passed against these revisions, each
with a clean working tree (the slice 3 ergonomics pass used sinal
`c886825`):

| Package        | Revision  | Relationship                                                                  |
| -------------- | --------- | ----------------------------------------------------------------------------- |
| llm_wire       | `a822ea4` | Direct dependency (`fabric/llm`, `llm_wire/testing` in tests)                 |
| json_blueprint | `ecf5c60` | Direct dependency (tool codecs)                                               |
| sinal          | `858dfa3` | Direct dependency since slice 2b (`fabric/observation`)                       |
| saga           | `4a93b04` | Dependency of `integrations/fabric_saga` and the consumer only; not of Fabric |

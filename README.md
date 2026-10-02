# fabric

A bounded, typed LLM agent and agentic graph runtime for Gleam: typed application operations, an explicit policy gate, pure controllers, and supervised runners with cancellation. It consumes llm_wire for providers and json_blueprint for codecs. Saga workflows remain an optional integration.

Status: slice 1 (bounded agent execution), slice 2a (durable pause, approval, resume, cancellation, and restart), slice 2b (approval-gated sub-agents, Sinal observations, and Saga workflows as tools), the public API ergonomics pass (a built agent, one policy gate, typed run ids, a named supervisable store), and the first production-runtime slices (timer limits; runners supervised under the store's subtree, drained and handed off on shutdown; the leased store contract for several nodes sharing one database, with an in-memory test backend, the PostgreSQL adapter, and automatic recovery of expired leases) implemented; see [docs/PLAN.md](docs/PLAN.md), [docs/CAPABILITIES.md](docs/CAPABILITIES.md) and [docs/ORACLE.md](docs/ORACLE.md). Design: see [fabric-design.md](https://github.com/gleam-dream/oversight/blob/master/fabric-design.md) in [gleam-dream/oversight](https://github.com/gleam-dream/oversight). Not yet published to Hex.

Behavioural oracle: BeamWeaver (partial migration of its agent loop).

Serial agentic graphs are available through `fabric/graph`: typed operations,
conditional routing, bounded cycles, durable records, approval, recovery,
reconciliation, typed durable signals, managed subgraphs and managed ordinary
agents with idle/nested waits. `fabric/graph/agent` binds a native input,
prompt and typed reply conversion to the existing agent runner.
See the [runnable public graph consumer](consumers/graph/README.md)
and [graph implementation tracker](docs/implementation/graph-flow/wave-tracker.md).
The [external-job consumer](consumers/jobs/README.md) proves durable submission,
receipt recovery and retained read-only job observation against a separate local
service. `operation.await_job` retains the receipt without holding a runner;
`graph.poll_job` records completion. Opt in with `job.with_poll_interval` to let
the registered sweeper observe due jobs on a leased store, including after
restart. Canceling a read-only binding detaches observation. `operation.own_job`
instead admits cancellation ownership: `graph.cancel` saves intent, fences the
stop request, and exposes `CancellingJob` until an observation confirms a terminal
outcome. Acknowledgments and uncertain requests survive restart. Completion after
local cancellation is retained without routing success.
Terminal agent uncertainty settlement, complete-family PostgreSQL retention and
shared work/child/depth budgets are implemented. Registered graph sweeping recovers
expired work and changed idle dependencies after local wakeups are lost.
Signal, job, managed-child and fork deadlines survive restart and retain
expiration separately from owned cleanup. Typed pairs and bounded maps retain
private member results and join them in input order, including after restart.
`fabric/graph/llm` binds a structured LLM decision to an ordinary graph activity,
retaining typed answers, raw JSON and usage without a chat continuation. See the
[decision consumer](consumers/decision/README.md) and
[adapter contract](docs/implementation/graph-flow/decision-adapters.md).
The optional [MCP package](integrations/fabric_mcp/README.md) binds discovered
tool schemas and native values to policy-gated operations, retaining original
responses and restoring saved results without replay. Its stdio client and graph
binding are exercised against a real local service.
The optional [TypeSafe package](integrations/fabric_typesafe/README.md) provides
non-generative yes/no, enum and rubric-score decisions with durable typed receipts.
Its protocol tests, shared routing consumer and actual OpenAI/TypeSafe
[validation](docs/implementation/graph-flow/completion-audit.md) pass. The [agent-recipe evaluation](docs/implementation/graph-flow/agent-recipe-evaluation.md)
retains ordinary agents as managed graph nodes, preserving per-tool approval,
recovery and cancellation while sharing execution mechanisms.

The [writing consumer](consumers/writing/README.md) composes real source and
artifact tools with generation, interchangeable LLM/TypeSafe review, bounded
revision and durable approval. Its tests exercise restart and an interrupted
save; an explicit live runner compares both reviewers on the same frozen cases
and verifies a full workflow across separate VMs.

Dependencies on `llm_wire`, `http_gun`, `json_blueprint`, and `sinal` are path dependencies (`../llm_wire`, `../http_gun`, `../json_blueprint`, `../sinal`); check out the sibling repositories next to this one. The LLM adapters take the application's started `http_gun.Client`; Fabric never starts or stops one. The optional Saga integration, `integrations/fabric_saga`, is a separate package that also needs `../saga`.

Run all maintained packages, consumers and local service/database checks with
`nix develop -c python3 scripts/check.py full`. See [verification](docs/VERIFICATION.md)
for fast iteration, logs and the prepared CI profile. Library publication and
hosted CI activation remain deferred.

## Usage

A payment desk: a typed tool whose large transfers wait for a treasurer's
approval, a supervised durable store, a request that starts a run, and a
later request that opens the run by its id to approve, reject, or
reconcile it. The block is `test/fabric/readme_example.gleam` verbatim;
`test/fabric/readme_test.gleam` checks that and runs it.

```gleam
import fabric
import fabric/agent.{type Agent}
import fabric/model.{type Model}
import fabric/policy
import fabric/run
import fabric/store
import fabric/tool
import gleam/erlang/process
import gleam/option.{Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import json/blueprint/codec

/// The live context of a run: who acts. It is never stored.
pub type Context {
  Context(user: String)
}

pub type Transfer {
  Transfer(to: String, amount: Int)
}

pub type Receipt {
  Receipt(id: String)
}

pub type TransferError {
  InsufficientFunds
  GatewayTimeout
}

/// A tool's definition owns its name and its input and output codecs: the
/// declaration the model sees and the decoder of its arguments.
pub fn transfer_definition() -> tool.Definition(Transfer, Receipt) {
  let input = {
    use to <- codec.field("to", codec.string(), get: fn(t) { t.to })
    use amount <- codec.field("amount", codec.int(), get: fn(t) { t.amount })
    codec.success(Transfer(to:, amount:))
  }
  let output = {
    use id <- codec.field("receipt", codec.string(), get: fn(r) { r.id })
    codec.success(Receipt(id:))
  }
  tool.define("transfer_funds", "Transfer an amount.", input, output)
}

/// Binding a typed handler says what each of its errors means: a definite
/// failure the model sees, or an effect that may have happened, which is
/// never retried and waits for a person to reconcile it.
pub fn transfer_tool(
  pay: fn(Transfer) -> Result(Receipt, TransferError),
) -> tool.Tool(Context) {
  tool.bind(
    transfer_definition(),
    fn(_context, transfer) { pay(transfer) },
    fn(error) {
      case error {
        InsufficientFunds -> tool.Explain("insufficient funds")
        GatewayTimeout -> tool.Uncertain("the gateway timed out after sending")
      }
    },
  )
}

/// One policy gates every effect. `tool.input` matches an action on a
/// tool's definition and gives its typed input (`None` for another tool);
/// arguments that definition cannot read are an error, which stops the run.
pub fn desk_policy(
  _context: Context,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  use transfer <- result.try(tool.input(transfer_definition(), action))
  case transfer {
    Some(transfer) if transfer.amount > 100 ->
      Ok(policy.RequireApproval(run.Requirement("treasurer", 1)))
    _ -> Ok(policy.Allow)
  }
}

/// An agent is described, then built once: `build` reports every problem.
/// A provider's model comes from `fabric/llm.model(client, settings, model_id)`,
/// given the application's started HTTP Gun client.
pub fn desk(
  model: Model,
  pay: fn(Transfer) -> Result(Receipt, TransferError),
) -> Result(Agent(Context), List(agent.ConfigError)) {
  agent.new("desk", model, [transfer_tool(pay)], desk_policy)
  |> agent.with_limits(
    agent.Limits(
      ..agent.default_limits(),
      max_turns: 6,
      token_budget: Some(20_000),
    ),
  )
  |> agent.build
}

/// A store is a named value. Its subtree, the store's process and the
/// factory its runners start under, runs under the application's supervisor
/// (`store.start(runs)` in a script or a test). When the application stops,
/// each runner drains for up to the drain window: it starts nothing new,
/// lets its running tools and model call finish, commits their results, and
/// hands its run off to `resume` below. A runner still busy when the window
/// ends is killed, and its running tools become uncertain effects. A
/// directory store suits development, tests and one host; it does not
/// survive a power loss, so production uses a database backend through
/// `store.new`.
pub fn supervise(path: String) -> Result(store.Store, actor.StartError) {
  let assert Ok(runs) =
    store.directory(process.new_name("runs"), path)
    |> store.with_drain(10_000)
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(store.supervised(runs))
  |> static_supervisor.start
  |> result.replace(runs)
}

/// A request starts a run and keeps its id (in a link, a job, a table).
pub fn start_payment(
  runs: store.Store,
  desk: Agent(Context),
  context: Context,
  prompt: String,
) -> Result(String, fabric.StartError) {
  use handle <- result.map(fabric.start(runs, desk, context, prompt))
  run.id_to_string(fabric.id(handle))
}

pub type Verdict {
  Approve
  Reject(reason: String)
  /// What actually happened to an effect of unknown status, as the model
  /// will see it.
  Happened(content: String)
}

/// A later request opens the run by the id it kept and acts on its status.
/// Opening takes nothing over, and every command is checked against the
/// stored record. The application authenticates the reviewer; an approval
/// checks the policy again with the context passed here.
pub fn review(
  runs: store.Store,
  desk: Agent(Context),
  context: Context,
  stored_id: String,
  verdict: Verdict,
) -> Result(run.Status, fabric.CommandError) {
  use id <- result.try(
    run.parse_id(stored_id)
    |> result.replace_error(fabric.Unreadable(fabric.RunNotFound)),
  )
  use handle <- result.try(
    fabric.open(runs, desk, context, id) |> result.map_error(fabric.Unreadable),
  )
  use status <- result.try(
    fabric.await(handle, 5000) |> result.map_error(fabric.Unreadable),
  )
  let reviewer = Some(context.user)
  case status, verdict {
    run.Suspended([pending, ..], _), Approve ->
      fabric.approve(handle, pending.reference, reviewer:, context:)
    run.Suspended([pending, ..], _), Reject(reason) ->
      fabric.reject(handle, pending.reference, reason:, reviewer:)
    run.Suspended(_, [uncertain, ..]), Happened(content) ->
      fabric.reconcile(handle, uncertain.reference, content)
    // `Working`: the time ran out. `Unattended`: its runner was lost.
    // `Finished`: nothing more can change it.
    status, _ -> Ok(status)
  }
}

/// At boot, when the previous owner is known to be gone, `recover` takes
/// over work whose runner was lost. A run handed off by a drained shutdown
/// goes on with nothing uncertain; after a crash, running tools become
/// uncertain effects, never retried. On an unleased store, never recover
/// a run another process may drive; a leased store's `recover` leaves a run
/// alone while another node holds its lease.
pub fn resume(
  runs: store.Store,
  desk: Agent(Context),
  context: Context,
  stored_id: String,
) -> Result(fabric.Run(Context), fabric.CommandError) {
  use id <- result.try(
    run.parse_id(stored_id)
    |> result.replace_error(fabric.Unreadable(fabric.RunNotFound)),
  )
  fabric.recover(runs, desk, context, id)
}

pub type Topic {
  Topic(name: String)
}

pub type Summary {
  Summary(text: String)
}

/// A sub-agent is a typed delegation whose start the policy gates like a
/// tool (`action.target` is `policy.StartAgent(..)`). Its approvals surface
/// in the parent's status, cancelling the parent cancels it, and
/// recovering the parent recovers it. `output` parses a completed
/// sub-agent's answer; any other ending is a definite failure the model
/// sees.
pub fn front_desk(
  model: Model,
  researcher: Agent(Context),
) -> Result(Agent(Context), List(agent.ConfigError)) {
  let research =
    tool.define(
      "research",
      "Research a topic.",
      {
        use name <- codec.field("topic", codec.string(), get: fn(t) { t.name })
        codec.success(Topic(name:))
      },
      {
        use text <- codec.field("summary", codec.string(), get: fn(s) { s.text })
        codec.success(Summary(text:))
      },
    )
  agent.new("front-desk", model, [], desk_policy)
  |> agent.with_sub_agent(
    research,
    to: researcher,
    prompt: fn(topic) { topic.name },
    output: fn(answer) { Ok(Summary(answer)) },
  )
  |> agent.build
}

/// A tool whose effect outlives its task settles its result late: its
/// handler gets a `tool.Settlement`, and a stopped run waits up to
/// `within` milliseconds for `tool.settle(settlement, result, summary:)`.
/// The summary is observed if the settlement is refused, so it must not
/// carry secrets.
pub fn settling_transfer(
  pay: fn(Transfer, tool.Settlement(Receipt)) -> Result(Receipt, TransferError),
) -> tool.Tool(Context) {
  tool.bind_settling(
    transfer_definition(),
    fn(_context, transfer, settlement) { pay(transfer, settlement) },
    fn(_error) { tool.Uncertain("the transfer did not report") },
    within: 5000,
  )
}
```

Stores: `store.in_memory` keeps records in its process (tests and
scripts). `store.directory` keeps them in files, for development, tests and
a single host: a record survives a process or VM crash, but not a power
loss or an operating-system crash, after which the latest revisions may be
missing and a tool whose start was among them could run again. In
production, use [fabric_postgres](integrations/fabric_postgres/README.md),
which supplies the leased backend, migrations and pruning of finished run
families, or provide an application backend through `store.new` or
`store.leased`.

Several nodes that share one database coordinate through per-run leases:
`store.leased(name, node: "app-1", lease: 30_000, backend:)` over a
`store.LeasedBackend` (its contract is in the `fabric/store` docs, and
`fabric/testing.leased_backend_checks` checks one; `testing.leased_memory()`
is one in memory, for tests). Every commit that keeps work in flight
requires the runner's store to hold the lease; a final commit releases it
with the revision check alone. Another node reads the run `Working`,
answers an idle run itself, gets `RunUnattended` for a command that needs the other node's
runner, and can always cancel. `recover` takes over only a free or expired
lease, or this store's lease whose runner is gone (including a lease of an
earlier store process), so it is safe to call at any time. Node ids must
be unique across live VMs; generated process names are unique only within
a VM. Coordination over Erlang distribution is not supported.

`store.now(runs)` reads UTC Unix milliseconds from the backend's lease and
discovery clock. Custom `LeasedBackend` implementations must provide `now`;
PostgreSQL uses database time, and unleased memory/directory stores use host
system time. Clock failures propagate without a local-time fallback. Signal
deadlines use this time domain; clock corrections can advance or delay expiry.

Automatic recovery: register agent roots with
`fabric.recovery(agent, context_for_run)` and graph roots with `graph.recovery`
(described below), then add
`fabric.sweeper(runs, recoveries, every: 1000)` after the store in a
rest-for-one supervisor. It scans expired leases and changed idle dependencies
at boot and periodically,
rebuilds context from the root run id, and recovers each eligible family
member under its own lease. A live parent learns a child’s stored outcome
even when another node recovered the child. Running tools become uncertain
and are never replayed. See the [PostgreSQL setup](integrations/fabric_postgres/README.md#automatic-recovery)
for shutdown order and recovery limits. The [operations runbook](docs/OPERATIONS.md)
covers readiness, database statistics, shutdown summaries, recovery procedures,
rolling upgrades and retention.

Conversations: Fabric stores each `model.AssistantTurn` (text, calls and
optional provider data) before dispatching tools. The llm_wire adapter
prepares the next request from that conversation, retaining signed Google
parts and custom adapter data across pauses and restarts. Fabric owns the
history and effects; llm_wire validates and interprets the provider data.
Application models return `model.ToolRequest(turn, usage)` and use
`model.AssistantTurn(text, calls, None)` when they have no provider data.

Rolling upgrades: the default agent-record writer is version 7; readers accept
versions 1–7. Writers 2–6 remain available for representable states.
Assistant provider data requires at least version 4; graph parent attachments
require version 5; settled child evidence requires version 6; retained root
family-budget declarations and quota outcomes require version 7. Older writers
refuse unrepresentable records before dispatching work. Configure the store before
starting it and use the returned value for every handle and sweeper.
Existing values and runners keep their setting; this does not migrate rows.
See the [rollout procedure](integrations/fabric_postgres/README.md#record-versions)
for compatibility and rollback limits.

Use `fabric.start_with_budget(store, agent, context, prompt, limits)` or
`graph.start_with_budget(runtime, id, initial, limits)` to bound the whole family.
For example, `budget.Limits(work: 40, children: 6, depth: 3)` allows up to 40
work admissions and six children, at most three levels below the root.
Graph attempts, model attempts and agent tool actions each spend one work unit;
managed children inherit the same ledger across graph/agent boundaries and
restarts. Rechecking an approval reuses its saved claim. Failed or uncertain
attempts retain their charge; these limits do not predict provider token costs.
Existing `start` calls keep their per-run limits without a shared family budget.
Quota exhaustion is a typed `FamilyLimit` agent outcome or `FamilyBudget` graph
failure, with started effects preserved for reconciliation. See the
[reservation contract](docs/implementation/graph-flow/managed-composition.md#shared-family-reservations).

Add `graph.recovery(identity, fn(pinned_store) { build_runtime(pinned_store) })`
alongside ordinary `fabric.recovery` registrations in `fabric.sweeper`. Rebuild
all child runtimes against the supplied store. The sweeper follows saved
attachments to the correct agent or graph root and recovers expired work
without taking a live parent's lease. An interrupted effect keeps its recovery
contract. Registrations are distinct by runtime kind and definition version.
Free managed waits remain discoverable when their child changes, including
after local wakeups are lost. Scheduled job waits and signal/job deadlines share
this scan. PostgreSQL schema version 5 indexes these waits; refresh existing rows with
`fabric_postgres.refresh_discovery` after migration. Only the backend's clock
determines when a polling interval is due. Failed observations retry after lease
expiry. Polls reuse the admitted wait's work grant.
Signal waits without a deadline require explicit delivery.

For a bounded signal wait, apply `operation.with_deadline(wait, 60_000)` before
binding it to a node. Approval admits the wait; the runner then saves its due
time from the backend clock. `snapshot.deadline` exposes that UTC timestamp.
Late delivery or recovery commits `Failed(DeadlineExpired(due))` without accepting
an output or routing onward. The sweeper discovers overdue waits on leased
backends after downtime. Unleased stores require explicit recovery or delivery.
Each new visit gets its own deadline. Eligibility uses the last backend time sample before the
revision-checked write; the clock check and write are separate operations.

The same option bounds a job wait. Read-only jobs finish with
`Expired(due, JobDetached(reference))`. Owned jobs retain
`CancellingJob(reference, progress, DeadlineReached(due))` until observation
confirms remote cancellation, completion or failure. A completed output is
retained with a canceled route. Explicit cancellation uses the separate
`CancellationRequested` cause; whichever cause commits first remains saved.
The deadline bounds Fabric's observation and acceptance, not the remote
service's completion timestamp. Scheduled jobs are discovered when either their
poll interval or deadline is due; cleanup then uses only the poll interval.
Manual jobs expire automatically on leased stores but require manual cleanup
observation.

For a managed agent or subgraph, apply the same option to its operation binding.
The parent saves the deadline before creating the child. Expiration records
`CancellingChild(reference, DeadlineReached(due))`, then
`Expired(due, ChildSettled(reference))` when cleanup settles. The child retains
its actual result. Uncertain effects remain `ChildUnresolved` until reconciled;
the family stays retained and the sweeper follows nested cleanup. Neither late
completion nor reconciliation reopens parent routing. The deadline governs
parent acceptance; committed stop intent closes further descendant admission.

After cancellation, `fabric.reconcile_stored(store, effect, content)` records
evidence for an uncertain tool without resuming the agent. Then
`fabric.settle_stored(store, agent_root)` verifies saved child outcomes and
propagates settlement through finished delegations. Both return a snapshot
with any remaining uncertain actions and need no deployed agent definition.
For a graph-owned agent, recover the graph parent afterward; it stays canceled
and records the child's settlement without invoking a route.

PostgreSQL retention follows saved graph and agent attachments. It preserves
whole families with unresolved effects or missing children, and prunes them
together only after settlement. See the [migration and refresh procedure](integrations/fabric_postgres/README.md#pruning).

A Saga workflow is one typed tool too, from the separate package
`integrations/fabric_saga`: `fabric_saga.tool(definition, workflow,
execution.config(), explain:, rollback_within:)`. A cancelled call waits up
to `rollback_within` ms for Saga's rollback: every completed step undone is
a definite failure, anything left in place an uncertain effect.
`consumers/app` uses it.

Observations: attach Sinal handlers to the events of `fabric/observation`.
They run in the committing process unless the application routes `[fabric]`
through a `sinal/forwarder` (`forwarder.route` at start, `forwarder.unroute`
at shutdown), which keeps a slow handler from holding up a run; handlers that
call Fabric should run there.

`consumers/app` is a complete external application using public imports only.

## Development

```sh
nix develop
gleam format --check src test
gleam build --warnings-as-errors
gleam test
(cd consumers/app && gleam test)
(cd integrations/fabric_saga && gleam test)
nix flake check
```

The PostgreSQL package has a separate gate. Its script starts and removes
its own temporary cluster; it never uses an existing database:

```sh
(cd integrations/fabric_postgres && gleam format --check src test && gleam build --warnings-as-errors)
integrations/fabric_postgres/scripts/test-postgres.sh
```

`scripts/check.py full`, and its prepared `ci` profile, run this PostgreSQL
gate with the other packages. The root `gleam test` runs no PostgreSQL
tests, and `nix flake check` checks formatting across the repository and
starts no database. The packages use
sibling path dependencies; see the tested revisions in [PLAN](docs/PLAN.md#tested-sibling-revisions).

Production slices S1–S6 are complete. [Remaining work](docs/REMAINING.md)
lists S7 operations, the later Grind integration, retained features and
release work, with optional improvements kept separate.

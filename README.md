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
import fabric/reviewer
import fabric/run
import fabric/store
import fabric/tool
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import gleam/time/duration
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
/// never retried and waits for a person to reconcile it. The handler also
/// gets the `tool.Call` it answers: its run, its action and the run's
/// correlation, for the requests it makes. A body runs for at most the
/// agent's tool timeout (`agent.with_tool_timeout`, 60 s by default).
pub fn transfer_tool(
  pay: fn(Transfer) -> Result(Receipt, TransferError),
) -> tool.Tool(Context) {
  tool.bind(
    transfer_definition(),
    fn(_context, _call, transfer) { pay(transfer) },
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
  |> agent.with_max_turns(6)
  |> agent.with_token_budget(20_000)
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
    |> store.with_drain(duration.seconds(10))
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(store.supervised(runs))
  |> static_supervisor.start
  |> result.replace(runs)
}

/// A request starts a run under an id it chooses and keeps (in a link, a
/// job, a table). A job derives the id from its own
/// (`run.id_from_parts("job", [job_id])`), so a retried start finds the run
/// (`fabric.AlreadyStarted`) instead of paying twice. The run's correlation is in every event, model request and tool
/// call of the run; `None` derives it from the id.
pub fn start_payment(
  runs: store.Store,
  desk: Agent(Context),
  context: Context,
  prompt: String,
) -> Result(String, fabric.Error) {
  let id = run.new_id()
  use _handle <- result.map(fabric.start(
    runs,
    desk,
    id:,
    context:,
    prompt:,
    correlation: None,
  ))
  run.id_to_string(id)
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
/// stored record. The application authenticates the reviewer and names it
/// with `reviewer.new`; an approval checks the policy again with the context
/// passed here, and one that comes after the request expired (7 days by
/// default, `agent.with_approval_expiry`) is `fabric.ApprovalExpired`.
pub fn review(
  runs: store.Store,
  desk: Agent(Context),
  context: Context,
  stored_id: String,
  verdict: Verdict,
) -> Result(run.Status, fabric.Error) {
  use id <- result.try(
    run.parse_id(stored_id)
    |> result.replace_error(fabric.RunNotFound),
  )
  use handle <- result.try(fabric.open(runs, desk, context, id))
  use status <- result.try(fabric.await(handle, within: duration.seconds(5)))
  let reviewer = reviewer.new(context.user)
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
/// uncertain effects, never retried, unless a tool is replayable
/// (`tool.with_replay`). On an unleased store, never recover
/// a run another process may drive; a leased store's `recover` leaves a run
/// alone while another node holds its lease.
pub fn resume(
  runs: store.Store,
  desk: Agent(Context),
  context: Context,
  stored_id: String,
) -> Result(fabric.Run(Context), fabric.Error) {
  use id <- result.try(
    run.parse_id(stored_id)
    |> result.replace_error(fabric.RunNotFound),
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
/// `settle_within` for `tool.settle(settlement, result, summary:)`.
/// The summary is observed if the settlement is refused, so it must not
/// carry secrets.
pub fn settling_transfer(
  pay: fn(Transfer, tool.Settlement(Receipt)) -> Result(Receipt, TransferError),
) -> tool.Tool(Context) {
  tool.bind_settling(
    transfer_definition(),
    fn(_context, _call, transfer, settlement) { pay(transfer, settlement) },
    fn(_error) { tool.Uncertain("the transfer did not report") },
    settle_within: duration.seconds(5),
  )
}
```

### Defaults

Every step and every wait is bounded unless the caller asks for
`run.Infinity`. A run's own length is then bounded by its turns, its model
and tool timeouts, and the answers it waits for.

| Bound                                       | Default                         | Change it with                                            | When it is reached                                                        |
| ------------------------------------------- | ------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------- |
| Model attempts per run                      | 8                               | `agent.with_max_turns`                                    | the run ends `BudgetExhausted(TurnLimit(8))`                              |
| One model call                              | 600 s                           | `agent.with_model_timeout`                                | the call stops; a retryable `model.TimedOut` that spends a turn           |
| One tool body                               | 60 s                            | `agent.with_tool_timeout`, `tool.with_timeout`            | the body stops; uncertain, or started again (`tool.with_replay`)          |
| Tool result size                            | 1 MiB                           | `agent.with_max_result_bytes`                             | the run fails with `OutputEncodingFailed`, naming the limit               |
| Concurrent tool bodies                      | 4                               | `agent.with_max_concurrency`                              | later tools queue                                                         |
| One policy decision                         | 5 s                             | `agent.with_policy_timeout`                               | the run stops closed (`PolicyFailed`)                                     |
| A command waiting for a busy runner         | 5 s                             | `agent.with_command_timeout`                              | `RunnerBusy`                                                              |
| First model retry delay                     | 200 ms, doubling up to 64 times | `agent.with_model_retry_delay`                            | a provider's `Retry-After` is waited instead when longer (10 min at most) |
| Sub-agents per run, depth                   | 4, 1                            | `agent.with_max_children`, `agent.with_max_depth`         | the delegation is refused and the model sees why                          |
| An approval request                         | 7 days                          | `agent.with_approval_expiry`                              | the request expires: the action is rejected, the model sees it            |
| Token budget                                | none (opt in)                   | `agent.with_token_budget`                                 | `BudgetExhausted(TokenLimit(..))`                                         |
| Family budget                               | none (opt in)                   | `agent.with_family_budget`                                | `BudgetExhausted(FamilyLimit(..))`                                        |
| Replays of a crashed tool body              | none (opt in)                   | `tool.with_replay`                                        | the action is an uncertain effect                                         |
| Drain window on shutdown                    | 25 s                            | `store.with_drain`                                        | the runner is killed; running tools become uncertain                      |
| Graph callbacks, operation bodies, commands | 1 s, 60 s, 1 s                  | `graph.with_timeouts(callbacks:, operations:, commands:)` | `CallbackFailed`, an uncertain operation, `Busy`                          |

Every timeout is a `gleam/time/duration.Duration`. An approval request
stores its deadline (`run.PendingApproval.expires`); one stored before
deadlines existed never expires. A graph signal, job, child or fork wait
stays unbounded until `operation.with_deadline` bounds it (the graph's
defaults follow with its vocabulary).

### Failures

Every function of `fabric` returns one `fabric.Error`. Branch on
`fabric.error_kind(error)`: `NotFound`, `Refused` (the run's state refuses
the request, such as `ApprovalExpired` or `AlreadyStarted`), `Retry` (a
transient conflict), `Unavailable` (the store or the runner, with a write
whose outcome may be unknown) or `Incompatible`; log with
`fabric.describe_error`. A model fails with an opaque `model.ModelError`:
`model.error_kind`, `model.is_retryable` and the provider's
`model.retry_after`. The unions that may grow (`fabric.Error`,
`agent.ConfigError`, `model.ErrorKind`, `run.Outcome`, `run.HostFailure`,
`run.ActionState`, `graph.Status`) each have such a classification or a
`describe_*` function.

### Correlation

A run has one `sinal/correlation.Correlation`, chosen where the run starts
(`fabric.start(.., correlation: Some(c))`) or derived from its id. It is
stored with the run and carried in every `fabric/telemetry` event of the
run and its sub-agents, in every `model.Request` (with the run id and the
turn), and in every tool's `tool.Call`. Every run event also names its
family's root run (`root`), so a sub-agent's events join their root's. `fabric/llm` puts it on each
turn's HTTP Gun client view, so one agent serves every run, and
`fabric_saga` starts each Saga run with it.

### Waiting for a run or a cancellation

`fabric.await(handle, within:)` blocks. A handler that must also react to
its caller, such as Relay's `tool.cancelled` signal, waits for both in one
receive with `fabric.await_with(handle, within:, or: selector)`: it returns
`Reached(status)`, or `Interrupted(message)` when the selector fires first,
and leaves the run as it is, so the handler decides whether to `cancel` it.
A run that must stop with the process that asked for it (a connection, a
request) is tied to it once: `fabric.cancel_when_down(handle, owner: pid)`
cancels the run when `pid` exits.

Stores: `store.in_memory` keeps records in its process (tests and
scripts). `store.directory` keeps them in files, for development, tests and
a single host: a record survives a process or VM crash, but not a power
loss or an operating-system crash, after which the latest revisions may be
missing and a tool whose start was among them could run again. In
production, use [fabric_postgres](integrations/fabric_postgres/README.md),
which supplies the leased backend, migrations and pruning of finished run
families, or provide an application backend through `store.new` or
`store.leased`. A store started with `store.start` (scripts and tests) is
stopped with `store.stop`, which drains its runners as a supervisor would.

Several nodes that share one database coordinate through per-run leases:
`store.leased(name, node: "app-1", lease: duration.seconds(30), backend:)` over a
`backend.LeasedBackend` (its contract is in the `fabric/store/backend` docs;
`fabric/store/conformance.checks` checks one, and
`conformance.leased_memory()` is one in memory, for tests). Every commit that keeps work in flight
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
`sweeper.agent(agent, context: context_for_run)` and graph roots with
`sweeper.graph` (described below), then put
`sweeper.supervised(runs, roots, every: duration.seconds(1))` under the
application's supervisor in place of `store.supervised(runs)`: it starts the
store's subtree and then its sweeper, so the order cannot be wrong. It scans expired leases and changed idle dependencies
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

Use `agent.with_family_budget(spec, limits)` (checked by `agent.build`) or
`graph.start_with_budget(runtime, id, initial, limits)` to bound the whole family.
For example, `budget.limits(work: 40) |> budget.with_children(6) |> budget.with_depth(3)`
allows up to 40 work admissions and six children, at most three levels below
the root.
Graph attempts, model attempts and agent tool actions each spend one work unit;
managed children inherit the same ledger across graph/agent boundaries and
restarts. Rechecking an approval reuses its saved claim. Failed or uncertain
attempts retain their charge; these limits do not predict provider token costs.
An agent without a family budget keeps its per-run limits only.
Quota exhaustion is a typed `FamilyLimit` agent outcome or `FamilyBudget` graph
failure, with started effects preserved for reconciliation. See the
[reservation contract](docs/implementation/graph-flow/managed-composition.md#shared-family-reservations).

Add `sweeper.graph(identity, build: fn(pinned_store) { build_runtime(pinned_store) })`
alongside `sweeper.agent` roots in `sweeper.supervised`. Rebuild
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

For a bounded signal wait, apply `operation.with_deadline(wait, duration.minutes(1))` before
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
retained with a stopped route (`graph.Stopped`). Explicit cancellation uses the separate
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
execution.config(), input:, explain:, rollback_within:)`. `input` builds the
workflow's input from the run's context, the `tool.Call` and the tool's
input, and each Saga run carries the Fabric run's correlation. A cancelled
call waits up to `rollback_within` for Saga's rollback: every completed step
undone is a definite failure, anything left in place an uncertain effect.
`consumers/app` uses it.

Telemetry: attach Sinal handlers to the events of `fabric/telemetry`.
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

# fabric

A bounded, typed LLM agent and agentic graph runtime for Gleam: typed application operations, an explicit policy gate, pure controllers, and supervised runners with cancellation. It consumes llm_wire for providers and json_blueprint for codecs. Saga workflows use a compiled recipe over the two packages' public APIs.

Start with [Usage](#usage): one agent with a typed tool, an approval, a
durable store, a typed answer and recovery, then the [defaults](#defaults)
every run gets. The [graph runtime](#graph-runs) (`fabric/graph`) and the
[integrations](#integrations) (MCP over Relay, Saga workflows, PostgreSQL,
TypeSafe classifiers) follow. Fabric is not yet published to Hex; see
[Status and scope](#status-and-scope).

## Usage

A payment desk: a typed tool whose large transfers wait for a treasurer's
approval, a supervised durable store, a request that starts a run, and a
later request that opens the run by its id to approve, reject, or
reconcile it. The block is `test/fabric/readme_example.gleam` verbatim;
`test/fabric/readme_test.gleam` checks that and runs it.

```gleam
import fabric
import fabric/agent.{type Agent}
import fabric/approvers.{type Approvers}
import fabric/model.{type Model}
import fabric/policy
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

/// The desk's final answer, typed: the model is asked for its JSON Schema,
/// and a run completes with the decoded value.
pub type Resolution {
  Resolution(summary: String)
}

pub fn resolution_codec() -> codec.Codec(Resolution) {
  use summary <- codec.field("summary", codec.string(), get: fn(r) { r.summary })
  codec.success(Resolution(summary:))
}

/// An agent is described, then built once: `build` reports every problem.
/// A provider's model comes from `fabric/llm.model(client, settings, model_id)`,
/// given the application's started HTTP Gun client. Without `with_answer`
/// the answer is the model's text (`Agent(Context, String)`).
///
/// `treasurers` decide who may answer the desk's approval requests: the
/// application's own `approvers.new(name, verify)`, whose `verify`
/// authenticates a credential (a token) and checks that it may answer the
/// request's requirement. `fabric/approvers` shows one for warden tokens.
/// Build them once, at boot, and give the same value to `review`: a proof
/// from any other approvers is refused.
pub fn desk(
  model: Model,
  pay: fn(Transfer) -> Result(Receipt, TransferError),
  treasurers: Approvers(credential),
) -> Result(Agent(Context, Resolution), List(agent.ConfigError)) {
  agent.new("desk", model, [transfer_tool(pay)], desk_policy)
  |> agent.with_approvers(treasurers)
  |> agent.with_answer(resolution_codec())
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
  desk: Agent(Context, Resolution),
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
  /// will see it (`tool.reconciliation` encodes a typed result).
  Happened(content: String)
  /// No one can say yet: the model is told so, and the run goes on.
  StillUnknown(note: String)
}

/// Why a review did nothing.
pub type ReviewError {
  /// The credential may not answer the request: not authenticated, not
  /// authorized for its requirement, or the verifier is unavailable.
  Denied(approvers.Denial)
  Failed(fabric.Error)
}

/// A later request opens the run by the id it kept and acts on its status.
/// Opening takes nothing over, and every command is checked against the
/// stored record. An approval checks the policy again with the context
/// passed here, and one that comes after the request expired (7 days by
/// default, `agent.with_approval_expiry`) is `fabric.ApprovalExpired`.
/// Every command returns the run's status, as `await` does; a finished
/// run's is `run.Finished(run.Completed(Resolution(..)))`.
///
/// An answer takes a proof: `approvers.check` verifies the reviewer's
/// credential for the request's requirement with the desk's approvers, and
/// the desk refuses a proof from any other approvers
/// (`fabric.ProofRefused`). The reviewer the verifier returned and the
/// approvers' name are recorded with the answer.
pub fn review(
  runs: store.Store,
  desk: Agent(Context, Resolution),
  treasurers: Approvers(credential),
  context: Context,
  credential: credential,
  stored_id: String,
  verdict: Verdict,
) -> Result(run.Status(Resolution), ReviewError) {
  use id <- result.try(
    run.parse_id(stored_id)
    |> result.replace_error(Failed(fabric.RunNotFound)),
  )
  use handle <- result.try(
    fabric.open(runs, desk, context, id) |> result.map_error(Failed),
  )
  use status <- result.try(
    fabric.await(handle, within: duration.seconds(5))
    |> result.map_error(Failed),
  )
  let prove = fn(pending: run.PendingApproval) {
    approvers.check(treasurers, credential, pending.reference.requirement)
    |> result.map_error(Denied)
  }
  case status, verdict {
    run.Suspended([pending, ..], _), Approve -> {
      use proof <- result.try(prove(pending))
      fabric.approve(handle, pending.reference, proof:, context:)
      |> result.map_error(Failed)
    }
    run.Suspended([pending, ..], _), Reject(reason) -> {
      use proof <- result.try(prove(pending))
      fabric.reject(handle, pending.reference, proof:, reason:)
      |> result.map_error(Failed)
    }
    run.Suspended(_, [uncertain, ..]), Happened(content) ->
      fabric.reconcile(handle, uncertain.reference, content)
      |> result.map_error(Failed)
    run.Suspended(_, [uncertain, ..]), StillUnknown(note) ->
      fabric.reconcile(
        handle,
        uncertain.reference,
        tool.unconfirmed_reconciliation(note),
      )
      |> result.map_error(Failed)
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
  desk: Agent(Context, Resolution),
  context: Context,
  stored_id: String,
) -> Result(fabric.Run(Context, Resolution), fabric.Error) {
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

pub fn summary_codec() -> codec.Codec(Summary) {
  use text <- codec.field("summary", codec.string(), get: fn(s) { s.text })
  codec.success(Summary(text:))
}

/// A sub-agent is a typed delegation whose start the policy gates like a
/// tool (`action.target` is `policy.StartAgent(..)`). Its approvals surface
/// in the parent's status, cancelling the parent cancels it, and
/// recovering the parent recovers it. The researcher's typed answer is the
/// delegation's output (`Summary`); any other ending is a definite failure
/// the model sees. A sub-agent without approvers of its own is answered
/// with its parent's.
pub fn front_desk(
  model: Model,
  researcher: Agent(Context, Summary),
  treasurers: Approvers(credential),
) -> Result(Agent(Context, String), List(agent.ConfigError)) {
  let research =
    tool.define(
      "research",
      "Research a topic.",
      {
        use name <- codec.field("topic", codec.string(), get: fn(t) { t.name })
        codec.success(Topic(name:))
      },
      summary_codec(),
    )
  agent.new("front-desk", model, [], desk_policy)
  |> agent.with_sub_agent(research, to: researcher, prompt: fn(topic) {
    topic.name
  })
  |> agent.with_approvers(treasurers)
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

### Who may answer: approvers

An answer to an approval request takes a proof, and only
`approvers.check` makes one: the agent's approvers (`agent.with_approvers`,
`graph.with_approvers`) verify the reviewer's credential for the request's
`run.Requirement`, and return the authenticated reviewer or why they refuse
(`NotAuthenticated`, `NotAuthorized`, `Unavailable`). An answer refuses
(`fabric.ProofRefused`) a proof made by other approvers (each
`approvers.new` makes distinct ones, so build them once and share the
value), one checked for another requirement, one older than 60 s
(`approvers.with_proof_lifetime`), and any proof at all when the agent has
no approvers. A sub-agent without approvers of its own is answered with its
parent's. The reviewer and the
approvers' name are recorded with the answer (`run.Approval.reviewer`,
`run.Approval.verifier`). Tests that are not about who answers use
`fabric/testing.trusting_approvers()`, whose credential is the reviewer.

Fabric does not depend on an identity library. With warden, the approvers
take a bearer token for the application's audience that carries the scope
`approve:<requirement name>`. The block is `consumers/approvers_warden`
verbatim, which tests it against warden's test provider, and the module doc
of `fabric/approvers` carries the same code (`scripts/check.py recipe`):

<!-- approvers-recipe -->

```gleam
import fabric/approvers.{type Approvers}
import fabric/reviewer
import gleam/bool
import gleam/list
import gleam/result
import warden/resource

/// Approvers that accept a warden access token issued for the validator's
/// audience and carrying the scope `approve:<requirement name>`. The answer
/// records the token's `sub` and `iss`, and the verifier `"warden"`. Call
/// it once, at boot: the agent and the request handlers share the value.
pub fn warden_approvers(validator: resource.Validator) -> Approvers(String) {
  use token, requirement <- approvers.new("warden")
  use claims <- result.try(
    resource.verify(validator, token) |> result.map_error(denial),
  )
  let scope = "approve:" <> requirement.name
  use <- bool.guard(
    !list.contains(resource.scopes(claims), scope),
    Error(approvers.NotAuthorized("the token lacks the scope " <> scope)),
  )
  reviewer.new(resource.subject(claims))
  |> result.try(reviewer.with_issuer(_, resource.issuer(claims)))
  |> result.map_error(fn(error) {
    approvers.NotAuthenticated(reviewer.describe_error(error))
  })
}

fn denial(error: resource.TokenError) -> approvers.Denial {
  let reason = resource.describe_error(error)
  case resource.error_kind(error) {
    resource.Rejected | resource.WrongAudience ->
      approvers.NotAuthenticated(reason)
    resource.Forbidden -> approvers.NotAuthorized(reason)
    resource.Unavailable -> approvers.Unavailable(reason)
  }
}
```

### Defaults

Every step and every wait is bounded unless the caller asks for
`run.Infinity`. A run's own length is then bounded by its turns, its model
and tool timeouts, and the answers it waits for.

| Bound                                         | Default                         | Change it with                                           | When it is reached                                                       |
| --------------------------------------------- | ------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------ |
| Model attempts per run                        | 8                               | `agent.with_max_turns`                                   | the run ends `BudgetExhausted(TurnLimit(8))`                             |
| Final answers per run, for a typed answer     | 2 (one corrective turn)         | `agent.with_answer_attempts`                             | the run ends `AnswerInvalid`; each answer spends a model attempt         |
| One model call                                | 600 s                           | `agent.with_model_timeout`                               | the call stops; a retryable `model.TimedOut` that spends a turn          |
| One tool body                                 | 60 s                            | `agent.with_tool_timeout`, `tool.with_timeout`           | the body stops; uncertain, or started again (`tool.with_replay`)         |
| Tool result size                              | 1 MiB                           | `agent.with_max_result_bytes`                            | the run fails with `OutputEncodingFailed`, naming the limit              |
| Concurrent tool bodies                        | 4                               | `agent.with_max_concurrency`                             | later tools queue                                                        |
| One policy decision                           | 5 s                             | `agent.with_policy_timeout`                              | the run stops closed (`PolicyFailed`)                                    |
| A command waiting for a busy runner           | 5 s                             | `agent.with_command_timeout`                             | `RunnerBusy`                                                             |
| First model retry delay                       | 200 ms, doubling up to 64 times | `agent.with_model_retry_delay`                           | a provider's `Retry-After` is waited instead when longer                 |
| A provider's retry delay                      | 10 min at most                  | none (a cap)                                             | a longer `Retry-After` is cut to 10 min                                  |
| Sub-agents per run, depth                     | 4, 1                            | `agent.with_max_children`, `agent.with_max_depth`        | the delegation is refused and the model sees why                         |
| An approval request                           | 7 days                          | `agent.with_approval_expiry`                             | the request expires: the action is rejected, the model sees it           |
| A proof for an answer                         | 60 s                            | `approvers.with_proof_lifetime`                          | the answer is refused: `ProofRefused(ProofExpired(..))`                  |
| Token budget                                  | none (opt in)                   | `agent.with_token_budget`                                | `BudgetExhausted(TokenLimit(..))`                                        |
| Family budget                                 | none (opt in)                   | `agent.with_family_budget`, `graph.with_family_budget`   | `BudgetExhausted(FamilyLimit(..))`, `graph.FamilyBudget(..)`             |
| Family children, depth (once a budget is set) | as many as `work`, 16 levels    | `budget.with_children`, `budget.with_depth` (at most 63) | the child is refused (`ChildLimit`, `DepthLimit`)                        |
| Replays of a crashed tool body                | none (opt in)                   | `tool.with_replay`                                       | the action is an uncertain effect                                        |
| Drain window on shutdown                      | 25 s                            | `store.with_drain`                                       | the runner is killed; running tools become uncertain                     |
| Graph pure callbacks                          | 1 s                             | `graph.with_callback_timeout`                            | `graph.CallbackFailed`                                                   |
| One graph activity body                       | 60 s                            | `graph.with_operation_timeout`                           | the body stops; the run is `Blocked` on an uncertain effect              |
| A graph command waiting for its runner        | 1 s                             | `graph.with_command_timeout`                             | `graph.RunnerBusy` (a cancellation is committed to the record instead)   |
| A graph approval request                      | 7 days                          | `graph.with_approval_expiry`                             | the request expires: the run fails with `ExpiredApproval`                |
| A graph signal, job, child or fork wait       | 7 days                          | `operation.with_deadline`                                | the run fails or expires with `DeadlineExpired`, after stopping children |
| Graph activations per run                     | 100                             | `definition.with_max_activations`                        | the run ends `Exhausted`                                                 |

Every timeout is a `gleam/time/duration.Duration`; one that may be lifted
is a `run.Timeout` (`run.After(duration)` or `run.Infinity`). Every deadline
is set and judged by the store's clock (`store.now`), so every node judges
it alike. An approval request or a graph wait stores its deadline
(`run.PendingApproval.expires`, `graph.Snapshot.deadline`); one stored
before deadlines had defaults keeps none and never expires. A bound may
come from configuration, so a setter only stores it: `agent.build`,
`graph.build`, `definition.build` and `fabric_relay.serve` report every
bound out of range at once, each as `InvalidLimit(limit:, value:, minimum:,
maximum:)` naming its setter (`describe_config_errors`,
`definition.describe_build_errors`).

### Typed answers

`agent.with_answer(codec)` gives an agent a typed final answer. Every model
request carries the codec's JSON Schema (`model.Request.answer`), which
`fabric/llm` sends as the provider's structured output format, and a run
completes with the decoded value: `run.Completed(Resolution(..))`. A final
text the codec does not read gets one corrective turn by default: the model
is told why and given the schema again, within the run's turn and token
budgets (`agent.with_answer_attempts`). When that answer does not decode
either, the run ends with `run.AnswerInvalid(raw:, reason:)`, keeping the
text. Without `with_answer` the answer is the
model's text (`Agent(context, String)`). A sub-agent's answer is its
delegation's output, and a graph agent's is its operation's output. A run
stores the text the model sent, so a run stored before its agent had a
codec reads through it when the text decodes.

### Failures

Every function of `fabric` returns one `fabric.Error`. Branch on
`fabric.error_kind(error)`: `NotFound`, `Refused` (the run's state refuses
the request, such as `ApprovalExpired` or `AlreadyStarted`), `Retry` (a
transient conflict), `Unavailable` (the store or the runner, with a write
whose outcome may be unknown) or `Incompatible`; log with
`fabric.describe_error`. `fabric/graph` returns one `graph.Error`, which
`graph.error_kind` classifies with the same `fabric.ErrorKind`. A model
fails with an opaque `model.ModelError`:
`model.error_kind`, `model.is_retryable` and the provider's
`model.retry_after`. The unions that may grow (`fabric.Error`,
`agent.ConfigError`, `model.ErrorKind`, `run.Outcome`, `run.HostFailure`,
`run.ActionState`, `graph.Error`, `graph.Failure`,
`definition.BuildError`, `graph.Status`) each have such a classification or
a `describe_*` function: `run.host_failure_kind` and
`run.action_state_kind` with `describe_host_failure` and
`describe_action_state`, for example. `agent.describe_config_errors` puts
every problem `build` reported on one line.

### Correlation

A run has one `sinal/correlation.Correlation`, chosen where the run starts
(`fabric.start(.., correlation: Some(c))`) or derived from its id. It is
stored with the run and carried in every `fabric/telemetry` event of the
run and its sub-agents, in every `model.Request` (with the run id and the
turn), and in every tool's `tool.Call`. Every run event also names its
family's root run (`root`), so a sub-agent's events join their root's. A
sub-agent record stored before roots were recorded gets its exact root from
its stored ancestors when it is read, and stores it at its next commit; when
an ancestor cannot be read, the topmost readable one stands in and
`telemetry.root_inferred` says so. `fabric/llm` puts it on each
turn's HTTP Gun client view, so one agent serves every run.
The saga tool recipe starts each Saga run with it, and every step of the workflow
reads it with `saga.correlation_of(key)` for the clients it calls; the
tool's `input` need not carry it. A graph run takes its
correlation the same way (`graph.start(.., correlation:)`): it is stored,
carried in every `graph_*` and `activation_*` event, in every operation's
`operation.Invocation`, and inherited by the graph's child runs, managed
agents included, which name the graph's root as theirs.

### Graph runs

A graph runtime speaks the agent's vocabulary: the same `policy.Policy`
(an action's `step` is `policy.Activation(..)` and its `target`
`policy.RunOperation(node:, operation:, kind:)`), the same `tool.Failure`
for operation bodies, approvals answered with an `approvers.Proof` from the
runtime's approvers (`graph.with_approvers`) and the current context, a
context built from the run id, and one classified `graph.Error`.

```gleam
let assert Ok(runtime) =
  graph.new(publishing, runs, context: fn(_run) { ctx }, policy:)
  |> graph.with_approvers(editors)
  |> graph.with_approval_expiry(run.After(duration.hours(48)))
  |> graph.build   // Result(Runtime, List(graph.ConfigError))
let assert Ok(handle) =
  graph.start(runtime, id: run.new_id(), initial: draft, correlation: None)
let assert Ok(graph.AwaitingApproval(pending)) =
  graph.await(handle, within: duration.seconds(5))
let assert Ok(proof) = approvers.check(editors, token, pending.requirement)
graph.approve(handle, pending, proof:, context: ctx)
```

`await` and every command return the run's `graph.Status`, as in the agent
runtime; `graph.snapshot` reads the whole record, and `graph.status_kind`
classifies a status (`Active`, `NeedsRecovery`, `NeedsInput`, `Ended`). A
managed agent (`fabric/graph/agent`) is an operation whose output is the
agent's typed answer.

A request handler reopens a run with `graph.open(runtime, id)`, which checks
the stored record against the deployed definition (`IncompatibleDefinition`
otherwise; `graph.cancel_stored(store, id)` then cancels it without one).

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
even when another node recovered the child. Running tools become uncertain,
unless they are replayable (`tool.with_replay`). See the [PostgreSQL setup](integrations/fabric_postgres/README.md#automatic-recovery)
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
`graph.with_family_budget(spec, limits)` (checked by `graph.build`) to bound the whole family of
every root run the agent or runtime starts.
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
Signal waits without a deadline (`run.Infinity`, or stored before waits
had one) require explicit delivery.

Every wait is bounded: 7 days after admission unless its operation says
otherwise. For a one-minute signal wait, apply
`operation.with_deadline(wait, run.After(duration.minutes(1)))` (or
`run.Infinity` to wait without a deadline) before
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

Telemetry: attach Sinal handlers to the events of `fabric/telemetry`.
They run in the committing process unless the application routes `[fabric]`
through a `sinal/forwarder` (`forwarder.route` at start, `forwarder.unroute`
at shutdown), which keeps a slow handler from holding up a run; handlers that
call Fabric should run there.

`consumers/app` is a complete external application using public imports only.

## Classification decisions

`fabric/graph/classify.decision(identity, input, questions, config, request)`
uses llm_wire's provider-neutral classification family. The request builder
returns `classify.call(http, model, state)` after policy admission. Build
questions with `llm_wire/classify/question`, settings with
`llm_wire/classify.typesafe(fn() { key })`, and durable answer codecs with
`llm_wire/classify.receipt_codec(config, questions)`. The decision and writing
consumers compile this public path. Earlier stored classifier receipts and
graph runs remain readable without a network call.

## A saga workflow as a tool

Copy this 47-line recipe into your application's `saga_tool` module. Saga owns
outcome classification and the receiver that reports compensation after the
calling task exits. Fabric owns the tool's settlement deadline. The recipe
passes `call.correlation` into saga; steps read it with
`saga.correlation_of(key)`. Keep the rollback budget long enough for the
workflow's settle and compensation bounds. Late results are refused and their
evidence is retained for reconciliation. This adds no saga dependency to fabric.

<!-- saga-recipe -->

```gleam
import fabric/tool
import gleam/result
import gleam/time/duration.{type Duration}
import saga
import saga/execution
import saga/outcome
import saga/reporting

pub fn tool(
  definition: tool.Definition(input, output),
  workflow: saga.Workflow(workflow_input, output, error, undo_error),
  config: execution.Config,
  input input: fn(context, tool.Call, input) -> workflow_input,
  explain explain: fn(error) -> String,
  rollback_within rollback_within: Duration,
) -> tool.Tool(context) {
  tool.bind_settling(
    definition,
    fn(context, call: tool.Call, value, settlement) {
      reporting.run_owned(
        workflow,
        input(context, call, value),
        execution.with_correlation(config, call.correlation),
        explain,
        fn(stopped, summary) {
          let _ =
            tool.settle(
              settlement,
              result.map_error(stopped, failure),
              summary:,
            )
          Nil
        },
        rollback_within,
      )
    },
    failure,
    settle_within: rollback_within,
  )
}

fn failure(stopped: outcome.Failure) -> tool.Failure {
  case outcome.failure_kind(stopped) {
    outcome.Compensated -> tool.Explain(outcome.describe_failure(stopped))
    _ -> tool.Uncertain(outcome.describe_failure(stopped))
  }
}
```

The unpublished `consumers/saga_tool` compiles this exact block; the
`saga-recipe` gate checks it against these docs and `fabric/tool`.

## Integrations

Each integration is a separate package under `integrations/`, so Fabric
itself depends on none of them.

| Package                                                   | What it adds                                                                                                                                                                                                                                                                  |
| --------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [fabric_relay](integrations/fabric_relay/README.md)       | MCP over [Relay](https://github.com/gleam-dream/relay): `fabric_relay.tool(definition, peer:)`, `discover` and `operation` call MCP tools from agents and graphs; `serve` publishes an agent as an MCP tool, and a retried call with an idempotency key reaches the same run. |
| [fabric_postgres](integrations/fabric_postgres/README.md) | The leased PostgreSQL backend, its migrations, discovery refresh and pruning of finished run families.                                                                                                                                                                        |

The [writing consumer](consumers/writing/README.md) composes real source and
artifact tools with generation, interchangeable LLM and TypeSafe review,
bounded revision and durable approval; the
[graph](consumers/graph/README.md), [decision](consumers/decision/README.md)
and [external-job](consumers/jobs/README.md) consumers exercise the graph
runtime from public imports.

## Status and scope

Fabric is not yet published to Hex. It depends on its siblings `llm_wire`,
`http_gun`, `json_blueprint` and `sinal` through path dependencies
(`../llm_wire`, ...); check out those repositories next to this one. The LLM
adapters take the application's started `http_gun.Client`; Fabric never
starts or stops one. Each integration names its own siblings (`../relay`,
`../saga`).

The agent runtime covers bounded execution, durable pause, approval, resume,
cancellation and restart, sub-agents, telemetry, a supervised store with
drained shutdown, and leased stores for several nodes sharing one database
with automatic recovery of expired leases. The graph runtime covers typed
operations, conditional routing, bounded cycles, approvals, typed durable
signals, external jobs, managed subgraphs and agents, typed pairs and
bounded maps, and durable deadlines. See [docs/PLAN.md](docs/PLAN.md),
[docs/CAPABILITIES.md](docs/CAPABILITIES.md) and
[docs/ORACLE.md](docs/ORACLE.md); the behavioural oracle is BeamWeaver (a
partial migration of its agent loop).

The design is [fabric-design.md](https://github.com/gleam-dream/oversight/blob/master/fabric-design.md)
in [gleam-dream/oversight](https://github.com/gleam-dream/oversight). The
graph runtime stays in Fabric and ships in Fabric 1.0 (release decision 2);
which package owns durable execution across Grind, Saga and Fabric is still
open (release decision 1). [Remaining work](docs/REMAINING.md) lists
operations, the later Grind integration and release work.

## Development

```sh
nix develop -c python3 scripts/check.py full
```

runs every check: formatting (`nix flake check`), the gate's own tests, and
for every package (the core, each integration, consumer and experiment) its
format check, its build with warnings as errors and its tests. That includes
the PostgreSQL suite, which `integrations/fabric_postgres/scripts/test-postgres.sh`
runs against a temporary cluster it starts and removes (it never uses an
existing database), and the external-job service tests. `check.py fast`
checks the core only. See [verification](docs/VERIFICATION.md) for logs and
the prepared CI profile.

For one package at a time:

```sh
nix develop
gleam format --check src test
gleam build --warnings-as-errors
gleam test                                   # the core; no PostgreSQL
(cd integrations/fabric_relay && gleam test)
integrations/fabric_postgres/scripts/test-postgres.sh
```

The tested sibling revisions are in [PLAN](docs/PLAN.md#tested-sibling-revisions).

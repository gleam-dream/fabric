# fabric

A bounded, typed LLM agent runtime for Gleam: typed application tools, an explicit policy gate, a pure agent controller, and a thin OTP runner with cancellation. It consumes llm_wire for providers and json_blueprint for tool codecs; typed workflows (DAGs) belong to Saga.

Status: slice 1 (bounded agent execution), slice 2a (durable pause, approval, resume, cancellation, and restart), slice 2b (approval-gated sub-agents, Sinal observations, and Saga workflows as tools), the public API ergonomics pass (a built agent, one policy gate, typed run ids, a named supervisable store), and the first production-runtime slices (timer limits; runners supervised under the store's subtree, drained and handed off on shutdown; the leased store contract for several nodes sharing one database, with an in-memory leased backend) implemented; see [docs/PLAN.md](docs/PLAN.md), [docs/CAPABILITIES.md](docs/CAPABILITIES.md) and [docs/ORACLE.md](docs/ORACLE.md). Design: see [fabric-design.md](https://github.com/gleam-dream/oversight/blob/master/fabric-design.md) in [gleam-dream/oversight](https://github.com/gleam-dream/oversight). Not yet published to Hex.

Behavioural oracle: BeamWeaver (partial migration of its agent loop).

Dependencies on `llm_wire`, `json_blueprint`, and `sinal` are path dependencies (`../llm_wire`, `../json_blueprint`, `../sinal`); check out the sibling repositories next to this one. The optional Saga integration, `integrations/fabric_saga`, is a separate package that also needs `../saga`.

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
  let assert Ok(input) =
    codec.record2(
      codec.required("to", codec.string()),
      codec.required("amount", codec.int()),
      Transfer,
      fn(transfer) { transfer.to },
      fn(transfer) { transfer.amount },
    )
  let output =
    codec.field("receipt", codec.string())
    |> codec.imap(Receipt, fn(receipt) { receipt.id })
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
/// A provider's model comes from `fabric/llm.model(settings, model_id)`.
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
      codec.field("topic", codec.string())
        |> codec.imap(Topic, fn(topic) { topic.name }),
      codec.field("summary", codec.string())
        |> codec.imap(Summary, fn(summary) { summary.text }),
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
production, give Fabric a database backend through `store.new` (a Postgres
adapter is planned) or another application backend.

Several nodes that share one database coordinate through per-run leases:
`store.leased(name, node: "app-1", lease: 30_000, backend:)` over a
`store.LeasedBackend` (its contract is in the `fabric/store` docs, and
`fabric/testing.leased_backend_checks` checks one; `store.leased_memory()`
is one in memory, for tests). A runner commits only while its node holds
the run's lease; another node reads the run `Working`, answers an idle run
itself, gets `RunUnattended` for a command that needs the other node's
runner, and can always cancel. `recover` takes over only a free or expired
lease, so it is safe to call at any time. Coordination over Erlang
distribution is not supported.

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

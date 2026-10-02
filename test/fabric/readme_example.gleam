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
    use to <- codec.field("to", codec.string(), fn(t: Transfer) { t.to })
    use amount <- codec.field("amount", codec.int(), fn(t: Transfer) {
      t.amount
    })
    codec.success(Transfer(to:, amount:))
  }
  let output = {
    use id <- codec.field("receipt", codec.string(), fn(r: Receipt) { r.id })
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
        use name <- codec.field("topic", codec.string(), fn(t: Topic) { t.name })
        codec.success(Topic(name:))
      },
      {
        use text <- codec.field("summary", codec.string(), fn(s: Summary) {
          s.text
        })
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

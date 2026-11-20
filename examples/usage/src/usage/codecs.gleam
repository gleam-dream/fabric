//// Codecs in tools, made where Fabric builds the agent. The agent's builder
//// captures the run's account ids and the model, nothing built; each
//// process that runs the agent makes the tool and its codecs.

// snips-start: codecs
import fabric/agent.{type Agent}
import fabric/model.{type Model}
import fabric/policy
import fabric/tool
import gleam/list
import json/blueprint/codec.{type Codec}

pub type Line {
  Line(memo: String, cents: Int)
}

pub type Transfer {
  Transfer(to: String, lines: List(Line))
}

/// Each child codec is made inside its field, by its own function. The
/// payee is a run-time enum: the run's own account ids, made into a codec
/// inside the field.
fn transfer_codec(accounts: List(String)) -> Codec(Transfer) {
  use to <- codec.field(
    "to",
    codec.string_enum(list.map(accounts, fn(id) { #(id, id) })),
    get: fn(transfer: Transfer) { transfer.to },
  )
  use lines <- codec.field(
    "lines",
    codec.list(of: line_codec()),
    get: fn(transfer: Transfer) { transfer.lines },
  )
  codec.success(Transfer(to:, lines:))
}

fn line_codec() -> Codec(Line) {
  use memo <- codec.field("memo", codec.string(), get: fn(line: Line) {
    line.memo
  })
  use cents <- codec.field("cents", codec.int(), get: fn(line: Line) {
    line.cents
  })
  codec.success(Line(memo:, cents:))
}

fn transfer_tool(accounts: List(String)) -> tool.Tool(Nil) {
  tool.define(
    "transfer",
    "Pay one of the run's accounts.",
    transfer_codec(accounts),
    codec.string(),
  )
  |> tool.bind(
    fn(_context, _call, transfer: Transfer) -> Result(String, Nil) {
      Ok("paid " <> transfer.to)
    },
    fn(_) { tool.Explain("transfer failed") },
  )
}

/// The agent for a run that may pay `accounts`. The builder captures the
/// ids and the model; `transfer_tool` runs in every process that builds it.
pub fn payer(
  model: Model,
  accounts: List(String),
) -> Result(Agent(Nil, String), List(agent.ConfigError)) {
  agent.build_with(fn() {
    agent.new("payer", model, [transfer_tool(accounts)], policy.always_allow())
  })
}
// snips-end: codecs

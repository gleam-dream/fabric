//// The README's usage example is `readme_example.gleam`, verbatim: one
//// test checks that the README shows exactly that compiled module, the
//// others run it with scripted models.

import fabric
import fabric/agent.{type Agent}
import fabric/readme_example.{
  type Context, type Receipt, type Transfer, type TransferError, Approve,
  Context, GatewayTimeout, Happened, Receipt, Reject,
}
import fabric/run
import fabric/support/restart
import fabric/support/scripted
import gleam/result
import gleam/string
import gleeunit/should

pub fn the_readme_shows_the_compiled_example_test() {
  let assert Ok(readme) = restart.read_file("README.md")
  let assert Ok(source) = restart.read_file("test/fabric/readme_example.gleam")
  first_gleam_block(readme) |> should.equal(Ok(source))
}

fn first_gleam_block(markdown: String) -> Result(String, Nil) {
  use #(_, rest) <- result.try(string.split_once(markdown, "```gleam\n"))
  use #(block, _) <- result.try(string.split_once(rest, "```\n"))
  Ok(block)
}

/// Pays up to 1000; a larger transfer times out after sending.
fn pay(transfer: Transfer) -> Result(Receipt, TransferError) {
  case transfer.amount > 1000 {
    True -> Error(GatewayTimeout)
    False -> Ok(Receipt("r-" <> transfer.to))
  }
}

fn desk(amount: String) -> Agent(Context) {
  let model =
    scripted.plan([
      scripted.call(
        "t",
        "transfer_funds",
        "{\"to\":\"bob\",\"amount\":" <> amount <> "}",
      ),
    ])
  let assert Ok(desk) = readme_example.desk(model, pay)
  desk
}

const ann = Context("ann")

const tess = Context("tess")

pub fn the_readme_example_runs_test() {
  let dir = restart.temp_dir()
  let assert Ok(runs) = readme_example.supervise(dir)

  // Approved in a later request.
  let small = desk("150")
  let assert Ok(id) = readme_example.start_payment(runs, small, ann, "Pay Bob")
  let assert Ok(_) = readme_example.review(runs, small, tess, id, Approve)
  readme_example.review(runs, small, tess, id, Approve)
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"receipt\":\"r-bob\"}"))),
  )

  // Rejected.
  let assert Ok(id) = readme_example.start_payment(runs, small, ann, "Pay Bob")
  let assert Ok(_) =
    readme_example.review(runs, small, tess, id, Reject("not today"))
  let assert Ok(run.Finished(run.Completed(answer))) =
    readme_example.review(runs, small, tess, id, Approve)
  string.contains(answer, "not today") |> should.be_true

  // Approved, and the gateway timed out after sending: reconciled.
  let large = desk("5000")
  let assert Ok(id) = readme_example.start_payment(runs, large, ann, "Pay Bob")
  let assert Ok(_) = readme_example.review(runs, large, tess, id, Approve)
  let assert Ok(_) =
    readme_example.review(
      runs,
      large,
      tess,
      id,
      Happened("{\"receipt\":\"r-1\"}"),
    )
  readme_example.review(runs, large, tess, id, Approve)
  |> should.equal(
    Ok(run.Finished(run.Completed("final: {\"receipt\":\"r-1\"}"))),
  )

  // At boot: a finished run is reopened unchanged; a malformed id names
  // no run.
  let assert Ok(handle) = readme_example.resume(runs, large, ann, id)
  let assert Ok(run.Finished(_)) = fabric.await(handle, 0)
  readme_example.resume(runs, large, ann, "../etc")
  |> should.equal(Error(fabric.Unreadable(fabric.RunNotFound)))
  restart.remove_dir(dir)
}

pub fn the_readme_sub_agent_and_settling_tool_build_test() {
  let quiet = scripted.plan([])
  let assert Ok(_front_desk) = readme_example.front_desk(quiet, desk("1"))
  let settling =
    readme_example.settling_transfer(fn(transfer, _settlement) { pay(transfer) })
  let assert Ok(_) =
    agent.new("settler", quiet, [settling], readme_example.desk_policy)
    |> agent.build
}

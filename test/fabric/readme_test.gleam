//// The usage guide's payment example is `readme_example.gleam`, verbatim: one
//// test checks that the guide shows exactly that compiled module, the
//// others run it with scripted models.

import fabric
import fabric/agent.{type Agent}
import fabric/approvers.{type Approvers}
import fabric/model
import fabric/readme_example.{
  type Context, type Receipt, type Resolution, type Transfer, type TransferError,
  Approve, Context, GatewayTimeout, Happened, Receipt, Reject, Resolution,
  StillUnknown,
}
import fabric/reviewer
import fabric/run
import fabric/support/restart
import fabric/support/scripted
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleeunit/should

pub fn the_readme_shows_the_compiled_example_test() {
  let assert Ok(readme) = restart.read_file("USAGE.md")
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

/// Asks for the transfer, then answers with a resolution naming every
/// result it saw.
fn desk(
  amount: String,
  treasurers: Approvers(String),
) -> Agent(Context, Resolution) {
  let transfer =
    scripted.call(
      "t",
      "transfer_funds",
      "{\"to\":\"bob\",\"amount\":" <> amount <> "}",
    )
  let model =
    scripted.model(fn(messages) {
      case scripted.results(messages) {
        [] ->
          model.ToolRequest(
            model.AssistantTurn("", [transfer], None),
            Some(model.Usage(10, 5)),
          )
        seen ->
          json.object([
            #("summary", json.string("final: " <> string.join(seen, " | "))),
          ])
          |> json.to_string
          |> model.FinalAnswer(Some(model.Usage(20, 5)))
      }
    })
  let assert Ok(desk) = readme_example.desk(model, pay, treasurers)
  desk
}

const ann = Context("ann")

const tess = Context("tess")

/// The application's sign-in, scripted: a token names its holder, and
/// only a treasurer's may answer a `"treasurer"` requirement.
fn treasurers() -> Approvers(String) {
  approvers.new("readme-sso", fn(token, requirement: run.Requirement) {
    case token, requirement.name {
      "tess-token", "treasurer" ->
        reviewer.new("tess")
        |> result.try(reviewer.with_issuer(_, "https://id.example"))
        |> result.map_error(fn(error) {
          approvers.NotAuthenticated(reviewer.describe_error(error))
        })
      "ann-token", _ ->
        Error(approvers.NotAuthorized("ann is not a " <> requirement.name))
      _, _ -> Error(approvers.NotAuthenticated("unknown token"))
    }
  })
}

const tess_token = "tess-token"

pub fn the_readme_example_runs_test() {
  // Built once: the desk and every review share them.
  let treasurers = treasurers()
  let dir = restart.temp_dir()
  let assert Ok(runs) = readme_example.supervise(dir)

  // Approved in a later request.
  let small = desk("150", treasurers)
  let assert Ok(id) = readme_example.start_payment(runs, small, ann, "Pay Bob")
  let assert Ok(_) =
    readme_example.review(
      runs,
      small,
      treasurers,
      tess,
      tess_token,
      id,
      Approve,
    )
  readme_example.review(runs, small, treasurers, tess, tess_token, id, Approve)
  |> should.equal(
    Ok(
      run.Finished(run.Completed(Resolution("final: {\"receipt\":\"r-bob\"}"))),
    ),
  )

  // Ann is signed in, but may not answer a treasurer's request, and an
  // unknown token proves no one: nothing is answered.
  let assert Ok(id) = readme_example.start_payment(runs, small, ann, "Pay Bob")
  readme_example.review(runs, small, treasurers, ann, "ann-token", id, Approve)
  |> should.equal(
    Error(
      readme_example.Denied(approvers.NotAuthorized("ann is not a treasurer")),
    ),
  )
  readme_example.review(runs, small, treasurers, ann, "forged", id, Approve)
  |> should.equal(
    Error(readme_example.Denied(approvers.NotAuthenticated("unknown token"))),
  )
  let assert Ok(run.Suspended([_], [])) =
    readme_example.review(
      runs,
      small,
      treasurers,
      tess,
      tess_token,
      id,
      StillUnknown("nothing to reconcile"),
    )

  // Rejected.
  let assert Ok(id) = readme_example.start_payment(runs, small, ann, "Pay Bob")
  let assert Ok(_) =
    readme_example.review(
      runs,
      small,
      treasurers,
      tess,
      tess_token,
      id,
      Reject("not today"),
    )
  let assert Ok(run.Finished(run.Completed(Resolution(summary)))) =
    readme_example.review(
      runs,
      small,
      treasurers,
      tess,
      tess_token,
      id,
      Approve,
    )
  string.contains(summary, "not today") |> should.be_true

  // Approved, and the gateway timed out after sending: reconciled.
  let large = desk("5000", treasurers)
  let assert Ok(id) = readme_example.start_payment(runs, large, ann, "Pay Bob")
  let assert Ok(_) =
    readme_example.review(
      runs,
      large,
      treasurers,
      tess,
      tess_token,
      id,
      Approve,
    )
  let assert Ok(_) =
    readme_example.review(
      runs,
      large,
      treasurers,
      tess,
      tess_token,
      id,
      Happened("{\"receipt\":\"r-1\"}"),
    )
  readme_example.review(runs, large, treasurers, tess, tess_token, id, Approve)
  |> should.equal(
    Ok(run.Finished(run.Completed(Resolution("final: {\"receipt\":\"r-1\"}")))),
  )

  // Approved, and no one knows yet whether the gateway paid: the model is
  // told, and the run goes on.
  let unknown = desk("5000", treasurers)
  let assert Ok(id) =
    readme_example.start_payment(runs, unknown, ann, "Pay Carol")
  let assert Ok(_) =
    readme_example.review(
      runs,
      unknown,
      treasurers,
      tess,
      tess_token,
      id,
      Approve,
    )
  let assert Ok(_) =
    readme_example.review(
      runs,
      unknown,
      treasurers,
      tess,
      tess_token,
      id,
      StillUnknown("the bank is checking"),
    )
  readme_example.review(
    runs,
    unknown,
    treasurers,
    tess,
    tess_token,
    id,
    Approve,
  )
  |> should.equal(
    Ok(
      run.Finished(
        run.Completed(Resolution(
          "final: {\"unconfirmed\":\"the bank is checking\"}",
        )),
      ),
    ),
  )

  // At boot: a finished run is reopened unchanged; a malformed id names
  // no run.
  let assert Ok(handle) = readme_example.resume(runs, large, ann, id)
  let assert Ok(run.Finished(_)) =
    fabric.await(handle, within: duration.milliseconds(0))
  readme_example.resume(runs, large, ann, "../etc")
  |> should.equal(Error(fabric.RunNotFound))
  restart.remove_dir(dir)
}

pub fn the_readme_sub_agent_and_settling_tool_build_test() {
  let quiet = scripted.plan([])
  let assert Ok(researcher) =
    agent.new("researcher", quiet, [], readme_example.desk_policy)
    |> agent.with_answer(readme_example.summary_codec())
    |> agent.build
  let assert Ok(_front_desk) =
    readme_example.front_desk(quiet, researcher, treasurers())
  let settling =
    readme_example.settling_transfer(fn(transfer, _settlement) { pay(transfer) })
  let assert Ok(_) =
    agent.new("settler", quiet, [settling], readme_example.desk_policy)
    |> agent.build
}

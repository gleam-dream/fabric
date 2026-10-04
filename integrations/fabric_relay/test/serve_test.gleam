//// A Fabric agent served as a Relay MCP tool: the typed answer, the call's
//// correlation, a retried call that reaches the same run through its
//// idempotency key, and what a call answers when the run does not
//// complete in time.

import fabric
import fabric/agent
import fabric/model
import fabric/policy
import fabric/reviewer
import fabric/run
import fabric/store
import fabric/tool as fabric_tool
import fabric_relay
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import json/blueprint/value.{type Value}
import relay/client
import relay/content
import relay/http
import relay/server
import relay/testing
import relay/tool as relay_tool
import sinal/correlation

pub type Question {
  Question(text: String)
}

pub type Answer {
  Answer(text: String)
}

fn question_codec() -> codec.Codec(Question) {
  use text <- codec.field("question", codec.string(), get: fn(q: Question) {
    q.text
  })
  codec.success(Question(text:))
}

fn answer_codec() -> codec.Codec(Answer) {
  use text <- codec.field("answer", codec.string(), get: fn(a: Answer) {
    a.text
  })
  codec.success(Answer(text:))
}

fn ask() -> relay_tool.Definition(Question, Answer) {
  relay_tool.define("ask_desk", question_codec(), answer_codec())
  |> relay_tool.with_description("Ask the desk")
}

/// What the model saw of one request.
pub type Turn {
  Turn(run: run.RunId, turn: Int, correlation: correlation.Correlation)
}

/// A model that calls `charge` first when `charging`, then answers with
/// the prompt, after `delay` milliseconds per request.
fn desk_model(
  turns: process.Subject(Turn),
  charging: Bool,
  delay: Int,
) -> model.Model {
  model.new(fn(request: model.Request) {
    process.send(turns, Turn(request.run, request.turn, request.correlation))
    process.sleep(delay)
    let assert [model.UserMessage(prompt), ..] = request.messages
    case charging, list.last(request.messages) {
      True, Ok(model.UserMessage(_)) ->
        Ok(model.ToolRequest(
          model.AssistantTurn(
            "",
            [model.tool_call(id: "c1", name: "charge", arguments_json: "{}")],
            None,
          ),
          None,
        ))
      _, _ ->
        Ok(model.FinalAnswer("{\"answer\":\"done: " <> prompt <> "\"}", None))
    }
  })
}

fn charge() -> fabric_tool.Tool(Nil) {
  fabric_tool.bind(
    fabric_tool.define("charge", "Charge the card.", codec.success(Nil), {
      use ok <- codec.field("ok", codec.bool(), get: fn(ok) { ok })
      codec.success(ok)
    }),
    fn(_, _, _) { Ok(True) },
    fn(_: Nil) { fabric_tool.Explain("cannot fail") },
  )
}

fn desk(model: model.Model) -> agent.Agent(Nil, Answer) {
  let assert Ok(desk) =
    agent.new("desk", model, [charge()], fn(_, action: policy.Action) {
      case action.name {
        "charge" -> Ok(policy.RequireApproval(run.Requirement("treasurer", 1)))
        _ -> Ok(policy.Allow)
      }
    })
    |> agent.with_answer(answer_codec())
    |> agent.build
  desk
}

fn runs() -> store.Store {
  let runs = store.in_memory(process.new_name("fabric-relay-serve"))
  let assert Ok(Nil) = store.start(runs)
  runs
}

/// The server, whose context is the caller's principal.
fn desk_server(
  service: fabric_relay.Service(String, Nil, Question, Answer),
) -> server.Server(String) {
  let assert Ok(assistant) = fabric_relay.serve(service)
  server.new([assistant])
}

/// The input's type comes from the definition: `start` needs no
/// annotation.
fn served(runs, desk) {
  fabric_relay.service(ask(), runs:, agent: desk, start: fn(call, question) {
    fabric_relay.start(Nil, prompt: question.text)
    |> fabric_relay.with_principal(relay_tool.context(call))
  })
}

/// The `error` and `run_id` of an `isError` result.
fn refusal(result) -> #(String, Option(String)) {
  let assert Ok(client.ToolFailed(_, Some(value.Object(facts)))) = result
  let text = fn(name) {
    case list.key_find(facts, name) {
      Ok(value.String(text)) -> Some(text)
      _ -> None
    }
  }
  let assert Some(error) = text("error")
  #(error, text("run_id"))
}

fn facts(result) -> List(#(String, Value)) {
  let assert Ok(client.ToolFailed(_, Some(value.Object(facts)))) = result
  facts
}

fn count(subject: process.Subject(a)) -> Int {
  case process.receive(subject, 50) {
    Ok(_) -> 1 + count(subject)
    Error(Nil) -> 0
  }
}

// --- the common path ---------------------------------------------------------------

pub fn a_call_answers_with_the_runs_typed_answer_test() {
  let turns = process.new_subject()
  let service = served(runs(), desk(desk_model(turns, False, 0)))
  let peer =
    testing.connect(desk_server(service), "ada")
    |> client.with_correlation(correlation.from_key("ticket-12"))
  let assert Ok(result) = client.call(peer, ask(), Question("hello"))
  let assert client.Succeeded(answer, blocks) = result
  answer |> should.equal(Answer("done: hello"))
  // The run took the call's correlation, and the answer names the run.
  let assert Ok(Turn(run: id, correlation:, ..)) = process.receive(turns, 100)
  correlation |> should.equal(correlation.from_key("ticket-12"))
  fabric_relay.run_of(result) |> should.equal(Some(id))
  let assert [content.TextContent(text:, ..)] = blocks
  text |> should.equal("{\"answer\":\"done: hello\"}")
}

/// A result that names no run, such as another server's, has no run.
pub fn a_result_without_a_run_names_none_test() {
  fabric_relay.run_of(client.Succeeded(Nil, [content.text("plain")]))
  |> should.equal(None)
  fabric_relay.run_of(client.ToolFailed([], None)) |> should.equal(None)
}

/// A `start` that names no principal runs a keyed call for `anonymous`.
pub fn a_call_without_a_principal_runs_for_anonymous_test() {
  let turns = process.new_subject()
  let service =
    fabric_relay.service(
      ask(),
      runs: runs(),
      agent: desk(desk_model(turns, False, 0)),
      start: fn(_call, question) {
        fabric_relay.start(Nil, prompt: question.text)
      },
    )
  let assert Ok(result) =
    testing.connect(desk_server(service), "ada")
    |> client.with_idempotency_key("k-1")
    |> client.call(ask(), Question("hello"))
  let assert client.Succeeded(..) = result
  fabric_relay.run_of(result)
  |> should.equal(
    Some(fabric_relay.run_id(
      ask(),
      principal: fabric_relay.anonymous,
      key: "k-1",
    )),
  )
}

pub fn start_refuses_a_call_with_its_own_result_test() {
  let turns = process.new_subject()
  let service =
    fabric_relay.service(
      ask(),
      runs: runs(),
      agent: desk(desk_model(turns, False, 0)),
      start: fn(_call, _question) {
        fabric_relay.refuse(relay_tool.error_message("not your desk"))
      },
    )
  let assert Ok(client.ToolFailed([content.TextContent(text:, ..)], _)) =
    testing.connect(desk_server(service), "ada")
    |> client.call(ask(), Question("hello"))
  text |> should.equal("not your desk")
  count(turns) |> should.equal(0)
}

// --- retries through the idempotency key ---------------------------------------------

/// The first call finds the run waiting for an approval; once a person
/// approves it, the retried call reaches the same run and gets its answer.
pub fn a_retried_call_reaches_the_same_run_test() {
  let runs = runs()
  let turns = process.new_subject()
  let desk = desk(desk_model(turns, True, 0))
  let peer =
    testing.connect(desk_server(served(runs, desk)), "ada")
    |> client.with_idempotency_key("order-1001")
  let first = client.call(peer, ask(), Question("pay"))
  let expected = fabric_relay.run_id(ask(), principal: "ada", key: "order-1001")
  refusal(first)
  |> should.equal(#("awaiting_approval", Some(run.id_to_string(expected))))
  let assert Ok(failed) = first
  let assert client.ToolFailed(..) = failed
  fabric_relay.run_of(failed) |> should.equal(Some(expected))
  let assert Ok(approvals) = list.key_find(facts(first), "approvals")
  approvals
  |> should.equal(
    value.Array([value.Object([#("tool", value.String("charge"))])]),
  )
  // The application answers the approval on the run the key names.
  let assert Ok(handle) = fabric.open(runs, desk, Nil, expected)
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(handle, within: duration.milliseconds(100))
  let assert Ok(ada) = reviewer.new("ada")
  let assert Ok(_) =
    fabric.approve(handle, pending.reference, reviewer: ada, context: Nil)
  let assert Ok(client.Succeeded(answer, _)) =
    client.call(peer, ask(), Question("pay"))
  answer |> should.equal(Answer("done: pay"))
  // One run: its first turn and the turn after the approval.
  count(turns) |> should.equal(2)
}

pub fn a_key_names_one_run_per_principal_test() {
  let runs = runs()
  let turns = process.new_subject()
  let service = served(runs, desk(desk_model(turns, True, 0)))
  let as_principal = fn(principal) {
    testing.connect(desk_server(service), principal)
    |> client.with_idempotency_key("order-1")
    |> client.call(ask(), Question("pay"))
    |> refusal
  }
  let #(_, ada) = as_principal("ada")
  let #(_, bob) = as_principal("bob")
  { ada != bob } |> should.be_true
  bob
  |> should.equal(
    Some(
      run.id_to_string(fabric_relay.run_id(
        ask(),
        principal: "bob",
        key: "order-1",
      )),
    ),
  )
}

pub fn a_key_reused_for_another_request_is_refused_test() {
  let turns = process.new_subject()
  let peer =
    testing.connect(
      desk_server(served(runs(), desk(desk_model(turns, True, 0)))),
      "ada",
    )
    |> client.with_idempotency_key("order-2")
  let assert #("awaiting_approval", _) =
    refusal(client.call(peer, ask(), Question("pay")))
  let assert #("key_reused", Some(_)) =
    refusal(client.call(peer, ask(), Question("refund")))
}

// --- runs that do not complete in time ----------------------------------------------------

/// A keyed run outlives a call that stops waiting: a later call with the
/// key gets the answer, and the model was asked once.
pub fn a_keyed_run_keeps_working_for_the_retry_test() {
  let turns = process.new_subject()
  let runs = runs()
  let desk = desk(desk_model(turns, False, 300))
  let service =
    served(runs, desk) |> fabric_relay.with_wait(duration.milliseconds(50))
  let peer =
    testing.connect(desk_server(service), "ada")
    |> client.with_idempotency_key("slow-1")
  let assert #("working", Some(id)) =
    refusal(client.call(peer, ask(), Question("slow")))
  // The retry comes once the run has its answer, however long that takes.
  let assert Ok(id) = run.parse_id(id)
  let assert Ok(handle) = fabric.open(runs, desk, Nil, id)
  let assert Ok(run.Finished(_)) =
    fabric.await(handle, within: duration.seconds(30))
  let assert Ok(client.Succeeded(Answer("done: slow"), _)) =
    client.call(peer, ask(), Question("slow"))
  count(turns) |> should.equal(1)
}

/// A wait may come from configuration: `serve` reports one out of range
/// instead of panicking.
pub fn serve_reports_a_wait_out_of_range_test() {
  let desk = desk(desk_model(process.new_subject(), False, 0))
  let assert Error(errors) =
    served(runs(), desk)
    |> fabric_relay.with_wait(duration.milliseconds(0))
    |> fabric_relay.serve
  errors
  |> should.equal([
    fabric_relay.InvalidLimit(fabric_relay.Wait, 0, 1, 4_294_967_295),
  ])
  fabric_relay.describe_config_errors(errors)
  |> should.equal("fabric_relay.with_wait (ms) is 0, outside 1..4294967295")
  let assert Error([
    fabric_relay.InvalidLimit(fabric_relay.Wait, 4_294_967_296, ..),
  ]) =
    served(runs(), desk)
    |> fabric_relay.with_wait(duration.milliseconds(4_294_967_296))
    |> fabric_relay.serve
  let assert Ok(_) =
    served(runs(), desk)
    |> fabric_relay.with_wait(duration.milliseconds(4_294_967_295))
    |> fabric_relay.serve
}

/// A call without a key owns its run: when the wait ends, the run is
/// cancelled.
pub fn an_unkeyed_run_is_cancelled_when_the_wait_ends_test() {
  let runs = runs()
  let turns = process.new_subject()
  let desk = desk(desk_model(turns, False, 2000))
  let service =
    served(runs, desk) |> fabric_relay.with_wait(duration.milliseconds(50))
  let result =
    testing.connect(desk_server(service), "ada")
    |> client.call(ask(), Question("slow"))
  let assert #("timed_out", Some(id)) = refusal(result)
  let assert Ok(id) = run.parse_id(id)
  let assert Ok(handle) = fabric.open(runs, desk, Nil, id)
  fabric.await(handle, within: duration.seconds(30))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
}

/// Over HTTP, a client that gives up closes its connection, which cancels
/// the call; the run the call owns is cancelled with it.
pub fn a_disconnect_cancels_an_unkeyed_run_test() {
  let runs = runs()
  let turns = process.new_subject()
  // The model outlasts any wait here: only the cancellation ends the run.
  let desk = desk(desk_model(turns, False, 60_000))
  let assert Ok(mcp) =
    http.new_with_context(desk_server(served(runs, desk)), fn(_) { Ok("ada") })
    |> http.start
  let assert Ok(config) =
    client.http("http://127.0.0.1:" <> int.to_string(http.port(mcp)) <> "/")
  let assert Ok(peer) =
    config |> client.with_timeout(duration.seconds(1)) |> client.connect
  let assert Error(error) = client.call(peer, ask(), Question("slow"))
  let assert client.TimedOut(_) = client.reason(error)
  let assert Ok(Turn(run: id, ..)) = process.receive(turns, 30_000)
  let assert Ok(handle) = fabric.open(runs, desk, Nil, id)
  fabric.await(handle, within: duration.seconds(30))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
  client.close(peer)
  http.stop(mcp)
}

pub fn a_run_that_ends_otherwise_names_its_outcome_test() {
  let turns = process.new_subject()
  let rambling =
    model.new(fn(request: model.Request) {
      process.send(turns, Turn(request.run, request.turn, request.correlation))
      Ok(model.FinalAnswer("no idea", None))
    })
  let result =
    testing.connect(desk_server(served(runs(), desk(rambling))), "ada")
    |> client.call(ask(), Question("hello"))
  let assert #("answer_invalid", Some(_)) = refusal(result)
  let assert Ok(client.ToolFailed([content.TextContent(text:, ..)], _)) = result
  text
  |> should.equal(
    "the model's final answer is invalid: invalid JSON at line 1, column 1: unexpected character",
  )
  // The default corrective turn: two answers.
  count(turns) |> should.equal(2)
}

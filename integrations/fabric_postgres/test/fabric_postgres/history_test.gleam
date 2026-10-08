//// Public history invocation on real PostgreSQL. The application retains
//// acceptance and incorporation; Fabric's existing sweeper recovers execution.
//// The accepted row is not a queue: transactional delivery belongs to an
//// existing job/outbox, as described in docs/OPERATIONS.md.

import fabric
import fabric/agent
import fabric/input
import fabric/invoke
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/sweeper
import fabric_postgres
import fabric_postgres/agents
import fabric_postgres/support
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/result
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import pog

type Revision {
  Revision(text: String)
}

@external(erlang, "fabric_postgres_test_ffi", "with_process")
fn with_process(pid: process.Pid, work: fn() -> a) -> a

fn revision_codec() {
  use text <- codec.field("text", codec.string(), get: fn(r) { r.text })
  codec.success(Revision(text))
}

fn assistant(text) {
  model.AssistantMessage(model.AssistantTurn(text, [], None))
}

fn historical() {
  let call =
    model.tool_call("old-call", "retired_tool", "{\"id\":1}")
    |> model.with_provider_replay(
      Some("provider-call"),
      Some("opaque-signature"),
    )
  [
    model.UserMessage("first draft"),
    model.AssistantMessage(model.AssistantTurn(
      "old lookup",
      [call],
      Some(model.ProviderData("fixture.v1", "opaque assistant data")),
    )),
    model.ToolResultMessage("old-call", "old result"),
    assistant("{\"text\":\"first\"}"),
    model.UserMessage("revise"),
    assistant("{\"text\":\"second\"}"),
  ]
}

fn editor(provider) {
  let assert Ok(agent) =
    agent.new("history-editor", provider, [], fn(_: Nil, _) { Ok(policy.Allow) })
    |> agent.with_answer(revision_codec())
    |> agent.with_answer_attempts(2)
    |> agent.with_max_turns(5)
    |> agent.build
  agent
}

fn request(initial) {
  invoke.request(Nil, initial)
  |> invoke.with_principal("authenticated-editor")
  |> invoke.with_key(Some("accepted-turn"))
}

fn settled(handle, tries) {
  let assert Ok(status) = fabric.await(handle, duration.milliseconds(100))
  case status {
    run.Working | run.Unattended if tries > 0 -> settled(handle, tries - 1)
    other -> other
  }
}

fn table(schema) {
  "\"" <> schema <> "\".accepted_turns"
}

// Application-owned serialization preserves the public message values. Fabric
// still owns transcript validation through input.new when starting the next turn.
fn provider_data_codec() {
  use format <- codec.field("format", codec.string(), get: fn(d) { d.format })
  use value <- codec.field("value", codec.string(), get: fn(d) { d.value })
  codec.success(model.ProviderData(format, value))
}

fn call_codec() {
  use id <- codec.field("id", codec.string(), get: fn(c) { c.id })
  use name <- codec.field("name", codec.string(), get: fn(c) { c.name })
  use arguments <- codec.field("arguments", codec.string(), get: fn(c) {
    c.arguments_json
  })
  use provider_id <- codec.field(
    "provider_id",
    codec.nullable(codec.string()),
    get: fn(c) { c.provider_id },
  )
  use provider_state <- codec.field(
    "provider_state",
    codec.nullable(codec.string()),
    get: fn(c) { c.provider_state },
  )
  codec.success(
    model.tool_call(id, name, arguments)
    |> model.with_provider_replay(provider_id, provider_state),
  )
}

fn turn_codec() {
  use text <- codec.field("text", codec.string(), get: fn(t) { t.text })
  use calls <- codec.field("calls", codec.list(call_codec()), get: fn(t) {
    t.calls
  })
  use data <- codec.field(
    "data",
    codec.nullable(provider_data_codec()),
    get: fn(t) { t.data },
  )
  codec.success(model.AssistantTurn(text, calls, data))
}

fn result_codec() {
  use id <- codec.field("call_id", codec.string(), get: fn(r) { r.0 })
  use content <- codec.field("content", codec.string(), get: fn(r) { r.1 })
  codec.success(#(id, content))
}

fn messages_codec() {
  codec.list(
    codec.union({
      use user <- codec.variant("user", codec.string(), model.UserMessage)
      use assistant <- codec.variant(
        "assistant",
        turn_codec(),
        model.AssistantMessage,
      )
      use tool_result <- codec.variant("tool_result", result_codec(), fn(r) {
        model.ToolResultMessage(r.0, r.1)
      })
      codec.match(fn(message) {
        case message {
          model.UserMessage(text) -> user(text)
          model.AssistantMessage(turn) -> assistant(turn)
          model.ToolResultMessage(id, content) -> tool_result(#(id, content))
        }
      })
    }),
  )
}

fn applied(connection, table) {
  let assert Ok(rows) =
    pog.query(
      "SELECT answer,messages FROM "
      <> table
      <> " WHERE turn_id='accepted-turn' AND answer IS NOT NULL",
    )
    |> pog.returning({
      use answer <- decode.field(0, decode.string)
      use messages <- decode.field(1, decode.string)
      decode.success(#(answer, messages))
    })
    |> pog.execute(connection)
  case rows.rows {
    [] -> None
    [#(text, encoded)] -> {
      let assert Ok(messages) = codec.decode_json(messages_codec(), encoded)
      Some(#(Revision(text), messages))
    }
    _ -> panic as "turn identity is not unique"
  }
}

/// One transaction guards incorporation and records the business mutation.
/// Native result, messages and business mutation commit together.
fn incorporate(connection, table, revision: Revision, messages) {
  let assert Ok(encoded) = codec.encode_json(messages_codec(), messages)
  pog.transaction(connection, fn(tx) {
    pog.query(
      "UPDATE "
      <> table
      <> " SET answer=$1, messages=$2, applications=applications+1 WHERE turn_id='accepted-turn' AND answer IS NULL",
    )
    |> pog.parameter(pog.text(revision.text))
    |> pog.parameter(pog.text(encoded))
    |> pog.execute(tx)
    |> result.replace(Nil)
  })
}

/// Delivery always checks the durable applied marker before invoking.
fn deliver(connection, table, service, runs, agent, initial) {
  case applied(connection, table) {
    Some(outcome) -> outcome
    None -> {
      let response = invoke.call(service, request(initial))
      let assert Some(revision) = invoke.answer(response)
      let assert Ok(handle) = fabric.open(runs, agent, Nil, invoke.id(response))
      let assert Ok(messages) = fabric.generated_messages(handle)
      let assert Ok(Nil) = incorporate(connection, table, revision, messages)
      #(revision, messages)
    }
  }
}

pub fn sweeper_recovers_history_and_application_incorporates_once_before_pruning_test() {
  use connection <- support.using_pool(8)
  let schema = support.schema()
  let settings =
    support.migrated(connection, "owner", schema)
    |> fabric_postgres.with_lease(duration.milliseconds(300))
  let table = table(schema)
  let assert Ok(_) =
    pog.query(
      "CREATE TABLE "
      <> table
      <> " (turn_id text PRIMARY KEY, answer text, messages text, applications integer NOT NULL DEFAULT 0, CHECK ((answer IS NULL) = (messages IS NULL)))",
    )
    |> pog.execute(connection)
  let assert Ok(_) =
    pog.query("INSERT INTO " <> table <> " (turn_id) VALUES ('accepted-turn')")
    |> pog.execute(connection)
  let arrivals = process.new_subject()
  let initial_messages =
    list.append(historical(), [model.UserMessage("shorten")])
  let assert Ok(initial) = input.new(historical(), "shorten")
  let blocked =
    editor(
      model.new(fn(request) {
        case request.messages == initial_messages {
          True -> Ok(model.FinalAnswer("invalid answer", None))
          False -> {
            process.send(arrivals, request.messages)
            process.sleep_forever()
            Ok(model.FinalAnswer("unreachable", None))
          }
        }
      }),
    )
  let #(owner, id) =
    agents.owned(fn() {
      let assert Ok(runs) =
        fabric_postgres.store(process.new_name("history-owner"), settings)
      let assert Ok(Nil) = store.start(runs)
      let service =
        invoke.agent_with_history("revision", runs, blocked)
        |> invoke.with_wait(duration.milliseconds(50))
      let response = invoke.call(service, request(initial))
      invoke.response_kind(response) |> should.equal(invoke.Working)
      invoke.id(response)
    })
  use <- with_process(owner)
  let assert Ok(before_crash) = process.receive(arrivals, 30_000)
  list.take(before_crash, list.length(initial_messages))
  |> should.equal(initial_messages)
  agents.kill(owner)

  let replayed = process.new_subject()
  let recovered_agent =
    editor(
      model.new(fn(request) {
        process.send(replayed, request.messages)
        Ok(model.FinalAnswer("{\"text\":\"recovered revision\"}", None))
      }),
    )
  let assert Ok(settings) =
    fabric_postgres.settings(connection, "survivor")
    |> fabric_postgres.with_schema(schema)
  let settings =
    fabric_postgres.with_lease(settings, duration.milliseconds(300))
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("history-survivor"), settings)
  let assert Ok(subtree) =
    sweeper.supervised(
      runs,
      [sweeper.agent(recovered_agent, fn(_) { Nil })],
      every: duration.milliseconds(10),
    )
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(subtree)
    |> static_supervisor.start
  use <- with_process(supervisor.pid)
  let assert Ok(handle) = fabric.open(runs, recovered_agent, Nil, id)
  settled(handle, 300)
  |> should.equal(run.Finished(run.Completed(Revision("recovered revision"))))
  let assert Ok(after_crash) = process.receive(replayed, 30_000)
  after_crash |> should.equal(before_crash)
  fabric.matches_initial(handle, initial) |> should.equal(Ok(True))
  let assert Ok([invalid, correction, final]) =
    fabric.generated_messages(handle)
  invalid |> should.equal(assistant("invalid answer"))
  let assert model.UserMessage(_) = correction
  final |> should.equal(assistant("{\"text\":\"recovered revision\"}"))
  let generated = [invalid, correction, final]
  let assert Ok(snapshot) = fabric.snapshot(handle)
  snapshot.actions |> should.equal([])
  snapshot.incarnation |> should.equal(2)

  // No prune runs while this store has an unapplied outcome.
  applied(connection, table) |> should.equal(None)
  let service = invoke.agent_with_history("revision", runs, recovered_agent)
  let outcome = #(Revision("recovered revision"), generated)
  // A delivery process observes completion and dies before incorporation.
  let #(delivery, observed) =
    agents.owned(fn() { invoke.call(service, request(initial)) })
  use <- with_process(delivery)
  invoke.answer(observed) |> should.equal(Some(outcome.0))
  agents.kill(delivery)
  applied(connection, table) |> should.equal(None)
  // The next delivery commits incorporation, then dies before acknowledging
  // delivery. The harness sees the commit boundary, not an acknowledgement.
  let #(writer, committed) =
    agents.owned(fn() {
      deliver(connection, table, service, runs, recovered_agent, initial)
    })
  use <- with_process(writer)
  committed |> should.equal(outcome)
  agents.kill(writer)
  // A duplicated transaction or delivery has no second business mutation.
  incorporate(connection, table, Revision("recovered revision"), generated)
  |> should.equal(Ok(Nil))
  deliver(connection, table, service, runs, recovered_agent, initial)
  |> should.equal(outcome)
  applied(connection, table) |> should.equal(Some(outcome))
  let assert Ok(rows) =
    pog.query("SELECT applications FROM " <> table)
    |> pog.returning(decode.field(0, decode.int, decode.success))
    |> pog.execute(connection)
  rows.rows |> should.equal([1])

  // This isolated store now has no unapplied outcomes and admission is stopped.
  fabric_postgres.prune(
    settings,
    ended_for: duration.milliseconds(0),
    limit: 10,
  )
  |> should.equal(Ok(1))
  fabric.open(runs, recovered_agent, Nil, id)
  |> should.equal(Error(fabric.RunNotFound))
  deliver(connection, table, service, runs, recovered_agent, initial)
  |> should.equal(outcome)
  fabric.open(runs, recovered_agent, Nil, id)
  |> should.equal(Error(fabric.RunNotFound))
  process.receive(replayed, 0) |> should.equal(Error(Nil))
}

fn durable(connection, schema) {
  let assert Ok(rows) =
    pog.query(
      "SELECT json_build_array(record,revision,updated_at,lease_owner,lease_until)::text FROM \""
      <> schema
      <> "\".fabric_runs ORDER BY run_id",
    )
    |> pog.returning(decode.field(0, decode.string, decode.success))
    |> pog.execute(connection)
  rows.rows
}

pub fn previous_projection_unknown_markers_refresh_history_records_without_rewriting_them_test() {
  use connection <- support.using_pool(4)
  let schema = support.schema()
  let settings = support.migrated(connection, "refresh", schema)
  let assert Ok(runs) =
    fabric_postgres.store(process.new_name("history-refresh"), settings)
  let assert Ok(Nil) = store.start(runs)
  let agent =
    editor(
      model.new(fn(_) { Ok(model.FinalAnswer("{\"text\":\"done\"}", None)) }),
    )
  let assert Ok(initial) = input.new(historical(), "summarize")
  let response =
    invoke.call(
      invoke.agent_with_history("revision", runs, agent),
      request(initial),
    )
  invoke.answer(response) |> should.equal(Some(Revision("done")))
  let assert Ok(_) =
    pog.query(
      "UPDATE \""
      <> schema
      <> "\".fabric_runs SET retention='{\"version\":11}', discovery='{\"version\":12}', statistics='{\"version\":1}', updated_at=clock_timestamp()-interval '5 seconds'",
    )
    |> pog.execute(connection)
  let before = durable(connection, schema)
  let assert Ok(stale) = fabric_postgres.stats(settings)
  stale.unknown.count |> should.equal(1)
  fabric_postgres.prune(
    settings,
    ended_for: duration.milliseconds(0),
    limit: 10,
  )
  |> should.equal(Ok(0))
  fabric_postgres.refresh_retention(settings, 10) |> should.equal(Ok(1))
  fabric_postgres.refresh_discovery(settings, 10) |> should.equal(Ok(1))
  fabric_postgres.refresh_statistics(settings, 10) |> should.equal(Ok(1))
  durable(connection, schema) |> should.equal(before)
  let assert Ok(fresh) = fabric_postgres.stats(settings)
  fresh.unknown.count |> should.equal(0)
  fresh.finished.count |> should.equal(1)
  let assert Some(age) = fresh.finished.oldest_record_age_ms
  should.be_true(age >= 5000)
  fabric_postgres.refresh_retention(settings, 10) |> should.equal(Ok(0))
  fabric_postgres.refresh_discovery(settings, 10) |> should.equal(Ok(0))
  fabric_postgres.refresh_statistics(settings, 10) |> should.equal(Ok(0))
  let assert Ok(handle) = fabric.open(runs, agent, Nil, invoke.id(response))
  fabric.matches_initial(handle, initial) |> should.equal(Ok(True))
  fabric_postgres.prune(
    settings,
    ended_for: duration.milliseconds(0),
    limit: 10,
  )
  |> should.equal(Ok(1))
  store.stop(runs) |> should.equal(Ok(Nil))
}

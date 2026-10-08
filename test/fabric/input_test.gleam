import fabric
import fabric/agent
import fabric/input
import fabric/invoke
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import sinal/correlation

fn history(text: String) {
  [
    model.UserMessage("first"),
    model.AssistantMessage(model.AssistantTurn(text, [], None)),
  ]
}

pub fn keyed_history_compares_the_complete_original_input_test() {
  let runs = support.store()
  let model =
    model.new(fn(request) {
      request.messages
      |> should.equal(list.append(history("old"), [model.UserMessage("next")]))
      Ok(model.FinalAnswer("done", None))
    })
  let agent =
    agent.new("history", model, [], policy.always_allow()) |> support.agent
  let service = invoke.agent_with_history("history", runs, agent)
  let original = input.new(history("old"), "next") |> should.be_ok
  let request =
    invoke.request("context", original) |> invoke.with_key(Some("turn"))
  let response = invoke.call(service, request)
  invoke.answer(response) |> should.equal(Some("done"))
  let retry =
    invoke.request("new context", original)
    |> invoke.with_key(Some("turn"))
    |> invoke.with_correlation(correlation.from_key("retry"))
  invoke.call(service, retry) |> invoke.answer |> should.equal(Some("done"))
  let changed = input.new(history("changed"), "next") |> should.be_ok
  invoke.call(
    service,
    invoke.request("context", changed) |> invoke.with_key(Some("turn")),
  )
  |> invoke.code
  |> should.equal("key_reused")
  let changed = input.new(history("old"), "changed") |> should.be_ok
  invoke.call(
    service,
    invoke.request("context", changed) |> invoke.with_key(Some("turn")),
  )
  |> invoke.code
  |> should.equal("key_reused")
  let handle =
    fabric.open(runs, agent, "new context", invoke.id(response)) |> should.be_ok
  fabric.matches_initial(handle, original) |> should.equal(Ok(True))
  fabric.generated_messages(handle)
  |> should.equal(
    Ok([model.AssistantMessage(model.AssistantTurn("done", [], None))]),
  )
  fabric.await(handle, duration.seconds(1))
  |> should.equal(Ok(run.Finished(run.Completed("done"))))
}

pub fn malformed_history_is_refused_at_construction_test() {
  let call = model.tool_call("c", "lookup", "{}")
  input.new([model.ToolResultMessage("c", "orphan")], "next") |> should.be_error
  input.new(
    [model.AssistantMessage(model.AssistantTurn("answer", [], None))],
    "next",
  )
  |> should.be_error
  input.new(
    [
      model.UserMessage("first"),
      model.AssistantMessage(model.AssistantTurn("", [call], None)),
    ],
    "next",
  )
  |> should.be_error
  input.new(
    [
      model.UserMessage("first"),
      model.AssistantMessage(model.AssistantTurn("", [call, call], None)),
      model.ToolResultMessage("c", "result"),
    ],
    "next",
  )
  |> should.be_error
  input.new(
    [
      model.UserMessage("first"),
      model.AssistantMessage(model.AssistantTurn("", [call], None)),
      model.ToolResultMessage("other", "result"),
    ],
    "next",
  )
  |> should.be_error
}

import fabric/internal/controller
import fabric/internal/record
import fabric/internal/runner
import fabric/store
import gleam/erlang/process
import gleam/string

pub fn closed_batches_preserve_roles_order_and_opaque_metadata_test() {
  let call =
    model.tool_call("a", "retired_tool", "not JSON: historical text")
    |> model.with_provider_replay(Some("provider-id"), Some("opaque signature"))
  let other = model.tool_call("b", "other_tool", "{}")
  let exchange = [
    model.UserMessage("first"),
    model.AssistantMessage(model.AssistantTurn(
      "thinking",
      [call, other],
      Some(model.ProviderData("unknown.v9", "opaque data")),
    )),
    model.ToolResultMessage("b", "second first"),
    model.ToolResultMessage("a", "first second"),
    model.AssistantMessage(model.AssistantTurn("answer", [], None)),
    model.UserMessage("another"),
    model.AssistantMessage(model.AssistantTurn("", [call], None)),
    model.ToolResultMessage("a", "reused in different turn"),
  ]
  input.new(exchange, "current")
  |> should.be_ok
  |> input.messages
  |> should.equal(list.append(exchange, [model.UserMessage("current")]))
  input.new([model.UserMessage("adjacent")], "current")
  |> should.be_ok
  |> input.messages
  |> should.equal([model.UserMessage("adjacent"), model.UserMessage("current")])
  input.new([], "current") |> should.equal(Ok(input.prompt("current")))
  let assistant = model.AssistantMessage(model.AssistantTurn("", [call], None))
  input.new(
    [
      model.UserMessage("first"),
      assistant,
      model.ToolResultMessage("a", "result"),
      model.ToolResultMessage("a", "duplicate"),
    ],
    "current",
  )
  |> should.equal(Error(input.UnexpectedToolResult("a")))
  input.new(
    [model.UserMessage("first"), assistant, model.UserMessage("interrupt")],
    "current",
  )
  |> should.equal(Error(input.UnresolvedCalls(["a"])))
  let empty = model.tool_call("", "tool", "{}")
  input.new(
    [
      model.UserMessage("first"),
      model.AssistantMessage(model.AssistantTurn("", [empty], None)),
      model.ToolResultMessage("", "result"),
    ],
    "current",
  )
  |> should.equal(Error(input.InvalidCallId))
}

fn answer_agent(seen) {
  agent.new(
    "codec-input",
    model.new(fn(request) {
      process.send(seen, request.messages)
      Ok(model.FinalAnswer("answer", None))
    }),
    [],
    policy.always_allow(),
  )
  |> support.agent
}

pub fn older_writers_refuse_history_before_storage_or_model_effects_test() {
  let seen = process.new_subject()
  let agent = answer_agent(seen)
  let runs = support.store()
  let original = input.new(history("old"), "next") |> should.be_ok
  list.each([2, 3, 4, 5, 6, 7], fn(version) {
    let old = store.with_record_version(runs, version) |> should.be_ok
    let id = run.new_id()
    fabric.start_with_input(
      old,
      agent,
      id:,
      context: Nil,
      input: original,
      correlation: None,
    )
    |> should.equal(Error(fabric.HistoryUnsupported))
    fabric.open(old, agent, Nil, id) |> should.equal(Error(fabric.RunNotFound))
  })
  process.receive(seen, 20) |> should.equal(Error(Nil))
  fabric.error_kind(fabric.HistoryUnsupported)
  |> should.equal(fabric.Incompatible)
}

pub fn boundary_and_original_history_are_validated_on_record_reads_and_writes_test() {
  let seen = process.new_subject()
  let agent = answer_agent(seen)
  let runs = support.store()
  let original = input.new(history("old"), "next") |> should.be_ok
  let id = run.new_id()
  let handle =
    fabric.start_with_input(
      runs,
      agent,
      id:,
      context: Nil,
      input: original,
      correlation: None,
    )
    |> should.be_ok
  fabric.await(handle, duration.seconds(1))
  |> should.equal(Ok(run.Finished(run.Completed("answer"))))
  let #(_, state) = runner.load(runs, run.id_to_string(id)) |> should.be_ok
  state.initial_message_count |> should.equal(3)
  record.encode_as(state, record.V8)
  |> should.be_ok
  |> record.decode
  |> should.equal(Ok(state))
  list.each(
    [record.V2, record.V3, record.V4, record.V5, record.V6, record.V7],
    fn(version) { record.encode_as(state, version) |> should.be_error },
  )
  list.each([-1, 0, 2, 5], fn(count) {
    let invalid = controller.State(..state, initial_message_count: count)
    let assert Error(record.Corrupt(_)) = record.decode(record.encode(invalid))
    record.encode_as(invalid, record.V8) |> should.be_error
  })
  let malformed =
    controller.State(..state, transcript: [
      model.ToolResultMessage("orphan", "result"),
      model.AssistantMessage(model.AssistantTurn("old", [], None)),
      model.UserMessage("next"),
    ])
  record.decode(record.encode(malformed)) |> should.be_error
  let missing =
    record.encode(state)
    |> string.replace("\"initial_message_count\":3", "\"other_field\":3")
  record.decode(missing) |> should.be_error
  let old_tag =
    record.encode(state) |> string.replace("\"version\":8", "\"version\":7")
  record.decode(old_tag) |> should.be_error
  fabric.start_with_input(
    runs,
    agent,
    id:,
    context: Nil,
    input: original,
    correlation: Some(correlation.from_key("new retry")),
  )
  |> should.equal(Error(fabric.AlreadyStarted(id, True)))
  let prompt_only =
    fabric.start(
      runs,
      agent,
      id: run.new_id(),
      context: Nil,
      prompt: "legacy",
      correlation: None,
    )
    |> should.be_ok
  fabric.await(prompt_only, duration.seconds(1)) |> should.be_ok
  let #(_, state) =
    runner.load(runs, run.id_to_string(fabric.id(prompt_only))) |> should.be_ok
  list.each(
    [record.V2, record.V3, record.V4, record.V5, record.V6, record.V7],
    fn(version) {
      record.encode_as(state, version)
      |> should.be_ok
      |> record.decode
      |> should.equal(Ok(state))
    },
  )
}

import fabric/support/restart
import json/blueprint/codec

pub fn recovered_repair_budget_counts_only_new_answers_and_still_exhausts_test() {
  let entered = process.new_subject()
  let waiting =
    model.new(fn(request) {
      case request.turn {
        1 -> Ok(model.FinalAnswer("invalid first", None))
        _ -> {
          process.send(entered, request.messages)
          let wait: process.Subject(Nil) = process.new_subject()
          process.receive_forever(wait)
          Ok(model.FinalAnswer("unreachable", None))
        }
      }
    })
  let definition = fn(model) {
    agent.new("repair-history", model, [], policy.always_allow())
    |> agent.with_answer(codec.int())
    |> agent.with_answer_attempts(2)
    |> support.agent
  }
  let original =
    input.new(
      list.append(history("old answer"), history("second old answer")),
      "new",
    )
    |> should.be_ok
  let runs = support.store()
  let service =
    invoke.agent_with_history("repair-history", runs, definition(waiting))
    |> invoke.with_wait(duration.milliseconds(10))
  let response =
    invoke.call(
      service,
      invoke.request(Nil, original) |> invoke.with_key(Some("turn")),
    )
  invoke.response_kind(response) |> should.equal(invoke.Working)
  let messages = process.receive(entered, 1000) |> should.be_ok
  list.take(messages, 5) |> should.equal(input.messages(original))
  list.length(messages) |> should.equal(7)
  let id = invoke.id(response)
  restart.runner(runs, id) |> should.be_ok |> restart.kill
  let seen = process.new_subject()
  let agent =
    definition(
      model.new(fn(request) {
        process.send(seen, request.messages)
        Ok(model.FinalAnswer("invalid second", None))
      }),
    )
  let handle = fabric.recover(runs, agent, Nil, id) |> should.be_ok
  let assert Ok(run.Finished(run.AnswerInvalid(raw: "invalid second", ..))) =
    fabric.await(handle, duration.seconds(2))
  process.receive(seen, 1000) |> should.equal(Ok(messages))
  process.receive(seen, 20) |> should.equal(Error(Nil))
  fabric.generated_messages(handle)
  |> should.be_ok
  |> list.length
  |> should.equal(3)
}

pub fn prompt_and_empty_history_facades_share_keyed_identity_test() {
  let seen = process.new_subject()
  let agent = answer_agent(seen)
  let runs = support.store()
  let legacy = invoke.agent("compatible", runs, agent)
  let history = invoke.agent_with_history("compatible", runs, agent)
  let first =
    invoke.call(
      legacy,
      invoke.request(Nil, "current")
        |> invoke.with_principal("member")
        |> invoke.with_key(Some("turn")),
    )
  let original = input.new([], "current") |> should.be_ok
  let duplicate =
    invoke.call(
      history,
      invoke.request(Nil, original)
        |> invoke.with_principal("member")
        |> invoke.with_key(Some("turn")),
    )
  invoke.id(duplicate) |> should.equal(invoke.id(first))
  invoke.answer(first) |> should.equal(Some("answer"))
  invoke.answer(duplicate) |> should.equal(invoke.answer(first))
  process.receive(seen, 1000)
  |> should.equal(Ok([model.UserMessage("current")]))
  process.receive(seen, 20) |> should.equal(Error(Nil))
}

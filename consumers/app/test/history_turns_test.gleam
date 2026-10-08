import fabric
import fabric/input
import fabric/invoke
import fabric/model
import fabric/run
import fabric/store
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleeunit/should
import history_turns
import sinal/correlation

fn memory() {
  let runs = store.in_memory(process.new_name("history-consumer"))
  let assert Ok(Nil) = store.start(runs)
  runs
}

fn editor() {
  history_turns.Editor("editor", True, process.new_subject())
}

fn request(context, initial, key) {
  invoke.request(context, initial)
  |> invoke.with_principal("authenticated-editor")
  |> invoke.with_key(Some(key))
}

fn assistant(text) {
  model.AssistantMessage(model.AssistantTurn(text, [], None))
}

fn historical() {
  [model.UserMessage("draft"), assistant("old revision")]
}

pub fn successive_keyed_turns_reopen_the_complete_original_input_test() {
  let observed = process.new_subject()
  let provider =
    model.new(fn(request) {
      process.send(observed, request)
      Ok(model.FinalAnswer("{\"text\":\"revised\"}", None))
    })
  let agent = history_turns.revision_agent(provider)
  let runs = memory()
  let service = invoke.agent_with_history("revision", runs, agent)
  let context = editor()
  let assert Ok(initial) = input.new(historical(), "shorten")
  let first =
    invoke.call(
      service,
      request(context, initial, "revision-1")
        |> invoke.with_correlation(correlation.from_key("first")),
    )
  invoke.answer(first) |> should.equal(Some(history_turns.Revision("revised")))
  let assert Ok(seen) = process.receive(observed, 1000)
  seen.messages
  |> should.equal(list.append(historical(), [model.UserMessage("shorten")]))
  seen.correlation |> should.equal(correlation.from_key("first"))
  let assert Ok(handle) = fabric.open(runs, agent, context, invoke.id(first))
  fabric.matches_initial(handle, initial) |> should.equal(Ok(True))
  let assert Ok(generated) = fabric.generated_messages(handle)
  generated |> should.equal([assistant("{\"text\":\"revised\"}")])

  let duplicate =
    invoke.call(
      service,
      request(
        history_turns.Editor(..context, name: "refreshed", may_record: False),
        initial,
        "revision-1",
      )
        |> invoke.with_correlation(correlation.from_key("retry")),
    )
  invoke.id(duplicate) |> should.equal(invoke.id(first))
  invoke.answer(duplicate) |> should.equal(invoke.answer(first))
  process.receive(observed, 0) |> should.equal(Error(Nil))

  let assert Ok(changed_history) =
    input.new(
      [model.UserMessage("draft"), assistant("different revision")],
      "shorten",
    )
  let assert Ok(changed_prompt) = input.new(historical(), "expand")
  list.each([changed_history, changed_prompt], fn(changed) {
    invoke.call(service, request(context, changed, "revision-1"))
    |> invoke.code
    |> should.equal("key_reused")
  })
  let next_history =
    list.append(
      list.append(historical(), [model.UserMessage("shorten")]),
      generated,
    )
  let assert Ok(next_input) = input.new(next_history, "add a title")
  let second = invoke.call(service, request(context, next_input, "revision-2"))
  invoke.id(second) |> should.not_equal(invoke.id(first))
  invoke.answer(second) |> should.equal(Some(history_turns.Revision("revised")))
  let assert Ok(next_seen) = process.receive(observed, 1000)
  next_seen.messages
  |> should.equal(list.append(next_history, [model.UserMessage("add a title")]))
}

pub fn classification_uses_native_answers_with_bounded_wait_and_keyed_disconnect_test() {
  let arrivals = process.new_subject()
  let agent =
    history_turns.label_agent(
      model.new(fn(_) {
        let release = process.new_subject()
        process.send(arrivals, release)
        process.receive_forever(release)
        Ok(model.FinalAnswer("{\"category\":\"reference\"}", None))
      }),
    )
  let runs = memory()
  let service =
    invoke.agent_with_history("classification", runs, agent)
    |> invoke.with_wait(duration.milliseconds(10))
  let assert Ok(initial) =
    input.new(
      [model.UserMessage("a manual"), assistant("{\"category\":\"technical\"}")],
      "classify its index",
    )
  let disconnected = process.new_subject()
  process.send(disconnected, Nil)
  let request =
    request(Nil, initial, "classification-1")
    |> invoke.with_cancelled(
      process.new_selector() |> process.select(disconnected),
    )
  let first = invoke.call(service, request)
  invoke.response_kind(first) |> should.equal(invoke.Working)
  let assert Ok(release) = process.receive(arrivals, 1000)
  let assert Ok(handle) = fabric.open(runs, agent, Nil, invoke.id(first))
  fabric.await(handle, duration.milliseconds(0))
  |> should.equal(Ok(run.Working))
  process.send(release, Nil)
  let second =
    invoke.call(service |> invoke.with_wait(duration.seconds(1)), request)
  invoke.id(second) |> should.equal(invoke.id(first))
  invoke.answer(second) |> should.equal(Some(history_turns.Label("reference")))
  process.receive(disconnected, 0) |> should.equal(Ok(Nil))
  process.send(disconnected, Nil)
  let unkeyed =
    invoke.call(
      service,
      invoke.request(Nil, initial)
        |> invoke.with_cancelled(
          process.new_selector() |> process.select(disconnected),
        ),
    )
  invoke.code(unkeyed) |> should.equal("cancelled")
  let assert Ok(cancelled) = fabric.open(runs, agent, Nil, invoke.id(unkeyed))
  fabric.await(cancelled, duration.seconds(1))
  |> should.equal(Ok(run.Finished(run.Cancelled)))
}

fn replay_turn(signature) {
  model.AssistantTurn(
    "recording",
    [
      model.tool_call("note", "record_note", "\"current note\"")
      |> model.with_provider_replay(Some("wire-call"), Some(signature)),
    ],
    Some(model.ProviderData("fixture.v1", "opaque response data")),
  )
}

pub fn historical_tools_are_context_and_current_tools_recheck_live_authority_test() {
  let old_turn = replay_turn("old-signature")
  let history = [
    model.UserMessage("previous note"),
    model.AssistantMessage(old_turn),
    model.ToolResultMessage("note", "\"old note\""),
    assistant("old answer"),
  ]
  let new_turn = replay_turn("new-signature")
  let observed = process.new_subject()
  let provider =
    model.new(fn(request) {
      process.send(observed, request.messages)
      Ok(case request.turn {
        1 -> model.ToolRequest(new_turn, None)
        _ -> model.FinalAnswer("{\"text\":\"done\"}", None)
      })
    })
  let agent = history_turns.revision_agent(provider)
  let context = editor()
  let runs = memory()
  let service = invoke.agent_with_history("revision", runs, agent)
  let assert Ok(initial) = input.new(history, "record another note")
  let response = invoke.call(service, request(context, initial, "notes-1"))
  invoke.answer(response) |> should.equal(Some(history_turns.Revision("done")))
  let assert Ok(seen) = process.receive(observed, 1000)
  seen
  |> should.equal(
    list.append(history, [model.UserMessage("record another note")]),
  )
  process.receive(context.recorded, 1000)
  |> should.equal(Ok("editor: current note"))
  process.receive(context.recorded, 0) |> should.equal(Error(Nil))
  let assert Ok(handle) = fabric.open(runs, agent, context, invoke.id(response))
  fabric.generated_messages(handle)
  |> should.equal(
    Ok([
      model.AssistantMessage(new_turn),
      model.ToolResultMessage("note", "\"current note\""),
      assistant("{\"text\":\"done\"}"),
    ]),
  )
  let assert Ok(changed) =
    input.new(
      [
        model.UserMessage("previous note"),
        model.AssistantMessage(replay_turn("changed-signature")),
        model.ToolResultMessage("note", "\"old note\""),
        assistant("old answer"),
      ],
      "record another note",
    )
  invoke.call(service, request(context, changed, "notes-1"))
  |> invoke.code
  |> should.equal("key_reused")

  let denied = history_turns.Editor(..context, may_record: False)
  let response = invoke.call(service, request(denied, initial, "notes-2"))
  invoke.answer(response) |> should.equal(Some(history_turns.Revision("done")))
  let assert Ok(handle) = fabric.open(runs, agent, denied, invoke.id(response))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert [action] = snapshot.actions
  action.state |> should.equal(run.Denied("editor cannot record notes"))
  process.receive(context.recorded, 0) |> should.equal(Error(Nil))
}

pub fn imported_answers_do_not_consume_the_new_typed_answer_repair_allowance_test() {
  let provider =
    model.new(fn(request) {
      Ok(model.FinalAnswer(
        case request.turn {
          1 -> "not valid JSON"
          _ -> "{\"text\":\"corrected\"}"
        },
        None,
      ))
    })
  let agent = history_turns.revision_agent(provider)
  let runs = memory()
  let context = editor()
  let history = [
    model.UserMessage("one"),
    assistant("first"),
    model.UserMessage("two"),
    assistant("second"),
    model.UserMessage("three"),
    assistant("third"),
  ]
  let assert Ok(initial) = input.new(history, "revise")
  let response =
    invoke.call(
      invoke.agent_with_history("revision", runs, agent),
      request(context, initial, "repair-1"),
    )
  invoke.answer(response)
  |> should.equal(Some(history_turns.Revision("corrected")))
  let assert Ok(handle) = fabric.open(runs, agent, context, invoke.id(response))
  let assert Ok([bad, correction, good]) = fabric.generated_messages(handle)
  bad |> should.equal(assistant("not valid JSON"))
  let assert model.UserMessage(_) = correction
  good |> should.equal(assistant("{\"text\":\"corrected\"}"))
}

pub fn malformed_history_is_refused_by_the_public_constructor_test() {
  let call = replay_turn("signature")
  list.each(
    [
      [assistant("no user")],
      [model.UserMessage("first"), model.ToolResultMessage("missing", "orphan")],
      [model.UserMessage("first"), model.AssistantMessage(call)],
      [
        model.UserMessage("first"),
        model.AssistantMessage(call),
        model.ToolResultMessage("note", "once"),
        model.ToolResultMessage("note", "twice"),
      ],
    ],
    fn(history) { input.new(history, "next") |> should.be_error },
  )
}

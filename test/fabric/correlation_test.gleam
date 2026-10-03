//// Caller-chosen run ids and the run's correlation: in every model request,
//// every tool call, every event, sub-agent runs and recovered runs.

import fabric
import fabric/agent
import fabric/internal/checked_agent
import fabric/internal/controller
import fabric/internal/record
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/codecs
import fabric/support/scripted
import fabric/telemetry as o
import fabric/tool
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import sinal
import sinal/correlation

/// A model that reports every request it receives to `requests`, then
/// answers with `reply`.
fn reporting_model(
  requests: Subject(model.Request),
  reply: fn(model.Request) -> model.Reply,
) -> model.Model {
  model.new(fn(request) {
    process.send(requests, request)
    Ok(reply(request))
  })
}

/// A tool `note` that reports the `tool.Call` it answers.
fn call_tool(calls: Subject(tool.Call)) -> tool.Tool(Nil) {
  tool.define(
    "note",
    "Notes a call.",
    codecs.one_field("x", codec.string()),
    codec.string(),
  )
  |> tool.bind(
    fn(_context, call, x: String) -> Result(String, Nil) {
      process.send(calls, call)
      Ok(x)
    },
    fn(_) { tool.Explain("failed") },
  )
}

fn one_call_then_answer(request: model.Request) -> model.Reply {
  case scripted.results(request.messages) {
    [] ->
      model.ToolRequest(
        model.AssistantTurn(
          "",
          [scripted.call("c1", "note", "{\"x\":\"a\"}")],
          None,
        ),
        None,
      )
    _ -> model.FinalAnswer("done", None)
  }
}

pub fn a_run_starts_under_the_callers_id_test() {
  let runs = support.store()
  let desk =
    agent.new(
      "desk",
      scripted.model(fn(_) { model.FinalAnswer("done", None) }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let id = support.id("job-42")
  let assert Ok(handle) =
    fabric.start(runs, desk, id:, context: Nil, prompt: "go", correlation: None)
  fabric.id(handle) |> should.equal(id)
  fabric.await(handle, within: duration.seconds(5))
  |> should.equal(Ok(run.Finished(run.Completed("done"))))
}

/// A job delivered twice starts its run once: the second start stores
/// nothing and names the run, which the caller then opens.
pub fn starting_again_with_the_same_id_is_already_started_test() {
  let runs = support.store()
  let requests = process.new_subject()
  let desk =
    agent.new(
      "desk",
      reporting_model(requests, fn(_) { model.FinalAnswer("done", None) }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let id = support.id("job-7")
  let assert Ok(first) =
    fabric.start(runs, desk, id:, context: Nil, prompt: "go", correlation: None)
  let assert Ok(run.Finished(run.Completed("done"))) =
    fabric.await(first, within: duration.seconds(5))
  fabric.start(
    runs,
    desk,
    id:,
    context: Nil,
    prompt: "again",
    correlation: None,
  )
  |> should_be_already_started(id)
  let assert Ok(opened) = fabric.open(runs, desk, Nil, id)
  fabric.await(opened, within: duration.seconds(1))
  |> should.equal(Ok(run.Finished(run.Completed("done"))))
  // The second start called no model.
  let assert Ok(_) = process.receive(requests, 100)
  process.receive(requests, 100) |> should.equal(Error(Nil))
}

fn should_be_already_started(
  started: Result(fabric.Run(Nil), fabric.Error),
  id: run.RunId,
) -> Nil {
  case started {
    Error(fabric.AlreadyStarted(found, same_input:)) -> {
      found |> should.equal(id)
      // The second start's prompt differs from the stored run's.
      same_input |> should.be_false
    }
    _ -> panic as "expected AlreadyStarted"
  }
}

/// Every model request names its run and turn and carries the run's
/// correlation; every tool call carries the run, the action and the
/// correlation.
pub fn requests_and_tool_calls_carry_the_run_and_its_correlation_test() {
  let runs = support.store()
  let requests = process.new_subject()
  let calls = process.new_subject()
  let desk =
    agent.new(
      "desk",
      reporting_model(requests, one_call_then_answer),
      [call_tool(calls)],
      policy.always_allow(),
    )
    |> support.agent
  let id = support.id("ticket-run")
  let ticket = correlation.from_key("ticket-9")
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk,
      id:,
      context: Nil,
      prompt: "go",
      correlation: Some(ticket),
    )
  let assert Ok(run.Finished(run.Completed("done"))) =
    fabric.await(handle, within: duration.seconds(5))
  let assert Ok(first) = process.receive(requests, 100)
  let assert Ok(second) = process.receive(requests, 100)
  #(first.run, first.turn, first.correlation)
  |> should.equal(#(id, 1, ticket))
  #(second.run, second.turn, second.correlation)
  |> should.equal(#(id, 2, ticket))
  let assert Ok(call) = process.receive(calls, 100)
  call
  |> should.equal(tool.Call(
    run: id,
    action: run.ActionId(1, "c1"),
    correlation: ticket,
  ))
}

/// Without a caller correlation, the run's is derived from its id.
pub fn the_default_correlation_is_derived_from_the_run_id_test() {
  let runs = support.store()
  let requests = process.new_subject()
  let desk =
    agent.new(
      "desk",
      reporting_model(requests, fn(_) { model.FinalAnswer("done", None) }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let id = run.new_id()
  let assert Ok(handle) =
    fabric.start(runs, desk, id:, context: Nil, prompt: "go", correlation: None)
  let assert Ok(_) = fabric.await(handle, within: duration.seconds(5))
  let assert Ok(request) = process.receive(requests, 100)
  request.correlation
  |> should.equal(correlation.from_key(run.id_to_string(id)))
}

/// The run's events carry its correlation in their metadata.
pub fn events_carry_the_run_correlation_test() {
  let runs = support.store()
  let id = support.id("observed-run")
  let ticket = correlation.from_key("ticket-observed")
  let seen = process.new_subject()
  let attachments = [
    sinal.observe(o.run_started(), fn(_, m: o.RunStarted) {
      process.send(seen, #("run_started", m.run, m.correlation))
    }),
    sinal.observe(o.model_turn(), fn(_, m: o.ModelTurn) {
      process.send(seen, #("model_turn", m.run, m.correlation))
    }),
    sinal.observe(o.tool_settled(), fn(_, m: o.ToolSettled) {
      process.send(seen, #("tool_settled", m.action.run, m.correlation))
    }),
    sinal.observe(o.run_finished(), fn(_, m: o.RunFinished) {
      process.send(seen, #("run_finished", m.run, m.correlation))
    }),
  ]
  let desk =
    agent.new(
      "desk",
      model.new(fn(request) { Ok(one_call_then_answer(request)) }),
      [call_tool(process.new_subject())],
      policy.always_allow(),
    )
    |> support.agent
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk,
      id:,
      context: Nil,
      prompt: "go",
      correlation: Some(ticket),
    )
  let assert Ok(_) = fabric.await(handle, within: duration.seconds(5))
  let events = collect(seen, [])
  list.each(attachments, fn(attachment) {
    let _ = sinal.detach(attachment)
    Nil
  })
  let mine = list.filter(events, fn(event) { event.1 == "observed-run" })
  list.map(mine, fn(event) { event.0 })
  |> should.equal([
    "run_started", "model_turn", "tool_settled", "model_turn", "run_finished",
  ])
  list.all(mine, fn(event) { event.2 == ticket }) |> should.be_true
}

fn collect(
  seen: Subject(#(String, String, correlation.Correlation)),
  acc: List(#(String, String, correlation.Correlation)),
) -> List(#(String, String, correlation.Correlation)) {
  case process.receive(seen, 100) {
    Ok(event) -> collect(seen, [event, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

/// A sub-agent run carries its parent's correlation.
pub fn a_sub_agent_carries_its_parents_correlation_test() {
  let runs = support.store()
  let requests = process.new_subject()
  let child =
    agent.new(
      "researcher",
      reporting_model(requests, fn(_) { model.FinalAnswer("found", None) }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let research =
    tool.define(
      "research",
      "Research a topic.",
      codecs.one_field("topic", codec.string()),
      codec.string(),
    )
  let parent =
    agent.new(
      "front",
      scripted.plan([scripted.call("r1", "research", "{\"topic\":\"x\"}")]),
      [],
      policy.always_allow(),
    )
    |> agent.with_sub_agent(
      research,
      to: child,
      prompt: fn(topic) { topic },
      output: fn(answer) { Ok(answer) },
    )
    |> support.agent
  let ticket = correlation.from_key("ticket-family")
  let assert Ok(handle) =
    fabric.start(
      runs,
      parent,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: Some(ticket),
    )
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(handle, within: duration.seconds(5))
  let assert Ok(request) = process.receive(requests, 100)
  request.correlation |> should.equal(ticket)
  request.run |> should.equal(support.child_id(fabric.id(handle), 1))
}

/// Every event of a family names its root run: a sub-agent's, and its
/// own sub-agent's, join the root's.
pub fn a_families_events_carry_its_root_test() {
  let runs = support.store()
  let research =
    tool.define(
      "research",
      "Research a topic.",
      codecs.one_field("topic", codec.string()),
      codec.string(),
    )
  let delegating = fn(name, child) {
    agent.new(
      name,
      scripted.plan([scripted.call("r1", "research", "{\"topic\":\"x\"}")]),
      [],
      policy.always_allow(),
    )
    |> agent.with_max_depth(2)
    |> agent.with_sub_agent(
      research,
      to: child,
      prompt: fn(topic) { topic },
      output: fn(answer) { Ok(answer) },
    )
    |> support.agent
  }
  let leaf =
    agent.new(
      "leaf",
      scripted.model(fn(_) { model.FinalAnswer("found", None) }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let root_agent = delegating("front", delegating("middle", leaf))
  let seen = process.new_subject()
  let attachments = [
    sinal.observe(o.run_started(), fn(_, m: o.RunStarted) {
      process.send(seen, #("run_started", m.run, m.root))
    }),
    sinal.observe(o.child_started(), fn(_, m: o.ChildStarted) {
      process.send(seen, #("child_started", m.action.run, m.root))
    }),
    sinal.observe(o.run_finished(), fn(_, m: o.RunFinished) {
      process.send(seen, #("run_finished", m.run, m.root))
    }),
  ]
  let id = support.id("family-root")
  let assert Ok(handle) =
    fabric.start(
      runs,
      root_agent,
      id:,
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(handle, within: duration.seconds(5))
  let events = collect_roots(seen, [])
  list.each(attachments, fn(attachment) {
    let _ = sinal.detach(attachment)
    Nil
  })
  let child = support.text(support.child_id(id, 1))
  let grandchild = support.text(support.child_id(support.child_id(id, 1), 1))
  let family =
    list.filter(events, fn(event) {
      event.1 == "family-root" || event.1 == child || event.1 == grandchild
    })
  list.count(family, fn(event) { event.0 == "run_started" }) |> should.equal(3)
  list.count(family, fn(event) { event.0 == "run_finished" }) |> should.equal(3)
  list.all(family, fn(event) { event.2 == "family-root" }) |> should.be_true
}

fn collect_roots(
  seen: Subject(#(String, String, String)),
  acc: List(#(String, String, String)),
) -> List(#(String, String, String)) {
  case process.receive(seen, 100) {
    Ok(event) -> collect_roots(seen, [event, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

/// A sub-agent's record stores its root; a root's does not, so its bytes
/// are as before. A sub-agent record written before roots were stored
/// reads its parent as its root.
pub fn a_sub_agents_record_keeps_its_root_test() {
  let desk =
    agent.new(
      "desk",
      scripted.model(fn(_) { model.FinalAnswer("done", None) }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let env =
    controller.Env(
      registry: checked_agent.admitted(desk).registry,
      policy: policy.always_allow(),
      context: Nil,
      system: None,
      approval_expiry: None,
      clock: fn() { 0 },
    )
  let #(root, _) =
    controller.start(
      env,
      "root-run",
      run.DefinitionId("desk", 1),
      controller.Limits(8, None, 2, 2),
      "go",
      None,
      0,
    )
  string.contains(record.encode(root), "\"root\"") |> should.be_false
  let parent =
    Some(run.AgentParent(support.id("middle-run"), run.ActionId(1, "c")))
  let child =
    controller.State(..root, run: "middle-run-1", parent:, root: "root-run")
  let encoded = record.encode(child)
  string.contains(encoded, "\"root\":\"root-run\"") |> should.be_true
  let assert Ok(decoded) = record.decode(encoded)
  decoded.root |> should.equal("root-run")
  let without = string.replace(encoded, ",\"root\":\"root-run\"", "")
  let assert Ok(old) = record.decode(without)
  old.root |> should.equal("middle-run")
}

/// A caller's correlation is stored with the run: a later reader decodes it.
/// The default one is not written, so such records keep their bytes.
pub fn the_record_keeps_only_a_chosen_correlation_test() {
  let desk =
    agent.new(
      "desk",
      scripted.model(fn(_) { model.FinalAnswer("done", None) }),
      [],
      policy.always_allow(),
    )
    |> support.agent
  let #(state, _) =
    controller.start(
      controller.Env(
        registry: checked_agent.admitted(desk).registry,
        policy: policy.always_allow(),
        context: Nil,
        system: None,
        approval_expiry: None,
        clock: fn() { 0 },
      ),
      "plain-run",
      run.DefinitionId("desk", 1),
      controller.Limits(8, None, 0, 0),
      "go",
      None,
      0,
    )
  let plain = record.encode(state)
  string.contains(plain, "\"correlation\"") |> should.be_false
  let ticket = correlation.from_key("ticket-stored")
  let chosen = record.encode(controller.State(..state, correlation: ticket))
  string.contains(chosen, "\"correlation\":\"ticket-stored\"")
  |> should.be_true
  let assert Ok(decoded) = record.decode(chosen)
  decoded.correlation |> should.equal(ticket)
  let assert Ok(decoded) = record.decode(plain)
  decoded.correlation |> should.equal(correlation.from_key("plain-run"))
}

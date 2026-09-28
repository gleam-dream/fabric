//// Executed differential comparison against BeamWeaver fixtures.
////
//// Each fixture under test/oracle/fixtures was captured by running
//// BeamWeaver at the pinned commit (see docs/ORACLE.md). Each test runs the
//// same scenario through Fabric with a transcript-pure model following the
//// same rules, normalizes both observable sequences, and compares them:
//// transcript entries exactly (tool content only for successes), tool
//// effects as a multiset, and model calls by count.

import fabric
import fabric/agent
import fabric/model.{type Reply}
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/probe.{type Probe}
import fabric/support/restart
import fabric/support/scripted
import fabric/tool
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/codec

// --- normalized observables ----------------------------------------------------

type Entry {
  User(String)
  Calls(List(#(String, String)))
  /// `content` is compared only for successful results.
  ToolResult(id: String, status: String, content: Option(String))
  Assistant(String)
}

type Observed {
  Observed(
    transcript: List(Entry),
    tool_effects: List(String),
    model_calls: Int,
  )
}

@external(erlang, "fabric_oracle_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

fn entry_decoder() -> decode.Decoder(Entry) {
  use role <- decode.field("role", decode.string)
  case role {
    "user" ->
      decode.field("content", decode.string, fn(c) { decode.success(User(c)) })
    "assistant" ->
      decode.field("content", decode.string, fn(c) {
        decode.success(Assistant(c))
      })
    "assistant_calls" -> {
      let call = {
        use name <- decode.field("name", decode.string)
        use id <- decode.field("id", decode.string)
        decode.success(#(name, id))
      }
      decode.field("calls", decode.list(call), fn(calls) {
        decode.success(Calls(calls))
      })
    }
    _ -> {
      use id <- decode.field("id", decode.string)
      use status <- decode.field("status", decode.string)
      use content <- decode.field("content", decode.string)
      decode.success(
        ToolResult(id, status, case status {
          "success" -> Some(content)
          _ -> None
        }),
      )
    }
  }
}

fn fixture(name: String) -> Observed {
  let assert Ok(text) = read_file("test/oracle/fixtures/" <> name <> ".json")
  let entry = entry_decoder()
  let observed = {
    use commit <- decode.subfield(["oracle", "commit"], decode.string)
    use transcript <- decode.subfield(
      ["result", "transcript"],
      decode.list(entry),
    )
    use effects <- decode.field("effects", decode.list(decode.string))
    // Fixtures are only valid at the pinned oracle commit.
    let assert "d0aa1f90d31c55d49be2f7b5a24224b5e18145a1" = commit
    decode.success(observed_effects(transcript, effects))
  }
  let assert Ok(observed) = json.parse(text, observed)
  observed
}

/// The paused half of a HITL scenario: the calls under review, the
/// transcript at the pause, and what ran before it.
type Pause {
  Pause(under_review: List(#(String, String)), before: Observed)
}

fn pause_fixture(name: String) -> Pause {
  let assert Ok(text) = read_file("test/oracle/fixtures/" <> name <> ".json")
  let call = {
    use name <- decode.field("name", decode.string)
    use id <- decode.field("id", decode.string)
    decode.success(#(name, id))
  }
  let first_step = {
    use under_review <- decode.subfield(
      ["interrupt", "under_review"],
      decode.list(call),
    )
    use transcript <- decode.subfield(
      ["snapshot", "transcript"],
      decode.list(entry_decoder()),
    )
    use effects <- decode.field("effects", decode.list(decode.string))
    decode.success(Pause(under_review, observed_effects(transcript, effects)))
  }
  let assert Ok([step, ..]) =
    json.parse(text, decode.at(["steps"], decode.list(decode.dynamic)))
  let assert Ok(pause) = decode.run(step, first_step)
  pause
}

fn observed_effects(
  transcript: List(Entry),
  effects: List(String),
) -> Observed {
  Observed(
    transcript:,
    tool_effects: list.filter(effects, string.starts_with(_, "tool:"))
      |> list.sort(string.compare),
    model_calls: list.count(effects, string.starts_with(_, "model:")),
  )
}

/// Fabric's tool results are JSON; a JSON string is compared by its text.
fn plain(content: String) -> String {
  case json.parse(content, decode.string) {
    Ok(text) -> text
    Error(_) -> content
  }
}

fn observe(run: fabric.Run(context), probe: Probe) -> Observed {
  let assert Ok(snapshot) = fabric.snapshot(run)
  let statuses =
    list.map(snapshot.actions, fn(action) {
      #(action.call.id, case action.state {
        run.Succeeded(_) | run.Reconciled(_) -> "success"
        _ -> "error"
      })
    })
  let transcript =
    list.flat_map(snapshot.transcript, fn(message) {
      case message {
        model.UserMessage(text) -> [User(text)]
        model.AssistantMessage(text, []) -> [Assistant(text)]
        model.AssistantMessage(_, calls) -> [
          Calls(list.map(calls, fn(call) { #(call.name, call.id) })),
        ]
        model.ToolResultMessage(id, content) -> {
          let assert Ok(status) = list.key_find(statuses, id)
          [
            ToolResult(id, status, case status {
              "success" -> Some(plain(content))
              _ -> None
            }),
          ]
        }
      }
    })
  observed_effects(transcript, probe.entries(probe))
}

// --- the same scenario rules as test/oracle/capture/capture.exs ----------------

fn oracle_model(probe: Probe, rules: fn(List(String)) -> Reply) -> model.Model {
  model.new(fn(request: model.Request) {
    let seen = scripted.results(request.messages) |> list.map(plain)
    probe.record(probe, "model:tool_msgs=" <> int.to_string(list.length(seen)))
    Ok(rules(seen))
  })
}

fn final(seen: List(String)) -> Reply {
  model.FinalAnswer("final: " <> string.join(seen, "|"), None)
}

fn lookup(probe: Probe) -> tool.Tool(Nil) {
  tool.define(
    "lookup",
    "Weather lookup",
    codec.field("city", codec.string()),
    codec.string(),
  )
  |> tool.bind(
    fn(_, city: String) {
      probe.record(probe, "tool:lookup:" <> city)
      case city {
        "Paris" -> Ok("sunny in Paris")
        other -> Error("unknown city: " <> other)
      }
    },
    tool.Explain,
  )
}

fn pay(probe: Probe) -> tool.Tool(Nil) {
  tool.define(
    "pay",
    "Payment",
    codec.field("to", codec.string()),
    codec.string(),
  )
  |> tool.bind(
    fn(_, to: String) -> Result(String, Nil) {
      probe.record(probe, "tool:pay:" <> to)
      Ok("paid " <> to)
    },
    fn(_) { tool.Explain("failed") },
  )
}

fn step(probe: Probe) -> tool.Tool(Nil) {
  tool.define("step", "One step", codec.field("n", codec.int()), codec.string())
  |> tool.bind(
    fn(_, n: Int) -> Result(String, Nil) {
      probe.record(probe, "tool:step:" <> int.to_string(n))
      Ok("stepped " <> int.to_string(n))
    },
    fn(_) { tool.Explain("failed") },
  )
}

fn run_scenario(
  probe: Probe,
  rules: fn(List(String)) -> Reply,
  tools: List(tool.Tool(Nil)),
  max_turns: Int,
) -> #(fabric.Run(Nil), run.Status) {
  let agent =
    agent.new("agent", oracle_model(probe, rules), tools, policy.always_allow())
    |> agent.with_limits(
      agent.Limits(..agent.default_limits(), max_turns: max_turns),
    )
    |> support.agent
  let assert Ok(run) = fabric.start(store.in_memory(), agent, Nil, "go")
  let assert Ok(status) = fabric.await(run, 5000)
  #(run, status)
}

// --- comparisons ---------------------------------------------------------------

pub fn two_tool_calls_match_beamweaver_test() {
  let probe = probe.new()
  let rules = fn(seen: List(String)) {
    case seen {
      [] ->
        model.ToolRequest(
          "",
          [
            scripted.call("call_a", "lookup", "{\"city\":\"Paris\"}"),
            scripted.call("call_b", "pay", "{\"to\":\"bob\"}"),
          ],
          None,
        )
      _ -> final(seen)
    }
  }
  let #(run, status) =
    run_scenario(probe, rules, [lookup(probe), pay(probe)], 8)
  let assert run.Finished(run.Completed(_)) = status
  observe(run, probe) |> should.equal(fixture("two_tool_calls"))
}

pub fn tool_errors_are_model_visible_like_beamweaver_test() {
  let probe = probe.new()
  let rules = fn(seen: List(String)) {
    case seen {
      [] ->
        model.ToolRequest(
          "",
          [
            scripted.call("call_a", "lookup", "{\"city\":\"Paris\"}"),
            scripted.call("call_b", "lookup", "{\"city\":\"Oslo\"}"),
            scripted.call("call_c", "ghost", "{}"),
          ],
          None,
        )
      _ -> final(seen)
    }
  }
  let #(run, status) = run_scenario(probe, rules, [lookup(probe)], 8)
  let assert run.Finished(run.Completed(_)) = status
  let fabric_side = observe(run, probe)
  let oracle = fixture("tool_error_visible")
  // The final answer embeds tool error texts, whose wording is package
  // specific; everything else must match.
  let without_final = fn(observed: Observed) {
    Observed(
      ..observed,
      transcript: list.filter(observed.transcript, fn(entry) {
        case entry {
          Assistant(_) -> False
          _ -> True
        }
      }),
    )
  }
  without_final(fabric_side) |> should.equal(without_final(oracle))
  let assert Ok(Assistant(_)) = list.last(fabric_side.transcript)
  let assert Ok(Assistant(_)) = list.last(oracle.transcript)
  Nil
}

/// Deliberate divergence. BeamWeaver's run model-call limit is checked
/// before the next model call, so the tool requested by the last allowed
/// reply still runs. Fabric refuses to start a tool whose result could not
/// be sent to the model within the limit.
pub fn model_call_limit_diverges_from_beamweaver_by_design_test() {
  let probe = probe.new()
  let rules = fn(seen: List(String)) {
    let n = list.length(seen) + 1
    model.ToolRequest(
      "",
      [
        scripted.call(
          "call_" <> int.to_string(n),
          "step",
          "{\"n\":" <> int.to_string(n) <> "}",
        ),
      ],
      None,
    )
  }
  let #(run, status) = run_scenario(probe, rules, [step(probe)], 2)
  status |> should.equal(run.Finished(run.BudgetExhausted(run.TurnLimit(2))))
  let fabric_side = observe(run, probe)
  let oracle = fixture("model_call_limit")

  // Same number of model calls, same first round trip, same second request.
  fabric_side.model_calls |> should.equal(oracle.model_calls)
  list.take(fabric_side.transcript, 4)
  |> should.equal(list.take(oracle.transcript, 4))

  // BeamWeaver ran step 2 and answered with a limit message; Fabric kept the
  // second call outstanding and never ran it.
  oracle.tool_effects |> should.equal(["tool:step:1", "tool:step:2"])
  fabric_side.tool_effects |> should.equal(["tool:step:1"])
  list.drop(oracle.transcript, 4)
  |> should.equal([
    ToolResult("call_2", "success", Some("stepped 2")),
    Assistant("Model call limits exceeded: run limit (2/2)"),
  ])
  list.drop(fabric_side.transcript, 4) |> should.equal([])
  let assert Ok(snapshot) = fabric.snapshot(run)
  let assert [_, run.ActionRecord(state: run.NotStarted, ..)] = snapshot.actions
}

// --- approvals -----------------------------------------------------------------

fn pay_needs_review(
  _context: Nil,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  case action.tool {
    "pay" -> Ok(policy.RequireApproval(run.Requirement("review", 1)))
    _ -> Ok(policy.Allow)
  }
}

fn hitl_agent(probe: Probe) -> agent.Agent(Nil) {
  let rules = fn(seen: List(String)) {
    case seen {
      [] ->
        model.ToolRequest(
          "",
          [scripted.call("call_t", "pay", "{\"to\":\"bob\"}")],
          None,
        )
      _ -> final(seen)
    }
  }
  agent.new("agent", oracle_model(probe, rules), [pay(probe)], pay_needs_review)
  |> support.agent
}

/// Runs until the pause and observes it as a HITL fixture does.
fn paused(run: fabric.Run(Nil), probe: Probe) -> #(Pause, run.PendingApproval) {
  let assert Ok(run.Suspended([pending], [])) = fabric.await(run, 5000)
  let observed = observe(run, probe)
  // BeamWeaver's paused snapshot has no tool messages yet; neither has
  // Fabric's transcript (the pending call is not answered).
  #(Pause([#(pending.tool, pending.reference.id.call_id)], observed), pending)
}

/// A1: approve runs the reviewed call once and the model answers.
pub fn an_approved_call_matches_beamweaver_test() {
  let probe = probe.new()
  let assert Ok(run) =
    fabric.start(store.in_memory(), hitl_agent(probe), Nil, "go")
  let #(pause, pending) = paused(run, probe)
  pause |> should.equal(pause_fixture("hitl_approve"))
  let assert Ok(_) = fabric.approve(run, pending.reference, None, Nil)
  let assert Ok(run.Finished(run.Completed(_))) = fabric.await(run, 5000)
  observe(run, probe) |> should.equal(fixture("hitl_approve"))
}

/// A3: reject answers the call with an error result and the tool never
/// runs. The rejection's wording is package specific (BeamWeaver sends the
/// reviewer's message as the tool content; Fabric sends
/// `{"error":"rejected","detail":...}`), so the final answer, which embeds
/// it, is not compared.
pub fn a_rejected_call_matches_beamweaver_test() {
  let probe = probe.new()
  let assert Ok(run) =
    fabric.start(store.in_memory(), hitl_agent(probe), Nil, "go")
  let #(pause, pending) = paused(run, probe)
  pause |> should.equal(pause_fixture("hitl_reject"))
  let assert Ok(_) =
    fabric.reject(
      run,
      pending.reference,
      reason: "payment declined by reviewer",
      reviewer: None,
    )
  let assert Ok(run.Finished(run.Completed(_))) = fabric.await(run, 5000)
  let without_final = fn(observed: Observed) {
    Observed(
      ..observed,
      transcript: list.filter(observed.transcript, fn(entry) {
        case entry {
          Assistant(_) -> False
          _ -> True
        }
      }),
    )
  }
  let oracle = fixture("hitl_reject")
  without_final(observe(run, probe)) |> should.equal(without_final(oracle))
  oracle.tool_effects |> should.equal([])
}

/// A13: the pause survives the loss of every process (BeamWeaver: a VM
/// exit with an SQLite checkpointer; Fabric: every process killed over a
/// directory store) and the approved call runs once afterwards.
pub fn an_approval_after_a_restart_matches_beamweaver_test() {
  let dir = restart.temp_dir()
  let probe = probe.new()
  let #(owner, #(old, run)) =
    restart.owned(fn() {
      let assert Ok(store) = store.directory(dir)
      let assert Ok(run) = fabric.start(store, hitl_agent(probe), Nil, "go")
      #(store, run)
    })
  let #(pause, _) = paused(run, probe)
  pause |> should.equal(pause_fixture("hitl_cold_restart"))
  restart.kill(owner)
  restart.gone(store.pid(old))

  let assert Ok(store) = store.directory(dir)
  let assert Ok(run) =
    fabric.recover(store, hitl_agent(probe), Nil, fabric.id(run))
  let assert Ok([pending]) = fabric.pending(run)
  let assert Ok(_) = fabric.approve(run, pending.reference, None, Nil)
  let assert Ok(run.Finished(run.Completed(_))) = fabric.await(run, 5000)
  observe(run, probe) |> should.equal(fixture("hitl_cold_restart"))
  restart.remove_dir(dir)
}

// --- sub-agent gate ------------------------------------------------------------

/// The same rules as the capture's `:subagent` script: parent and child
/// share them, told apart by their first user message.
fn delegation_model(probe: Probe) -> model.Model {
  model.new(fn(request: model.Request) {
    let who = case request.messages {
      [model.UserMessage(text), ..] -> text
      _ -> ""
    }
    let seen = scripted.results(request.messages) |> list.map(plain)
    probe.record(
      probe,
      "model:" <> who <> ":tool_msgs=" <> int.to_string(list.length(seen)),
    )
    Ok(case who, seen {
      "go", [] ->
        model.ToolRequest(
          "",
          [
            scripted.call(
              "call_task",
              "task",
              "{\"subagent_type\":\"researcher\",\"description\":\"Paris\"}",
            ),
          ],
          None,
        )
      "Paris", [] ->
        model.ToolRequest(
          "",
          [scripted.call("call_c", "lookup", "{\"city\":\"Paris\"}")],
          None,
        )
      _, seen -> final(seen)
    })
  })
}

pub type Task {
  Task(subagent_type: String, description: String)
}

/// BeamWeaver's `task` tool as a Fabric delegation: its description is the
/// child's prompt and the child's final text its result. Starting the
/// child needs a review, as `interrupt_on: %{"task" => true}` does.
fn delegation_agent(probe: Probe) -> agent.Agent(Nil) {
  let assert Ok(task_codec) =
    codec.record2(
      codec.required("subagent_type", codec.string()),
      codec.required("description", codec.string()),
      Task,
      fn(task) { task.subagent_type },
      fn(task) { task.description },
    )
  let researcher =
    agent.new(
      "researcher",
      delegation_model(probe),
      [lookup(probe)],
      policy.always_allow(),
    )
    |> support.agent
  agent.new("agent", delegation_model(probe), [], fn(_, action: policy.Action) {
    case action.target {
      policy.StartAgent(..) ->
        Ok(policy.RequireApproval(run.Requirement("review", 1)))
      policy.InvokeTool -> Ok(policy.Allow)
    }
  })
  |> agent.with_sub_agent(
    tool.define("task", "Start a sub-agent", task_codec, codec.string()),
    to: researcher,
    prompt: fn(task: Task) { task.description },
    result: fn(outcome) {
      case outcome {
        run.Completed(text) -> Ok(text)
        _ -> Error(tool.Explain("the sub-agent did not complete"))
      }
    },
  )
  |> support.agent
}

/// Approving the start of a sub-agent runs the child once (its model and
/// its tool) and its answer is the delegation's result; nothing of the
/// child exists at the pause.
pub fn an_approved_sub_agent_start_matches_beamweaver_test() {
  let probe = probe.new()
  let assert Ok(run) =
    fabric.start(store.in_memory(), delegation_agent(probe), Nil, "go")
  let #(pause, pending) = paused(run, probe)
  pause |> should.equal(pause_fixture("subagent_gate_approve"))
  let assert Ok(_) = fabric.approve(run, pending.reference, None, Nil)
  let assert Ok(run.Finished(run.Completed(_))) = fabric.await(run, 5000)
  observe(run, probe) |> should.equal(fixture("subagent_gate_approve"))
}

/// Rejecting the start answers the delegation with an error and the child
/// never runs. The rejection's wording is package specific, so the final
/// answer, which embeds it, is not compared.
pub fn a_rejected_sub_agent_start_matches_beamweaver_test() {
  let probe = probe.new()
  let assert Ok(run) =
    fabric.start(store.in_memory(), delegation_agent(probe), Nil, "go")
  let #(pause, pending) = paused(run, probe)
  pause |> should.equal(pause_fixture("subagent_gate_reject"))
  let assert Ok(_) =
    fabric.reject(
      run,
      pending.reference,
      reason: "no sub-agent today",
      reviewer: None,
    )
  let assert Ok(run.Finished(run.Completed(_))) = fabric.await(run, 5000)
  let without_final = fn(observed: Observed) {
    Observed(
      ..observed,
      transcript: list.filter(observed.transcript, fn(entry) {
        case entry {
          Assistant(_) -> False
          _ -> True
        }
      }),
    )
  }
  let oracle = fixture("subagent_gate_reject")
  without_final(observe(run, probe)) |> should.equal(without_final(oracle))
  oracle.tool_effects |> should.equal([])
  oracle.model_calls |> should.equal(2)
}

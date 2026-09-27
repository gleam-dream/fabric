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
import fabric/support/probe.{type Probe}
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

fn fixture(name: String) -> Observed {
  let assert Ok(text) = read_file("test/oracle/fixtures/" <> name <> ".json")
  let entry = {
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
  let observed = {
    use commit <- decode.subfield(["oracle", "commit"], decode.string)
    use transcript <- decode.subfield(
      ["result", "transcript"],
      decode.list(entry),
    )
    use effects <- decode.field("effects", decode.list(decode.string))
    // Fixtures are only valid at the pinned oracle commit.
    let assert "d0aa1f90d31c55d49be2f7b5a24224b5e18145a1" = commit
    decode.success(Observed(
      transcript:,
      tool_effects: list.filter(effects, string.starts_with(_, "tool:"))
        |> list.sort(string.compare),
      model_calls: list.count(effects, string.starts_with(_, "model:")),
    ))
  }
  let assert Ok(observed) = json.parse(text, observed)
  observed
}

/// Fabric's tool results are JSON; a JSON string is compared by its text.
fn plain(content: String) -> String {
  case json.parse(content, decode.string) {
    Ok(text) -> text
    Error(_) -> content
  }
}

fn observe(run: fabric.Run, probe: Probe) -> Observed {
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
  let effects = probe.entries(probe)
  Observed(
    transcript:,
    tool_effects: list.filter(effects, string.starts_with(_, "tool:"))
      |> list.sort(string.compare),
    model_calls: list.count(effects, string.starts_with(_, "model:")),
  )
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
  |> tool.bind_reporting(
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
  |> tool.bind(fn(_, to: String) -> Result(String, Nil) {
    probe.record(probe, "tool:pay:" <> to)
    Ok("paid " <> to)
  })
}

fn step(probe: Probe) -> tool.Tool(Nil) {
  tool.define("step", "One step", codec.field("n", codec.int()), codec.string())
  |> tool.bind(fn(_, n: Int) -> Result(String, Nil) {
    probe.record(probe, "tool:step:" <> int.to_string(n))
    Ok("stepped " <> int.to_string(n))
  })
}

fn run_scenario(
  probe: Probe,
  rules: fn(List(String)) -> Reply,
  tools: List(tool.Tool(Nil)),
  max_turns: Int,
) -> #(fabric.Run, run.Status) {
  let agent =
    agent.new(oracle_model(probe, rules), tools, policy.always_allow())
    |> agent.with_max_turns(max_turns)
  let assert Ok(run) = fabric.start(agent, Nil, "go")
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
  let assert [_, run.ActionRecord(_, _, run.NotStarted)] = snapshot.actions
}

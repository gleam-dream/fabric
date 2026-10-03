//// Differential and counterexample checks for the evaluation-only graph recipe.

import fabric
import fabric/agent
import fabric/graph
import fabric/internal/controller
import fabric/internal/record
import fabric/model
import fabric/policy
import fabric/run
import fabric/support
import fabric/support/agent_recipe as recipe
import fabric/support/apps
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import fabric/tool
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn observed(snapshot: run.Snapshot) {
  #(
    snapshot.status,
    snapshot.turns_used,
    snapshot.usage,
    snapshot.transcript,
    snapshot.actions,
  )
}

fn ordinary(worker) {
  let assert Ok(handle) =
    fabric.start(
      support.store(),
      worker,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(_) = fabric.await(handle, within: duration.milliseconds(5000))
  let assert Ok(snapshot) = fabric.snapshot(handle)
  snapshot
}

fn candidate(worker) {
  let assert Ok(handle) =
    graph.start(
      recipe.runtime(support.store(), worker, fn() { Nil }),
      support.id("recipe"),
      recipe.initial(worker, Nil, "go"),
    )
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Completed(raw) = done.status
  let assert Ok(state) = record.decode(raw)
  #(controller.snapshot(state), done)
}

pub fn model_turns_preserve_typed_tool_results_provider_data_and_usage_test() {
  let assistant =
    model.AssistantTurn(
      "checking",
      [
        model.tool_call(
          id: "a",
          name: "lookup_weather",
          arguments_json: "{\"city\":\"Paris\"}",
        )
          |> model.with_provider_replay(
            id: Some("provider-a"),
            state: Some("signature-a"),
          ),
        model.tool_call(
          id: "b",
          name: "lookup_weather",
          arguments_json: "{\"city\":\"Oslo\"}",
        )
          |> model.with_provider_replay(
            id: Some("provider-b"),
            state: Some("signature-b"),
          ),
        scripted.call("c", "missing", "{}"),
      ],
      Some(model.ProviderData("test.provider.v1", "opaque replay data")),
    )
  let model =
    model.new(fn(request) {
      request.system |> should.equal(Some("system"))
      list.map(request.tools, fn(tool) { tool.name })
      |> should.equal(["lookup_weather"])
      case scripted.results(request.messages) {
        [] -> Ok(model.ToolRequest(assistant, Some(model.Usage(10, 5))))
        results -> {
          let assert [_, model.AssistantMessage(restored), ..] =
            request.messages
          restored |> should.equal(assistant)
          list.length(results) |> should.equal(3)
          Ok(model.FinalAnswer("done", Some(model.Usage(20, 5))))
        }
      }
    })
  let worker =
    agent.new("metadata", model, [apps.weather_tool()], policy.always_allow())
    |> agent.with_system_prompt("system")
    |> support.agent
  let baseline = ordinary(worker)
  let #(snapshot, done) = candidate(worker)
  observed(snapshot) |> should.equal(observed(baseline))
  list.map(done.receipts, fn(receipt) { receipt.node })
  |> should.equal(["model", "batch", "model"])
  let assert [first, _, _] = done.receipts
  let assert Ok(raw) = codec.decode_json(codec.string(), first.output_json)
  let assert Ok(saved) = record.decode(raw)
  let assert [_, model.AssistantMessage(restored)] = saved.transcript
  restored |> should.equal(assistant)
}

pub fn final_outcomes_and_turn_token_limits_match_on_supported_paths_test() {
  let request =
    model.ToolRequest(
      model.AssistantTurn(
        "",
        [scripted.call("a", "lookup_weather", "{\"city\":\"Paris\"}")],
        None,
      ),
      Some(model.Usage(4, 2)),
    )
  [
    #(model.Refusal("cannot answer", Some(model.Usage(2, 1))), 4, None),
    #(model.Truncated("partial", None), 4, None),
    #(request, 1, None),
    #(request, 4, Some(6)),
    #(
      model.ToolRequest(
        model.AssistantTurn(
          "",
          [scripted.call("a", "lookup_weather", "{\"city\":\"Paris\"}")],
          None,
        ),
        None,
      ),
      4,
      Some(10),
    ),
  ]
  |> list.each(fn(example) {
    let worker =
      agent.new(
        "outcomes",
        scripted.model(fn(_) { example.0 }),
        [apps.weather_tool()],
        policy.always_allow(),
      )
      |> agent.with_max_turns(example.1)
      |> fn(spec) {
        case example.2 {
          Some(tokens) -> agent.with_token_budget(spec, tokens)
          None -> spec
        }
      }
      |> support.agent
    let baseline = ordinary(worker)
    let #(snapshot, _) = candidate(worker)
    observed(snapshot) |> should.equal(observed(baseline))
  })
}

pub fn an_agent_approval_cannot_be_replaced_by_approval_of_the_batch_test() {
  let calls = probe.new()
  let payment =
    tool.define("pay", "Pay", codec.string(), codec.string())
    |> tool.bind(
      fn(_context, _call, input) -> Result(String, Nil) {
        probe.record(calls, "paid")
        Ok(input)
      },
      fn(_) { tool.Explain("failed") },
    )
  let worker =
    agent.new(
      "approval",
      scripted.plan([scripted.call("a", "pay", "\"bob\"")]),
      [payment],
      fn(changed, _) {
        case changed {
          False -> Ok(policy.RequireApproval(run.Requirement("payment", 1)))
          True -> Ok(policy.Deny("context changed"))
        }
      },
    )
    |> support.agent
  let assert Ok(ordinary) =
    fabric.start(
      support.store(),
      worker,
      id: run.new_id(),
      context: False,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(ordinary, within: duration.milliseconds(5000))
  let assert Ok(candidate) =
    graph.start(
      recipe.runtime(support.store(), worker, fn() { False }),
      support.id("approval-probe"),
      recipe.initial(worker, False, "go"),
    )
  let assert Ok(done) =
    graph.await(candidate, within: duration.milliseconds(5000))
  let assert graph.Failed(graph.OperationFailed(reason)) = done.status
  string.contains(reason, "per-action approval") |> should.be_true
  let assert Ok(inner) = record.decode(done.value)
  let assert run.Suspended([_], []) = controller.status(inner)
  // The existing agent API can recheck the action with fresh caller context.
  fabric.approve(
    ordinary,
    pending.reference,
    support.reviewer("reviewer"),
    True,
  )
  |> should.be_ok
  let assert Ok(run.Finished(run.Completed(_))) =
    fabric.await(ordinary, within: duration.milliseconds(5000))
  probe.entries(calls) |> should.equal([])
}

fn interrupted_worker(calls) {
  agent.new(
    "interrupted",
    scripted.plan([scripted.slow("a", "first"), scripted.slow("b", "second")]),
    [scripted.gated_tool(calls)],
    policy.always_allow(),
  )
  |> agent.with_max_concurrency(1)
  |> support.agent
}

pub fn a_batch_receipt_loses_the_individual_success_that_the_agent_retains_test() {
  let ordinary_dir = restart.temp_dir()
  let ordinary_calls = probe.new()
  let worker = interrupted_worker(ordinary_calls)
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(ordinary_dir)
      let assert Ok(handle) =
        fabric.start(
          runs,
          worker,
          id: run.new_id(),
          context: Nil,
          prompt: "go",
          correlation: None,
        )
      #(runs, handle)
    })
  probe.release(probe.arrival(ordinary_calls))
  probe.arrival(ordinary_calls).name |> should.equal("second")
  restart.crash(owner, runs)
  let assert Ok(recovered) =
    fabric.recover(
      support.directory(ordinary_dir),
      worker,
      Nil,
      fabric.id(handle),
    )
  let assert Ok(run.Suspended([], [_])) =
    fabric.await(recovered, within: duration.milliseconds(5000))
  let assert Ok(saved) = fabric.snapshot(recovered)
  let assert [first, second] = saved.actions
  first.state |> should.equal(run.Succeeded("\"first\""))
  let assert run.Uncertain(_) = second.state

  let graph_dir = restart.temp_dir()
  let graph_calls = probe.new()
  let worker = interrupted_worker(graph_calls)
  let #(owner, runs) =
    restart.owned(fn() {
      let runs = support.directory(graph_dir)
      let assert Ok(_) =
        graph.start(
          recipe.runtime(runs, worker, fn() { Nil }),
          support.id("batch-loss"),
          recipe.initial(worker, Nil, "go"),
        )
      runs
    })
  probe.release(probe.arrival(graph_calls))
  probe.arrival(graph_calls).name |> should.equal("second")
  restart.crash(owner, runs)
  let runs = support.directory(graph_dir)
  let handle =
    graph.attach(
      recipe.runtime(runs, worker, fn() { Nil }),
      support.id("batch-loss"),
    )
  graph.recover(handle) |> should.be_ok
  let assert Ok(saved) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Blocked(_, graph.EffectUncertain(_)) = saved.status
  let assert Ok(inner) = record.decode(saved.value)
  let assert controller.Acting(_, [first, second]) = inner.phase
  // These are only the last committed inner states, not permission to replay:
  // the outer graph correctly blocks the entire interrupted batch.
  first.state |> should.equal(run.Queued)
  second.state |> should.equal(run.Queued)
  list.length(saved.receipts) |> should.equal(1)
  probe.count(graph_calls, "start:first") |> should.equal(1)
  probe.count(graph_calls, "end:first") |> should.equal(1)
  probe.count(graph_calls, "start:second") |> should.equal(1)
  restart.remove_dir(ordinary_dir)
  restart.remove_dir(graph_dir)
}

pub fn canceling_a_batch_exposes_only_scope_uncertainty_test() {
  let calls = probe.new()
  let worker = interrupted_worker(calls)
  let assert Ok(handle) =
    graph.start(
      recipe.runtime(support.store(), worker, fn() { Nil }),
      support.id("cancel-batch"),
      recipe.initial(worker, Nil, "go"),
    )
  probe.release(probe.arrival(calls))
  probe.arrival(calls).name |> should.equal("second")
  graph.cancel(handle) |> should.be_ok
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Cancelled(graph.Unresolved(_, _)) = done.status
  let assert Ok(inner) = record.decode(done.value)
  let assert controller.Acting(_, [first, second]) = inner.phase
  first.state |> should.equal(run.Queued)
  second.state |> should.equal(run.Queued)
  list.length(done.receipts) |> should.equal(1)
  probe.count(calls, "end:second") |> should.equal(0)
}

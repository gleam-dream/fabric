//// Correlation. A run has one `sinal/correlation.Correlation`, chosen where
//// the run starts or derived from its id. The run's model requests and tool
//// calls carry it, so one id joins them to the run's telemetry events.

import fabric
import fabric/agent
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/tool
import gleam/erlang/process
import gleam/option.{type Option}
import gleam/time/duration
import json/blueprint/codec
import sinal/correlation.{type Correlation}
import usage/support

/// The correlations one run showed to its model and to its tool.
pub type Seen {
  Seen(in_request: Correlation, in_tool_call: Correlation)
}

/// Starts a run with the correlation the application chose (for example the
/// id of the HTTP request that caused it) and reads it back where the run
/// used it. `None` derives the correlation from the run's id.
pub fn seen_by_the_run(chosen: Option(Correlation)) -> Seen {
  let requests = process.new_subject()
  let calls = process.new_subject()
  let note =
    tool.define(
      "note",
      "Notes a call.",
      support.one_field("text", codec.string()),
      codec.string(),
    )
    |> tool.bind(
      fn(_context, call: tool.Call, text: String) -> Result(String, Nil) {
        process.send(calls, call.correlation)
        Ok(text)
      },
      fn(_) { tool.Explain("failed") },
    )
  let reply =
    support.call_once_then("note", "{\"text\":\"hi\"}", fn(_) { "noted" })
  let reporting =
    model.new(fn(request: model.Request) {
      process.send(requests, request.correlation)
      reply(request)
    })
  let assert Ok(noting) =
    agent.new("noting", reporting, [note], policy.always_allow())
    |> agent.build
  let runs = store.in_memory(process.new_name("usage-correlation"))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(handle) =
    fabric.start(
      runs,
      noting,
      id: run.new_id(),
      context: Nil,
      prompt: "note hi",
      correlation: chosen,
    )
  let assert Ok(run.Finished(run.Completed("noted"))) =
    fabric.await(handle, within: duration.seconds(5))
  let assert Ok(in_request) = process.receive(requests, 1000)
  let assert Ok(in_tool_call) = process.receive(calls, 1000)
  let assert Ok(Nil) = store.stop(runs)
  Seen(in_request:, in_tool_call:)
}

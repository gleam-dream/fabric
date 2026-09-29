//// A small agent for runs on the PostgreSQL store: its model calls the
//// tool `work` once with a number and then answers with the tool's
//// result. The tool's body announces itself to the test and waits until
//// the test releases it; its policy asks for an approval above 100.

import fabric/agent.{type Agent}
import fabric/model.{FinalAnswer, ToolRequest, ToolResultMessage, Usage}
import fabric/policy
import fabric/run
import fabric/tool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import json/blueprint/codec

/// A tool body that started: its process and how to let it finish.
pub type Arrival {
  Arrival(amount: Int, body: Pid, release: Subject(Nil))
}

/// Where the tool bodies of a test announce themselves. Must be made by
/// the test process, which receives the arrivals.
pub type Gate {
  Gate(arrivals: Subject(Arrival))
}

pub fn gate() -> Gate {
  Gate(process.new_subject())
}

/// The next tool body to start, within 5 seconds.
pub fn arrival(gate: Gate) -> Arrival {
  let assert Ok(arrival) = process.receive(gate.arrivals, 5000)
  arrival
}

/// Whether another body started within `milliseconds`.
pub fn another(gate: Gate, milliseconds: Int) -> Bool {
  process.receive(gate.arrivals, milliseconds) |> result.is_ok
}

pub fn release(arrival: Arrival) -> Nil {
  process.send(arrival.release, Nil)
}

fn definition() -> tool.Definition(Int, Int) {
  tool.define(
    "work",
    "Works on an amount.",
    codec.field("amount", codec.int()),
    codec.field("done", codec.int()),
  )
}

/// The agent whose model asks for `work` with `amount`.
pub fn agent(gate: Gate, amount: Int) -> Agent(Nil) {
  let work =
    tool.bind(
      definition(),
      fn(_context, amount: Int) -> Result(Int, Nil) {
        let release = process.new_subject()
        process.send(gate.arrivals, Arrival(amount, process.self(), release))
        process.receive_forever(release)
        Ok(amount)
      },
      fn(_) { tool.Explain("failed") },
    )
  let model =
    model.new(fn(request: model.Request) {
      let results =
        list.filter_map(request.messages, fn(message) {
          case message {
            ToolResultMessage(_, content) -> Ok(content)
            _ -> Error(Nil)
          }
        })
      case results {
        [] ->
          Ok(ToolRequest(
            model.AssistantTurn(
              "",
              [
                model.ToolCall(
                  "c1",
                  "work",
                  "{\"amount\":" <> int.to_string(amount) <> "}",
                  None,
                  None,
                ),
              ],
              None,
            ),
            Some(Usage(10, 5)),
          ))
        [result, ..] -> Ok(FinalAnswer("done: " <> result, Some(Usage(20, 5))))
      }
    })
  let policy = fn(_context: Nil, action: policy.Action) {
    use input <- result.try(tool.input(definition(), action))
    case input {
      Some(amount) if amount > 100 ->
        Ok(policy.RequireApproval(run.Requirement("reviewer", 1)))
      _ -> Ok(policy.Allow)
    }
  }
  let assert Ok(agent) =
    agent.new("worker", model, [work], policy) |> agent.build
  agent
}

/// Waits until `pid` has exited, within `milliseconds`.
pub fn gone(pid: Pid, milliseconds: Int) -> Bool {
  let monitor = process.monitor(pid)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(milliseconds)
  |> result.is_ok
}

/// Runs `body` in a new process that then stays alive until killed:
/// everything `body` starts linked (a pool, a store and its runners)
/// belongs to it, as to a node.
pub fn owned(body: fn() -> a) -> #(Pid, a) {
  let reply = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      process.send(reply, body())
      let hold: Subject(Nil) = process.new_subject()
      process.receive_forever(hold)
    })
  #(pid, process.receive_forever(reply))
}

/// Kills `pid`, as a node's VM would die, and waits until it is gone.
pub fn kill(pid: Pid) -> Nil {
  let monitor = process.monitor(pid)
  process.kill(pid)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive_forever
  Nil
}

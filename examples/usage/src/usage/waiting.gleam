//// Waiting for a run and for its caller. `fabric.await` blocks on the run;
//// `fabric.await_with` also waits on the caller's own messages, and
//// `fabric.cancel_when_down` ties a run to the process that asked for it.

import fabric
import fabric/agent
import fabric/policy
import fabric/run
import fabric/store
import gleam/erlang/process
import gleam/option.{None}
import gleam/time/duration
import usage/support

type Started {
  Started(runs: store.Store, handle: fabric.Run(Nil, String))
}

/// Starts a run whose tool is blocked, once the tool body is running.
fn start_blocked(name: String) -> Started {
  let gate = support.new_gate()
  let assert Ok(desk) =
    agent.new(
      "desk",
      support.calling_once("wait", "{\"text\":\"x\"}", fn(_) { "done" }),
      [support.waiting_tool(gate)],
      policy.always_allow(),
    )
    |> agent.build
  let runs = store.in_memory(process.new_name(name))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(Nil) = process.receive(gate.arrived, 5000)
  Started(runs:, handle:)
}

/// A handler waits for the run and for its caller's signal in one receive.
/// When the signal arrives first the run goes on until the handler decides:
/// here it cancels.
pub fn the_caller_gives_up() -> run.Status(String) {
  let Started(runs:, handle:) = start_blocked("usage-await-with")
  let caller = process.new_subject()
  let signal = process.new_selector() |> process.select(caller)
  process.send(caller, "caller went away")
  let assert Ok(fabric.Interrupted("caller went away")) =
    fabric.await_with(handle, within: duration.seconds(5), or: signal)
  let assert Ok(_) = fabric.cancel(handle)
  let assert Ok(status) = fabric.await(handle, within: duration.seconds(5))
  let assert Ok(Nil) = store.stop(runs)
  status
}

/// A run tied to a process is cancelled when that process exits.
pub fn the_owner_exits() -> run.Status(String) {
  let Started(runs:, handle:) = start_blocked("usage-owner")
  let owner = process.spawn_unlinked(fn() { process.sleep_forever() })
  fabric.cancel_when_down(handle, owner:)
  process.kill(owner)
  let assert Ok(status) = fabric.await(handle, within: duration.seconds(5))
  let assert Ok(Nil) = store.stop(runs)
  status
}

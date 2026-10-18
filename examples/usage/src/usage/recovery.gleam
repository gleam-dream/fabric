//// Automatic recovery wiring. Nodes that share one database coordinate
//// through per-run leases; a sweeper recovers runs whose node died. It
//// runs under the application's supervisor in place of `store.supervised`,
//// and only a leased store has leases.

import fabric
import fabric/agent
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/conformance
import fabric/sweeper
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/string
import gleam/time/duration
import usage/support

fn desk() -> agent.Agent(Nil, String) {
  let assert Ok(desk) =
    agent.new("desk", support.answering("done"), [], policy.always_allow())
    |> agent.build
  desk
}

/// A leased store (an in-memory backend here; production uses
/// `fabric_postgres`) with its sweeper under a supervisor. A run started
/// through the store completes while the sweeper watches.
pub fn supervised_sweeper() -> run.Status(String) {
  let backend = conformance.leased_memory().backend
  let assert Ok(runs) =
    store.leased(
      process.new_name("usage-leased"),
      node: "node-a",
      lease: duration.seconds(30),
      backend:,
    )
  let assert Ok(subtree) =
    sweeper.supervised(
      runs,
      [sweeper.agent(desk(), context: fn(_run) { Nil })],
      every: duration.seconds(1),
    )
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(subtree)
    |> static_supervisor.start
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk(),
      id: run.new_id(),
      context: Nil,
      prompt: "go",
      correlation: None,
    )
  let assert Ok(status) = fabric.await(handle, within: duration.seconds(5))
  status
}

/// A store without leases has nothing for a sweeper to recover through.
pub fn needs_a_leased_store() -> String {
  let runs = store.in_memory(process.new_name("usage-unleased"))
  let assert Ok(Nil) = store.start(runs)
  let assert Error(errors) =
    sweeper.supervised(
      runs,
      [sweeper.agent(desk(), context: fn(_run) { Nil })],
      every: duration.seconds(1),
    )
  let assert Ok(Nil) = store.stop(runs)
  string.join(list.map(errors, sweeper.describe_error), "; ")
}

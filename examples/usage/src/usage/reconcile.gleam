//// An effect of unknown status. A tool that cannot tell whether its effect
//// happened reports `tool.Uncertain`; the run waits, and the effect is never
//// retried. After the run has ended, `fabric.reconcile_stored` records what
//// actually happened without resuming the run or needing its agent.

import fabric
import fabric/agent
import fabric/policy
import fabric/run
import fabric/store
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/time/duration
import json/blueprint/codec
import usage/support

fn transfer() -> tool.Tool(Nil) {
  tool.define(
    "transfer",
    "Moves money.",
    support.one_field("to", codec.string()),
    codec.string(),
  )
  |> tool.bind(
    fn(_context, _call, _to: String) -> Result(String, String) {
      Error("the gateway timed out after sending")
    },
    fn(evidence) { tool.Uncertain(evidence) },
  )
}

/// How many actions still need reconciliation at each step: while the run
/// waits for it, after it was cancelled, and after the evidence was stored.
pub fn counts() -> #(Int, Int, Int) {
  let assert Ok(desk) =
    agent.new(
      "desk",
      support.calling_once("transfer", "{\"to\":\"ada\"}", fn(_) { "done" }),
      [transfer()],
      policy.always_allow(),
    )
    |> agent.build
  let runs = store.in_memory(process.new_name("usage-reconcile"))
  let assert Ok(Nil) = store.start(runs)
  let assert Ok(handle) =
    fabric.start(
      runs,
      desk,
      id: run.new_id(),
      context: Nil,
      prompt: "pay ada",
      correlation: None,
    )
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(handle, within: duration.seconds(5))
  let waiting = needing_reconciliation(handle)
  let assert Ok(_) = fabric.cancel(handle)
  let assert Ok(run.Finished(run.Cancelled)) =
    fabric.await(handle, within: duration.seconds(5))
  let cancelled = needing_reconciliation(handle)
  let assert Ok(_) =
    fabric.reconcile_stored(runs, uncertain.reference, "refunded: no transfer")
  let settled = needing_reconciliation(handle)
  let assert Ok(Nil) = store.stop(runs)
  #(waiting, cancelled, settled)
}

fn needing_reconciliation(handle: fabric.Run(Nil, String)) -> Int {
  let assert Ok(snapshot) = fabric.snapshot(handle)
  snapshot.actions
  |> list.count(fn(action) {
    run.action_state_kind(action.state) == run.NeedsReconciliation
  })
}

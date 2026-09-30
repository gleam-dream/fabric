//// Agent-family observation for graph attachments. Terminal replies here are
//// raw text; the deployed typed adapter encodes them before graph acceptance.

import fabric/graph/child
import fabric/internal/controller
import fabric/internal/family
import fabric/internal/runner
import fabric/run
import fabric/store
import gleam/option.{Some}
import gleam/result
import gleam/string

pub fn check(
  state: controller.State,
  parent: child.Parent,
) -> Result(Nil, String) {
  case
    state.parent == Some(child.attachment(parent))
    && state.run == child.reserved_id(parent.run, parent.activation)
  {
    True -> Ok(Nil)
    False -> Error("agent belongs to a different parent activation")
  }
}

pub fn progress(
  runs: store.Store,
  parent: child.Parent,
  id: String,
) -> Result(child.Progress, String) {
  case family.load_settled(runs, id) {
    Error(runner.NotFound) -> Ok(child.Working)
    Error(error) -> Error(string.inspect(error))
    Ok(node) -> progress_from_node(node, parent)
  }
}

fn progress_from_node(
  node: family.Node,
  parent: child.Parent,
) -> Result(child.Progress, String) {
  use _ <- result.try(check(node.state, parent))
  case controller.child_result(node.state) {
    Ok(controller.ChildFinished(run.Cancelled, uncertain)) ->
      Ok(child.Cancelled(uncertain))
    Ok(controller.ChildFinished(outcome, True)) ->
      Ok(child.FinishedUncertain(string.inspect(outcome)))
    Ok(controller.ChildFinished(run.Completed(text), False)) ->
      Ok(child.Succeeded(text))
    Ok(controller.ChildFinished(outcome, False)) ->
      Ok(child.Failed(string.inspect(outcome)))
    Ok(controller.ChildMissing) -> Ok(child.Cancelled(False))
    _ ->
      Ok(case family.status(node) {
        run.Suspended([], []) -> child.Working
        run.Suspended(approvals, uncertain) ->
          child.AgentInput(approvals, uncertain)
        _ -> child.Working
      })
  }
}

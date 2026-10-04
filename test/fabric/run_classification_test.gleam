//// `run.host_failure_kind`, `describe_host_failure`, `action_state_kind`
//// and `describe_action_state`: every variant has a kind and one line.

import fabric/model
import fabric/run
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import gleeunit/should

fn id() -> run.ActionId {
  run.ActionId(1, "c1")
}

pub fn every_host_failure_has_a_kind_and_a_line_test() {
  [
    #(
      run.PolicyFailed(id(), "boom"),
      run.PolicyFault,
      "the policy failed: boom",
    ),
    #(
      run.OutputEncodingFailed(id(), "bad"),
      run.ToolFault,
      "a tool's result could not be recorded: bad",
    ),
    #(
      run.ToolChanged(id(), "gone"),
      run.ToolFault,
      "a tool changed after its call was admitted: gone",
    ),
    #(
      run.ModelFailed(model.error(model.Rejected, "no key")),
      run.ModelFault,
      "the model failed: ",
    ),
    #(
      run.ModelProtocolViolation("two answers"),
      run.ModelFault,
      "the model broke the protocol: two answers",
    ),
  ]
  |> list.each(fn(case_) {
    let #(failure, kind, line) = case_
    run.host_failure_kind(failure) |> should.equal(kind)
    string.starts_with(run.describe_host_failure(failure), line)
    |> should.be_true
    run.describe_outcome(run.Failed(failure))
    |> should.equal(run.describe_host_failure(failure))
  })
}

pub fn every_action_state_has_a_kind_test() {
  let requirement = run.Requirement("treasurer", 2)
  [
    #(run.Queued, run.Active),
    #(run.Running, run.Active),
    #(run.Delegated, run.Active),
    #(run.AwaitingApproval(requirement, 3, None), run.NeedsApproval),
    #(run.Uncertain("lost"), run.NeedsReconciliation),
    #(run.Succeeded("ok"), run.Ended),
    #(run.ToolFailed("no"), run.Ended),
    #(run.Denied("policy"), run.Ended),
    #(run.Rejected("reviewer"), run.Ended),
    #(run.InvalidArguments("bad"), run.Ended),
    #(run.UnknownTool, run.Ended),
    #(run.Reconciled("done"), run.Ended),
    #(run.ChildSettled(run.Cancelled), run.Ended),
    #(run.NotStarted, run.Ended),
    #(run.LimitReached(run.ChildLimit(3)), run.Ended),
    #(run.Faulted("encoding"), run.Ended),
  ]
  |> list.each(fn(case_) {
    run.action_state_kind(case_.0) |> should.equal(case_.1)
  })
}

/// A tool's result and a sub-agent's answer are named only by presence;
/// host-written reasons and evidence are shown.
pub fn an_action_state_line_names_results_by_presence_test() {
  run.describe_action_state(run.Succeeded("secret result"))
  |> should.equal("succeeded")
  run.describe_action_state(run.ToolFailed("secret failure"))
  |> string.contains("secret")
  |> should.be_false
  run.describe_action_state(run.Reconciled("secret"))
  |> should.equal("reconciled")
  run.describe_action_state(run.ChildSettled(run.Completed("secret")))
  |> should.equal("settled from its sub-agent run: the run completed")
  run.describe_action_state(run.Uncertain("the call may have reached it"))
  |> should.equal("its effect is uncertain: the call may have reached it")
  run.describe_action_state(run.LimitReached(run.DepthLimit(2)))
  |> should.equal(
    "refused: sub-agents nest at most 2 levels below the root run",
  )
  run.describe_action_state(run.AwaitingApproval(
    run.Requirement("treasurer", 2),
    3,
    Some(timestamp.from_unix_seconds(0)),
  ))
  |> should.equal(
    "awaiting approval (treasurer version 2, revision 3), expires at 1970-01-01T00:00:00Z",
  )
}

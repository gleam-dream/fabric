//// Observable data for a managed graph attachment. Open the referenced child
//// to answer its approvals or signals; the child owns its own progress.

import fabric/run

pub type Parent {
  Parent(run: String, activation: Int)
}

@internal
pub fn attachment(parent: Parent) -> run.Parent {
  run.GraphParent(run.issued(parent.run), parent.activation)
}

pub type Reference {
  Reference(run: run.RunId, activation: Int, child: run.RunId)
}

pub type Progress {
  Working
  Approval(run.Requirement)
  /// Every pending decision in an idle agent family, with its own run/action
  /// reference. Answer through the managed agent's ordinary Fabric handle.
  AgentInput(
    approvals: List(run.PendingApproval),
    uncertain: List(run.UncertainAction),
  )
  Signal(run.Identity)
  Job(run.Identity)
  Uncertain(String)
  FinishedUncertain(String)
  InvalidOutput(output: String, reason: String)
  Succeeded(String)
  Failed(String)
  Cancelled(uncertain: Bool)
}

@external(erlang, "fabric_ffi", "graph_child_id")
@internal
pub fn reserved_id(parent: String, activation: Int) -> String

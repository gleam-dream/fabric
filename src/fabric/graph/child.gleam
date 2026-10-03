//// Observable data for a managed graph attachment. Open the referenced child
//// to answer its approvals or signals; the child owns its own progress.

import fabric/graph/fork
import fabric/run

pub type Parent {
  Parent(run: String, activation: Int)
  Branch(run: String, activation: Int, member: Int)
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
  Signal(run.DefinitionId)
  Job(run.DefinitionId)
  /// An idle structured scope. Open its graph and branches to resolve inputs.
  Fork(fork.Snapshot)
  Uncertain(String)
  FinishedUncertain(String)
  InvalidOutput(output: String, reason: String)
  Succeeded(String)
  Failed(String)
  Cancelled(uncertain: Bool)
}

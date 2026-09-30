//// Observable data for a managed graph attachment. Open the referenced child
//// to answer its approvals or signals; the child owns its own progress.

import fabric/run

pub type Parent {
  Parent(run: String, activation: Int)
}

pub type Reference {
  Reference(run: run.RunId, activation: Int, child: run.RunId)
}

pub type Progress {
  Working
  Approval(run.Requirement)
  Signal(run.Identity)
  Uncertain(String)
  Succeeded(String)
  Failed(String)
  Cancelled(uncertain: Bool)
}

@external(erlang, "fabric_ffi", "graph_child_id")
@internal
pub fn reserved_id(parent: String, activation: Int) -> String

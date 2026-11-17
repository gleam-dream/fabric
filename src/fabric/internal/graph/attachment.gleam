//// How a managed graph attachment names its child: the durable parent link
//// and the deterministic ids of a node's child run and fork members.

import fabric/graph/child
import fabric/internal/ids
import fabric/internal/run_id
import fabric/run

pub fn parent(parent: child.Parent) -> run.Parent {
  case parent {
    child.Parent(id, activation) ->
      run.GraphParent(run_id.from_string(id), activation)
    child.Branch(id, activation, member) ->
      run.GraphBranch(run_id.from_string(id), activation, member)
  }
}

/// The id of the child run that activation `activation` of `parent` starts.
pub fn reserved_id(parent: String, activation: Int) -> String {
  ids.graph_child(parent, activation)
}

/// The id of fork member `member` of activation `activation` of `parent`.
pub fn branch_id(parent: String, activation: Int, member: Int) -> String {
  ids.graph_branch(parent, activation, member)
}

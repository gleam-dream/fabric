//// How a managed graph attachment names its child: the durable parent link
//// and the deterministic ids of a node's child run and fork members.

import fabric/graph/child
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
@external(erlang, "fabric_ffi", "graph_child_id")
pub fn reserved_id(parent: String, activation: Int) -> String

/// The id of fork member `member` of activation `activation` of `parent`.
@external(erlang, "fabric_ffi", "graph_branch_id")
pub fn branch_id(parent: String, activation: Int, member: Int) -> String

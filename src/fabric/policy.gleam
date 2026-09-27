//// The action-authorization gate.
////
//// A `Policy(context)` is supplied by the application and runs before any
//// effect. It sees one `Action` at a time: which run, which model turn,
//// which provider call, which target, and the exact arguments the model
//// sent (already validated against the tool's input codec). It allows the
//// action, denies it with a reason the model will see, or requires an
//// approval. An `Error` is a policy failure: the run stops as a host failure
//// and nothing is allowed by default.

/// Identifies an action within one run. A provider call id alone is not
/// unique: providers reuse ids on later turns.
pub type ActionId {
  ActionId(turn: Int, call_id: String)
}

pub type Action {
  Action(run: String, id: ActionId, tool: String, arguments_json: String)
}

/// Which approval an action needs. `version` lets an application change the
/// requirement for an action and have stale approvals refused.
pub type Requirement {
  Requirement(name: String, version: Int)
}

pub type Decision {
  Allow
  /// The model sees `reason`; the run continues.
  Deny(reason: String)
  /// The action waits for an approval. A run whose remaining work is only
  /// waiting approvals suspends as stored data.
  RequireApproval(Requirement)
}

pub type Policy(context) =
  fn(context, Action) -> Result(Decision, String)

/// Allows every action. Use it deliberately: it is the only policy without a
/// decision of the application's own.
pub fn always_allow() -> Policy(context) {
  fn(_, _) { Ok(Allow) }
}

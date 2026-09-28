//// Shorthands that keep the tests about behaviour rather than set-up.

import fabric/run.{type RunId}
import gleam/int

/// The run id `text`, which must have the shape Fabric issues.
pub fn id(text: String) -> RunId {
  let assert Ok(id) = run.parse_id(text)
  id
}

/// The text of a run id, for backend-level instruments that key by it.
pub fn text(id: RunId) -> String {
  run.id_to_string(id)
}

/// The id of the `n`th sub-agent run that `parent` starts.
pub fn child_id(parent: RunId, n: Int) -> RunId {
  id(run.id_to_string(parent) <> "-" <> int.to_string(n))
}

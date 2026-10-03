//// The run id type, defined apart from `fabric/run` so that `fabric/model`
//// can name it without importing `fabric/run`, which imports the model.
//// Callers use `fabric/run.RunId`, an alias of this type.

pub opaque type RunId {
  RunId(String)
}

/// Wraps text already checked, or issued by Fabric.
pub fn from_string(text: String) -> RunId {
  RunId(text)
}

pub fn to_string(id: RunId) -> String {
  let RunId(text) = id
  text
}

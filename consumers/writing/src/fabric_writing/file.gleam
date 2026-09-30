//// Real application tools. The save key is stable across interrupted attempts;
//// identical bytes are acknowledged and conflicting bytes never overwrite them.

import fabric/graph/operation
import fabric/run
import fabric_writing/domain
import gleam/int
import gleam/result
import gleam/string

@external(erlang, "fabric_writing_ffi", "read")
pub fn read(path: String) -> Result(String, String)

@external(erlang, "fabric_writing_ffi", "publish")
pub fn publish(
  directory: String,
  key: String,
  body: String,
) -> Result(domain.Artifact, String)

pub fn loader() -> operation.Operation(Nil, domain.Brief, domain.Draft) {
  let op =
    operation.new(
      run.Identity("source-read", 1),
      domain.brief_codec(),
      domain.draft_codec(),
      fn(_, _, brief) {
        use source <- result.try(read(brief.source_path))
        case string.trim(source) == "" {
          True -> Error("source is empty")
          False ->
            Ok(domain.Draft(domain.Text(source, brief.instructions, ""), 0))
        }
      },
      operation.DefiniteFailure,
    )
  let assert Ok(op) = operation.with_replay(op, 2)
  op
}

pub fn publisher(
  directory: String,
) -> operation.Operation(Nil, domain.Draft, domain.Artifact) {
  let op =
    operation.new(
      run.Identity("artifact-publish", 1),
      domain.draft_codec(),
      domain.artifact_codec(),
      fn(_, invocation, draft) {
        let key =
          run.id_to_string(invocation.run)
          <> "-"
          <> int.to_string(invocation.activation)
        publish(directory, key, string.trim(draft.text.body) <> "\n")
      },
      operation.UncertainEffect,
    )
  let assert Ok(op) = operation.with_replay(op, 2)
  op
}

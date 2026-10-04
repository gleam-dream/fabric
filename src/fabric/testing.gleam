//// Helpers for testing an application's agents with scripted models, and
//// approvers that trust any reviewer. Production code needs nothing here.
//// A store backend's checks are in `fabric/store/conformance`.

import fabric/approvers.{type Approvers, type Denial}
import fabric/internal/tool as core_tool
import fabric/model.{type ToolCall}
import fabric/reviewer.{type Reviewer}
import fabric/run.{type Requirement}
import fabric/tool.{type Definition}
import json/blueprint/codec

/// A call to `definition` with `input` encoded by its input codec, as a
/// model would request it: for a scripted model (`model.new`) that calls
/// the application's tools. The arguments always decode under the tool
/// bound from the same definition.
pub fn call(
  definition: Definition(input, output),
  id: String,
  input: input,
) -> Result(ToolCall, codec.EncodeError) {
  core_tool.call(definition, id, input)
}

/// Approvers that verify nothing: the credential is the reviewer itself,
/// and every requirement is granted. For tests that are not about who
/// answers; never give them to a production agent, since any code that can
/// name a reviewer can then answer. They are named
/// `"fabric/testing.trusting_approvers"`, the verifier their answers
/// record. Unlike approvers from `approvers.new`, every call returns the
/// same approvers (in one VM), so a test can give them to its agents in
/// one place and check proofs with them in another.
///
/// ```gleam
/// let approvers = testing.trusting_approvers()
/// // agent.new(..) |> agent.with_approvers(approvers) |> agent.build
/// let assert Ok(proof) =
///   approvers.check(approvers, alice, pending.reference.requirement)
/// fabric.approve(handle, pending.reference, proof:, context:)
/// ```
pub fn trusting_approvers() -> Approvers(Reviewer) {
  memoized(trusting_key, fn() {
    approvers.new("fabric/testing.trusting_approvers", trust)
  })
}

const trusting_key = "fabric/testing.trusting_approvers"

@external(erlang, "fabric_ffi", "memoized")
fn memoized(key: String, make: fn() -> a) -> a

fn trust(
  reviewer: Reviewer,
  _requirement: Requirement,
) -> Result(Reviewer, Denial) {
  Ok(reviewer)
}

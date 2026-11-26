//// The approvers an agent or a graph runtime holds, with their credential
//// type forgotten: what an answer checks its proof with.

import fabric/approvers.{type Approvers, type Proof, type ProofError}
import fabric/internal/approvers as core
import fabric/reviewer.{type Reviewer}
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Answerer =
  fn(Proof, core.Binding) -> Result(Reviewer, ProofError)

pub fn from(given: Approvers(credential)) -> Answerer {
  fn(proof, binding) {
    core.accept(given, proof, binding)
    |> result.map_error(fn(refusal) {
      case refusal {
        core.OtherApprovers(verifier) -> approvers.OtherApprovers(verifier)
        core.OtherRequest(proof, request) ->
          approvers.OtherRequest(proof, request)
        core.ProofExpired(age, lifetime) ->
          approvers.ProofExpired(age, lifetime)
      }
    })
  }
}

/// Who answers the request `binding` with `proof`: the reviewer and the
/// name of the approvers that verified them.
pub fn check(
  answerer: Option(Answerer),
  proof: Proof,
  binding: core.Binding,
) -> Result(#(Reviewer, String), ProofError) {
  case answerer {
    None -> Error(approvers.NoApprovers)
    Some(accept) ->
      accept(proof, binding)
      |> result.map(fn(reviewer) { #(reviewer, approvers.verifier(proof)) })
  }
}

//// The approvers an agent or a graph runtime holds, with their credential
//// type forgotten: what an answer checks its proof with.

import fabric/approvers.{type Approvers, type Proof, type ProofError}
import fabric/reviewer.{type Reviewer}
import fabric/run.{type Requirement}
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Answerer =
  fn(Proof, Requirement) -> Result(Reviewer, ProofError)

pub fn from(approvers: Approvers(credential)) -> Answerer {
  fn(proof, requirement) { approvers.accept(approvers, proof, requirement) }
}

/// Who answers a request that waits for `requirement` with `proof`: the
/// reviewer and the name of the approvers that verified them.
pub fn check(
  answerer: Option(Answerer),
  proof: Proof,
  requirement: Requirement,
) -> Result(#(Reviewer, String), ProofError) {
  case answerer {
    None -> Error(approvers.NoApprovers)
    Some(accept) ->
      accept(proof, requirement)
      |> result.map(fn(reviewer) { #(reviewer, approvers.verifier(proof)) })
  }
}

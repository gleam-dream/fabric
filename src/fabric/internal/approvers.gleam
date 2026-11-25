//// The representation behind `fabric/approvers`: approvers and the proofs
//// only their `check` makes, each bound to the one request it answers, and
//// `accept`, what every answer does with a proof. Both types stay opaque here too: this module never builds a
//// proof without running the approvers' `verify`. `denial` is
//// `approvers.Denial`, which this module cannot import.

import fabric/internal/clock
import fabric/reviewer.{type Reviewer}
import fabric/run.{
  type ApprovalRef, type Requirement, type RunId, type Timeout, After, Infinity,
}
import gleam/erlang/reference.{type Reference}
import gleam/string
import gleam/time/duration

pub opaque type Approvers(credential, denial) {
  Approvers(
    name: String,
    /// Minted by `new`: what tells these approvers from any other.
    key: Reference,
    verify: fn(credential, Request) -> Result(Reviewer, denial),
    proof_lifetime: Timeout,
  )
}

/// What a verifier authorizes: the run whose request a credential would
/// answer, and the requirement that request waits for.
pub type Request {
  Request(run: RunId, requirement: Requirement)
}

/// The exact request a proof answers: an agent action's approval
/// reference, or a graph activation's.
pub type Binding {
  ActionRequest(ApprovalRef)
  ActivationRequest(
    run: RunId,
    activation: Int,
    attempt: Int,
    revision: Int,
    requirement: Requirement,
  )
}

pub opaque type Proof {
  Proof(
    verifier: String,
    key: Reference,
    binding: Binding,
    reviewer: Reviewer,
    checked_at: Int,
  )
}

/// Why `accept` refused a proof; `approvers.ProofError` without
/// `NoApprovers`.
pub type Refusal {
  OtherApprovers(verifier: String)
  OtherRequest(proof: Request, request: Request)
  ProofExpired(age: Int, lifetime: Int)
}

/// The run and requirement of `binding`, as a verifier sees them.
pub fn request(binding: Binding) -> Request {
  case binding {
    ActionRequest(reference) -> Request(reference.run, reference.requirement)
    ActivationRequest(run:, requirement:, ..) -> Request(run, requirement)
  }
}

pub const max_name_bytes = 64

const default_lifetime_seconds = 60

pub fn new(
  name: String,
  verify: fn(credential, Request) -> Result(Reviewer, denial),
) -> Approvers(credential, denial) {
  case string.byte_size(name) {
    bytes if bytes >= 1 && bytes <= max_name_bytes ->
      Approvers(
        name:,
        key: reference.new(),
        verify:,
        proof_lifetime: After(duration.seconds(default_lifetime_seconds)),
      )
    _ ->
      panic as {
        "approvers.new: the name must be 1 to 64 bytes: "
        <> string.inspect(name)
      }
  }
}

pub fn with_proof_lifetime(
  approvers: Approvers(credential, denial),
  lifetime: Timeout,
) -> Approvers(credential, denial) {
  Approvers(..approvers, proof_lifetime: lifetime)
}

pub fn name(approvers: Approvers(credential, denial)) -> String {
  approvers.name
}

pub fn check(
  approvers: Approvers(credential, denial),
  credential: credential,
  binding: Binding,
) -> Result(Proof, denial) {
  case approvers.verify(credential, request(binding)) {
    Ok(reviewer) ->
      Ok(Proof(
        verifier: approvers.name,
        key: approvers.key,
        binding:,
        reviewer:,
        checked_at: clock.now(),
      ))
    Error(denial) -> Error(denial)
  }
}

/// The reviewer `proof` names, when these approvers made it for exactly
/// the request `binding`, within their proof lifetime.
pub fn accept(
  approvers: Approvers(credential, denial),
  proof: Proof,
  binding: Binding,
) -> Result(Reviewer, Refusal) {
  let age = clock.now() - proof.checked_at
  case proof.key == approvers.key {
    False -> Error(OtherApprovers(proof.verifier))
    True ->
      case proof.binding == binding, approvers.proof_lifetime {
        False, _ ->
          Error(OtherRequest(request(proof.binding), request(binding)))
        True, After(lifetime) ->
          case duration.to_milliseconds(lifetime) {
            lifetime if age > lifetime -> Error(ProofExpired(age:, lifetime:))
            _ -> Ok(proof.reviewer)
          }
        True, Infinity -> Ok(proof.reviewer)
      }
  }
}

pub fn reviewer(proof: Proof) -> Reviewer {
  proof.reviewer
}

pub fn verifier(proof: Proof) -> String {
  proof.verifier
}

pub fn request_of(proof: Proof) -> Request {
  request(proof.binding)
}

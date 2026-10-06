//// Who may answer an approval request, and the proof that someone was
//// checked.
////
//// An agent (`agent.with_approvers`) or a graph runtime
//// (`graph.with_approvers`) is given its `Approvers` once: a name and a
//// `verify` function that turns a credential (a bearer token, a session)
//// into the `Reviewer` it authenticates, after checking that the
//// credential may answer the request's `run.Requirement`. A request
//// handler calls `check` with the credential it received and the pending
//// request's requirement, and passes the `Proof` it returns to
//// `fabric.approve`, `fabric.reject`, `graph.approve` or `graph.reject`.
//// Only `check` makes a `Proof`, and an answer refuses a proof that:
////
//// - was made by other approvers than the agent's or runtime's
////   (`OtherApprovers`), so a permissive verifier built elsewhere in the
////   application is never accepted;
//// - was checked for another requirement than the one the request waits
////   for (`OtherRequirement`), so a proof for `"refund"` cannot answer
////   `"payout"`;
//// - is older than the approvers' proof lifetime (`ProofExpired`, 60 s
////   by default, `with_proof_lifetime`): a proof is evidence of a check
////   made for this answer, not a standing grant.
////
//// An agent or runtime without approvers refuses every answer
//// (`NoApprovers`). The answer records the reviewer and the approvers'
//// name (`run.Approval.reviewer`, `run.Approval.verifier`).
////
//// ```gleam
//// let desk_approvers = warden_approvers(validator)  // the recipe below
//// let assert Ok(desk) =
////   agent.new("desk", model, tools, policy)
////   |> agent.with_approvers(desk_approvers)
////   |> agent.build
//// // In the request handler that answers `pending`:
//// case approvers.check(desk_approvers, bearer, pending.reference.requirement) {
////   Ok(proof) -> fabric.approve(handle, pending.reference, proof:, context:)
////   Error(approvers.NotAuthenticated(_)) -> todo  // 401
////   Error(approvers.NotAuthorized(_)) -> todo     // 403
////   Error(approvers.Unavailable(_)) -> todo       // 503
//// }
//// ```
////
//// Each call of `new` makes distinct approvers, even with the same name
//// and function: a proof is accepted only by an agent or runtime given the
//// very value that made it. Build the approvers once, at boot, and pass
//// that value to the agent and to the request handlers. Tests that do not
//// exercise authentication use `fabric/testing.trusting_approvers()`,
//// whose credential is the reviewer itself.
////
//// ## With warden
////
//// A warden access token must be valid for the application's audience
//// and carry the scope
//// `approve:<requirement name>`. The block is compiled and tested verbatim
//// by `consumers/approvers_warden`, and `scripts/check.py` checks that it
//// is the same in this module, USAGE.md and that package.
////
//// ```gleam
//// import fabric/approvers.{type Approvers}
//// import fabric/reviewer
//// import gleam/bool
//// import gleam/list
//// import gleam/result
//// import warden/resource
////
//// /// Approvers that accept a warden access token issued for the validator's
//// /// audience and carrying the scope `approve:<requirement name>`. The answer
//// /// records the token's `sub` and `iss`, and the verifier `"warden"`. Call
//// /// it once, at boot: the agent and the request handlers share the value.
//// pub fn warden_approvers(validator: resource.Validator) -> Approvers(String) {
////   use token, requirement <- approvers.new("warden")
////   use claims <- result.try(
////     resource.verify(validator, token) |> result.map_error(denial),
////   )
////   let scope = "approve:" <> requirement.name
////   use <- bool.guard(
////     !list.contains(resource.scopes(claims), scope),
////     Error(approvers.NotAuthorized("the token lacks the scope " <> scope)),
////   )
////   reviewer.new(resource.subject(claims))
////   |> result.try(reviewer.with_issuer(_, resource.issuer(claims)))
////   |> result.map_error(fn(error) {
////     approvers.NotAuthenticated(reviewer.describe_error(error))
////   })
//// }
////
//// fn denial(error: resource.TokenError) -> approvers.Denial {
////   let reason = resource.describe_error(error)
////   case resource.error_kind(error) {
////     resource.Rejected | resource.WrongAudience ->
////       approvers.NotAuthenticated(reason)
////     resource.Forbidden -> approvers.NotAuthorized(reason)
////     resource.Unavailable -> approvers.Unavailable(reason)
////   }
//// }
//// ```

import fabric/internal/approvers as core
import fabric/reviewer.{type Reviewer}
import fabric/run.{type Requirement, type Timeout}
import gleam/int

/// A verifier of credentials that answer approval requests. Make one with
/// `new`.
pub type Approvers(credential) =
  core.Approvers(credential, Denial)

/// Why `verify` refused a credential. The three cases are the
/// classification: an application maps them to 401, 403 and 503.
pub type Denial {
  /// The credential proves no identity: missing, malformed, forged,
  /// expired, issued for another audience.
  NotAuthenticated(reason: String)
  /// The identity is authenticated but may not answer this requirement.
  NotAuthorized(reason: String)
  /// The verifier could not decide: its key source or identity provider
  /// is unreachable. Trying again later may succeed.
  Unavailable(reason: String)
}

/// Evidence that `check` verified a credential for one requirement. Only
/// `check` makes one.
pub type Proof =
  core.Proof

/// Why an answer refused a proof. This union may grow: keep a catch-all,
/// or use `describe_proof_error`.
pub type ProofError {
  /// The agent or graph runtime has no approvers (`agent.with_approvers`,
  /// `graph.with_approvers`), so it accepts no answer.
  NoApprovers
  /// The proof was made by other approvers than the agent's or runtime's;
  /// `verifier` is their name.
  OtherApprovers(verifier: String)
  /// The proof was checked for `proof`, and the request waits for
  /// `request`.
  OtherRequirement(proof: Requirement, request: Requirement)
  /// The proof is older than the proof lifetime (`with_proof_lifetime`):
  /// `age` and `lifetime` in milliseconds.
  ProofExpired(age: Int, lifetime: Int)
}

/// The longest name, in bytes.
pub const max_name_bytes = core.max_name_bytes

/// Approvers named `name` (stored with every answer they verify, as
/// `run.Approval.verifier`), which verify a credential with `verify`.
///
/// `verify` receives the credential and the requirement of the request it
/// would answer, and returns the authenticated reviewer, or why it refused.
/// It decides authorization from the requirement, for example by asking
/// for the scope `"approve:" <> requirement.name`. It runs in the process
/// that calls `check`, which waits for it: bound its network calls (a key
/// fetch) with their own timeouts.
///
/// `name` is written in source code, so it is checked here: 1 to 64 bytes,
/// or this panics.
pub fn new(
  name: String,
  verify: fn(credential, Requirement) -> Result(Reviewer, Denial),
) -> Approvers(credential) {
  core.new(name, verify)
}

/// How long a proof from `check` stays good for an answer, judged by the
/// approvers of the agent or runtime that receives it. A proof is made
/// for one answer, right before it; one kept longer is refused with
/// `ProofExpired`, so that a credential revoked or expired since is not
/// honoured. Default 60 s; `run.Infinity` never expires a proof. The
/// approvers it returns are the same approvers, with another lifetime.
pub fn with_proof_lifetime(
  approvers: Approvers(credential),
  lifetime: Timeout,
) -> Approvers(credential) {
  core.with_proof_lifetime(approvers, lifetime)
}

pub fn name(approvers: Approvers(credential)) -> String {
  core.name(approvers)
}

/// Verifies `credential` for an answer to a request that waits for
/// `requirement` (`run.PendingApproval.reference.requirement`,
/// `graph.ApprovalRef.requirement`), and returns the proof to answer it
/// with.
pub fn check(
  approvers: Approvers(credential),
  credential: credential,
  requirement: Requirement,
) -> Result(Proof, Denial) {
  core.check(approvers, credential, requirement)
}

/// The reviewer `verify` returned.
pub fn reviewer(proof: Proof) -> Reviewer {
  core.reviewer(proof)
}

/// The name of the approvers that made the proof.
pub fn verifier(proof: Proof) -> String {
  core.verifier(proof)
}

/// The requirement the proof was checked for.
pub fn requirement(proof: Proof) -> Requirement {
  core.requirement(proof)
}

/// One line for logs.
pub fn describe_denial(denial: Denial) -> String {
  case denial {
    NotAuthenticated(reason) -> "not authenticated: " <> reason
    NotAuthorized(reason) -> "not authorized: " <> reason
    Unavailable(reason) -> "the verifier is unavailable: " <> reason
  }
}

/// One line for logs, naming the setter where one fixes it.
pub fn describe_proof_error(error: ProofError) -> String {
  case error {
    NoApprovers ->
      "the agent or graph runtime has no approvers (agent.with_approvers, graph.with_approvers)"
    OtherApprovers(verifier) ->
      "the proof was made by other approvers ("
      <> verifier
      <> ") than the agent's or graph runtime's"
    OtherRequirement(proof, request) ->
      "the proof was checked for "
      <> describe_requirement(proof)
      <> ", and the request waits for "
      <> describe_requirement(request)
    ProofExpired(age, lifetime) ->
      "the proof is "
      <> int.to_string(age)
      <> " ms old, older than its lifetime of "
      <> int.to_string(lifetime)
      <> " ms (approvers.with_proof_lifetime)"
  }
}

fn describe_requirement(requirement: Requirement) -> String {
  requirement.name <> " version " <> int.to_string(requirement.version)
}

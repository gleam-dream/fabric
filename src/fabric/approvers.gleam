//// Who may answer an approval request, and the proof that someone was
//// checked.
////
//// An agent (`agent.with_approvers`) or a graph runtime
//// (`graph.with_approvers`) is given its `Approvers` once: a name and a
//// `verify` function that turns a credential (a bearer token, a session)
//// into the `Reviewer` it authenticates, after checking that the
//// credential may answer the `Request`: its run and its `run.Requirement`.
//// A request handler calls `check` (an agent's request) or
//// `graph.check_approval` (a graph's) with the credential it received and
//// the pending request's reference, and passes the `Proof` it returns to
//// `fabric.approve`, `fabric.reject`, `graph.approve` or `graph.reject`.
//// Only these functions make a `Proof`, and an answer refuses a proof that:
////
//// - was made by other approvers than the agent's or runtime's
////   (`OtherApprovers`), so a permissive verifier built elsewhere in the
////   application is never accepted;
//// - was checked for another request than the one it answers
////   (`OtherRequest`): a proof is bound to one reference, so a proof for
////   `"refund"` cannot answer `"payout"`, and a proof checked for one run's
////   request cannot answer another run's request for the same requirement;
//// - is older than the approvers' proof lifetime (`ProofExpired`, 60 s
////   by default, `with_proof_lifetime`): a proof is evidence of a check
////   made for this answer, not a standing grant.
////
//// An agent or runtime without approvers refuses every answer
//// (`NoApprovers`). The answer records the reviewer and the approvers'
//// name (`run.Approval.reviewer`, `run.Approval.verifier`).
////
//// ```gleam
//// let desk_approvers = hellhound_approvers(validator)  // the recipe below
//// let assert Ok(desk) =
////   agent.build_with(fn() {
////     agent.new("desk", model, tools(), policy)
////     |> agent.with_approvers(desk_approvers)
////   })
//// // In the request handler that answers `pending`:
//// case approvers.check(desk_approvers, bearer, pending.reference) {
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
//// ## With hellhound
////
//// A hellhound access token must be valid for the application's audience and
//// carry the scope `approve:<requirement name>`. Copy the module
//// `approvers_hellhound` of `consumers/approvers_hellhound` into the application;
//// that consumer compiles it and tests it against hellhound's test issuer. Its
//// function `hellhound_approvers(validator)` builds approvers named `"hellhound"`:
//// they verify the token with `hellhound/resource.verify`, require the scope,
//// and answer with a reviewer made of the token's `sub` and `iss`. A rejected
//// or wrong-audience token is `NotAuthenticated`, a forbidden one
//// `NotAuthorized` and an unavailable validator `Unavailable`. Call it once,
//// at boot: the agent and the request handlers share the value.

import fabric/internal/approvers as core
import fabric/reviewer.{type Reviewer}
import fabric/run.{type ApprovalRef, type Requirement, type Timeout}
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

/// What `verify` authorizes: the run whose request the credential would
/// answer (`run`), and the requirement that request waits for
/// (`requirement`). A multi-tenant application checks here that the
/// credential may see `run`.
pub type Request =
  core.Request

/// Evidence that `check` verified a credential for one request. Only
/// `check` and `graph.check_approval` make one.
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
  /// The proof was checked for another request than the one it answers:
  /// `proof` is the run and requirement it was checked for, `request` the
  /// answered request's. They can be equal when the proof answers another
  /// action or an earlier revision of the same run.
  OtherRequest(proof: Request, request: Request)
  /// The proof is older than the proof lifetime (`with_proof_lifetime`):
  /// `age` and `lifetime` in milliseconds.
  ProofExpired(age: Int, lifetime: Int)
}

/// The longest name, in bytes.
pub const max_name_bytes = core.max_name_bytes

/// Approvers named `name` (stored with every answer they verify, as
/// `run.Approval.verifier`), which verify a credential with `verify`.
///
/// `verify` receives the credential and the `Request` it would answer, and
/// returns the authenticated reviewer, or why it refused. It decides
/// authorization from the request's requirement, for example by asking for
/// the scope `"approve:" <> request.requirement.name`, and from its run, for
/// example that the run belongs to the credential's tenant. It runs in the process
/// that calls `check`, which waits for it: bound its network calls (a key
/// fetch) with their own timeouts.
///
/// `name` is written in source code, so it is checked here: 1 to 64 bytes,
/// or this panics.
pub fn new(
  name: String,
  verify: fn(credential, Request) -> Result(Reviewer, Denial),
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

/// Verifies `credential` for an answer to the agent request `reference`
/// (`run.PendingApproval.reference`), and returns the proof that answers
/// that request and no other. A graph request is checked with
/// `graph.check_approval`.
pub fn check(
  approvers: Approvers(credential),
  credential: credential,
  reference: ApprovalRef,
) -> Result(Proof, Denial) {
  core.check(approvers, credential, core.ActionRequest(reference))
}

/// The reviewer `verify` returned.
pub fn reviewer(proof: Proof) -> Reviewer {
  core.reviewer(proof)
}

/// The name of the approvers that made the proof.
pub fn verifier(proof: Proof) -> String {
  core.verifier(proof)
}

/// The run and requirement of the request the proof was checked for.
pub fn request(proof: Proof) -> Request {
  core.request_of(proof)
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
    OtherRequest(proof, request) ->
      "the proof was checked for another request (run "
      <> run.id_to_string(proof.run)
      <> ", "
      <> describe_requirement(proof.requirement)
      <> ") than the answered one (run "
      <> run.id_to_string(request.run)
      <> ", "
      <> describe_requirement(request.requirement)
      <> ")"
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

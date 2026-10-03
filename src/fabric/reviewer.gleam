//// The identity that answers an approval request.
////
//// `fabric.approve` and `fabric.reject` require a `Reviewer`, and Fabric
//// records it with the answer (`run.Approval.reviewer`). Fabric does not
//// authenticate it: the application builds it from an identity it has
//// already authenticated and authorized, such as the subject and issuer of a
//// verified OpenID Connect ID token or session.
////
//// ```gleam
//// let reviewer =
////   reviewer.new(claims.subject) |> reviewer.with_issuer(claims.issuer)
//// fabric.approve(handle, pending.reference, reviewer:, context:)
//// ```
////
//// Fabric may add optional parts to a reviewer; build one with `new` and
//// read it with the accessors.

import gleam/option.{type Option, None, Some}

pub opaque type Reviewer {
  Reviewer(subject: String, issuer: Option(String))
}

/// A reviewer named by `subject`: the authenticated identity's stable id
/// within its issuer (an OIDC `sub`, a user id).
pub fn new(subject: String) -> Reviewer {
  Reviewer(subject:, issuer: None)
}

/// The authority that vouches for the subject (an OIDC `iss`), so that two
/// identity providers' subjects are not confused.
pub fn with_issuer(reviewer: Reviewer, issuer: String) -> Reviewer {
  Reviewer(..reviewer, issuer: Some(issuer))
}

pub fn subject(reviewer: Reviewer) -> String {
  reviewer.subject
}

pub fn issuer(reviewer: Reviewer) -> Option(String) {
  reviewer.issuer
}

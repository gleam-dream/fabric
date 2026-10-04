//// The identity that answers an approval request.
////
//// An answer (`fabric.approve`, `fabric.reject`, `graph.approve`,
//// `graph.reject`) does not take a reviewer: it takes an
//// `approvers.Proof`, and the reviewer it records
//// (`run.Approval.reviewer`) is the one the approvers' `verify` function
//// returned. A reviewer is that function's building block: it names the
//// identity a credential authenticated, such as the subject and issuer of
//// a verified access token.
////
//// ```gleam
//// use token, requirement <- approvers.new("sso")
//// use claims <- result.try(verify_token(token, requirement))
//// reviewer.new(claims.subject)
//// |> result.try(reviewer.with_issuer(_, claims.issuer))
//// |> result.map_error(fn(error) {
////   approvers.NotAuthenticated(reviewer.describe_error(error))
//// })
//// ```
////
//// A subject and an issuer come from a token, so they are checked: each is
//// 1 to 256 bytes. Fabric may add optional parts to a reviewer; build one
//// with `new` and read it with the accessors.

import fabric/internal/reviewer as core
import gleam/int
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string

/// An authenticated identity that answers approvals. Build one with `new`.
pub type Reviewer =
  core.Reviewer

/// Which part of a reviewer `Error` names.
pub type Part {
  Subject
  Issuer
}

/// Why `new` or `with_issuer` refused a value.
pub type Error {
  /// The part is the empty string.
  Empty(part: Part)
  /// The part is longer than `limit` bytes (`bytes` is its length).
  TooLong(part: Part, bytes: Int, limit: Int)
}

/// The longest subject or issuer, in bytes.
pub const max_bytes = 256

/// A reviewer named by `subject`: the authenticated identity's stable id
/// within its issuer (an OIDC `sub`, a user id), 1 to 256 bytes.
pub fn new(subject: String) -> Result(Reviewer, Error) {
  use subject <- result.map(check(Subject, subject))
  core.Reviewer(subject:, issuer: option.None)
}

/// The authority that vouches for the subject (an OIDC `iss`), so that two
/// identity providers' subjects are not confused; 1 to 256 bytes.
pub fn with_issuer(
  reviewer: Reviewer,
  issuer: String,
) -> Result(Reviewer, Error) {
  use issuer <- result.map(check(Issuer, issuer))
  core.Reviewer(..reviewer, issuer: Some(issuer))
}

pub fn subject(reviewer: Reviewer) -> String {
  reviewer.subject
}

pub fn issuer(reviewer: Reviewer) -> Option(String) {
  reviewer.issuer
}

/// One line for logs.
pub fn describe_error(error: Error) -> String {
  case error {
    Empty(part) -> "the reviewer's " <> part_name(part) <> " is empty"
    TooLong(part, bytes, limit) ->
      "the reviewer's "
      <> part_name(part)
      <> " is "
      <> int.to_string(bytes)
      <> " bytes, longer than "
      <> int.to_string(limit)
  }
}

fn part_name(part: Part) -> String {
  case part {
    Subject -> "subject"
    Issuer -> "issuer"
  }
}

fn check(part: Part, text: String) -> Result(String, Error) {
  case string.byte_size(text) {
    0 -> Error(Empty(part))
    bytes if bytes > max_bytes -> Error(TooLong(part, bytes, max_bytes))
    _ -> Ok(text)
  }
}

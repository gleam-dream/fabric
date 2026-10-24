//// The representation behind `fabric/reviewer.Reviewer`. `fabric/reviewer`
//// checks what an application builds; a stored record restores the
//// reviewer it holds as it was written.

import gleam/option.{type Option}

pub type Reviewer {
  Reviewer(subject: String, issuer: Option(String))
}

/// The reviewer a record stored, unchecked: a record written before
/// reviewers were checked may hold any subject.
pub fn restore(subject: String, issuer: Option(String)) -> Reviewer {
  Reviewer(subject:, issuer:)
}

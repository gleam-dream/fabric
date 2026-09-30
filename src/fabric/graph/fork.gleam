//// Observable membership and outcomes of structured graph forks.
//// Ordinals identify members within a parent activation; equal inputs retain
//// distinct members. A failed member does not discard settled sibling results.

import fabric/run
import gleam/option.{type Option}
import gleam/result
import json/blueprint/codec

pub type Occurrence {
  Occurrence(run: run.RunId, activation: Int)
}

pub type Reference {
  Reference(occurrence: Occurrence, member: Int)
}

pub type Request {
  Request(definition: run.Identity, input: String)
}

pub type Progress {
  Active
  Uncertain(evidence: String)
  Succeeded(output: String)
  Failed(reason: String)
  /// Only use after the child has no unresolved effects.
  Cancelled
}

pub type Status {
  Pending
  Withdrawn
  Rejected(reason: String)
  /// Admission is saved; child creation has not yet been acknowledged.
  Reserved
  Admitted(Progress)
}

pub type Member {
  Member(request: Request, status: Status)
}

pub type Cause {
  MemberFailed(Reference)
  CancelledByCaller
  DeadlineElapsed(due: Int)
}

/// Data for the owning graph record. List position is the member ordinal;
/// there is no second set of indices that can disagree with that order.
pub type Snapshot {
  Snapshot(
    occurrence: Occurrence,
    max_members: Int,
    concurrency: Int,
    members: List(Member),
    stop: Option(Cause),
  )
}

/// A settled definite failure that the parent node can route on.
/// Detailed member evidence remains in the parent snapshot and child records.
pub type Failure {
  Failure(member: Int, reason: String)
}

/// Codec for a typed fork result, including its explicit failure alternative.
pub fn result_codec(
  success: codec.Codec(output),
) -> Result(codec.Codec(Result(output, Failure)), codec.UnionError) {
  let failure =
    codec.imap(
      codec.pair(codec.int(), codec.string()),
      fn(pair) { Failure(pair.0, pair.1) },
      fn(failure) { #(failure.member, failure.reason) },
    )
  use tagged <- result.map(codec.tagged("ok", success, "error", failure))
  codec.imap(
    tagged,
    fn(value) {
      case value {
        codec.Left(value) -> Ok(value)
        codec.Right(failure) -> Error(failure)
      }
    },
    fn(value) {
      case value {
        Ok(value) -> codec.Left(value)
        Error(failure) -> codec.Right(failure)
      }
    },
  )
}

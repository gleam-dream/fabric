//// Observable membership and outcomes of structured graph forks.
//// Ordinals identify members within a parent activation; equal inputs retain
//// distinct members. A failed member does not discard settled sibling results.

import fabric/run
import gleam/option.{type Option}
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
/// The JSON is `{"tag": "ok", "value": output}` or
/// `{"tag": "error", "value": [member, reason]}`.
pub fn result_codec(
  success: codec.Codec(output),
) -> codec.Codec(Result(output, Failure)) {
  let failure =
    codec.pair(codec.int(), codec.string())
    |> codec.map(
      decode: fn(pair) { Failure(pair.0, pair.1) },
      encode: fn(failure: Failure) { #(failure.member, failure.reason) },
    )
  codec.union({
    use ok <- codec.variant("ok", success, Ok)
    use error <- codec.variant("error", failure, Error)
    codec.match(fn(value) {
      case value {
        Ok(value) -> ok(value)
        Error(failure) -> error(failure)
      }
    })
  })
}

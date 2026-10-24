//// Pure membership and join control for one structured fork occurrence.
//// The graph owner must commit every returned scope before starting children.
//// Child observations are authoritative data supplied by the fenced runner;
//// this model neither executes effects nor establishes ownership by itself.

import fabric/graph/fork.{
  type Cause, type Member, type Occurrence, type Progress, type Reference,
  type Request, type Snapshot, type Status, Active, Admitted, Cancelled,
  CancelledByCaller, DeadlineElapsed, Failed, Member, MemberFailed, Pending,
  Reference, Rejected, Reserved, Snapshot, Succeeded, Uncertain, Withdrawn,
}
import fabric/run
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub opaque type Scope {
  Scope(Snapshot)
}

pub type Join {
  Waiting
  Unresolved(members: List(Reference))
  Ready(Result(List(String), Cause))
}

pub type Rejection {
  InvalidOccurrence
  InvalidBounds
  TooManyMembers(found: Int, limit: Int)
  InvalidRequest(member: Int)
  InvalidOutput
  InvalidDeadline(Int)
  InvalidSnapshot(String)
  WrongOccurrence
  UnknownMember
  NotNext
  NotAdmitted
  ConflictingOutcome
}

pub fn new(
  occurrence: Occurrence,
  requests: List(Request),
  max_members: Int,
  concurrency: Int,
) -> Result(Scope, Rejection) {
  restore(Snapshot(
    occurrence,
    max_members,
    concurrency,
    list.map(requests, Member(_, Pending)),
    None,
  ))
}

pub fn snapshot(scope: Scope) -> Snapshot {
  let Scope(saved) = scope
  saved
}

/// Restoration validates data, never reenacts admissions or observations.
/// Native codecs and deployed child compatibility are checked by the owner.
pub fn restore(saved: Snapshot) -> Result(Scope, Rejection) {
  use _ <- result.try(
    case
      run.parse_id(run.id_to_string(saved.occurrence.run)),
      saved.occurrence.activation > 0
    {
      Ok(_), True -> Ok(Nil)
      _, _ -> Error(InvalidOccurrence)
    },
  )
  use _ <- result.try(case saved.max_members > 0 && saved.concurrency > 0 {
    True -> Ok(Nil)
    False -> Error(InvalidBounds)
  })
  let count = list.length(saved.members)
  use _ <- result.try(case count <= saved.max_members {
    True -> Ok(Nil)
    False -> Error(TooManyMembers(count, saved.max_members))
  })
  use _ <- result.try(
    saved.members
    |> list.index_map(fn(member, index) { #(member, index + 1) })
    |> list.try_map(fn(item) { validate_member(item.0, item.1) }),
  )
  use _ <- result.try(validate_order(saved.members, False, 0, saved.concurrency))
  let scope = Scope(saved)
  use _ <- result.try(validate_stop(scope))
  Ok(scope)
}

fn validate_member(member: Member, ordinal: Int) -> Result(Nil, Rejection) {
  let request = member.request
  use _ <- result.try(
    case
      string.trim(request.definition.name) != ""
      && request.definition.version > 0
      && valid_json(request.input)
    {
      True -> Ok(Nil)
      False -> Error(InvalidRequest(ordinal))
    },
  )
  case member.status {
    Admitted(Succeeded(output)) -> check_output(output)
    Reserved
    | Pending
    | Withdrawn
    | Rejected(_)
    | Admitted(Active)
    | Admitted(Uncertain(_))
    | Admitted(Failed(_))
    | Admitted(Cancelled) -> Ok(Nil)
  }
}

// Admissions form a prefix. A rejected admission can only be the next member,
// and closes the prefix even though that member never owned a child.
// Earlier unsettled members still held their slots when later members entered,
// even if those later members have since completed.
fn validate_order(
  members: List(Member),
  closed: Bool,
  unsettled_before: Int,
  concurrency: Int,
) -> Result(Nil, Rejection) {
  case members {
    [] -> Ok(Nil)
    [member, ..rest] ->
      case member.status, closed {
        Admitted(_), True | Reserved, True | Rejected(_), True ->
          Error(InvalidSnapshot("admission skipped an earlier member"))
        Admitted(_), False
        | Reserved, False
        | Rejected(_), False
          if unsettled_before >= concurrency
        -> Error(InvalidSnapshot("admission exceeded concurrency"))
        Reserved, False ->
          validate_order(rest, False, unsettled_before + 1, concurrency)
        Admitted(progress), False -> {
          let still_open = case terminal(progress) {
            True -> 0
            False -> 1
          }
          validate_order(
            rest,
            False,
            unsettled_before + still_open,
            concurrency,
          )
        }
        Pending, _ | Withdrawn, _ | Rejected(_), False ->
          validate_order(rest, True, unsettled_before, concurrency)
      }
  }
}

fn validate_stop(scope: Scope) -> Result(Nil, Rejection) {
  let saved = snapshot(scope)
  case saved.stop {
    None ->
      case
        list.any(saved.members, fn(member) {
          case member.status {
            Withdrawn
            | Rejected(_)
            | Admitted(Failed(_))
            | Admitted(Cancelled) -> True
            Reserved
            | Pending
            | Admitted(Active)
            | Admitted(Uncertain(_))
            | Admitted(Succeeded(_)) -> False
          }
        })
      {
        True -> Error(InvalidSnapshot("stopped member without stop intent"))
        False -> Ok(Nil)
      }
    Some(cause) -> {
      use _ <- result.try(
        case list.any(saved.members, fn(member) { member.status == Pending }) {
          True ->
            Error(InvalidSnapshot("stopped scope still has pending members"))
          False -> Ok(Nil)
        },
      )
      let rejected =
        select(scope, fn(status) {
          case status {
            Rejected(_) -> True
            Pending | Withdrawn | Reserved | Admitted(_) -> False
          }
        })
      use _ <- result.try(case rejected, cause {
        [], _ -> Ok(Nil)
        [reference], MemberFailed(failed) if reference == failed -> Ok(Nil)
        _, _ -> Error(InvalidSnapshot("rejected admission must cause the stop"))
      })
      case cause {
        CancelledByCaller -> Ok(Nil)
        DeadlineElapsed(due) -> check_deadline(due)
        MemberFailed(reference) -> {
          use member <- result.try(member(scope, reference))
          case member.status {
            Rejected(_) | Admitted(Failed(_)) | Admitted(Cancelled) -> Ok(Nil)
            Reserved
            | Pending
            | Withdrawn
            | Admitted(Active)
            | Admitted(Uncertain(_))
            | Admitted(Succeeded(_)) ->
              Error(InvalidSnapshot(
                "failure cause does not name a failed member",
              ))
          }
        }
      }
    }
  }
}

pub fn next(scope: Scope) -> Option(Reference) {
  let saved = snapshot(scope)
  case
    saved.stop == None
    && list.length(unsettled(scope)) < saved.concurrency
    && uncertain(scope) == []
  {
    False -> None
    True ->
      select(scope, fn(status) { status == Pending })
      |> list.first
      |> result.map(Some)
      |> result.unwrap(None)
  }
}

/// Parking must not abandon a ready admission or an unacknowledged child start.
pub fn can_wait(scope: Scope) -> Bool {
  case join(scope) {
    Ready(_) -> False
    Waiting | Unresolved(_) ->
      next(scope) == None
      && !list.any(snapshot(scope).members, fn(member) {
        member.status == Reserved
      })
  }
}

pub fn admit(scope: Scope, reference: Reference) -> Result(Scope, Rejection) {
  use _ <- result.try(check_next(scope, reference))
  Ok(replace(scope, reference, Reserved))
}

/// A definite refusal before admission owns no child, unlike a child failure.
pub fn reject(
  scope: Scope,
  reference: Reference,
  reason: String,
) -> Result(Scope, Rejection) {
  use _ <- result.try(check_next(scope, reference))
  Ok(
    scope
    |> replace(reference, Rejected(reason))
    |> close(MemberFailed(reference)),
  )
}

fn check_next(scope: Scope, reference: Reference) -> Result(Nil, Rejection) {
  use _ <- result.try(member(scope, reference))
  case next(scope) == Some(reference) {
    True -> Ok(Nil)
    False -> Error(NotNext)
  }
}

pub fn observe(
  scope: Scope,
  reference: Reference,
  progress: Progress,
) -> Result(Scope, Rejection) {
  use member <- result.try(member(scope, reference))
  use previous <- result.try(case member.status {
    Reserved -> Ok(Active)
    Admitted(previous) -> Ok(previous)
    Pending | Withdrawn | Rejected(_) -> Error(NotAdmitted)
  })
  case terminal(previous) {
    True ->
      case previous == progress {
        True -> Ok(scope)
        False -> Error(ConflictingOutcome)
      }
    False -> {
      use _ <- result.try(case progress {
        Succeeded(output) -> check_output(output)
        Active | Uncertain(_) | Failed(_) | Cancelled -> Ok(Nil)
      })
      let updated = replace(scope, reference, Admitted(progress))
      case progress {
        Failed(_) | Cancelled -> Ok(close(updated, MemberFailed(reference)))
        Active | Uncertain(_) | Succeeded(_) -> Ok(updated)
      }
    }
  }
}

pub fn cancel(scope: Scope) -> Scope {
  close(scope, CancelledByCaller)
}

/// The owning runner verifies the absolute deadline against backend time.
/// This transition retains that decision and its cleanup obligation.
pub fn expire(scope: Scope, due: Int) -> Result(Scope, Rejection) {
  use _ <- result.try(check_deadline(due))
  Ok(close(scope, DeadlineElapsed(due)))
}

fn close(scope: Scope, cause: Cause) -> Scope {
  let saved = snapshot(scope)
  case saved.stop {
    Some(_) -> scope
    None ->
      Scope(
        Snapshot(
          ..saved,
          stop: Some(cause),
          members: list.map(saved.members, fn(member) {
            case member.status {
              Pending -> Member(..member, status: Withdrawn)
              Withdrawn | Rejected(_) | Reserved | Admitted(_) -> member
            }
          }),
        ),
      )
  }
}

/// Admitted children still needing observation (and cancellation after a stop).
/// Waiting for approval, a signal or reconciliation does not free a slot.
pub fn unsettled(scope: Scope) -> List(Reference) {
  select(scope, fn(status) {
    case status {
      Reserved -> True
      Admitted(progress) -> !terminal(progress)
      Pending | Withdrawn | Rejected(_) -> False
    }
  })
}

/// Includes terminal children: a join must not erase their retention links.
pub fn owned(scope: Scope) -> List(Reference) {
  select(scope, fn(status) {
    case status {
      Reserved | Admitted(_) -> True
      Pending | Withdrawn | Rejected(_) -> False
    }
  })
}

fn uncertain(scope: Scope) -> List(Reference) {
  select(scope, fn(status) {
    case status {
      Admitted(Uncertain(_)) -> True
      Reserved
      | Pending
      | Withdrawn
      | Rejected(_)
      | Admitted(Active)
      | Admitted(Succeeded(_))
      | Admitted(Failed(_))
      | Admitted(Cancelled) -> False
    }
  })
}

pub fn join(scope: Scope) -> Join {
  let saved = snapshot(scope)
  case uncertain(scope), unsettled(scope) {
    [_, ..] as members, _ -> Unresolved(members)
    [], [_, ..] -> Waiting
    [], [] ->
      case saved.stop {
        Some(cause) -> Ready(Error(cause))
        None ->
          case
            list.try_map(saved.members, fn(member) {
              case member.status {
                Admitted(Succeeded(output)) -> Ok(output)
                Reserved
                | Pending
                | Withdrawn
                | Rejected(_)
                | Admitted(Active)
                | Admitted(Uncertain(_))
                | Admitted(Failed(_))
                | Admitted(Cancelled) -> Error(Nil)
              }
            })
          {
            Ok(outputs) -> Ready(Ok(outputs))
            Error(Nil) -> Waiting
          }
      }
  }
}

pub fn member(scope: Scope, reference: Reference) -> Result(Member, Rejection) {
  let saved = snapshot(scope)
  case reference.occurrence == saved.occurrence {
    False -> Error(WrongOccurrence)
    True ->
      case reference.member > 0 {
        False -> Error(UnknownMember)
        True ->
          saved.members
          |> list.drop(reference.member - 1)
          |> list.first
          |> result.map_error(fn(_) { UnknownMember })
      }
  }
}

fn replace(scope: Scope, reference: Reference, status: Status) -> Scope {
  let saved = snapshot(scope)
  Scope(
    Snapshot(
      ..saved,
      members: list.index_map(saved.members, fn(member, index) {
        case index + 1 == reference.member {
          True -> Member(..member, status: status)
          False -> member
        }
      }),
    ),
  )
}

fn select(scope: Scope, predicate: fn(Status) -> Bool) -> List(Reference) {
  let saved = snapshot(scope)
  saved.members
  |> list.index_map(fn(member, index) {
    #(Reference(saved.occurrence, index + 1), member.status)
  })
  |> list.filter_map(fn(item) {
    case predicate(item.1) {
      True -> Ok(item.0)
      False -> Error(Nil)
    }
  })
}

fn terminal(progress: Progress) -> Bool {
  case progress {
    Active | Uncertain(_) -> False
    Succeeded(_) | Failed(_) | Cancelled -> True
  }
}

fn check_deadline(due: Int) -> Result(Nil, Rejection) {
  case due >= 0 {
    True -> Ok(Nil)
    False -> Error(InvalidDeadline(due))
  }
}

fn check_output(output: String) -> Result(Nil, Rejection) {
  case valid_json(output) {
    True -> Ok(Nil)
    False -> Error(InvalidOutput)
  }
}

fn valid_json(encoded: String) -> Bool {
  json.parse(encoded, decode.dynamic) |> result.is_ok
}

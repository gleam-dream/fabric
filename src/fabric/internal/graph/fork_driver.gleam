//// Deployed typed bindings for a retained fork. The scope and its child
//// reservations live in graph records; these callbacks are never serialized.

import fabric/graph/child
import fabric/graph/fork
import fabric/internal/graph/child_driver
import fabric/internal/graph/fork as scope
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/result
import gleam/string

pub type Driver {
  Driver(
    stores: fn() -> List(Result(Pid, Nil)),
    prepare: fn(String) -> Result(List(fork.Request), String),
    member: fn(Int) -> Result(child_driver.Driver, String),
    check: fn(Int, fork.Request) -> Result(Nil, String),
    output: fn(Result(List(String), fork.Failure)) -> Result(String, String),
  )
}

/// The parent retains its member's progress, not copies of descendant scopes.
pub fn progress(progress: child.Progress) -> fork.Progress {
  case progress {
    child.Working
    | child.Approval(_)
    | child.AgentInput(..)
    | child.Signal(_)
    | child.Job(_) -> fork.Active
    child.Fork(saved) ->
      case
        list.any(saved.members, fn(member) {
          case member.status {
            fork.Admitted(fork.Uncertain(_)) -> True
            _ -> False
          }
        })
      {
        True -> fork.Uncertain("nested fork requires reconciliation")
        False -> fork.Active
      }
    child.Uncertain(reason) | child.FinishedUncertain(reason) ->
      fork.Uncertain(reason)
    child.InvalidOutput(output, reason) ->
      fork.Uncertain(reason <> ": " <> output)
    child.Succeeded(output) -> fork.Succeeded(output)
    child.Failed(reason) -> fork.Failed(reason)
    child.Cancelled(False) -> fork.Cancelled
    child.Cancelled(True) ->
      fork.Uncertain("child cancellation retains uncertain effects")
  }
}

/// Joining and validating retained joins use the same ordered child evidence.
/// This callback contains codecs only, never a descendant runtime.
pub fn encode_join(
  saved: fork.Snapshot,
  encode: fn(Result(List(String), fork.Failure)) -> Result(String, String),
) -> Result(String, String) {
  use members <- result.try(
    scope.restore(saved) |> result.map_error(string.inspect),
  )
  use outcome <- result.try(case scope.join(members) {
    scope.Ready(Ok(outputs)) -> Ok(Ok(outputs))
    scope.Ready(Error(fork.MemberFailed(ref))) -> {
      use failed <- result.try(
        scope.member(members, ref) |> result.map_error(string.inspect),
      )
      use reason <- result.map(case failed.status {
        fork.Rejected(reason) | fork.Admitted(fork.Failed(reason)) -> Ok(reason)
        fork.Admitted(fork.Cancelled) -> Ok("child was cancelled")
        _ -> Error("invalid failed member")
      })
      Error(fork.Failure(ref.member, reason))
    }
    _ -> Error("fork has no settled business result")
  })
  encode(outcome)
}

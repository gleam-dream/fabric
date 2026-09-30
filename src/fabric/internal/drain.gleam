//// Diagnostic evidence for one factory's shutdown. Handoff confirmation and
//// process exit are independent: a confirmed runner can still be force killed.

import fabric/observation
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/option.{type Option, None, Some}

pub opaque type Accounting {
  Accounting(members: Dict(Pid, Member), draining: Option(#(Pid, Int)))
}

type Member {
  Member(factory: Pid, handoff: Handoff, exit: Option(Exit))
}

pub type Handoff {
  NotAttempted
  Pending
  Confirmed
  Failed
}

pub type Exit {
  Killed
  Exited
}

pub fn new() -> Accounting {
  Accounting(dict.new(), None)
}

pub fn track(state: Accounting, factory: Pid, runner: Pid) -> Accounting {
  case dict.has_key(state.members, runner) {
    True -> state
    False ->
      Accounting(
        ..state,
        members: dict.insert(
          state.members,
          runner,
          Member(factory, NotAttempted, None),
        ),
      )
  }
}

pub fn begin(state: Accounting, factory: Pid, now: Int) -> Accounting {
  case state.draining {
    Some(#(current, _)) if current == factory -> state
    _ ->
      Accounting(
        draining: Some(#(factory, now)),
        members: dict.filter(state.members, fn(_, member) {
          member.factory == factory
        }),
      )
  }
}

pub fn handoff(
  state: Accounting,
  runner: Pid,
  evidence: Handoff,
) -> Accounting {
  case dict.get(state.members, runner) {
    Error(Nil) -> state
    Ok(Member(handoff: Confirmed, ..)) -> state
    Ok(member) ->
      Accounting(
        ..state,
        members: dict.insert(
          state.members,
          runner,
          Member(..member, handoff: evidence),
        ),
      )
  }
}

pub fn exited(state: Accounting, runner: Pid, exit: Exit) -> Accounting {
  case dict.get(state.members, runner), state.draining {
    Ok(member), Some(#(factory, _)) if member.factory == factory ->
      Accounting(
        ..state,
        members: dict.insert(
          state.members,
          runner,
          Member(..member, exit: Some(exit)),
        ),
      )
    _, _ -> Accounting(..state, members: dict.delete(state.members, runner))
  }
}

pub fn report(state: Accounting, now: Int) -> Option(observation.Drain) {
  use #(factory, started) <- option.map(state.draining)
  dict.fold(
    state.members,
    observation.Drain(0, 0, 0, 0, 0, 0, 0, int.max(0, now - started)),
    fn(summary, _, member) {
      case member.factory == factory {
        False -> summary
        True -> {
          let summary =
            observation.Drain(..summary, runners: summary.runners + 1)
          let summary = case member.handoff {
            NotAttempted -> summary
            Pending ->
              observation.Drain(
                ..summary,
                pending_handoffs: summary.pending_handoffs + 1,
              )
            Confirmed ->
              observation.Drain(..summary, handed_off: summary.handed_off + 1)
            Failed ->
              observation.Drain(
                ..summary,
                failed_handoffs: summary.failed_handoffs + 1,
              )
          }
          case member.exit {
            None ->
              observation.Drain(..summary, unobserved: summary.unobserved + 1)
            Some(Killed) ->
              observation.Drain(..summary, killed: summary.killed + 1)
            Some(Exited) ->
              observation.Drain(..summary, exited: summary.exited + 1)
          }
        }
      }
    },
  )
}

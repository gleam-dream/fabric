//// Runs typed bodies for one runner: one linked task per identity, at most
//// `max_in_flight` at a time, first in first out across every batch the run
//// dispatches.
////
//// Ownership: the executor is linked to its runner and traps exits. When the
//// runner exits for any reason, the executor kills its tasks and exits. Each
//// task is linked to the executor, so an executor crash kills its tasks.
////
//// A task calls `fence` before running a body; the body runs only if the
//// runner committed the action as running. Crashes inside the body are
//// contained and reported separately from returned values. Each job carries
//// its own body, bound to its invocation's context, so one executor can run
//// jobs of the same run with different contexts.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/string

pub type Report(identity, outcome) {
  Reported(identity, outcome)
  /// A body raised after passing its start fence. The owning controller must
  /// classify the possible effect; this is never a successful typed result.
  Crashed(identity, reason: String)
  /// A task died without reporting.
  Lost(identity, reason: String)
  /// Every task is dead after a stop; nothing more will be reported.
  Stopped
}

pub type Hooks(identity, outcome) {
  Hooks(
    max_in_flight: Int,
    /// Called by a task before its body; `False` means do not run.
    fence: fn(identity) -> Bool,
    report: fn(Report(identity, outcome)) -> Nil,
  )
}

/// An invocation and its body, bound to the context it runs with.
pub type Job(identity, outcome) {
  Job(id: identity, body: fn() -> outcome)
}

pub opaque type Executor(identity, outcome) {
  Executor(pid: Pid, subject: Subject(Message(identity, outcome)))
}

type Message(identity, outcome) {
  Submit(List(Job(identity, outcome)))
  Stop
  Done(identity, Result(outcome, String))
  Exited(Pid, process.ExitReason)
}

type Loop(identity, outcome) {
  Loop(
    hooks: Hooks(identity, outcome),
    parent: Pid,
    self: Subject(Message(identity, outcome)),
    queue: List(Job(identity, outcome)),
    running: Dict(Pid, identity),
    reported: List(identity),
  )
}

/// Starts an executor linked to the calling process (the runner).
pub fn start(hooks: Hooks(identity, outcome)) -> Executor(identity, outcome) {
  let parent = process.self()
  let ready = process.new_subject()
  let pid =
    process.spawn(fn() {
      process.trap_exits(True)
      let self = process.new_subject()
      process.send(ready, self)
      serve(Loop(hooks, parent, self, [], dict.new(), []))
    })
  Executor(pid, process.receive_forever(ready))
}

pub fn pid(executor: Executor(identity, outcome)) -> Pid {
  executor.pid
}

pub fn submit(
  executor: Executor(identity, outcome),
  jobs: List(Job(identity, outcome)),
) -> Nil {
  process.send(executor.subject, Submit(jobs))
}

/// Kills every task, reports whatever finished first, then `Stopped`.
pub fn stop(executor: Executor(identity, outcome)) -> Nil {
  process.send(executor.subject, Stop)
}

fn selector(
  self: Subject(Message(identity, outcome)),
) -> process.Selector(Message(identity, outcome)) {
  process.new_selector()
  |> process.select(self)
  |> process.select_trapped_exits(fn(exit) { Exited(exit.pid, exit.reason) })
}

fn serve(state: Loop(identity, outcome)) -> Nil {
  let state = fill(state)
  case process.selector_receive_forever(selector(state.self)) {
    Submit(actions) ->
      serve(Loop(..state, queue: list.append(state.queue, actions)))
    Done(id, outcome) -> {
      report(state.hooks, id, outcome)
      serve(Loop(..state, reported: [id, ..state.reported]))
    }
    Exited(pid, _) if pid == state.parent -> kill_all(state)
    Exited(pid, reason) -> serve(task_exited(state, pid, reason))
    Stop -> {
      kill_all(state)
      drain(Loop(..state, queue: []))
    }
  }
}

fn task_exited(
  state: Loop(identity, outcome),
  pid: Pid,
  reason: process.ExitReason,
) -> Loop(identity, outcome) {
  case dict.get(state.running, pid) {
    Error(Nil) -> state
    Ok(id) -> {
      case list.contains(state.reported, id), reason {
        True, _ | False, process.Normal -> Nil
        False, _ -> state.hooks.report(Lost(id, string.inspect(reason)))
      }
      Loop(
        ..state,
        running: dict.delete(state.running, pid),
        reported: list.filter(state.reported, fn(r) { r != id }),
      )
    }
  }
}

fn kill_all(state: Loop(identity, outcome)) -> Nil {
  dict.each(state.running, fn(pid, _) { process.kill(pid) })
}

/// After a stop: forward reports that were sent before a task died, then
/// confirm once every task is gone.
fn drain(state: Loop(identity, outcome)) -> Nil {
  case dict.is_empty(state.running) {
    True -> state.hooks.report(Stopped)
    False ->
      case process.selector_receive_forever(selector(state.self)) {
        Done(id, outcome) -> {
          report(state.hooks, id, outcome)
          drain(Loop(..state, reported: [id, ..state.reported]))
        }
        Exited(pid, _) if pid == state.parent -> Nil
        Exited(pid, _) ->
          drain(Loop(..state, running: dict.delete(state.running, pid)))
        Submit(_) | Stop -> drain(state)
      }
  }
}

fn fill(state: Loop(identity, outcome)) -> Loop(identity, outcome) {
  case state.queue, dict.size(state.running) < state.hooks.max_in_flight {
    [Job(id, body), ..rest], True -> {
      let hooks = state.hooks
      let self = state.self
      let pid =
        process.spawn(fn() {
          case hooks.fence(id) {
            False -> Nil
            True -> process.send(self, Done(id, rescue(body)))
          }
        })
      fill(
        Loop(..state, queue: rest, running: dict.insert(state.running, pid, id)),
      )
    }
    _, _ -> state
  }
}

fn report(
  hooks: Hooks(identity, outcome),
  id: identity,
  outcome: Result(outcome, String),
) -> Nil {
  case outcome {
    Ok(value) -> hooks.report(Reported(id, value))
    Error(crash) -> hooks.report(Crashed(id, crash))
  }
}

@external(erlang, "fabric_ffi", "rescue")
pub fn rescue(body: fn() -> a) -> Result(a, String)

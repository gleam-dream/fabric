//// Shared supervised runner startup. A caller commits the first state before
//// releasing the prepared process. Startup can be abandoned during shutdown
//// without deadlocking a parent that is itself one of the factory's runners.

import fabric/internal/claim
import fabric/store.{type Store}
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/result

pub fn prepare(
  runs: Store,
  begin: fn(
    Store,
    #(Pid, Pid, Pid),
    Subject(#(Subject(message), Subject(initial))),
  ) -> Nil,
  abandon: initial,
) -> Result(#(Pid, Subject(message), Subject(initial)), Nil) {
  use #(pinned, factory, factory_pid) <- result.try(store.runners(runs))
  use store_pid <- result.try(store.pid(pinned))
  let caller = process.self()
  let answer = process.new_subject()
  let wanted = claim.new()
  process.spawn_unlinked(fn() {
    let ready = process.new_subject()
    let started = case
      store.start_runner(factory, fn(parent) {
        process.spawn(fn() {
          begin(pinned, #(store_pid, parent, caller), ready)
        })
      })
    {
      Error(Nil) -> Error(Nil)
      Ok(pid) -> {
        let monitor = process.monitor(pid)
        let started =
          process.new_selector()
          |> process.select_map(ready, fn(ready) {
            let #(mailbox, go) = ready
            Ok(#(pid, mailbox, go))
          })
          |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
          |> process.selector_receive_forever
        process.demonitor_process(monitor)
        started
      }
    }
    case claim.accept(wanted), started {
      True, _ -> process.send(answer, started)
      False, Ok(#(_, _, go)) -> process.send(go, abandon)
      False, Error(Nil) -> Nil
    }
  })
  await_start(answer, wanted, pinned, factory_pid)
}

/// Waits for the helper's `answer`. The start is given up (`Error`) when
/// the caller, a runner of the factory, receives the factory's shutdown,
/// which is put back for the caller's receive loop; or when the store's
/// process reports that its runners drain (checked every 100 ms), since a
/// start that reached the factory after it began stopping waits for the
/// factory, which may wait for the caller: a tool body of one of its
/// runners, say.
fn await_start(
  answer: Subject(Result(a, Nil)),
  wanted: claim.Claim,
  pinned: Store,
  factory_pid: Pid,
) -> Result(a, Nil) {
  let give_up = fn() {
    case claim.withdraw(wanted) {
      True -> {
        store.draining(pinned, factory_pid)
        Error(Nil)
      }
      // The helper answered first: its answer is on the way.
      False -> process.receive_forever(answer)
    }
  }
  case await_or_shutdown(answer, factory_pid, 100) {
    Answered(started) -> started
    ShutDown -> {
      requeue_shutdown(factory_pid)
      give_up()
    }
    StillWaiting ->
      case store.runners(pinned) {
        Ok(_) -> await_start(answer, wanted, pinned, factory_pid)
        Error(Nil) -> give_up()
      }
  }
}

type Awaited(a) {
  Answered(a)
  ShutDown
  StillWaiting
}

/// Receives from `answer`, or the caller's own trapped exit signal
/// `shutdown` from `factory`, whichever comes first within `timeout` ms;
/// any other message stays queued.
@external(erlang, "fabric_ffi", "await_or_shutdown")
fn await_or_shutdown(
  answer: Subject(a),
  factory: Pid,
  timeout: Int,
) -> Awaited(a)

/// Queues the exit signal `shutdown` from `factory` to the caller again, as
/// the message its receive loop takes.
@external(erlang, "fabric_ffi", "requeue_shutdown")
fn requeue_shutdown(factory: Pid) -> Nil

/// What a runner waiting for its first state receives.
type Before(initial) {
  First(initial)
  OwnerGone
  ExitSignal(process.ExitMessage)
}

/// Waits for the first state, and whether a shutdown arrived meanwhile.
/// `Error` when the store or the caller goes first, or the factory stops
/// otherwise than by a shutdown.
pub fn first_state(
  go: Subject(initial),
  pinned: Store,
  factory: Pid,
  draining: Bool,
) -> Result(#(initial, Bool), Nil) {
  let received =
    process.new_selector()
    |> process.select_map(go, First)
    |> process.select_monitors(fn(_) { OwnerGone })
    |> process.select_trapped_exits(ExitSignal)
    |> process.selector_receive_forever
  case received {
    First(first) -> Ok(#(first, draining))
    OwnerGone -> Error(Nil)
    ExitSignal(exit) ->
      case exit.pid == factory && is_shutdown(exit.reason) {
        True -> {
          store.draining(pinned, factory)
          first_state(go, pinned, factory, True)
        }
        False -> Error(Nil)
      }
  }
}

pub fn is_shutdown(reason: process.ExitReason) -> Bool {
  case reason {
    process.Abnormal(reason) ->
      reason == atom.to_dynamic(atom.create("shutdown"))
    process.Normal | process.Killed -> False
  }
}

@external(erlang, "fabric_ffi", "take_shutdown")
pub fn take_shutdown(factory: Pid) -> Bool

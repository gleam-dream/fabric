//// A store backend that keeps records in memory and fails writes on
//// demand: before writing (the write did not happen) or after writing (the
//// write happened but the caller is told it is unavailable).

import fabric/store.{type Store}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Fault {
  Pass
  /// Reports `Unavailable` without writing.
  FailBefore
  /// Writes, then reports `Unavailable`.
  FailAfter
}

type Message {
  Get(String, Subject(Result(store.Stored, store.StoreError)))
  Write(String, Option(Int), String, Subject(Result(Nil, store.StoreError)))
  Arm(List(Fault))
  ArmRun(String, List(Fault))
}

pub opaque type Flaky {
  Flaky(subject: Subject(Message))
}

pub fn new() -> Flaky {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    process.send(ready, subject)
    loop(subject, dict.new(), [], dict.new())
  })
  let assert Ok(subject) = process.receive(ready, 1000)
  Flaky(subject)
}

/// The next writes meet `faults`, in order; later writes pass.
pub fn arm(flaky: Flaky, faults: List(Fault)) -> Nil {
  process.send(flaky.subject, Arm(faults))
}

/// The next writes of `run` meet `faults`, in order, before any faults
/// armed for every run; later writes of `run` pass.
pub fn arm_run(flaky: Flaky, run: String, faults: List(Fault)) -> Nil {
  process.send(flaky.subject, ArmRun(run, faults))
}

pub fn store(flaky: Flaky) -> Store {
  let subject = flaky.subject
  store.new(
    get: fn(run) { process.call_forever(subject, Get(run, _)) },
    insert: fn(run, record) {
      process.call_forever(subject, Write(run, None, record, _))
    },
    compare_and_set: fn(run, expected, record) {
      process.call_forever(subject, Write(run, Some(expected), record, _))
    },
  )
}

fn loop(
  subject: Subject(Message),
  records: Dict(String, store.Stored),
  faults: List(Fault),
  by_run: Dict(String, List(Fault)),
) -> Nil {
  case process.receive_forever(subject) {
    Arm(faults) -> loop(subject, records, faults, by_run)
    ArmRun(run, run_faults) ->
      loop(subject, records, faults, dict.insert(by_run, run, run_faults))
    Get(run, reply) -> {
      process.send(
        reply,
        dict.get(records, run) |> result.replace_error(store.NotFound),
      )
      loop(subject, records, faults, by_run)
    }
    Write(run, expected, record, reply) -> {
      let #(fault, faults, by_run) = case dict.get(by_run, run), faults {
        Ok([fault, ..rest]), _ -> #(
          fault,
          faults,
          dict.insert(by_run, run, rest),
        )
        _, [] -> #(Pass, [], by_run)
        _, [fault, ..rest] -> #(fault, rest, by_run)
      }
      let outcome = case expected, dict.get(records, run) {
        None, Ok(_) -> Error(store.AlreadyExists)
        None, Error(Nil) -> Ok(store.Stored(1, record))
        Some(_), Error(Nil) -> Error(store.NotFound)
        Some(expected), Ok(current) if current.revision == expected ->
          Ok(store.Stored(expected + 1, record))
        Some(_), Ok(current) -> Error(store.Conflict(current.revision))
      }
      let unavailable = Error(store.Unavailable("the backend blinked"))
      let #(reply_with, records) = case fault, outcome {
        FailBefore, _ -> #(unavailable, records)
        FailAfter, Ok(stored) -> #(
          unavailable,
          dict.insert(records, run, stored),
        )
        _, Ok(stored) -> #(Ok(Nil), dict.insert(records, run, stored))
        _, Error(error) -> #(Error(error), records)
      }
      process.send(reply, reply_with)
      loop(subject, records, faults, by_run)
    }
  }
}

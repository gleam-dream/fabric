//// A store backend that keeps records in memory and fails writes on
//// demand: before writing (the write did not happen) or after writing (the
//// write happened but the caller is told it is unavailable). It can also
//// hold one write until the test releases it, while serving every other
//// request, to order a write after a concurrent one.

import fabric/internal/record
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
  /// Reports `Unavailable` without writing, and writes just before the
  /// run's next write: a write that lands after its caller, and a read
  /// back, found it missing.
  FailLate
  /// Another writer inserted the same record first, with its own write
  /// token: an insert finds it and reports `AlreadyExists`.
  StoredByAnother
}

type Message {
  Get(String, Subject(Result(store.Stored, store.StoreError)))
  Write(String, Option(Int), String, Subject(Result(Nil, store.StoreError)))
  Arm(List(Fault))
  ArmWhere(fn(String) -> Bool, List(Fault))
  Hold(fn(String) -> Bool, Subject(String))
  ReleaseHeld
  DropHeld
}

type Held {
  Holding(matches: fn(String) -> Bool, notify: Subject(String))
  HeldWrite(
    run: String,
    expected: Option(Int),
    record: String,
    reply: Subject(Result(Nil, store.StoreError)),
  )
  NotHolding
}

pub opaque type Flaky {
  Flaky(subject: Subject(Message))
}

pub fn new() -> Flaky {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    process.send(ready, subject)
    loop(
      subject,
      State(dict.new(), [], #(fn(_) { False }, []), NotHolding, dict.new()),
    )
  })
  let assert Ok(subject) = process.receive(ready, 1000)
  Flaky(subject)
}

/// The next writes meet `faults`, in order; later writes pass.
pub fn arm(flaky: Flaky, faults: List(Fault)) -> Nil {
  process.send(flaky.subject, Arm(faults))
}

/// Holds the next write of a run that `matches`, without answering it,
/// until `release_held`; every other request is served meanwhile. The
/// returned subject receives the held write's run id.
pub fn hold(flaky: Flaky, matches: fn(String) -> Bool) -> Subject(String) {
  let held = process.new_subject()
  process.send(flaky.subject, Hold(matches, held))
  held
}

/// Performs the held write against the records as they are now, and
/// answers it.
pub fn release_held(flaky: Flaky) -> Nil {
  process.send(flaky.subject, ReleaseHeld)
}

/// Answers the held write `Unavailable` without performing it.
pub fn drop_held(flaky: Flaky) -> Nil {
  process.send(flaky.subject, DropHeld)
}

/// The next writes of `run` meet `faults`, in order, before any faults
/// armed for every run; later writes of `run` pass.
pub fn arm_run(flaky: Flaky, run: String, faults: List(Fault)) -> Nil {
  arm_where(flaky, fn(written) { written == run }, faults)
}

/// The next writes of runs that `matches` meet `faults`, in order, before
/// any faults armed for every run. Arming again replaces this.
pub fn arm_where(
  flaky: Flaky,
  matches: fn(String) -> Bool,
  faults: List(Fault),
) -> Nil {
  process.send(flaky.subject, ArmWhere(matches, faults))
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

type State {
  State(
    records: Dict(String, store.Stored),
    faults: List(Fault),
    targeted: #(fn(String) -> Bool, List(Fault)),
    held: Held,
    /// Writes that land before the next write of their run.
    late: Dict(String, store.Stored),
  )
}

fn loop(subject: Subject(Message), state: State) -> Nil {
  case process.receive_forever(subject) {
    Arm(faults) -> loop(subject, State(..state, faults:))
    ArmWhere(matches, targeted) ->
      loop(subject, State(..state, targeted: #(matches, targeted)))
    Hold(matches, notify) ->
      loop(subject, State(..state, held: Holding(matches, notify)))
    ReleaseHeld ->
      case state.held {
        HeldWrite(run, expected, record, reply) ->
          loop(
            subject,
            write(
              State(..state, held: NotHolding),
              run,
              expected,
              record,
              reply,
            ),
          )
        _ -> loop(subject, state)
      }
    DropHeld ->
      case state.held {
        HeldWrite(reply:, ..) -> {
          process.send(reply, Error(store.Unavailable("the write was lost")))
          loop(subject, State(..state, held: NotHolding))
        }
        _ -> loop(subject, state)
      }
    Get(run, reply) -> {
      process.send(
        reply,
        dict.get(state.records, run) |> result.replace_error(store.NotFound),
      )
      loop(subject, state)
    }
    Write(run, expected, record, reply) -> {
      let state = land(state, run)
      case state.held {
        Holding(matches, notify) ->
          case matches(run) {
            True -> {
              process.send(notify, run)
              loop(
                subject,
                State(..state, held: HeldWrite(run, expected, record, reply)),
              )
            }
            False -> loop(subject, write(state, run, expected, record, reply))
          }
        _ -> loop(subject, write(state, run, expected, record, reply))
      }
    }
  }
}

/// Performs the write of `run` that is landing late, if any.
fn land(state: State, run: String) -> State {
  case dict.get(state.late, run) {
    Ok(stored) ->
      State(
        ..state,
        records: dict.insert(state.records, run, stored),
        late: dict.delete(state.late, run),
      )
    Error(Nil) -> state
  }
}

fn write(
  state: State,
  run: String,
  expected: Option(Int),
  record: String,
  reply: Subject(Result(Nil, store.StoreError)),
) -> State {
  let State(records:, faults:, targeted:, ..) = state
  let #(matches, aimed) = targeted
  let #(fault, faults, targeted) = case matches(run), aimed, faults {
    True, [fault, ..rest], _ -> #(fault, faults, #(matches, rest))
    _, _, [] -> #(Pass, [], targeted)
    _, _, [fault, ..rest] -> #(fault, rest, targeted)
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
  let #(reply_with, records, late) = case fault, outcome {
    FailBefore, _ -> #(unavailable, records, state.late)
    FailAfter, Ok(stored) -> #(
      unavailable,
      dict.insert(records, run, stored),
      state.late,
    )
    FailLate, Ok(stored) -> #(
      unavailable,
      records,
      dict.insert(state.late, run, stored),
    )
    StoredByAnother, Ok(store.Stored(revision, written)) -> {
      let assert Ok(decoded) = record.decode(written)
      #(
        Error(store.AlreadyExists),
        dict.insert(
          records,
          run,
          store.Stored(revision, record.encode(decoded)),
        ),
        state.late,
      )
    }
    _, Ok(stored) -> #(Ok(Nil), dict.insert(records, run, stored), state.late)
    _, Error(error) -> #(Error(error), records, state.late)
  }
  process.send(reply, reply_with)
  State(..state, records:, faults:, targeted:, late:)
}

//// A store backend that keeps records in memory, counts the writes it
//// performs, and on request tells the test about the next read.

import fabric/store.{type Store}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/result

type Message {
  Get(String, Subject(Result(store.Stored, store.StoreError)))
  Write(String, Option(Int), String, Subject(Result(Nil, store.StoreError)))
  Writes(Subject(Int))
  NotifyRead(Subject(String))
}

pub opaque type Watched {
  Watched(subject: Subject(Message))
}

type State {
  State(
    records: Dict(String, store.Stored),
    writes: Int,
    notify: Option(Subject(String)),
  )
}

pub fn new() -> Watched {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    process.send(ready, subject)
    loop(subject, State(dict.new(), 0, None))
  })
  let assert Ok(subject) = process.receive(ready, 1000)
  Watched(subject)
}

pub fn store(watched: Watched) -> Store {
  let subject = watched.subject
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

/// How many writes were performed.
pub fn writes(watched: Watched) -> Int {
  process.call_forever(watched.subject, Writes)
}

/// The returned subject receives the run id of the next read.
pub fn notify_reads(watched: Watched) -> Subject(String) {
  let reads = process.new_subject()
  process.send(watched.subject, NotifyRead(reads))
  reads
}

fn loop(subject: Subject(Message), state: State) -> Nil {
  case process.receive_forever(subject) {
    Writes(reply) -> {
      process.send(reply, state.writes)
      loop(subject, state)
    }
    NotifyRead(reads) -> loop(subject, State(..state, notify: Some(reads)))
    Get(run, reply) -> {
      process.send(
        reply,
        dict.get(state.records, run) |> result.replace_error(store.NotFound),
      )
      case state.notify {
        Some(reads) -> process.send(reads, run)
        None -> Nil
      }
      loop(subject, State(..state, notify: None))
    }
    Write(run, expected, record, reply) -> {
      let outcome = case expected, dict.get(state.records, run) {
        None, Ok(_) -> Error(store.AlreadyExists)
        None, Error(Nil) -> Ok(store.Stored(1, record))
        Some(_), Error(Nil) -> Error(store.NotFound)
        Some(expected), Ok(current) if current.revision == expected ->
          Ok(store.Stored(expected + 1, record))
        Some(_), Ok(current) -> Error(store.Conflict(current.revision))
      }
      case outcome {
        Ok(stored) -> {
          process.send(reply, Ok(Nil))
          loop(
            subject,
            State(
              ..state,
              records: dict.insert(state.records, run, stored),
              writes: state.writes + 1,
            ),
          )
        }
        Error(error) -> {
          process.send(reply, Error(error))
          loop(subject, state)
        }
      }
    }
  }
}

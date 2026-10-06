//// In-memory CAS store for the workflow composition experiment.
//// JSON records retain a revision per key. The store process survives a
//// runtime-process crash, allowing restart probes within the same VM.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}

pub type Revision =
  Int

pub type StoreError {
  NotFound
  AlreadyExists
  /// The caller's expected revision is not the current one.
  Conflict(current: Revision)
}

pub opaque type Store {
  Store(subject: Subject(Request))
}

type Request {
  Get(key: String, reply: Subject(Result(#(Revision, String), StoreError)))
  Insert(
    key: String,
    record: String,
    reply: Subject(Result(Revision, StoreError)),
  )
  CompareAndSet(
    key: String,
    expected: Revision,
    record: String,
    reply: Subject(Result(Revision, StoreError)),
  )
}

/// Starts an unlinked store process. It lives until the VM stops.
pub fn start() -> Store {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    process.send(ready, subject)
    loop(subject, dict.new())
  })
  let assert Ok(subject) = process.receive(ready, 1000)
  Store(subject)
}

pub fn get(
  store: Store,
  key: String,
) -> Result(#(Revision, String), StoreError) {
  process.call(store.subject, 1000, Get(key, _))
}

pub fn insert(
  store: Store,
  key: String,
  record: String,
) -> Result(Revision, StoreError) {
  process.call(store.subject, 1000, Insert(key, record, _))
}

pub fn compare_and_set(
  store: Store,
  key: String,
  expected: Revision,
  record: String,
) -> Result(Revision, StoreError) {
  process.call(store.subject, 1000, CompareAndSet(key, expected, record, _))
}

fn loop(subject: Subject(Request), records: Dict(String, #(Revision, String))) {
  case process.receive_forever(subject) {
    Get(key, reply) -> {
      process.send(reply, case dict.get(records, key) {
        Ok(entry) -> Ok(entry)
        Error(Nil) -> Error(NotFound)
      })
      loop(subject, records)
    }
    Insert(key, record, reply) ->
      case dict.has_key(records, key) {
        True -> {
          process.send(reply, Error(AlreadyExists))
          loop(subject, records)
        }
        False -> {
          process.send(reply, Ok(1))
          loop(subject, dict.insert(records, key, #(1, record)))
        }
      }
    CompareAndSet(key, expected, record, reply) ->
      case dict.get(records, key) {
        Error(Nil) -> {
          process.send(reply, Error(NotFound))
          loop(subject, records)
        }
        Ok(#(current, _)) if current != expected -> {
          process.send(reply, Error(Conflict(current)))
          loop(subject, records)
        }
        Ok(#(current, _)) -> {
          process.send(reply, Ok(current + 1))
          loop(subject, dict.insert(records, key, #(current + 1, record)))
        }
      }
  }
}

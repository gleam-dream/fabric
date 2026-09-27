//// The run store port and its in-memory implementation.
////
//// One record per run, with a revision. Every write is either an insert of
//// a new run or a compare-and-set against the revision the writer read, so
//// two owners can never both advance the same revision. The store also
//// remembers which live runner (if any) currently drives a run, and tells
//// watchers about every commit.
////
//// The store process is linked to the process that started it and dies with
//// it. It never traps exits.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type Revision =
  Int

pub type StoreError {
  NotFound
  AlreadyExists
  /// The writer's expected revision is no longer current.
  Conflict(current: Revision)
  /// The store process is gone.
  Unavailable
}

pub type Entry(record, live) {
  Entry(revision: Revision, record: record, live: Option(live))
}

pub type Committed(record) {
  Committed(revision: Revision, record: record)
}

pub opaque type Store(record, live) {
  Store(pid: Pid, subject: Subject(Request(record, live)))
}

type Request(record, live) {
  Get(run: String, reply: Subject(Result(Entry(record, live), StoreError)))
  Insert(
    run: String,
    record: record,
    reply: Subject(Result(Revision, StoreError)),
  )
  CompareAndSet(
    run: String,
    expected: Revision,
    record: record,
    release: Bool,
    reply: Subject(Result(Revision, StoreError)),
  )
  Attach(run: String, pid: Pid, live: live, reply: Subject(Nil))
  Watch(run: String, watcher: Subject(Committed(record)), reply: Subject(Nil))
  Unwatch(run: String, watcher: Subject(Committed(record)))
  RunnerDown(pid: Pid)
}

type Slot(record, live) {
  Slot(
    revision: Revision,
    record: record,
    live: Option(#(Pid, live)),
    watchers: List(Subject(Committed(record))),
  )
}

type Loop(record, live) {
  Loop(
    subject: Subject(Request(record, live)),
    slots: Dict(String, Slot(record, live)),
    monitors: Dict(Pid, Monitor),
  )
}

/// Starts an in-memory store linked to the calling process.
pub fn start() -> Store(record, live) {
  let ready = process.new_subject()
  let pid =
    process.spawn(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      serve(Loop(subject, dict.new(), dict.new()))
    })
  let assert Ok(subject) = process.receive(ready, 5000)
    as "the store process did not start"
  Store(pid, subject)
}

pub fn pid(store: Store(record, live)) -> Pid {
  store.pid
}

pub fn get(
  store: Store(record, live),
  run: String,
) -> Result(Entry(record, live), StoreError) {
  call(store, Get(run, _)) |> result.flatten
}

pub fn insert(
  store: Store(record, live),
  run: String,
  record: record,
) -> Result(Revision, StoreError) {
  call(store, Insert(run, record, _)) |> result.flatten
}

/// Commits `record` if `expected` is still the current revision. With
/// `release`, the committing runner also gives up the run in the same step,
/// so a watcher woken by this commit already sees no live runner.
pub fn compare_and_set(
  store: Store(record, live),
  run: String,
  expected: Revision,
  record: record,
  release release: Bool,
) -> Result(Revision, StoreError) {
  call(store, CompareAndSet(run, expected, record, release, _))
  |> result.flatten
}

/// Records `live` as the runner driving `run` until `pid` exits.
pub fn attach(
  store: Store(record, live),
  run: String,
  pid: Pid,
  live: live,
) -> Result(Nil, StoreError) {
  call(store, Attach(run, pid, live, _))
}

/// Sends every later commit of `run` to `watcher`.
pub fn watch(
  store: Store(record, live),
  run: String,
  watcher: Subject(Committed(record)),
) -> Result(Nil, StoreError) {
  call(store, Watch(run, watcher, _))
}

pub fn unwatch(
  store: Store(record, live),
  run: String,
  watcher: Subject(Committed(record)),
) -> Nil {
  process.send(store.subject, Unwatch(run, watcher))
}

fn call(
  store: Store(record, live),
  request: fn(Subject(reply)) -> Request(record, live),
) -> Result(reply, StoreError) {
  let reply = process.new_subject()
  let monitor = process.monitor(store.pid)
  process.send(store.subject, request(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_) { Error(Unavailable) })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  answer
}

fn serve(state: Loop(record, live)) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(state.subject)
    |> process.select_monitors(fn(down) {
      case down {
        process.ProcessDown(pid:, ..) -> RunnerDown(pid)
        process.PortDown(..) -> RunnerDown(process.self())
      }
    })
  case process.selector_receive_forever(selector) {
    Get(run, reply) -> {
      process.send(reply, case dict.get(state.slots, run) {
        Ok(slot) ->
          Ok(Entry(
            slot.revision,
            slot.record,
            option.map(slot.live, fn(l) { l.1 }),
          ))
        Error(Nil) -> Error(NotFound)
      })
      serve(state)
    }
    Insert(run, record, reply) ->
      case dict.has_key(state.slots, run) {
        True -> {
          process.send(reply, Error(AlreadyExists))
          serve(state)
        }
        False -> {
          process.send(reply, Ok(1))
          serve(put(state, run, Slot(1, record, None, [])))
        }
      }
    CompareAndSet(run, expected, record, release, reply) ->
      case dict.get(state.slots, run) {
        Error(Nil) -> {
          process.send(reply, Error(NotFound))
          serve(state)
        }
        Ok(slot) if slot.revision != expected -> {
          process.send(reply, Error(Conflict(slot.revision)))
          serve(state)
        }
        Ok(slot) -> {
          let revision = slot.revision + 1
          let live = case release {
            True -> None
            False -> slot.live
          }
          process.send(reply, Ok(revision))
          let state = put(state, run, Slot(..slot, revision:, record:, live:))
          list.each(slot.watchers, process.send(_, Committed(revision, record)))
          serve(state)
        }
      }
    Attach(run, pid, live, reply) -> {
      let state = case dict.get(state.slots, run) {
        Error(Nil) -> state
        Ok(slot) -> {
          let monitors = case dict.has_key(state.monitors, pid) {
            True -> state.monitors
            False -> dict.insert(state.monitors, pid, process.monitor(pid))
          }
          Loop(
            ..put(state, run, Slot(..slot, live: Some(#(pid, live)))),
            monitors:,
          )
        }
      }
      process.send(reply, Nil)
      serve(state)
    }
    Watch(run, watcher, reply) -> {
      let state = case dict.get(state.slots, run) {
        Error(Nil) -> state
        Ok(slot) ->
          put(state, run, Slot(..slot, watchers: [watcher, ..slot.watchers]))
      }
      process.send(reply, Nil)
      serve(state)
    }
    Unwatch(run, watcher) ->
      case dict.get(state.slots, run) {
        Error(Nil) -> serve(state)
        Ok(slot) ->
          serve(put(
            state,
            run,
            Slot(
              ..slot,
              watchers: list.filter(slot.watchers, fn(w) { w != watcher }),
            ),
          ))
      }
    RunnerDown(pid) -> {
      let slots =
        dict.map_values(state.slots, fn(_, slot) {
          case slot.live {
            Some(#(live_pid, _)) if live_pid == pid -> Slot(..slot, live: None)
            _ -> slot
          }
        })
      serve(Loop(..state, slots:, monitors: dict.delete(state.monitors, pid)))
    }
  }
}

fn put(
  state: Loop(record, live),
  run: String,
  slot: Slot(record, live),
) -> Loop(record, live) {
  Loop(..state, slots: dict.insert(state.slots, run, slot))
}

//// The leased backend kept in memory behind
//// `fabric/store/conformance.leased_memory`, with the clock it runs on as
//// a parameter, so that tests can also run it on a clock that stands still.

import fabric/run
import fabric/store/backend.{
  type Current, type Lease, type LeasedBackend, type StoreError, AlreadyExists,
  Claim, Conflict, Current, Free, Held, Hold, LeaseRefused, LeasedBackend,
  NotFound, Release, Seize,
}
import fabric/store/discovery
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A leased backend kept in memory by one process, and a clock that tests
/// can move forward.
pub type Memory {
  Memory(
    backend: LeasedBackend,
    /// Moves the backend's clock forward by this many milliseconds.
    advance: fn(Int) -> Nil,
  )
}

/// The backend on UTC system time, moved forward by `advance`.
pub fn system() -> Memory {
  new(system_time_ms)
}

/// The backend on a clock that stands still unless `advance` moves it: no
/// lease expires by the passing of time, so a test that must not depend on
/// how fast the machine runs moves the clock itself.
pub fn frozen() -> Memory {
  let start = system_time_ms()
  new(fn() { start })
}

type Row {
  Row(
    revision: Int,
    record: String,
    lease: Option(#(String, Int)),
    observed: Option(#(String, List(#(String, Option(Int))))),
    checked: Int,
  )
}

type LeasedRequest {
  LeasedClock(Subject(Int))
  LeasedGet(String, Subject(Result(Current, StoreError)))
  LeasedWrite(
    String,
    Option(Int),
    String,
    Lease,
    Subject(Result(Nil, StoreError)),
  )
  LeasedRenew(String, List(String), Int, Subject(List(String)))
  LeasedClaimExpired(String, Int, Int, Subject(List(String)))
  LeasedClaimReady(String, Int, Int, Subject(List(String)))
  Advance(Int, Subject(Nil))
}

fn new(clock: fn() -> Int) -> Memory {
  let ready = process.new_subject()
  let owner = process.self()
  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    let requests =
      process.new_selector()
      |> process.select_map(subject, Ok)
      |> process.select_specific_monitor(process.monitor(owner), fn(_) {
        Error(Nil)
      })
    process.send(ready, subject)
    leased_loop(requests, dict.new(), 0, clock)
  })
  let subject = process.receive_forever(ready)
  Memory(
    backend: LeasedBackend(
      now: fn() { Ok(process.call_forever(subject, LeasedClock)) },
      get: fn(run) { process.call_forever(subject, LeasedGet(run, _)) },
      insert: fn(run, record, lease) {
        process.call_forever(subject, LeasedWrite(run, None, record, lease, _))
      },
      compare_and_set: fn(run, expected, record, lease) {
        process.call_forever(subject, LeasedWrite(
          run,
          Some(expected),
          record,
          lease,
          _,
        ))
      },
      renew: fn(owner, runs, ttl) {
        Ok(process.call_forever(subject, LeasedRenew(owner, runs, ttl, _)))
      },
      claim_ready: fn(owner, ttl, limit) {
        Ok(
          process.call_forever(subject, LeasedClaimReady(owner, ttl, limit, _)),
        )
      },
      claim_expired: fn(owner, ttl, limit) {
        Ok(
          process.call_forever(subject, LeasedClaimExpired(owner, ttl, limit, _)),
        )
      },
    ),
    advance: fn(milliseconds) {
      process.call_forever(subject, Advance(milliseconds, _))
    },
  )
}

fn leased_loop(
  requests: process.Selector(Result(LeasedRequest, Nil)),
  rows: Dict(String, Row),
  offset: Int,
  clock: fn() -> Int,
) -> Nil {
  case process.selector_receive_forever(requests) {
    Error(Nil) -> Nil
    Ok(request) -> {
      let #(rows, offset) =
        leased_serve(request, rows, clock() + offset, offset)
      leased_loop(requests, rows, offset, clock)
    }
  }
}

/// Serves one request at the backend's time `now`.
fn leased_serve(
  request: LeasedRequest,
  rows: Dict(String, Row),
  now: Int,
  offset: Int,
) -> #(Dict(String, Row), Int) {
  let holder = fn(row: Row) {
    case row.lease {
      None -> Free
      Some(#(owner, until)) -> Held(owner, until > now)
    }
  }
  case request {
    LeasedClock(reply) -> {
      process.send(reply, now)
      #(rows, offset)
    }
    Advance(milliseconds, reply) -> {
      process.send(reply, Nil)
      #(rows, offset + milliseconds)
    }
    LeasedGet(run, reply) -> {
      process.send(reply, case dict.get(rows, run) {
        Ok(row) -> Ok(Current(row.revision, row.record, holder(row)))
        Error(Nil) -> Error(NotFound)
      })
      #(rows, offset)
    }
    LeasedWrite(run, expected, record, lease, reply) -> {
      let outcome = case expected, dict.get(rows, run) {
        None, Ok(_) -> Error(AlreadyExists)
        None, Error(Nil) ->
          Ok(Row(
            1,
            record,
            case lease {
              Claim(owner, ttl) | Seize(owner, ttl) -> Some(#(owner, now + ttl))
              Hold(_) | Release -> None
            },
            None,
            now,
          ))
        Some(_), Error(Nil) -> Error(NotFound)
        Some(expected), Ok(row) if row.revision != expected ->
          Error(Conflict(row.revision))
        Some(_), Ok(row) -> {
          let next = Row(..row, revision: row.revision + 1, record: record)
          case lease, holder(row) {
            Hold(owner), Held(holding, _) if holding == owner -> Ok(next)
            Claim(owner, ttl), Free
            | Claim(owner, ttl), Held(_, False)
            | Seize(owner, ttl), _
            -> Ok(Row(..next, lease: Some(#(owner, now + ttl))))
            Claim(owner, ttl), Held(holding, True) if holding == owner ->
              Ok(Row(..next, lease: Some(#(owner, now + ttl))))
            Release, _ -> Ok(Row(..next, lease: None))
            Hold(_), found | Claim(..), found -> Error(LeaseRefused(found))
          }
        }
      }
      process.send(reply, result.replace(outcome, Nil))
      case outcome {
        Ok(row) -> #(dict.insert(rows, run, row), offset)
        Error(_) -> #(rows, offset)
      }
    }
    LeasedRenew(owner, runs, ttl, reply) -> {
      let renewed =
        list.filter(list.unique(runs), fn(run) {
          case dict.get(rows, run) {
            Ok(Row(lease: Some(#(holding, until)), ..)) ->
              holding == owner && until > now
            _ -> False
          }
        })
      process.send(reply, renewed)
      #(
        list.fold(renewed, rows, fn(rows, run) {
          dict.upsert(rows, run, fn(row) {
            let assert Some(row) = row
            Row(..row, lease: Some(#(owner, now + ttl)))
          })
        }),
        offset,
      )
    }
    LeasedClaimReady(owner, ttl, limit, reply) -> {
      let candidates =
        dict.to_list(rows)
        |> list.filter_map(fn(entry) {
          let #(id, row) = entry
          case row.lease, wait_for(id, row.record) {
            None, Some(wait) -> {
              let #(revision, ready) = case wait.trigger {
                discovery.At(due) -> #([], now >= due)
                discovery.Changed(dependencies, due) -> {
                  let revisions =
                    list.map(dependencies, fn(dependency) {
                      let id = run.id_to_string(dependency)
                      let revision =
                        dict.get(rows, id)
                        |> result.map(fn(row) { row.revision })
                        |> option.from_result
                      #(id, revision)
                    })
                  #(
                    revisions,
                    row.observed != Some(#(wait.key, revisions))
                      || deadline_due(due, now),
                  )
                }
                discovery.Poll(every, due) -> #(
                  [],
                  row.observed != Some(#(wait.key, []))
                    || row.checked + every <= now
                    || deadline_due(due, now),
                )
              }
              case !ready {
                True -> Error(Nil)
                False -> Ok(#(id, wait.key, revision, row.checked))
              }
            }
            _, _ -> Error(Nil)
          }
        })
        |> list.sort(fn(a, b) { int.compare(a.3, b.3) })
        |> list.take(int.max(limit, 0))
      process.send(reply, list.map(candidates, fn(candidate) { candidate.0 }))
      #(
        list.fold(candidates, rows, fn(rows, candidate) {
          let assert Ok(row) = dict.get(rows, candidate.0)
          dict.insert(
            rows,
            candidate.0,
            Row(
              ..row,
              lease: Some(#(owner, now + ttl)),
              observed: Some(#(candidate.1, candidate.2)),
              checked: now,
            ),
          )
        }),
        offset,
      )
    }
    LeasedClaimExpired(owner, ttl, limit, reply) -> {
      let claimed =
        dict.to_list(rows)
        |> list.filter_map(fn(entry) {
          case entry.1.lease {
            Some(#(_, until)) if until <= now -> Ok(#(until, entry.0))
            _ -> Error(Nil)
          }
        })
        |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
        |> list.take(int.max(limit, 0))
        |> list.map(fn(entry) { entry.1 })
      process.send(reply, claimed)
      #(
        list.fold(claimed, rows, fn(rows, run) {
          dict.upsert(rows, run, fn(row) {
            let assert Some(row) = row
            Row(..row, lease: Some(#(owner, now + ttl)))
          })
        }),
        offset,
      )
    }
  }
}

fn deadline_due(due: Option(Int), now: Int) -> Bool {
  case due {
    None -> False
    Some(at) -> now >= at
  }
}

@external(erlang, "fabric_ffi", "system_time_ms")
fn system_time_ms() -> Int

fn wait_for(id: String, encoded: String) -> Option(discovery.Wait) {
  case discovery.inspect(encoded) {
    Ok(Some(wait)) ->
      case run.id_to_string(wait.run) == id {
        True -> Some(wait)
        False -> None
      }
    _ -> None
  }
}

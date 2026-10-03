//// Bounded scans of expired leases and changed idle dependencies.
//// A candidate identifies a registered root;
//// recovery of that root preserves each member's independent lease.

import fabric/agent.{type Agent}
import fabric/internal/bounded
import fabric/internal/checked_agent
import fabric/internal/family
import fabric/internal/recovery_record as record
import fabric/internal/run_id
import fabric/internal/runner
import fabric/internal/store.{type Store}
import fabric/run.{type DefinitionId, type RunId}
import fabric/telemetry as o
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import sinal

pub opaque type Root {
  Root(key: record.Key, restore: fn(Store, String) -> Result(Nil, Nil))
}

pub fn agent_root(agent: Agent(c), context: fn(RunId) -> c) -> Root {
  let admitted = checked_agent.admitted(agent)
  Root(record.Key(record.Agent, admitted.identity), fn(store, root) {
    use context <- result.try(
      bounded.call(5000, fn() { context(run_id.from_string(root)) })
      |> result.map_error(fn(_) { Nil }),
    )
    family.take_over(runner.setup(store, admitted, context, None), root, 3)
    |> result.map_error(fn(_) { Nil })
  })
}

pub fn graph_root(
  identity: DefinitionId,
  restore: fn(Store, String) -> Result(Nil, Nil),
) -> Root {
  Root(record.Key(record.Graph, identity), restore)
}

pub type ConfigError {
  EveryNotPositive(Int)
  EveryTooLarge(Int)
  DuplicateRoot(DefinitionId)
  StoreNotLeased
}

const timer_limit = 4_294_967_295

const batch_size = 100

pub fn new(
  store: Store,
  roots: List(Root),
  every: Int,
) -> Result(supervision.ChildSpecification(Nil), List(ConfigError)) {
  let errors = case every {
    n if n <= 0 -> [EveryNotPositive(n)]
    n if n > timer_limit -> [EveryTooLarge(n)]
    _ -> []
  }
  let errors = case store.poll_interval(store) {
    None -> [StoreNotLeased, ..errors]
    Some(_) -> errors
  }
  let #(indexed, errors) =
    list.fold(roots, #(dict.new(), errors), fn(acc, recovery) {
      case dict.has_key(acc.0, recovery.key) {
        True -> #(acc.0, [DuplicateRoot(recovery.key.identity), ..acc.1])
        False -> #(dict.insert(acc.0, recovery.key, recovery), acc.1)
      }
    })
  case errors {
    [] -> Ok(supervision.worker(fn() { start(store, indexed, every) }))
    _ -> Error(list.reverse(errors))
  }
}

type Message {
  Tick
  Finished(o.Sweep)
  Down(Pid)
}

type Loop {
  Loop(
    store: Store,
    owner: Pid,
    self: process.Subject(Message),
    busy: Option(Pid),
  )
}

fn start(
  store: Store,
  roots: Dict(record.Key, Root),
  every: Int,
) -> actor.StartResult(Nil) {
  actor.new_with_initialiser(5000, fn(self) {
    case store.runners(store) {
      Error(Nil) -> Error("the sweeper's store is not running")
      Ok(#(pinned, _, _)) -> {
        let assert Ok(owner) = store.pid(pinned)
        process.monitor(owner)
        let selector =
          process.new_selector()
          |> process.select(self)
          |> process.select_monitors(fn(down) {
            case down {
              process.ProcessDown(pid:, ..) -> Down(pid)
              process.PortDown(..) -> Down(owner)
            }
          })
        process.send(self, Tick)
        Ok(
          actor.initialised(Loop(pinned, owner, self, None))
          |> actor.selecting(selector),
        )
      }
    }
  })
  |> actor.on_message(fn(state, message) {
    case message {
      Down(pid) if pid == state.owner ->
        actor.stop_abnormal("the sweeper's store stopped")
      Tick if state.busy == None -> {
        let worker =
          process.spawn(fn() {
            let summary = scan(state.store, roots)
            // Contain synchronous handlers too; they cannot accumulate
            // an unbounded number of blocked emitters across scans.
            let _ =
              bounded.call(1000, fn() { sinal.emit(o.sweep(), summary, Nil) })
            process.send(state.self, Finished(summary))
          })
        process.monitor(worker)
        actor.continue(Loop(..state, busy: Some(worker)))
      }
      Finished(_) -> {
        process.send_after(state.self, every, Tick)
        actor.continue(Loop(..state, busy: None))
      }
      Down(pid) if state.busy == Some(pid) -> {
        process.send_after(state.self, every, Tick)
        actor.continue(Loop(..state, busy: None))
      }
      _ -> actor.continue(state)
    }
  })
  |> actor.start
}

fn empty() -> o.Sweep {
  o.Sweep(claimed: 0, recovered: 0, unmatched: 0, failed: 0)
}

fn scan(store: Store, registered: Dict(record.Key, Root)) -> o.Sweep {
  // Reserve half the batch for each source so neither a stream of expired
  // runners nor changing dependencies can starve the other.
  let expired = store.claim_expired(store, batch_size / 2)
  let ready = store.claim_ready(store, batch_size / 2)
  let failures = list.count([expired, ready], result.is_error)
  let ids = list.append(result.unwrap(expired, []), result.unwrap(ready, []))
  let #(roots, failures) =
    list.fold(ids, #(dict.new(), failures), fn(acc, id) {
      case record.root(store, id, 128) {
        Error(_) -> #(acc.0, acc.1 + 1)
        Ok(#(root, identity)) -> #(
          dict.upsert(acc.0, #(root, identity), fn(existing) {
            [id, ..option.unwrap(existing, [])]
          }),
          acc.1,
        )
      }
    })
  dict.fold(
    roots,
    o.Sweep(..empty(), claimed: list.length(ids), failed: failures),
    fn(summary, key, candidates) {
      let #(root, identity) = key
      case dict.get(registered, identity) {
        Error(_) -> o.Sweep(..summary, unmatched: summary.unmatched + 1)
        Ok(recovery) -> {
          let before =
            list.filter_map(candidates, fn(id) {
              record.load(store, id)
              |> result.map(fn(loaded) {
                #(id, record.incarnation(loaded), record.revision(loaded))
              })
            })
          case bounded.call(30_000, fn() { recovery.restore(store, root) }) {
            Ok(Ok(Nil)) -> {
              let recovered =
                list.count(before, fn(candidate) {
                  let #(id, incarnation, revision) = candidate
                  case record.load(store, id) {
                    Ok(state) ->
                      record.incarnation(state) > incarnation
                      // A scheduled observation may accept a route without
                      // restarting the run. Its committed revision is progress.
                      || record.revision(state) > revision
                      || record.release_acknowledged(store, state)
                    Error(_) -> False
                  }
                })
              o.Sweep(..summary, recovered: summary.recovered + recovered)
            }
            _ -> o.Sweep(..summary, failed: summary.failed + 1)
          }
        }
      }
    },
  )
}

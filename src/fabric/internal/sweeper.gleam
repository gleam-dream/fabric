//// Bounded scans of expired leases. A candidate identifies a root agent;
//// recovery of that root preserves each member's independent lease.

import fabric/agent.{type Agent}
import fabric/internal/bounded
import fabric/internal/controller
import fabric/internal/family
import fabric/internal/runner
import fabric/observation as o
import fabric/run.{type Identity, type RunId}
import fabric/store.{type Store}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import sinal/forwarder

pub opaque type Recovery {
  Recovery(identity: Identity, restore: fn(Store, String) -> Result(Nil, Nil))
}

pub fn recovery(agent: Agent(c), context: fn(RunId) -> c) -> Recovery {
  let admitted = agent.admitted(agent)
  Recovery(admitted.identity, fn(store, root) {
    use context <- result.try(
      bounded.call(5000, fn() { context(run.issued(root)) })
      |> result.map_error(fn(_) { Nil }),
    )
    family.take_over(runner.setup(store, admitted, context, None), root, 3)
    |> result.map_error(fn(_) { Nil })
  })
}

pub type ConfigError {
  EveryNotPositive(Int)
  EveryTooLarge(Int)
  DuplicateRecovery(Identity)
  StoreNotLeased
}

const timer_limit = 4_294_967_295

const batch_size = 100

pub fn new(
  store: Store,
  recoveries: List(Recovery),
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
    list.fold(recoveries, #(dict.new(), errors), fn(acc, recovery) {
      case dict.has_key(acc.0, recovery.identity) {
        True -> #(acc.0, [DuplicateRecovery(recovery.identity), ..acc.1])
        False -> #(dict.insert(acc.0, recovery.identity, recovery), acc.1)
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
  recoveries: Dict(Identity, Recovery),
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
            let summary = scan(state.store, recoveries)
            // Contain synchronous handlers too; they cannot accumulate
            // an unbounded number of blocked emitters across scans.
            let _ =
              bounded.call(1000, fn() {
                forwarder.emit_routed(o.sweep(), summary, Nil)
              })
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

fn scan(store: Store, recoveries: Dict(Identity, Recovery)) -> o.Sweep {
  case store.claim_expired(store, batch_size) {
    Error(_) -> o.Sweep(..empty(), failed: 1)
    Ok(ids) -> {
      let #(roots, failures) =
        list.fold(ids, #(dict.new(), 0), fn(acc, id) {
          case root(store, id, 128) {
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
          case dict.get(recoveries, identity) {
            Error(_) -> o.Sweep(..summary, unmatched: summary.unmatched + 1)
            Ok(recovery) -> {
              let before =
                list.filter_map(candidates, fn(id) {
                  runner.load(store, id)
                  |> result.map(fn(loaded) { #(id, loaded.1.incarnation) })
                })
              case
                bounded.call(30_000, fn() { recovery.restore(store, root) })
              {
                Ok(Ok(Nil)) -> {
                  let recovered =
                    list.count(before, fn(candidate) {
                      let #(id, incarnation) = candidate
                      case runner.load(store, id) {
                        Ok(#(_, state)) ->
                          state.incarnation > incarnation
                          || release_acknowledged(store, state)
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
  }
}

/// Follow checked records, not the spelling of a run id. The record codec
/// validates parent prefixes; the bound also contains damaged ancestry.
fn root(
  store: Store,
  id: String,
  left: Int,
) -> Result(#(String, Identity), Nil) {
  case left {
    0 -> Error(Nil)
    _ -> {
      use #(_, state) <- result.try(
        runner.load(store, id) |> result.map_error(fn(_) { Nil }),
      )
      case state.parent {
        None -> Ok(#(id, state.agent))
        Some(parent) -> root(store, run.id_to_string(parent.run), left - 1)
      }
    }
  }
}

/// An ended child keeps a lease as a retry cue until its parent no longer
/// awaits it. Only then can a sweep clear that cue with a revision check.
fn release_acknowledged(store: Store, state: controller.State) -> Bool {
  let terminal = case state.phase {
    controller.Ended(_) | controller.NeverStarted -> True
    _ -> False
  }
  let acknowledged = case state.parent {
    None -> terminal
    Some(parent) ->
      case runner.load(store, run.id_to_string(parent.run)) {
        Error(_) -> False
        Ok(#(_, above)) ->
          !list.any(controller.active_children(above), fn(child) {
            child.0 == parent.id
          })
      }
  }
  case terminal && acknowledged {
    False -> False
    True ->
      case runner.load(store, state.run) {
        Ok(#(entry, current)) if current == state ->
          store.encode(store, state)
          |> result.try(fn(encoded) {
            store.commit(
              store,
              state.run,
              entry.revision,
              encoded,
              store.Detached(in_flight: False, seize: False),
            )
          })
          |> result.is_ok
        _ -> False
      }
  }
}

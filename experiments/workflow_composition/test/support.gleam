//// THROWAWAY (workflow composition experiment). Harness for variants A and
//// B. Waiting is event-driven: tests block on committed-state observations
//// or on barrier arrivals, never on sleeps.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/duration
import wc/agent
import wc/app
import wc/exec_saga
import wc/exec_tasks
import wc/probe.{type Probe}
import wc/runtime.{type Env, type Observation}
import wc/store.{type Store}

pub type Variant {
  /// Fabric-owned controller, plain supervised tasks.
  A
  /// Fabric-owned controller, one Saga run per dispatched batch.
  B
}

pub type Harness {
  Harness(env: Env, store: Store, probe: Probe, observer: Subject(Observation))
}

pub fn harness(variant: Variant, max_in_flight: Int) -> Harness {
  let store = store.start()
  let probe = probe.new()
  let observer = process.new_subject()
  let executor = case variant {
    A -> exec_tasks.executor()
    B ->
      exec_saga.executor(exec_saga.Settings(
        step_timeout: duration.seconds(10),
        settle_timeout: duration.milliseconds(50),
      ))
  }
  let env =
    runtime.Env(
      store: store,
      model: app.scripted(probe),
      tools: app.all_tools(probe),
      policy: app.policy,
      executor: executor,
      max_in_flight: max_in_flight,
      observer: Some(observer),
    )
  Harness(env, store, probe, observer)
}

/// Blocks until a commit for `run` reports a status matching `accept`.
pub fn await_status(
  h: Harness,
  run: String,
  accept: fn(agent.RunStatus) -> Bool,
) -> agent.RunStatus {
  let assert Ok(observation) = process.receive(h.observer, 5000)
  case observation {
    runtime.Committed(r, _, status) if r == run ->
      case accept(status) {
        True -> status
        False -> await_status(h, run, accept)
      }
    _ -> await_status(h, run, accept)
  }
}

/// Blocks until a commit for `run` stores a state matching `accept`.
pub fn await_record(
  h: Harness,
  run: String,
  accept: fn(agent.State) -> Bool,
) -> agent.State {
  let assert Ok(observation) = process.receive(h.observer, 5000)
  case observation {
    runtime.Committed(r, _, _) if r == run -> {
      let assert Ok(#(_, state)) = runtime.load(h.store, run)
      case accept(state) {
        True -> state
        False -> await_record(h, run, accept)
      }
    }
    _ -> await_record(h, run, accept)
  }
}

/// Blocks until the runtime reports that no process holds `run` any more.
pub fn await_released(h: Harness, run: String) -> Nil {
  let assert Ok(observation) = process.receive(h.observer, 5000)
  case observation {
    runtime.Released(r) if r == run -> Nil
    _ -> await_released(h, run)
  }
}

pub fn waiting(status: agent.RunStatus) -> Bool {
  case status {
    agent.WaitingForApproval(_) -> True
    _ -> False
  }
}

pub fn finished(status: agent.RunStatus) -> Bool {
  case status {
    agent.Finished(_) -> True
    _ -> False
  }
}

pub fn reconciling(status: agent.RunStatus) -> Bool {
  case status {
    agent.NeedsReconciliation(_) -> True
    _ -> False
  }
}

/// The largest number of tool bodies that were between their `:start:` and
/// `:end:` ledger entries at the same time. The ledger is synchronous, so
/// its order is the order the bodies actually ran in.
pub fn max_overlap(entries: List(String)) -> Int {
  let #(_, peak) =
    list.fold(entries, #(0, 0), fn(acc, entry) {
      let #(now, peak) = acc
      case string.contains(entry, ":start:"), string.contains(entry, ":end:") {
        True, _ -> #(now + 1, int_max(peak, now + 1))
        _, True -> #(now - 1, peak)
        _, _ -> acc
      }
    })
  peak
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

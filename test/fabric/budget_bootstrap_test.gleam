//// Fixtures retain a root at its initialization boundary; recovery, execution
//// and observation use the ordinary public graph and agent APIs.

import fabric/budget as quota
import fabric/internal/checked_agent

import fabric
import fabric/agent
import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/internal/budget/ledger
import fabric/internal/budget/model as budget
import fabric/internal/budget/record as budget_record
import fabric/internal/controller
import fabric/internal/graph/controller as graph_control
import fabric/internal/graph/record as graph_record
import fabric/internal/record
import fabric/internal/runner
import fabric/internal/store as store_core
import fabric/model
import fabric/policy
import fabric/run
import fabric/store/backend
import fabric/support
import fabric/support/flaky
import fabric/support/probe
import fabric/support/restart
import fabric/support/scripted
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec
import sinal/correlation

type Kind {
  Agent
  Graph
}

type Fixture {
  Fixture(
    recover: fn() -> Result(Nil, Nil),
    finished: fn() -> Bool,
    idle: fn() -> Bool,
    cancel: fn() -> Result(Nil, Nil),
    cancelled: fn() -> Bool,
  )
}

fn limits() {
  quota.Limits(4, 0, 0)
}

fn declared(runs, kind) {
  let assert Ok(entry) = store_core.get(runs, "root")
  case kind {
    Agent -> {
      let assert Ok(state) = record.decode(entry.record)
      state.family_budget
    }
    Graph -> {
      let assert Ok(state) = graph_record.decode(entry.record)
      state.family_budget
    }
  }
}

fn check_before_effect(runs, kind, calls) {
  declared(runs, kind) |> should.equal(Some(budget.Declaration(limits(), True)))
  let assert Ok(_) = ledger.read(runs, "root")
  probe.record(calls, "worked")
}

fn fixture(runs, kind, initialized, calls) {
  let declaration = Some(budget.Declaration(limits(), initialized))
  case kind {
    Agent -> {
      let worker =
        agent.new(
          "worker",
          scripted.model(fn(_) {
            check_before_effect(runs, Agent, calls)
            model.FinalAnswer("done", None)
          }),
          [],
          policy.always_allow(),
        )
        |> support.agent
      let setup = runner.setup(runs, checked_agent.admitted(worker), Nil, None)
      let #(state, _) =
        runner.root_state(setup, "root", "go", correlation.from_key("root"))
      let state = controller.State(..state, family_budget: declaration)
      let assert Ok(encoded) = store_core.encode(runs, state)
      let assert Ok(_) =
        store_core.insert(
          runs,
          "root",
          encoded,
          store_core.Detached(True, False),
        )
      let assert Ok(handle) = fabric.open(runs, worker, Nil, support.id("root"))
      Fixture(
        fn() {
          fabric.recover(runs, worker, Nil, support.id("root"))
          |> result.replace(Nil)
          |> result.replace_error(Nil)
        },
        fn() {
          fabric.await(handle, within: duration.milliseconds(2000))
          == Ok(run.Finished(run.Completed("done")))
        },
        fn() {
          fabric.await(handle, within: duration.milliseconds(2000))
          == Ok(run.Unattended)
        },
        fn() {
          fabric.cancel(handle)
          |> result.replace(Nil)
          |> result.replace_error(Nil)
        },
        fn() {
          fabric.await(handle, within: duration.milliseconds(2000))
          == Ok(run.Finished(run.Cancelled))
        },
      )
    }
    Graph -> {
      let assert Ok(node) = definition.node_id("work")
      let op =
        operation.new(
          run.DefinitionId("work", 1),
          codec.int(),
          codec.int(),
          fn(_, _, value) {
            check_before_effect(runs, Graph, calls)
            Ok(value + 1)
          },
          fn(_: Nil) { operation.DefiniteFailure("failed") },
        )
      let step =
        definition.node(
          node,
          op,
          fn(value) { Ok(value) },
          fn(_, output) { Ok(definition.Finish(output, output)) },
          [],
        )
      let assert Ok(spec) =
        definition.build(definition.Spec(
          run.DefinitionId("graph", 1),
          node,
          [step],
          codec.int(),
          codec.int(),
          2,
        ))
      let assert Ok(#(value, entry)) = definition.prepare(spec, 0)
      let assert Ok(#(state, _)) =
        graph_control.start("root", definition.identity(spec), value, entry)
      let state = graph_control.State(..state, family_budget: declaration)
      let assert Ok(encoded) = graph_record.encode(state)
      let assert Ok(_) =
        store_core.insert(
          runs,
          "root",
          encoded,
          store_core.Detached(True, False),
        )
      let runtime =
        graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
      let handle = graph.attach(runtime, support.id("root"))
      Fixture(
        fn() {
          graph.recover(handle)
          |> result.replace(Nil)
          |> result.replace_error(Nil)
        },
        fn() {
          case graph.await(handle, within: duration.milliseconds(2000)) {
            Ok(snapshot) -> snapshot.status == graph.Completed(1)
            Error(_) -> False
          }
        },
        fn() {
          case graph.await(handle, within: duration.milliseconds(2000)) {
            Ok(snapshot) -> snapshot.status == graph.Unattended
            Error(_) -> False
          }
        },
        fn() {
          graph.cancel(handle)
          |> result.replace(Nil)
          |> result.replace_error(Nil)
        },
        fn() {
          case graph.await(handle, within: duration.milliseconds(2000)) {
            Ok(graph.Snapshot(status: graph.Cancelled(_), ..)) -> True
            _ -> False
          }
        },
      )
    }
  }
}

pub fn recovery_initializes_each_runtime_before_its_first_effect_test() {
  list.each([Agent, Graph], fn(kind) {
    let runs = support.store()
    let calls = probe.new()
    let f = fixture(runs, kind, False, calls)
    f.recover() |> should.equal(Ok(Nil))
    f.finished() |> should.be_true
    probe.entries(calls) |> should.equal(["worked"])
    declared(runs, kind)
    |> should.equal(Some(budget.Declaration(limits(), True)))
  })
}

pub fn recovery_finishes_a_cancelled_roots_interrupted_initialization_test() {
  list.each([Agent, Graph], fn(kind) {
    let backend = flaky.new()
    let runs = flaky.store(backend)
    let calls = probe.new()
    let f = fixture(runs, kind, False, calls)
    flaky.arm_where(backend, fn(id) { id == budget_record.id("root") }, [
      flaky.FailBefore,
    ])
    f.cancel() |> should.equal(Error(Nil))
    f.cancelled() |> should.be_true
    declared(runs, kind)
    |> should.equal(Some(budget.Declaration(limits(), False)))
    f.recover() |> should.equal(Ok(Nil))
    f.cancelled() |> should.be_true
    declared(runs, kind)
    |> should.equal(Some(budget.Declaration(limits(), True)))
    let assert Ok(#(_, saved)) = ledger.read(runs, "root")
    budget.usage(saved) |> should.equal(quota.Usage(0, 0))
    probe.entries(calls) |> should.equal([])
  })
}

pub fn an_initialized_root_with_a_missing_ledger_never_gets_fresh_capacity_test() {
  list.each([Agent, Graph], fn(kind) {
    let runs = support.store()
    let calls = probe.new()
    let f = fixture(runs, kind, True, calls)
    f.recover() |> should.equal(Error(Nil))
    f.idle() |> should.be_true
    ledger.read(runs, "root")
    |> should.equal(Error(ledger.Storage(backend.NotFound)))
    declared(runs, kind)
    |> should.equal(Some(budget.Declaration(limits(), True)))
    probe.entries(calls) |> should.equal([])
  })
}

pub fn an_unconfirmed_ledger_insert_dispatches_nothing_and_recovery_repairs_it_test() {
  list.each([Agent, Graph], fn(kind) {
    let backend = flaky.new()
    let runs = flaky.store(backend)
    let calls = probe.new()
    let f = fixture(runs, kind, False, calls)
    flaky.arm_where(backend, fn(id) { id == budget_record.id("root") }, [
      flaky.FailBefore,
    ])
    f.recover() |> should.equal(Error(Nil))
    f.idle() |> should.be_true
    declared(runs, kind)
    |> should.equal(Some(budget.Declaration(limits(), False)))
    probe.entries(calls) |> should.equal([])
    f.recover() |> should.equal(Ok(Nil))
    f.finished() |> should.be_true
    probe.entries(calls) |> should.equal(["worked"])
  })
}

pub fn an_unconfirmed_marker_dispatches_nothing_and_preserves_existing_claims_test() {
  list.each([Agent, Graph], fn(kind) {
    let backend = flaky.new()
    let runs = flaky.store(backend)
    let calls = probe.new()
    let f = fixture(runs, kind, False, calls)
    // The recovery record commits; the marker write does not.
    flaky.arm_where(backend, fn(id) { id == "root" }, [
      flaky.Pass,
      flaky.FailBefore,
    ])
    f.recover() |> should.equal(Error(Nil))
    f.idle() |> should.be_true
    probe.entries(calls) |> should.equal([])
    let assert Ok(saved) =
      ledger.reserve(runs, "root", limits(), budget.GraphAttempt("root", 1, 1))
    f.recover() |> should.equal(Ok(Nil))
    f.finished() |> should.be_true
    let assert Ok(#(_, retained)) = ledger.read(runs, "root")
    list.all(budget.claims(saved), fn(claim) {
      list.contains(budget.claims(retained), claim)
    })
    |> should.be_true
    budget.usage(retained).work
    |> should.equal(case kind {
      Agent -> 2
      Graph -> 1
    })
  })
}

pub fn lost_ledger_and_marker_acknowledgements_are_confirmed_without_repeating_work_test() {
  list.each([Agent, Graph], fn(kind) {
    let backend = flaky.new()
    let runs = flaky.store(backend)
    let calls = probe.new()
    let f = fixture(runs, kind, False, calls)
    flaky.arm(backend, [flaky.Pass, flaky.FailAfter, flaky.FailAfter])
    f.recover() |> should.equal(Ok(Nil))
    f.finished() |> should.be_true
    f.recover() |> should.equal(Ok(Nil))
    probe.entries(calls) |> should.equal(["worked"])
  })
}

pub fn a_marker_that_lands_late_is_adopted_before_dispatch_test() {
  list.each([Agent, Graph], fn(kind) {
    let backend = flaky.new()
    let runs = flaky.store(backend)
    let calls = probe.new()
    let f = fixture(runs, kind, False, calls)
    flaky.arm_where(backend, fn(id) { id == "root" }, [
      flaky.Pass,
      flaky.FailLate,
    ])
    f.recover() |> should.equal(Error(Nil))
    f.idle() |> should.be_true
    probe.entries(calls) |> should.equal([])
    f.recover() |> should.equal(Ok(Nil))
    f.finished() |> should.be_true
    probe.entries(calls) |> should.equal(["worked"])
  })
}

pub fn directory_restart_preserves_the_initialized_marker_test() {
  let dir = restart.temp_dir()
  let calls = probe.new()
  let #(owner, runs) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let f = fixture(runs, Graph, False, calls)
      f.recover() |> should.equal(Ok(Nil))
      f.finished() |> should.be_true
      runs
    })
  restart.crash(owner, runs)
  let reopened = support.directory(dir)
  declared(reopened, Graph)
  |> should.equal(Some(budget.Declaration(limits(), True)))
  let assert Ok(_) = ledger.read(reopened, "root")
  probe.entries(calls) |> should.equal(["worked"])
  restart.remove_dir(dir)
}

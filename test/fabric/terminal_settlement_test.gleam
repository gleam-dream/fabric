import fabric
import fabric/internal/controller
import fabric/internal/record
import fabric/internal/store as store_core
import fabric/model
import fabric/run
import fabric/store
import fabric/support
import fabric/support/flaky
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import sinal/correlation

fn action(child) {
  run.ActionRecord(
    run.ActionId(1, "effect"),
    model.ToolCall("effect", "removed-tool", "{}", None, None),
    run.Uncertain("result was lost"),
    [],
    child,
  )
}

fn state(id, parent, actions) {
  controller.State(
    id,
    run.DefinitionId("removed-agent", 1),
    1,
    parent,
    0,
    controller.Limits(5, None, 3, 3),
    1,
    run.TokenUsage(10, 2, 0),
    [model.UserMessage("do it")],
    actions,
    0,
    controller.Ended(run.Cancelled),
    None,
    correlation.from_key(id),
    case parent {
      Some(run.AgentParent(run: parent, ..)) -> run.id_to_string(parent)
      _ -> id
    },
  )
}

fn insert(runs, state: controller.State) {
  let assert Ok(_) =
    store_core.insert(
      runs,
      state.run,
      record.encode(state),
      store_core.Detached(False, False),
    )
  Nil
}

fn read(runs, id) {
  let assert Ok(entry) = store_core.get(runs, id)
  let assert Ok(state) = record.decode(entry.record)
  #(entry, state)
}

fn effect(id) {
  run.ActionRef(support.id(id), run.ActionId(1, "effect"))
}

pub fn terminal_tool_evidence_preserves_execution_and_rejects_overwrite_test() {
  let runs = support.store()
  let before = state("root", None, [action(None)])
  insert(runs, before)
  let assert Ok(snapshot) =
    fabric.reconcile_stored(runs, effect("root"), "charged once")
  snapshot.status |> should.equal(run.Finished(run.Cancelled))
  let assert [saved] = snapshot.actions
  saved.state |> should.equal(run.Reconciled("charged once"))
  let #(entry, after) = read(runs, "root")
  after
  |> should.equal(
    controller.State(..before, history: [
      run.ActionRecord(..action(None), state: run.Reconciled("charged once")),
    ]),
  )
  fabric.reconcile_stored(runs, effect("root"), "charged once") |> should.be_ok
  fabric.reconcile_stored(runs, effect("root"), "never charged")
  |> should.equal(Error(fabric.NotReconcilable))
  read(runs, "root").0 |> should.equal(entry)
  fabric.reconcile_stored(
    runs,
    run.ActionRef(support.id("root"), run.ActionId(2, "effect")),
    "other",
  )
  |> should.equal(Error(fabric.WrongReference))
}

fn family(runs) {
  let root = state("root", None, [action(Some(support.id("root-1")))])
  let child =
    state(
      "root-1",
      Some(run.AgentParent(support.id("root"), run.ActionId(1, "effect"))),
      [action(Some(support.id("root-1-1")))],
    )
  let leaf =
    state(
      "root-1-1",
      Some(run.AgentParent(support.id("root-1"), run.ActionId(1, "effect"))),
      [action(None)],
    )
  list.each([root, child, leaf], insert(runs, _))
  #(root, child, leaf)
}

pub fn canceled_families_settle_from_saved_children_without_an_agent_test() {
  let runs = support.store()
  let #(root, child, _) = family(runs)
  fabric.reconcile_stored(runs, effect("root"), "pretend child succeeded")
  |> should.equal(Error(fabric.NotReconcilable))
  fabric.settle_stored(runs, support.id("root")) |> should.be_ok
  read(runs, "root").1 |> should.equal(root)
  fabric.reconcile_stored(runs, effect("root-1-1"), "charged") |> should.be_ok
  let assert Ok(snapshot) = fabric.settle_stored(runs, support.id("root"))
  snapshot.status |> should.equal(run.Finished(run.Cancelled))
  list.each([root, child], fn(before) {
    let #(entry, after) = read(runs, before.run)
    let assert [delegation] = after.history
    delegation.state |> should.equal(run.ChildSettled(run.Cancelled))
    controller.State(..after, history: before.history) |> should.equal(before)
    fabric.settle_stored(runs, support.id(before.run)) |> should.be_ok
    read(runs, before.run).0 |> should.equal(entry)
  })
}

pub fn an_interrupted_family_walk_resumes_after_partial_progress_test() {
  let backend = flaky.new()
  let runs = flaky.store(backend)
  let #(root, _, _) = family(runs)
  flaky.arm_run(backend, support.id("root-1-1"), [flaky.FailAfter])
  fabric.reconcile_stored(runs, effect("root-1-1"), "charged") |> should.be_ok
  flaky.arm_run(backend, support.id("root"), [flaky.FailBefore])
  let assert Error(fabric.Unreadable(fabric.StoreUnavailable(_))) =
    fabric.settle_stored(runs, support.id("root"))
  read(runs, "root").1 |> should.equal(root)
  let child_entry = read(runs, "root-1").0
  let assert [run.ActionRecord(state: run.ChildSettled(run.Cancelled), ..)] =
    read(runs, "root-1").1.history
  flaky.arm_run(backend, support.id("root"), [flaky.FailAfter])
  fabric.settle_stored(runs, support.id("root")) |> should.be_ok
  read(runs, "root-1").0 |> should.equal(child_entry)
}

pub fn missing_wrong_and_active_children_never_clear_parent_uncertainty_test() {
  list.each([0, 1, 2], fn(kind) {
    let runs = support.store()
    let root = state("root", None, [action(Some(support.id("root-1")))])
    insert(runs, root)
    case kind {
      0 -> Nil
      _ -> {
        let child =
          state(
            "root-1",
            Some(run.AgentParent(support.id("root"), run.ActionId(1, "wrong"))),
            [],
          )
        let child = case kind {
          1 -> child
          _ ->
            controller.State(
              ..child,
              parent: Some(run.AgentParent(
                support.id("root"),
                run.ActionId(1, "effect"),
              )),
              phase: controller.Acting(1, [action(None)]),
            )
        }
        insert(runs, child)
      }
    }
    case kind {
      0 ->
        fabric.settle_stored(runs, support.id("root"))
        |> should.equal(Error(fabric.Unreadable(fabric.RunNotFound)))
      1 -> {
        let assert Error(fabric.Unreadable(fabric.CorruptRecord(_))) =
          fabric.settle_stored(runs, support.id("root"))
        Nil
      }
      _ -> {
        fabric.settle_stored(runs, support.id("root")) |> should.be_ok
        fabric.reconcile_stored(runs, effect("root-1"), "charged")
        |> should.equal(Error(fabric.RunNotFinished))
        fabric.settle_stored(runs, support.id("root-1"))
        |> should.equal(Error(fabric.RunNotFinished))
      }
    }
    read(runs, "root").1 |> should.equal(root)
  })
}

pub fn competing_terminal_reconciliations_cannot_overwrite_evidence_test() {
  let backend = flaky.new()
  let first = flaky.store(backend)
  let second = flaky.store(backend)
  insert(first, state("root", None, [action(None)]))
  let held = flaky.hold(backend, fn(id) { id == "root" })
  let answer = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(
      answer,
      fabric.reconcile_stored(first, effect("root"), "charged"),
    )
  })
  let assert Ok(_) = process.receive(held, 1000)
  fabric.reconcile_stored(second, effect("root"), "not charged") |> should.be_ok
  flaky.release_held(backend)
  process.receive(answer, 1000)
  |> should.equal(Ok(Error(fabric.NotReconcilable)))
  let assert [saved] = read(first, "root").1.history
  saved.state |> should.equal(run.Reconciled("not charged"))
}

pub fn old_writers_refuse_child_settlement_without_changing_the_parent_test() {
  let runs = support.store()
  let #(root, _, _) = family(runs)
  fabric.reconcile_stored(runs, effect("root-1-1"), "charged") |> should.be_ok
  list.each([2, 3, 4, 5], fn(version) {
    let assert Ok(old) = store.with_record_version(runs, version)
    let assert Error(fabric.Unreadable(fabric.StoreUnavailable(_))) =
      fabric.settle_stored(old, support.id("root"))
    read(runs, "root").1 |> should.equal(root)
  })
  fabric.settle_stored(runs, support.id("root")) |> should.be_ok
}

pub fn a_saved_never_started_child_proves_no_effect_while_terminal_failures_stay_failed_test() {
  let runs = support.store()
  let failure = run.Failed(run.ModelProtocolViolation("invalid model reply"))
  let root =
    controller.State(
      ..state("root", None, [action(Some(support.id("root-1")))]),
      phase: controller.Ended(failure),
    )
  let child =
    controller.State(
      ..state(
        "root-1",
        Some(run.AgentParent(support.id("root"), run.ActionId(1, "effect"))),
        [],
      ),
      phase: controller.NeverStarted,
      transcript: [],
    )
  list.each([root, child], insert(runs, _))
  let assert Ok(snapshot) = fabric.settle_stored(runs, support.id("root"))
  snapshot.status |> should.equal(run.Finished(failure))
  let assert [settled] = snapshot.actions
  settled.state |> should.equal(run.NotStarted)
  read(runs, "root-1").1 |> should.equal(child)
}

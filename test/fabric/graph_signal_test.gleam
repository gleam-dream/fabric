import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/graph/signal
import fabric/internal/store as store_core
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/flaky
import fabric/support/probe
import fabric/support/restart
import fabric/tool
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn run_id(name: String) -> run.RunId {
  let assert Ok(id) = run.parse_id(name)
  id
}

fn node_id() -> definition.NodeId {
  let id = definition.node_id("review")
  id
}

fn review() -> signal.Signal(Bool) {
  signal.new(run.DefinitionId("human-review", 1), codec.bool())
}

fn spec(
  accept: fn(Int, Bool) -> Result(definition.Command(Int, Int), String),
) -> definition.Definition(Nil, Int, Int) {
  let node =
    definition.node(
      node_id(),
      operation.await_signal(codec.int(), review()),
      fn(n) { Ok(n) },
      accept,
      [node_id()],
    )
  let assert Ok(definition) =
    definition.build(
      definition.new(
        run.DefinitionId("human-loop", 1),
        entry: node_id(),
        nodes: [node],
        state: codec.int(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(3),
    )
  definition
}

fn accept(
  n: Int,
  approved: Bool,
) -> Result(definition.Command(Int, Int), String) {
  case approved {
    True -> Ok(definition.Finish(n, n))
    False -> Ok(definition.Continue(n + 1, node_id()))
  }
}

fn runtime(runs: store.Store) -> graph.Runtime(Nil, Int, Int) {
  graph.new(spec(accept), runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
}

pub fn a_typed_signal_survives_store_loss_without_holding_a_runner_test() {
  let dir = restart.temp_dir()
  let #(owner, #(runs, handle)) =
    restart.owned(fn() {
      let runs = support.directory(dir)
      let assert Ok(handle) =
        graph.start(
          runtime(runs),
          run_id("signal-restart"),
          7,
          correlation: None,
        )
      #(runs, handle)
    })
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Some(action) = waiting.current
  support.kind(action) |> should.equal(policy.Signal)
  action.arguments_json |> should.equal("7")
  let assert Ok(entry) = store_core.get(runs, "signal-restart")
  entry.live |> should.equal(None)
  restart.crash(owner, runs)
  let handle =
    support.open_graph(
      runtime(support.directory(dir)),
      run_id("signal-restart"),
    )
  let assert Ok(restored) = graph.recover(handle)
  restored |> should.equal(waiting.status)
  let assert Ok(_) = graph.deliver(handle, reference, review(), True)
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Completed(7))
  list.length(done.receipts) |> should.equal(1)
  let assert Ok(_) = graph.deliver(handle, reference, review(), True)
  let assert Ok(again) = graph.snapshot(handle)
  again.revision |> should.equal(done.revision)
  let assert Error(graph.SignalConflict) =
    graph.deliver(handle, reference, review(), False)
  restart.remove_dir(dir)
}

pub fn duplicate_delivery_cannot_consume_a_later_visit_to_the_same_node_test() {
  let ledger = probe.new()
  let runtime =
    graph.new(
      spec(fn(n, output) {
        probe.record(ledger, "accept")
        accept(n, output)
      }),
      support.store(),
      fn(_) { Nil },
      fn(_, _) { Ok(policy.Allow) },
    )
  let assert Ok(handle) =
    graph.start(runtime, run_id("signal-loop"), 0, correlation: None)
  let assert Ok(first) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingSignal(first_ref) = first
  let assert Ok(_) = graph.deliver(handle, first_ref, review(), False)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(second) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(second_ref) = second.status
  second_ref.activation |> should.equal(first_ref.activation + 1)
  let assert Ok(_) = graph.deliver(handle, first_ref, review(), False)
  let assert Ok(duplicate) = graph.snapshot(handle)
  duplicate.status |> should.equal(second.status)
  duplicate.revision |> should.equal(second.revision)
  probe.entries(ledger) |> list.length |> should.equal(1)
  let assert Error(graph.SignalConflict) =
    graph.deliver(handle, first_ref, review(), True)
  let assert Ok(done) = graph.deliver(handle, second_ref, review(), True)
  done |> should.equal(graph.Completed(1))
  probe.entries(ledger) |> list.length |> should.equal(2)
}

pub fn a_signal_is_available_only_after_policy_admission_test() {
  let runtime =
    graph.new(spec(accept), support.store(), fn(_) { Nil }, fn(_, action) {
      support.kind(action) |> should.equal(policy.Signal)
      Ok(policy.RequireApproval(run.Requirement("publish-review", 1)))
    })
  let id = run_id("signal-policy")
  let assert Ok(handle) = graph.start(runtime, id, 1, correlation: None)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingApproval(approval) = waiting
  let guessed =
    graph.SignalReference(id, 1, 1, run.DefinitionId("human-review", 1))
  let assert Error(graph.StaleReference) =
    graph.deliver(handle, guessed, review(), True)
  let assert Ok(_) =
    graph.approve(
      handle,
      approval,
      reviewer: support.reviewer("reviewer"),
      context: Nil,
    )
  let assert Ok(approved) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingSignal(reference) = approved
  let assert Ok(done) = graph.deliver(handle, reference, review(), True)
  done |> should.equal(graph.Completed(1))
}

pub fn malformed_or_wrongly_correlated_delivery_does_not_consume_the_wait_test() {
  let assert Ok(handle) =
    graph.start(
      runtime(support.store()),
      run_id("signal-invalid"),
      1,
      correlation: None,
    )
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Error(graph.ValueRefused(_)) =
    graph.deliver_json(handle, reference, "123")
  let wrong = signal.new(run.DefinitionId("human-review", 2), codec.bool())
  let assert Error(graph.WrongReference) =
    graph.deliver(handle, reference, wrong, True)
  let wrong_ref = graph.SignalReference(..reference, run: run_id("other"))
  let assert Error(graph.WrongReference) =
    graph.deliver(handle, wrong_ref, review(), True)
  let wrong_ref = graph.SignalReference(..reference, activation: 2)
  let assert Error(graph.WrongReference) =
    graph.deliver(handle, wrong_ref, review(), True)
  let assert Ok(unchanged) = graph.snapshot(handle)
  unchanged.revision |> should.equal(waiting.revision)
  unchanged.status |> should.equal(waiting.status)
}

pub fn rejected_transition_can_be_corrected_without_consuming_a_signal_test() {
  let runtime =
    graph.new(
      spec(fn(n, approved) {
        case approved {
          True -> Ok(definition.Finish(n, n))
          False -> Error("a negative answer is not acceptable here")
        }
      }),
      support.store(),
      fn(_) { Nil },
      fn(_, _) { Ok(policy.Allow) },
    )
  let assert Ok(handle) =
    graph.start(runtime, run_id("signal-transition"), 1, correlation: None)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(reference) = waiting.status
  let assert Error(graph.ValueRefused(definition.TransitionFailed(_))) =
    graph.deliver(handle, reference, review(), False)
  let assert Ok(unchanged) = graph.snapshot(handle)
  unchanged.revision |> should.equal(waiting.revision)
  let assert Ok(done) = graph.deliver(handle, reference, review(), True)
  done |> should.equal(graph.Completed(1))
}

pub fn failed_and_lost_delivery_commits_do_not_consume_twice_test() {
  let backend = flaky.new()
  let assert Ok(handle) =
    graph.start(
      runtime(flaky.store(backend)),
      run_id("signal-commit"),
      1,
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingSignal(reference) = waiting
  flaky.arm(backend, [flaky.FailBefore])
  let assert Error(graph.StoreUnavailable(_)) =
    graph.deliver(handle, reference, review(), True)
  let assert Ok(unchanged) = graph.snapshot(handle)
  unchanged.status |> should.equal(waiting)
  flaky.arm(backend, [flaky.FailAfter])
  let assert Ok(_) = graph.deliver(handle, reference, review(), True)
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Completed(1))
  let assert Ok(_) = graph.deliver(handle, reference, review(), True)
  let assert Ok(again) = graph.snapshot(handle)
  again.revision |> should.equal(done.revision)
  list.length(again.receipts) |> should.equal(1)
}

pub fn canceled_waits_refuse_late_signals_test() {
  let assert Ok(handle) =
    graph.start(
      runtime(support.store()),
      run_id("signal-cancel"),
      1,
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingSignal(reference) = waiting
  let assert Ok(_) = graph.cancel(handle)
  let assert Error(graph.RunEnded) =
    graph.deliver(handle, reference, review(), True)
  let assert Ok(cancelled) = graph.snapshot(handle)
  cancelled.status |> should.equal(graph.Cancelled(graph.BeforeStart))
  cancelled.receipts |> should.equal([])
}

pub fn two_concurrent_deliveries_accept_only_one_output_test() {
  let assert Ok(handle) =
    graph.start(
      runtime(support.store()),
      run_id("signal-concurrent"),
      1,
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingSignal(reference) = waiting
  let ready = process.new_subject()
  let replies = process.new_subject()
  list.each([True, False], fn(value) {
    process.spawn_unlinked(fn() {
      let go = process.new_subject()
      process.send(ready, go)
      let assert Ok(Nil) = process.receive(go, 30_000)
      process.send(replies, graph.deliver(handle, reference, review(), value))
    })
  })
  let assert Ok(first_go) = process.receive(ready, 30_000)
  let assert Ok(second_go) = process.receive(ready, 30_000)
  process.send(first_go, Nil)
  process.send(second_go, Nil)
  let assert Ok(first) = process.receive(replies, 30_000)
  let assert Ok(second) = process.receive(replies, 30_000)
  let count =
    list.count([first, second], fn(reply) {
      case reply {
        Ok(_) -> True
        Error(_) -> False
      }
    })
  count |> should.equal(1)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(after) = graph.snapshot(handle)
  list.length(after.receipts) |> should.equal(1)
}

fn with_successor(
  runs: store.Store,
  effects: process.Subject(Nil),
) -> graph.Runtime(Nil, Int, Int) {
  let last = definition.node_id("effect")
  let waiting =
    definition.node(
      node_id(),
      operation.await_signal(codec.int(), review()),
      fn(n) { Ok(n) },
      fn(n, _) { Ok(definition.Continue(n, last)) },
      [last],
    )
  let successor =
    definition.node(
      last,
      operation.new(
        run.DefinitionId("effect", 1),
        codec.int(),
        codec.int(),
        fn(_, _, n) {
          process.send(effects, Nil)
          Ok(n + 1)
        },
        fn(_error: Nil) { tool.Explain("cannot fail") },
      ),
      fn(n) { Ok(n) },
      fn(_, n) { Ok(definition.Finish(n, n)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("signal-effect", 1),
        entry: node_id(),
        nodes: [waiting, successor],
        state: codec.int(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(2),
    )
  graph.new(spec, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
}

pub fn unconfirmed_signal_consumption_releases_no_successor_effect_test() {
  let backend = flaky.new()
  let effects = process.new_subject()
  let assert Ok(handle) =
    graph.start(
      with_successor(flaky.store(backend), effects),
      run_id("signal-fence"),
      1,
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingSignal(reference) = waiting
  flaky.arm(backend, [flaky.FailLate])
  let assert Error(graph.StoreUnavailable(_)) =
    graph.deliver(handle, reference, review(), True)
  process.receive(effects, 0) |> should.equal(Error(Nil))
  // The first delivery lands just before the second commit. The second
  // commit loses CAS, observes the saved receipt, and cannot release its
  // own candidate. The abandoned owner's successor requires recovery.
  let assert Ok(_) = graph.deliver(handle, reference, review(), True)
  process.receive(effects, 0) |> should.equal(Error(Nil))
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(done) = graph.snapshot(handle)
  done.status |> should.equal(graph.Completed(2))
  process.receive(effects, 1000) |> should.equal(Ok(Nil))
  process.receive(effects, 0) |> should.equal(Error(Nil))
  list.length(done.receipts) |> should.equal(2)
}

pub fn cancellation_wins_against_a_held_delivery_commit_test() {
  let backend = flaky.new()
  let effects = process.new_subject()
  let assert Ok(handle) =
    graph.start(
      with_successor(flaky.store(backend), effects),
      run_id("signal-race"),
      1,
      correlation: None,
    )
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.AwaitingSignal(reference) = waiting
  let canceller =
    support.open_graph(
      with_successor(flaky.store(backend), effects),
      graph.id(handle),
    )
  let held = flaky.hold(backend, fn(_) { True })
  let reply = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(reply, graph.deliver(handle, reference, review(), True))
  })
  let assert Ok(_) = process.receive(held, 30_000)
  let assert Ok(_) = graph.cancel(canceller)
  flaky.release_held(backend)
  let assert Ok(Error(graph.RunEnded)) = process.receive(reply, 30_000)
  let assert Ok(cancelled) = graph.snapshot(handle)
  cancelled.status |> should.equal(graph.Cancelled(graph.BeforeStart))
  cancelled.receipts |> should.equal([])
  process.receive(effects, 0) |> should.equal(Error(Nil))
}

pub fn recovery_refuses_a_signal_contract_replaced_by_an_activity_test() {
  let runs = support.store()
  let id = run_id("signal-definition")
  let assert Ok(handle) = graph.start(runtime(runs), id, 1, correlation: None)
  let assert Ok(_) = graph.await(handle, within: duration.milliseconds(5000))
  let assert Ok(waiting) = graph.snapshot(handle)
  let assert graph.AwaitingSignal(_) = waiting.status
  let node =
    definition.node(
      node_id(),
      operation.new(
        run.DefinitionId("human-review", 1),
        codec.int(),
        codec.bool(),
        fn(_, _, _) { panic as "never execute a changed contract" },
        fn(_error: Nil) { tool.Explain("cannot fail") },
      ),
      fn(n) { Ok(n) },
      accept,
      [node_id()],
    )
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("human-loop", 1),
        entry: node_id(),
        nodes: [node],
        state: codec.int(),
        answer: codec.int(),
      )
      |> definition.with_max_activations(3),
    )
  let replacement =
    graph.new(spec, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
  graph.open(replacement, id) |> result.is_error |> should.be_true
  let assert Ok(unchanged) = graph.snapshot(handle)
  unchanged.revision |> should.equal(waiting.revision)
}

import fabric/graph
import fabric/graph/definition
import fabric/graph/fork
import fabric/graph/operation
import fabric/internal/graph/controller
import fabric/internal/graph/record
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/restart
import gleam/erlang/process
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn node_id(name: String) -> definition.NodeId {
  let assert Ok(id) = definition.node_id(name)
  id
}

fn member(
  runs: store.Store,
  name: String,
  input: codec.Codec(input),
  output: codec.Codec(output),
  perform: fn(input) -> Result(output, operation.Failure),
) -> graph.Runtime(Nil, input, output) {
  member_with_policy(runs, name, input, output, perform, fn(_, _) {
    Ok(policy.Allow)
  })
}

fn member_with_policy(
  runs: store.Store,
  name: String,
  input: codec.Codec(input),
  output: codec.Codec(output),
  perform: fn(input) -> Result(output, operation.Failure),
  policy: graph.Policy(Nil),
) -> graph.Runtime(Nil, input, output) {
  let node =
    definition.node(
      node_id("work"),
      operation.new(
        run.Identity(name <> "-work", 1),
        input,
        output,
        fn(_, _, value) { perform(value) },
        fn(failure) { failure },
      ),
      fn(value) { Ok(value) },
      fn(state, output) { Ok(definition.Finish(state, output)) },
      [],
    )
  let assert Ok(definition) =
    definition.build(definition.Spec(
      run.Identity(name, 1),
      node_id("work"),
      [node],
      input,
      output,
      1,
    ))
  graph.new(definition, runs, fn() { Nil }, policy)
}

fn paired(
  runs: store.Store,
  left: graph.Runtime(Nil, Int, Int),
  right: graph.Runtime(Nil, String, String),
) -> graph.Runtime(Nil, #(Int, String), #(Int, String)) {
  paired_with(runs, left, right, fn(state, outcome) {
    case outcome {
      Ok(output) -> Ok(definition.Finish(state, output))
      Error(failure) ->
        Ok(definition.Finish(state, #(-failure.member, "fallback")))
    }
  })
}

fn paired_with(
  runs: store.Store,
  left: graph.Runtime(Nil, Int, Int),
  right: graph.Runtime(Nil, String, String),
  accept: fn(#(Int, String), Result(#(Int, String), fork.Failure)) ->
    Result(definition.Command(#(Int, String), #(Int, String)), String),
) -> graph.Runtime(Nil, #(Int, String), #(Int, String)) {
  let values = codec.pair(codec.int(), codec.string())
  let assert Ok(both) = graph.both(run.Identity("paired-work", 1), left, right)
  let node =
    definition.node(node_id("pair"), both, fn(state) { Ok(state) }, accept, [])
  let assert Ok(definition) =
    definition.build(definition.Spec(
      run.Identity("pair-parent", 1),
      node_id("pair"),
      [node],
      values,
      values,
      1,
    ))
  graph.new(definition, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn mapped(
  runs: store.Store,
  child: graph.Runtime(Nil, Int, Int),
  maximum: Int,
  concurrency: Int,
) -> graph.Runtime(Nil, List(Int), List(Int)) {
  let values = codec.list(codec.int())
  let assert Ok(map) =
    graph.map(
      run.Identity("mapped-work", 1),
      child,
      max_members: maximum,
      concurrency: concurrency,
    )
  let node =
    definition.node(
      node_id("map"),
      map,
      fn(state) { Ok(state) },
      fn(state, outcome) {
        case outcome {
          Ok(output) -> Ok(definition.Finish(state, output))
          Error(failure) -> Ok(definition.Finish(state, [-failure.member]))
        }
      },
      [],
    )
  let assert Ok(definition) =
    definition.build(definition.Spec(
      run.Identity("map-parent", 1),
      node_id("map"),
      [node],
      values,
      values,
      1,
    ))
  graph.new(definition, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

// G9, F1–F4: later members start only when a slot settles; results stay ordered.
pub fn map_limits_concurrency_and_joins_in_input_order_test() {
  let runs = support.store()
  let started = process.new_subject()
  let child =
    member(runs, "mapped-integer", codec.int(), codec.int(), fn(n) {
      let release = process.new_subject()
      process.send(started, #(n, release))
      let assert Ok(Nil) = process.receive(release, 5000)
      Ok(n * 10)
    })
  let assert Ok(handle) =
    graph.start(mapped(runs, child, 3, 2), support.id("map-order"), [1, 2, 3])
  let assert Ok(first) = process.receive(started, 2000)
  let assert Ok(second) = process.receive(started, 2000)
  let assert Ok(#(_, release_first)) =
    list.find([first, second], fn(entry) { entry.0 == 1 })
  let assert Ok(#(_, release_second)) =
    list.find([first, second], fn(entry) { entry.0 == 2 })
  process.receive(started, 20) |> should.be_error
  process.send(release_second, Nil)
  let assert Ok(#(3, release_third)) = process.receive(started, 2000)
  process.send(release_third, Nil)
  let assert Ok(third) = graph.branch(handle, 1, 3, child)
  let assert Ok(third_done) =
    graph.await(third, within: duration.milliseconds(5000))
  third_done.status |> should.equal(graph.Completed(30))
  process.send(release_first, Nil)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed([10, 20, 30]))
  let assert [scope] = done.forks
  scope.concurrency |> should.equal(2)
  list.length(scope.members) |> should.equal(3)
}

// F1: bounds are checked before authoring; empty and oversized inputs own no child.
pub fn map_validates_bounds_and_handles_empty_and_oversized_input_test() {
  let runs = support.store()
  let started = process.new_subject()
  let child =
    member(runs, "mapped-integer", codec.int(), codec.int(), fn(n) {
      process.send(started, n)
      Ok(n)
    })
  graph.map(run.Identity("map", 1), child, max_members: 0, concurrency: 1)
  |> should.be_error
  graph.map(run.Identity("map", 1), child, max_members: 2, concurrency: 0)
  |> should.be_error
  let runtime = mapped(runs, child, 2, 1)
  let assert Ok(empty) = graph.start(runtime, support.id("map-empty"), [])
  let assert Ok(done) = graph.await(empty, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed([]))
  graph.branch(empty, 1, 1, child) |> should.be_error
  let assert Ok(oversized) =
    graph.start(runtime, support.id("map-oversized"), [1, 2, 3])
  let assert Ok(failed) =
    graph.await(oversized, within: duration.milliseconds(5000))
  let assert graph.Failed(_) = failed.status
  failed.forks |> should.equal([])
  graph.branch(oversized, 1, 1, child) |> should.be_error
  process.receive(started, 0) |> should.be_error
}

// G9: identical input values retain different children and ordered result slots.
pub fn map_equal_inputs_remain_independently_owned_children_test() {
  let runs = support.store()
  let child =
    member(runs, "mapped-integer", codec.int(), codec.int(), fn(n) { Ok(n + 1) })
  let assert Ok(handle) =
    graph.start(mapped(runs, child, 2, 2), support.id("map-equal"), [41, 41])
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed([42, 42]))
  let assert Ok(first) = graph.branch(handle, 1, 1, child)
  let assert Ok(second) = graph.branch(handle, 1, 2, child)
  { graph.id(first) == graph.id(second) } |> should.be_false
}

fn map_approval_member(runs: store.Store) -> graph.Runtime(Nil, Int, Int) {
  member_with_policy(
    runs,
    "mapped-integer",
    codec.int(),
    codec.int(),
    fn(n) { Ok(n + 10) },
    fn(_, action) {
      case action.input_json {
        "2" -> Ok(policy.RequireApproval(run.Requirement("review", 1)))
        _ -> Ok(policy.Allow)
      }
    },
  )
}

// G7, G9, F2, F8: idle members occupy capacity across process loss.
pub fn map_restart_keeps_completed_waiting_and_pending_members_distinct_test() {
  let directory = restart.temp_dir()
  let id = support.id("map-restart")
  let #(owner, #(runs, handle, child)) =
    restart.owned(fn() {
      let runs = support.directory(directory)
      let child = map_approval_member(runs)
      let assert Ok(handle) =
        graph.start(mapped(runs, child, 3, 1), id, [1, 2, 3])
      #(runs, handle, child)
    })
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Fork(scope, _) = waiting.status
  let assert [
    fork.Member(_, fork.Admitted(fork.Succeeded("11"))),
    fork.Member(_, fork.Admitted(fork.Active)),
    fork.Member(_, fork.Pending),
  ] = scope.members
  graph.branch(handle, 1, 3, child) |> should.be_error
  let assert Ok(second) = graph.branch(handle, 1, 2, child)
  let assert Ok(second_waiting) = graph.read(second)
  let assert graph.AwaitingApproval(approval) = second_waiting.status
  restart.crash(owner, runs)
  let runs = support.directory(directory)
  let child = map_approval_member(runs)
  let handle = graph.attach(mapped(runs, child, 3, 1), id)
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Fork(restored, _) = waiting.status
  restored.members |> should.equal(scope.members)
  graph.branch(handle, 1, 3, child) |> should.be_error
  let assert Ok(second) = graph.branch(handle, 1, 2, child)
  let assert Ok(_) = graph.approve(second, approval)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed([11, 12, 13]))
  let assert Ok(first) = graph.branch(handle, 1, 1, child)
  let assert Ok(first_done) = graph.read(first)
  list.length(first_done.receipts) |> should.equal(1)
  restart.remove_dir(directory)
}

// F5: a failed member withdraws later inputs; the parent can route its failure.
pub fn map_failure_keeps_completed_results_and_does_not_start_pending_members_test() {
  let runs = support.store()
  let started = process.new_subject()
  let child =
    member(runs, "mapped-integer", codec.int(), codec.int(), fn(n) {
      process.send(started, n)
      case n {
        2 -> Error(operation.DefiniteFailure("unavailable"))
        _ -> Ok(n + 10)
      }
    })
  let assert Ok(handle) =
    graph.start(mapped(runs, child, 3, 1), support.id("map-failure"), [1, 2, 3])
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed([-2]))
  let assert [scope] = done.forks
  let assert [
    fork.Member(_, fork.Admitted(fork.Succeeded("11"))),
    fork.Member(_, fork.Admitted(fork.Failed(_))),
    fork.Member(_, fork.Withdrawn),
  ] = scope.members
  graph.branch(handle, 1, 3, child) |> should.be_error
  process.receive(started, 0) |> should.equal(Ok(1))
  process.receive(started, 0) |> should.equal(Ok(2))
  process.receive(started, 0) |> should.be_error
}

// F6, F8: a failed join retains its members; cancellation releases no route.
pub fn cancel_after_join_failure_keeps_both_completed_members_test() {
  let runs = support.store()
  let left =
    member(runs, "integer", codec.int(), codec.int(), fn(n) { Ok(n + 1) })
  let right =
    member(runs, "text", codec.string(), codec.string(), fn(text) {
      Ok(string.uppercase(text))
    })
  let runtime =
    paired_with(runs, left, right, fn(state, outcome) {
      case outcome {
        Ok(#(42, "TWO")) -> Error("invalid route")
        Ok(output) -> Ok(definition.Finish(state, output))
        Error(_) -> Error("unexpected failure")
      }
    })
  let assert Ok(id) = run.parse_id("pair-join-failure")
  let assert Ok(handle) = graph.start(runtime, id, #(41, "two"))
  let assert Ok(blocked) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Blocked(reference, graph.InvalidResult(_, _)) =
    blocked.status
  blocked.receipts |> should.equal([])
  let output = fork.result_codec(codec.pair(codec.int(), codec.string()))
  let assert Ok(forged) = codec.encode_json(output, Ok(#(99, "changed")))
  graph.reconcile(handle, reference, forged) |> should.be_error
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Cancelled(graph.ForkSettled(1)))
  done.receipts |> should.equal([])
  let assert Ok(left_handle) = graph.branch(handle, 1, 1, left)
  let assert Ok(right_handle) = graph.branch(handle, 1, 2, right)
  let assert Ok(left_done) = graph.read(left_handle)
  let assert Ok(right_done) = graph.read(right_handle)
  left_done.status |> should.equal(graph.Completed(42))
  right_done.status |> should.equal(graph.Completed("TWO"))
  list.length(left_done.receipts) |> should.equal(1)
  list.length(right_done.receipts) |> should.equal(1)
}

// G1, G9, F2–F4: neither child may finish until both have actually started.
pub fn typed_pair_runs_real_children_concurrently_and_retains_ordered_answers_test() {
  let runs = support.store()
  let started = process.new_subject()
  let left =
    member(runs, "integer", codec.int(), codec.int(), fn(value) {
      let release = process.new_subject()
      process.send(started, #("left", release))
      let assert Ok(Nil) = process.receive(release, 5000)
      Ok(value + 1)
    })
  let right =
    member(runs, "text", codec.string(), codec.string(), fn(value) {
      let release = process.new_subject()
      process.send(started, #("right", release))
      let assert Ok(Nil) = process.receive(release, 5000)
      Ok(string.uppercase(value))
    })
  let assert Ok(run_id) = run.parse_id("typed-pair")
  let assert Ok(handle) =
    graph.start(paired(runs, left, right), run_id, #(41, "two"))
  let assert Ok(first) = process.receive(started, 2000)
  let assert Ok(second) = process.receive(started, 2000)
  let gates = [first, second]
  let assert Ok(#(_, right_gate)) =
    list.find(gates, fn(entry) { entry.0 == "right" })
  let assert Ok(#(_, left_gate)) =
    list.find(gates, fn(entry) { entry.0 == "left" })
  process.send(right_gate, Nil)
  let assert Ok(right_handle) = graph.branch(handle, 1, 2, right)
  let assert Ok(right_done) =
    graph.await(right_handle, within: duration.milliseconds(5000))
  right_done.status |> should.equal(graph.Completed("TWO"))
  process.send(left_gate, Nil)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(#(42, "TWO")))
  let assert Ok(left_handle) = graph.branch(handle, 1, 1, left)
  { graph.id(left_handle) == graph.id(right_handle) } |> should.be_false
  let assert Ok(left_done) = graph.read(left_handle)
  left_done.status |> should.equal(graph.Completed(42))
  list.length(done.forks) |> should.equal(1)
  list.length(done.receipts) |> should.equal(1)
}

// G9, F5: a settled failure is a typed decision input for the parent's route.
pub fn a_definite_member_failure_can_route_to_a_typed_fallback_test() {
  let runs = support.store()
  let started = process.new_subject()
  let left =
    member(runs, "integer", codec.int(), codec.int(), fn(n) { Ok(n + 1) })
  let right =
    member(runs, "text", codec.string(), codec.string(), fn(_) {
      let release = process.new_subject()
      process.send(started, release)
      let assert Ok(Nil) = process.receive(release, 5000)
      Error(operation.DefiniteFailure("review unavailable"))
    })
  let assert Ok(run_id) = run.parse_id("pair-fallback")
  let assert Ok(handle) =
    graph.start(paired(runs, left, right), run_id, #(41, "two"))
  let assert Ok(release) = process.receive(started, 2000)
  let assert Ok(left_handle) = graph.branch(handle, 1, 1, left)
  let assert Ok(left_done) =
    graph.await(left_handle, within: duration.milliseconds(5000))
  left_done.status |> should.equal(graph.Completed(42))
  process.send(release, Nil)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(#(-2, "fallback")))
  let assert Ok(right_handle) = graph.branch(handle, 1, 2, right)
  let assert Ok(right_done) = graph.read(right_handle)
  let assert graph.Failed(_) = right_done.status
}

// F5–F7: canceling during failure cleanup must not later run the fallback.
pub fn parent_cancel_during_uncertain_sibling_cleanup_suppresses_fallback_test() {
  let runs = support.store()
  let started = process.new_subject()
  let left =
    member(runs, "integer", codec.int(), codec.int(), fn(n) {
      let release = process.new_subject()
      process.send(started, #("left", release))
      let assert Ok(Nil) = process.receive(release, 5000)
      Ok(n + 1)
    })
  let right =
    member(runs, "text", codec.string(), codec.string(), fn(_) {
      let release = process.new_subject()
      process.send(started, #("right", release))
      let assert Ok(Nil) = process.receive(release, 5000)
      Error(operation.DefiniteFailure("unavailable"))
    })
  let assert Ok(id) = run.parse_id("pair-cancel-failure-cleanup")
  let assert Ok(handle) =
    graph.start(paired(runs, left, right), id, #(41, "two"))
  let assert Ok(first) = process.receive(started, 2000)
  let assert Ok(second) = process.receive(started, 2000)
  let assert Ok(#(_, release)) =
    list.find([first, second], fn(entry) { entry.0 == "right" })
  process.send(release, Nil)
  let assert Ok(uncertain) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Fork(scope, _) = uncertain.status
  let assert Some(fork.MemberFailed(failed)) = scope.stop
  failed.member |> should.equal(2)
  let assert [fork.Member(_, fork.Admitted(fork.Uncertain(_))), _] =
    scope.members
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Fork(_, Some(operation.CancellationRequested)) =
    waiting.status
  let assert Ok(left_handle) = graph.branch(handle, 1, 1, left)
  let assert Ok(left_cancelled) = graph.read(left_handle)
  let assert graph.Cancelled(graph.Unresolved(reference, _)) =
    left_cancelled.status
  let assert Ok(_) = graph.reconcile(left_handle, reference, "42")
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Cancelled(graph.ForkSettled(1)))
  done.value |> should.equal(#(41, "two"))
  done.receipts |> should.equal([])
}

fn approval_members(
  runs: store.Store,
) -> #(graph.Runtime(Nil, Int, Int), graph.Runtime(Nil, String, String)) {
  #(
    member(runs, "integer", codec.int(), codec.int(), fn(n) { Ok(n + 1) }),
    member_with_policy(
      runs,
      "text",
      codec.string(),
      codec.string(),
      fn(text) { Ok(string.uppercase(text)) },
      fn(_, _) { Ok(policy.RequireApproval(run.Requirement("review", 1))) },
    ),
  )
}

// G7, G9, F8: restore one result and one idle member, then wake on its approval.
pub fn partial_pair_survives_store_loss_and_joins_the_same_children_test() {
  let directory = restart.temp_dir()
  let assert Ok(id) = run.parse_id("pair-restart")
  let #(owner, #(runs, handle, left, right)) =
    restart.owned(fn() {
      let runs = support.directory(directory)
      let #(left, right) = approval_members(runs)
      let assert Ok(handle) =
        graph.start(paired(runs, left, right), id, #(41, "two"))
      #(runs, handle, left, right)
    })
  let assert Ok(waiting) =
    graph.await(handle, within: duration.milliseconds(5000))
  let assert graph.Fork(saved, _) = waiting.status
  let assert [
    fork.Member(_, fork.Admitted(fork.Succeeded(_))),
    fork.Member(_, fork.Admitted(fork.Active)),
  ] = saved.members
  let assert Ok(left_handle) = graph.branch(handle, 1, 1, left)
  let assert Ok(right_handle) = graph.branch(handle, 1, 2, right)
  let left_id = graph.id(left_handle)
  let right_id = graph.id(right_handle)
  let assert Ok(right_waiting) = graph.read(right_handle)
  let assert graph.AwaitingApproval(approval) = right_waiting.status
  restart.crash(owner, runs)
  let runs = support.directory(directory)
  let #(left, right) = approval_members(runs)
  let handle = graph.attach(paired(runs, left, right), id)
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(left_handle) = graph.branch(handle, 1, 1, left)
  let assert Ok(right_handle) = graph.branch(handle, 1, 2, right)
  graph.id(left_handle) |> should.equal(left_id)
  graph.id(right_handle) |> should.equal(right_id)
  let assert Ok(_) = graph.approve(right_handle, approval)
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(#(42, "TWO")))
  let assert Ok(left_done) = graph.read(left_handle)
  list.length(left_done.receipts) |> should.equal(1)
  restart.remove_dir(directory)
}

// F8: restoring a typed pair checks exact membership and retained join evidence.
pub fn typed_pair_rejects_changed_members_and_saved_outputs_test() {
  let runs = support.store()
  let left =
    member(runs, "integer", codec.int(), codec.int(), fn(n) { Ok(n + 1) })
  let right =
    member(runs, "text", codec.string(), codec.string(), fn(text) { Ok(text) })
  let assert Ok(id) = run.parse_id("pair-corruption")
  let assert Ok(handle) =
    graph.start(paired(runs, left, right), id, #(41, "two"))
  let assert Ok(done) = graph.await(handle, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(#(42, "two")))
  let assert Ok(entry) = store.get(runs, run.id_to_string(id))
  let assert Ok(saved) = record.decode(entry.record)
  let assert [scope] = saved.forks
  let assert [first, second] = scope.members
  let replacements = [
    [first],
    [
      fork.Member(..first, request: fork.Request(..first.request, input: "999")),
      second,
    ],
    [fork.Member(..first, status: fork.Admitted(fork.Succeeded("999"))), second],
  ]
  list.fold(replacements, entry.revision, fn(revision, members) {
    let corrupt =
      controller.State(..saved, forks: [
        fork.Snapshot(..scope, members: members),
      ])
    let assert Ok(bytes) = record.encode(corrupt)
    let assert Ok(revision) =
      store.commit(
        runs,
        run.id_to_string(id),
        revision,
        bytes,
        store.Detached(False, False),
      )
    graph.read(handle) |> should.be_error
    graph.recover(handle) |> should.be_error
    revision
  })
  Nil
}

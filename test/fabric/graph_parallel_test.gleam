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
  let assert Ok(blocked) = graph.await(handle, 5000)
  let assert graph.Blocked(reference, graph.InvalidResult(_, _)) =
    blocked.status
  blocked.receipts |> should.equal([])
  let assert Ok(output) =
    fork.result_codec(codec.pair(codec.int(), codec.string()))
  let assert Ok(forged) = codec.encode_json(output, Ok(#(99, "changed")))
  graph.reconcile(handle, reference, forged) |> should.be_error
  let assert Ok(_) = graph.recover(handle)
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(done) = graph.await(handle, 5000)
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
  let assert Ok(right_done) = graph.await(right_handle, 5000)
  right_done.status |> should.equal(graph.Completed("TWO"))
  process.send(left_gate, Nil)
  let assert Ok(done) = graph.await(handle, 5000)
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
  let assert Ok(left_done) = graph.await(left_handle, 5000)
  left_done.status |> should.equal(graph.Completed(42))
  process.send(release, Nil)
  let assert Ok(done) = graph.await(handle, 5000)
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
  let assert Ok(uncertain) = graph.await(handle, 5000)
  let assert graph.Fork(scope, _) = uncertain.status
  let assert Some(fork.MemberFailed(failed)) = scope.stop
  failed.member |> should.equal(2)
  let assert [fork.Member(_, fork.Admitted(fork.Uncertain(_))), _] =
    scope.members
  let assert Ok(_) = graph.cancel(handle)
  let assert Ok(waiting) = graph.await(handle, 5000)
  let assert graph.Fork(_, Some(operation.CancellationRequested)) =
    waiting.status
  let assert Ok(left_handle) = graph.branch(handle, 1, 1, left)
  let assert Ok(left_cancelled) = graph.read(left_handle)
  let assert graph.Cancelled(graph.Unresolved(reference, _)) =
    left_cancelled.status
  let assert Ok(_) = graph.reconcile(left_handle, reference, "42")
  let assert Ok(done) = graph.await(handle, 5000)
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
  let assert Ok(waiting) = graph.await(handle, 5000)
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
  let assert Ok(done) = graph.await(handle, 5000)
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
  let assert Ok(done) = graph.await(handle, 5000)
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

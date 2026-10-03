//// G3, G7, G9: fork identity and family capacity survive composition and restart.

import fabric/budget
import fabric/graph
import fabric/graph/definition
import fabric/graph/fork
import fabric/graph/operation
import fabric/graph/signal
import fabric/policy
import fabric/run
import fabric/store
import fabric/support
import fabric/support/restart
import gleam/list
import gleam/time/duration
import gleeunit/should
import json/blueprint/codec

fn node_id() -> definition.NodeId {
  let assert Ok(id) = definition.node_id("work")
  id
}

fn response() -> signal.Signal(Int) {
  signal.new(run.Identity("branch-answer", 1), codec.int())
}

fn leaf(runs: store.Store) -> graph.Runtime(Nil, Int, Int) {
  let node =
    definition.node(
      node_id(),
      operation.await_signal(codec.int(), response()),
      fn(value) { Ok(value) },
      fn(state, value) { Ok(definition.Finish(state, value)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("branch", 1),
      node_id(),
      [node],
      codec.int(),
      codec.int(),
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn mapped(
  runs: store.Store,
  name: String,
  member: graph.Runtime(Nil, input, output),
  input: codec.Codec(input),
  output: codec.Codec(output),
) -> graph.Runtime(Nil, List(input), Result(List(output), fork.Failure)) {
  let assert Ok(op) =
    graph.map(run.Identity(name, 1), member, max_members: 4, concurrency: 3)
  let node =
    definition.node(
      node_id(),
      op,
      fn(values) { Ok(values) },
      fn(state, values) { Ok(definition.Finish(state, values)) },
      [],
    )
  let output = fork.result_codec(codec.list(output))
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity(name, 1),
      node_id(),
      [node],
      codec.list(input),
      output,
      1,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn inner(runs: store.Store) {
  mapped(runs, "inner", leaf(runs), codec.int(), codec.int())
}

fn outer(runs: store.Store) {
  let answer = fork.result_codec(codec.list(codec.int()))
  mapped(runs, "outer", inner(runs), codec.list(codec.int()), answer)
}

fn repeated(runs: store.Store) {
  let values = codec.list(codec.int())
  let answer = fork.result_codec(values)
  let assert Ok(op) =
    graph.map(run.Identity("repeated-map", 1), leaf(runs), 2, 2)
  let node =
    definition.node(
      node_id(),
      op,
      fn(state: #(Int, List(Int))) { Ok(state.1) },
      fn(state: #(Int, List(Int)), output) {
        case state.0, output {
          0, Ok(_) -> Ok(definition.Continue(#(1, state.1), node_id()))
          _, _ -> Ok(definition.Finish(state, output))
        }
      },
      [node_id()],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("repeated", 1),
      node_id(),
      [node],
      codec.pair(codec.int(), values),
      answer,
      2,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

fn waiting_branch(parent, activation, ordinal, runs) {
  let assert Ok(branch) = graph.branch(parent, activation, ordinal, leaf(runs))
  let assert Ok(waiting) =
    graph.await(branch, within: duration.milliseconds(5000))
  let assert graph.AwaitingSignal(reference) = waiting.status
  #(branch, reference)
}

// Exact capacity covers two visits and four children, including recovery.
pub fn repeated_forks_keep_prior_results_separate_and_reuse_budget_after_restart_test() {
  let directory = restart.temp_dir()
  let id = support.id("repeated-forks")
  let #(owner, #(runs, root)) =
    restart.owned(fn() {
      let runs = support.directory(directory)
      let assert Ok(root) =
        graph.start_with_budget(
          repeated(runs),
          id,
          #(0, [7, 7]),
          budget.Limits(work: 6, children: 4, depth: 1),
        )
      #(runs, root)
    })
  let assert Ok(_) = graph.await(root, within: duration.milliseconds(5000))
  let old = list.map([1, 2], waiting_branch(root, 1, _, runs))
  list.each(old, fn(branch) {
    graph.deliver(branch.0, branch.1, response(), 10) |> should.be_ok
  })
  let assert Ok(waiting) =
    graph.await(root, within: duration.milliseconds(5000))
  let assert graph.Fork(current, _) = waiting.status
  current.occurrence.activation |> should.equal(2)
  let current = list.map([1, 2], waiting_branch(root, 2, _, runs))
  list.map(current, fn(branch) { graph.id(branch.0) })
  |> list.append(list.map(old, fn(branch) { graph.id(branch.0) }))
  |> list.unique
  |> list.length
  |> should.equal(4)
  restart.crash(owner, runs)
  let runs = support.directory(directory)
  let root = graph.attach(repeated(runs), id)
  graph.recover(root) |> should.be_ok
  let assert Ok(restored) =
    graph.await(root, within: duration.milliseconds(5000))
  restored.forks |> should.equal(waiting.forks)
  list.each(list.zip(old, current), fn(branches) {
    let old = branches.0
    let current = branches.1
    let saved = graph.attach(leaf(runs), graph.id(old.0))
    graph.deliver(saved, old.1, response(), 10) |> should.be_ok
    let next = graph.attach(leaf(runs), graph.id(current.0))
    graph.deliver(next, old.1, response(), 99) |> should.be_error
    let assert Ok(still_waiting) = graph.read(next)
    still_waiting.status |> should.equal(graph.AwaitingSignal(current.1))
    graph.deliver(next, current.1, response(), 20) |> should.be_ok
  })
  let assert Ok(done) = graph.await(root, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(Ok([20, 20])))
  list.map(done.receipts, fn(receipt) { receipt.activation })
  |> should.equal([1, 2])
  let assert [previous, current] = done.forks
  list.map(previous.members, fn(member) { member.status })
  |> should.equal(list.repeat(fork.Admitted(fork.Succeeded("10")), 2))
  list.map(current.members, fn(member) { member.status })
  |> should.equal(list.repeat(fork.Admitted(fork.Succeeded("20")), 2))
  restart.remove_dir(directory)
}

// Equal child definitions and payloads cannot make sibling scopes share results.
pub fn sibling_maps_keep_private_joins_with_one_shared_family_budget_test() {
  let runs = support.store()
  let assert Ok(root) =
    graph.start_with_budget(
      outer(runs),
      support.id("sibling-maps"),
      [[7, 7], [7, 7]],
      budget.Limits(work: 7, children: 6, depth: 2),
    )
  let assert Ok(_) = graph.await(root, within: duration.milliseconds(5000))
  let assert Ok(left) = graph.branch(root, 1, 1, inner(runs))
  let assert Ok(right) = graph.branch(root, 1, 2, inner(runs))
  let left_branches = list.map([1, 2], waiting_branch(left, 1, _, runs))
  let right_branches = list.map([1, 2], waiting_branch(right, 1, _, runs))
  list.map(list.append(left_branches, right_branches), fn(branch) {
    graph.id(branch.0)
  })
  |> list.unique
  |> list.length
  |> should.equal(4)
  list.each(right_branches, fn(branch) {
    graph.deliver(branch.0, branch.1, response(), 20) |> should.be_ok
  })
  let assert Ok(done) = graph.await(right, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(Ok([20, 20])))
  let assert Ok(waiting) =
    graph.await(left, within: duration.milliseconds(5000))
  let assert graph.Fork(_, _) = waiting.status
  waiting.receipts |> should.equal([])
  list.each(list.zip(left_branches, right_branches), fn(branches) {
    let left = branches.0
    let right = branches.1
    graph.deliver(left.0, right.1, response(), 99) |> should.be_error
    graph.deliver(left.0, left.1, response(), 10) |> should.be_ok
  })
  let assert Ok(done) = graph.await(root, within: duration.milliseconds(5000))
  done.status |> should.equal(graph.Completed(Ok([Ok([10, 10]), Ok([20, 20])])))
}

// Denied members own no child; already admitted signal waits settle on failure.
pub fn child_budget_closes_admission_and_keeps_refused_members_distinct_test() {
  let runs = support.store()
  let assert Ok(root) =
    graph.start_with_budget(
      inner(runs),
      support.id("fork-child-limit"),
      [1, 2, 3, 4],
      budget.Limits(work: 10, children: 2, depth: 1),
    )
  let assert Ok(done) = graph.await(root, within: duration.milliseconds(5000))
  let assert graph.Completed(Error(failure)) = done.status
  failure.member |> should.equal(3)
  let assert [saved] = done.forks
  let assert [
    fork.Member(_, fork.Admitted(fork.Cancelled)),
    fork.Member(_, fork.Admitted(fork.Cancelled)),
    fork.Member(_, fork.Rejected(_)),
    fork.Member(_, fork.Withdrawn),
  ] = saved.members
  list.each([3, 4], fn(ordinal) {
    graph.branch(root, 1, ordinal, leaf(runs)) |> should.be_error
  })
  graph.recover(root) |> should.be_ok
  let assert Ok(restored) = graph.read(root)
  restored.forks |> should.equal(done.forks)
}

// Every nested admission uses ancestry depth; a new scope does not reset it.
pub fn nested_forks_cannot_reset_the_family_depth_limit_test() {
  let runs = support.store()
  let assert Ok(root) =
    graph.start_with_budget(
      outer(runs),
      support.id("fork-depth-limit"),
      [[7, 7], [7, 7]],
      budget.Limits(work: 10, children: 6, depth: 1),
    )
  let assert Ok(done) = graph.await(root, within: duration.milliseconds(5000))
  let assert graph.Completed(Ok([Error(left), Error(right)])) = done.status
  left.member |> should.equal(1)
  right.member |> should.equal(1)
  list.each([1, 2], fn(ordinal) {
    let assert Ok(parent) = graph.branch(root, 1, ordinal, inner(runs))
    let assert Ok(done) = graph.read(parent)
    let assert [saved] = done.forks
    let assert [
      fork.Member(_, fork.Rejected(_)),
      fork.Member(_, fork.Withdrawn),
    ] = saved.members
    graph.branch(parent, 1, 1, leaf(runs)) |> should.be_error
  })
}

// The map activation consumes the last work grant; members cannot start waits.
pub fn fork_members_share_the_parents_work_limit_test() {
  let runs = support.store()
  let assert Ok(root) =
    graph.start_with_budget(
      inner(runs),
      support.id("fork-work-limit"),
      [1, 2, 3],
      budget.Limits(work: 1, children: 3, depth: 1),
    )
  let assert Ok(done) = graph.await(root, within: duration.milliseconds(5000))
  let assert graph.Completed(Error(failure)) = done.status
  let assert Ok(denied) = graph.branch(root, 1, failure.member, leaf(runs))
  let assert Ok(stopped) = graph.read(denied)
  stopped.status
  |> should.equal(graph.Failed(graph.FamilyBudget(budget.WorkLimit(1))))
  stopped.receipts |> should.equal([])
}

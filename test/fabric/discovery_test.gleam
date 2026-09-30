//// G7: a validated idle dependency can be indexed without deployed callbacks.

import fabric/budget as quota
import fabric/discovery
import fabric/graph/child
import fabric/graph/operation
import fabric/internal/budget/model as budget
import fabric/internal/budget/record as budget_record
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record
import fabric/policy
import fabric/run
import fabric/support
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn initial(kind) {
  let assert Ok(#(state, _)) =
    graph.start(
      "root",
      graph.Definition(run.Identity("root", 1), "v1", 4),
      "0",
      graph.Prepared(
        "child",
        run.Identity("child", 1),
        "0",
        operation.RequireReconciliation,
        kind,
        deadline: None,
      ),
    )
  state
}

fn waiting(kind) {
  let state = initial(kind)
  let assert graph.Ready(a) = state.phase
  graph.State(
    ..state,
    phase: graph.WaitingChild(a, child.reserved_id("root", a.id)),
  )
}

fn project(state) {
  let assert Ok(encoded) = record.encode(state)
  let assert Ok(Some(wait)) = discovery.inspect(encoded)
  wait
}

pub fn idle_graph_and_agent_attachments_have_stable_discovery_keys_test() {
  list.each([operation.Subgraph, operation.Agent], fn(kind) {
    let state = waiting(kind)
    let wait = project(state)
    wait.run |> should.equal(support.id("root"))
    wait.trigger
    |> should.equal(discovery.Changed(
      support.id(child.reserved_id("root", 1)),
      None,
    ))
    project(graph.State(..state, incarnation: 8)) |> should.equal(wait)
    let assert graph.WaitingChild(a, id) = state.phase
    project(
      graph.State(
        ..state,
        phase: graph.ChildBlocked(a, id, "waiting for reconciliation"),
      ),
    )
    |> should.equal(wait)
    let joining = graph.State(..state, phase: graph.Joining(a, id))
    let assert Ok(#(next, _)) =
      graph.step(
        joining,
        graph.ChildReturned(
          graph.reference(joining, a),
          id,
          "1",
          graph.Continue("1", a.prepared),
        ),
      )
    let assert graph.Ready(next_activation) = next.phase
    let assert Ok(#(joined, _)) =
      graph.step(
        next,
        graph.Inspected(
          graph.reference(next, next_activation),
          Ok(policy.Allow),
        ),
      )
    let assert graph.Joining(next_activation, next_child) = joined.phase
    let assert Ok(#(waiting, _)) =
      graph.step(
        joined,
        graph.ChildWaiting(graph.reference(joined, next_activation), next_child),
      )
    should.be_false(project(waiting).key == wait.key)
    should.be_false(project(waiting).trigger == wait.trigger)
    let cancelled =
      graph.State(
        ..state,
        phase: graph.Ended(graph.Cancelled(
          a,
          graph.UnresolvedCancellation(graph.Uncertain("child stopped")),
        )),
      )
    project(cancelled).trigger |> should.equal(wait.trigger)
    should.be_false(project(cancelled).key == wait.key)
  })
}

pub fn free_states_without_an_idle_child_are_not_scheduled_test() {
  let state = initial(operation.Activity)
  let assert graph.Ready(a) = state.phase
  list.each(
    [
      state,
      graph.State(
        ..state,
        phase: graph.Ended(graph.Cancelled(a, graph.BeforeStart)),
      ),
      graph.State(
        ..state,
        phase: graph.Ended(graph.Cancelled(
          a,
          graph.UnresolvedCancellation(graph.Uncertain("activity interrupted")),
        )),
      ),
    ],
    fn(state) {
      let assert Ok(encoded) = record.encode(state)
      discovery.inspect(encoded) |> should.equal(Ok(None))
    },
  )
  let assert Ok(saved) = budget.new(quota.Limits(1, 1, 1))
  discovery.inspect(budget_record.encode(budget_record.Record("root", saved)))
  |> should.equal(Ok(None))
}

pub fn unknown_corrupt_and_misfiled_records_have_no_usable_discovery_index_test() {
  let assert Ok(encoded) = record.encode(waiting(operation.Subgraph))
  let indexed = discovery.encode("root", encoded)
  json.parse(indexed, decode.at(["wait", "dependency"], decode.string))
  |> should.equal(Ok(child.reserved_id("root", 1)))
  list.each(
    ["invalid", string.replace(encoded, "\"version\":12", "\"version\":1199")],
    fn(encoded) {
      discovery.inspect(encoded) |> should.be_error
      discovery.encode("root", encoded) |> should.equal("{\"version\":7}")
    },
  )
  discovery.encode("wrong", encoded) |> should.equal("{\"version\":7}")
}

pub fn completed_and_settled_child_attachments_stop_dependency_discovery_test() {
  let state = waiting(operation.Subgraph)
  let assert graph.WaitingChild(a, id) = state.phase
  let joining = graph.State(..state, phase: graph.Joining(a, id))
  let assert Ok(#(done, _)) =
    graph.step(
      joining,
      graph.ChildReturned(
        graph.reference(joining, a),
        id,
        "1",
        graph.Complete("1", "1"),
      ),
    )
  let settled =
    graph.State(
      ..state,
      phase: graph.Ended(graph.Cancelled(a, graph.AfterChild(id))),
    )
  list.each([done, settled], fn(state) {
    let assert Ok(encoded) = record.encode(state)
    discovery.inspect(encoded) |> should.equal(Ok(None))
    json.parse(
      discovery.encode("root", encoded),
      decode.field("wait", decode.optional(decode.string), decode.success),
    )
    |> should.equal(Ok(None))
  })
}

import fabric/graph/operation
import fabric/internal/controller as agent
import fabric/internal/graph/attachment
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record as graph_record
import fabric/internal/record
import fabric/model
import fabric/policy
import fabric/run
import fabric/store/retention
import fabric/support
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import sinal/correlation

fn agent_state(id, parent, actions) {
  agent.State(
    id,
    run.DefinitionId("worker", 1),
    1,
    parent,
    0,
    agent.Limits(4, None, 3, 3),
    1,
    run.TokenUsage(0, 0, 0),
    [model.UserMessage("a\u{0}b")],
    actions,
    0,
    agent.Ended(run.Cancelled),
    None,
    correlation.from_key(id),
  )
}

fn action(state, child) {
  run.ActionRecord(
    run.ActionId(1, "effect\u{0}id"),
    model.ToolCall("effect\u{0}id", "tool", "{}", None, None),
    state,
    [],
    child,
  )
}

pub fn agent_retention_uses_saved_links_and_preserves_uncertainty_test() {
  let root =
    agent_state("arbitrary-root", None, [
      action(
        run.ChildSettled(run.Cancelled),
        Some(support.id("arbitrary-root-1")),
      ),
    ])
  let leaf =
    agent_state(
      "arbitrary-root-1",
      Some(run.AgentParent(
        support.id("arbitrary-root"),
        run.ActionId(1, "effect\u{0}id"),
      )),
      [],
    )
  let assert Ok(parent) = retention.inspect(record.encode(root))
  let assert Ok(child) = retention.inspect(record.encode(leaf))
  parent.settled |> should.be_true
  child.settled |> should.be_true
  let assert [link] = parent.children
  let assert Some(back) = child.parent
  link.run |> should.equal(child.run)
  back.run |> should.equal(parent.run)
  back.key |> should.equal(link.key)
  string.contains(link.key, "\u{0}") |> should.be_false
  list.each(
    [
      run.Uncertain("lost"),
      run.Delegated,
      run.Running,
      run.Queued,
      run.AwaitingApproval(run.Requirement("review", 1), 1),
    ],
    fn(state) {
      let record =
        agent.State(..root, history: [action(state, None)]) |> record.encode
      let assert Ok(metadata) = retention.inspect(record)
      metadata.settled |> should.be_false
    },
  )
}

fn prepared(kind) {
  graph.Prepared(
    "child",
    run.DefinitionId("child", 1),
    "0",
    operation.RequireReconciliation,
    kind,
    deadline: None,
  )
}

fn next(state, event) {
  let assert Ok(#(next, _)) = graph.step(state, event)
  next
}

fn describe(state) {
  let assert Ok(encoded) = graph_record.encode(state)
  let assert Ok(metadata) = retention.inspect(encoded)
  metadata
}

pub fn graph_retention_tracks_reserved_children_receipts_and_canceled_uncertainty_test() {
  list.each([operation.Agent, operation.Subgraph], fn(kind) {
    let assert Ok(#(ready, _)) =
      graph.start(
        "custom-root",
        graph.Definition(run.DefinitionId("root", 1), "manifest", 3),
        "0",
        prepared(kind),
      )
    describe(ready).children |> should.equal([])
    describe(ready).settled |> should.be_false
    let assert graph.Ready(activation) = ready.phase
    let ref = graph.reference(ready, activation)
    let child_id = attachment.reserved_id(ready.run, activation.id)
    let joined = next(ready, graph.Inspected(ref, Ok(policy.Allow)))
    let assert [link] = describe(joined).children
    link.run |> should.equal(support.id(child_id))
    let leaf =
      agent_state(
        child_id,
        Some(run.GraphParent(support.id(ready.run), activation.id)),
        [],
      )
    let assert Ok(child) = retention.inspect(record.encode(leaf))
    let assert Some(back) = child.parent
    back.key |> should.equal(link.key)
    let complete =
      next(
        joined,
        graph.ChildReturned(ref, child_id, "42", graph.Complete("42", "42")),
      )
    describe(complete).children |> should.equal([link])
    describe(complete).settled |> should.be_true
    let failed = next(joined, graph.ChildFailed(ref, child_id, "failed"))
    describe(failed).children |> should.equal([link])
    describe(failed).settled |> should.be_true
    let canceled =
      next(joined, graph.Cancel)
      |> next(graph.ChildStopped(ref, child_id, True))
    describe(canceled).children |> should.equal([link])
    describe(canceled).settled |> should.be_false
    let settled = next(canceled, graph.ChildCancellationSettled(ref, child_id))
    describe(settled).settled |> should.be_true
    describe(settled).children |> should.equal([link])
    describe(next(ready, graph.Cancel)).children |> should.equal([])
  })
}

pub fn unreadable_future_or_wrongly_keyed_records_cannot_claim_retention_metadata_test() {
  let encoded = record.encode(agent_state("root", None, []))
  list.each(
    [
      "not json",
      "{}",
      string.replace(encoded, "\"version\":7", "\"version\":999"),
    ],
    fn(encoded) {
      retention.inspect(encoded) |> should.equal(Error(Nil))
      retention.encode("root", encoded) |> should.equal("{\"version\":11}")
    },
  )
  retention.encode("different", encoded) |> should.equal("{\"version\":11}")
}

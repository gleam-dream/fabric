import fabric/budget as quota
import fabric/graph/child
import fabric/graph/operation
import fabric/internal/budget/model as budget
import fabric/internal/budget/record as budget_record
import fabric/internal/controller as agent
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record as graph_record
import fabric/internal/record
import fabric/model
import fabric/retention
import fabric/run
import fabric/support
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

fn limits() {
  quota.Limits(8, 2, 2)
}

fn agent_root() {
  agent.State(
    "root",
    run.Identity("agent", 1),
    1,
    None,
    0,
    agent.Limits(3, None, 2, 2),
    1,
    run.TokenUsage(0, 0, 0),
    [model.UserMessage("go")],
    [],
    0,
    agent.Ended(run.Cancelled),
    Some(budget.Declaration(limits(), False)),
  )
}

fn graph_root() {
  let assert Ok(#(state, _)) =
    graph.start(
      "root",
      graph.Definition(run.Identity("graph", 1), "graph-v1", 3),
      "0",
      graph.Prepared(
        "step",
        run.Identity("step", 1),
        "0",
        operation.RequireReconciliation,
        operation.Activity,
      ),
    )
  graph.State(..state, family_budget: Some(budget.Declaration(limits(), False)))
}

pub fn agent_roots_retain_limits_and_old_writers_refuse_to_discard_them_test() {
  let state = agent_root()
  let assert Ok(encoded) = record.encode_as(state, record.V7)
  record.decode(encoded) |> should.equal(Ok(state))
  list.each([record.V2, record.V3, record.V4, record.V5, record.V6], fn(writer) {
    let assert Error(record.Unrepresentable(_, _)) =
      record.encode_as(state, writer)
    let without = agent.State(..state, family_budget: None)
    let assert Ok(old) = record.encode_as(without, writer)
    record.decode(old) |> should.equal(Ok(without))
  })
  let assert Error(record.Corrupt(_)) =
    record.decode(string.replace(
      encoded,
      "\"family_budget\":",
      "\"missing_budget\":",
    ))
  let assert Error(record.Corrupt(_)) =
    record.decode(string.replace(encoded, "\"version\":7", "\"version\":6"))
}

pub fn graph_roots_retain_limits_without_reinterpreting_version_five_test() {
  let state = graph_root()
  let assert Ok(encoded) = graph_record.encode(state)
  graph_record.decode(encoded) |> should.equal(Ok(state))
  let assert Error(graph_record.Corrupt(_)) =
    graph_record.decode(string.replace(
      encoded,
      "\"family_budget\":",
      "\"missing_budget\":",
    ))
  let assert Error(graph_record.Corrupt(_)) =
    graph_record.decode(string.replace(
      encoded,
      "\"version\":7",
      "\"version\":5",
    ))
  let without = graph.State(..state, family_budget: None)
  let assert Ok(old) = graph_record.encode(without)
  let old =
    old
    |> string.replace("\"version\":7", "\"version\":5")
    |> string.replace(",\"family_budget\":null", "")
  graph_record.decode(old) |> should.equal(Ok(without))
}

pub fn children_cannot_declare_replacement_family_limits_test() {
  let parent = support.id("parent")
  let id = child.reserved_id("parent", 1)
  let agent =
    agent.State(
      ..agent_root(),
      run: id,
      parent: Some(run.GraphParent(parent, 1)),
    )
  let assert Error(record.Unrepresentable(7, _)) =
    record.encode_as(agent, record.V7)
  let assert Error(record.Corrupt(_)) = record.decode(record.encode(agent))
  let graph =
    graph.State(
      ..graph_root(),
      run: id,
      parent: Some(run.GraphParent(parent, 1)),
    )
  let assert Error(graph_record.InvalidState(_)) = graph_record.encode(graph)
  // The same attachment without an override is valid and inherits later.
  let agent = agent.State(..agent, family_budget: None)
  record.decode(record.encode(agent)) |> should.equal(Ok(agent))
  let graph = graph.State(..graph, family_budget: None)
  let assert Ok(encoded) = graph_record.encode(graph)
  graph_record.decode(encoded) |> should.equal(Ok(graph))
}

pub fn invalid_root_limits_are_refused_by_both_codecs_test() {
  list.each(
    [quota.Limits(-1, 2, 2), quota.Limits(2, -1, 2), quota.Limits(2, 2, 64)],
    fn(limits) {
      let state =
        agent.State(
          ..agent_root(),
          family_budget: Some(budget.Declaration(limits, False)),
        )
      record.encode_as(state, record.V7) |> should.be_error
      record.decode(record.encode(state)) |> should.be_error
      graph_record.encode(
        graph.State(
          ..graph_root(),
          family_budget: Some(budget.Declaration(limits, False)),
        ),
      )
      |> should.be_error
    },
  )
}

pub fn quota_outcomes_roundtrip_but_cannot_be_hidden_in_older_formats_test() {
  list.each(
    [quota.WorkLimit(0), quota.ChildLimit(2), quota.DepthLimit(1, 2)],
    fn(reason) {
      let base = agent.State(..agent_root(), family_budget: None)
      list.each(
        [
          agent.Ended(run.BudgetExhausted(run.FamilyLimit(reason))),
          agent.Stopping(1, [], agent.FamilyBudget(reason), False),
        ],
        fn(phase) {
          let state = agent.State(..base, phase: phase)
          let assert Ok(encoded) = record.encode_as(state, record.V7)
          record.decode(encoded) |> should.equal(Ok(state))
          list.each(
            [record.V2, record.V3, record.V4, record.V5, record.V6],
            fn(writer) { record.encode_as(state, writer) |> should.be_error },
          )
          record.decode(string.replace(
            encoded,
            "\"version\":7",
            "\"version\":6",
          ))
          |> should.be_error
        },
      )
      let base = graph.State(..graph_root(), family_budget: None)
      let assert graph.Ready(activation) = base.phase
      let assert Ok(#(failed, _)) =
        graph.step(
          base,
          graph.BudgetRefused(graph.reference(base, activation), reason),
        )
      let cancelled =
        graph.State(
          ..failed,
          phase: graph.Ended(graph.Cancelled(
            activation,
            graph.AfterFailure(graph.FamilyBudget(reason)),
          )),
        )
      list.each([failed, cancelled], fn(state) {
        let assert Ok(encoded) = graph_record.encode(state)
        graph_record.decode(encoded) |> should.equal(Ok(state))
        graph_record.decode(string.replace(
          encoded,
          "\"version\":7",
          "\"version\":5",
        ))
        |> should.be_error
      })
    },
  )
}

pub fn malformed_quota_denials_and_missing_initialization_markers_are_refused_test() {
  let state =
    agent.State(
      ..agent_root(),
      phase: agent.Ended(
        run.BudgetExhausted(run.FamilyLimit(quota.DepthLimit(1, 2))),
      ),
    )
  let encoded = record.encode(state)
  list.each(
    [
      #("\"limit\":1", "\"limit\":-1"),
      #("\"requested\":2", "\"requested\":1"),
      #("\"initialized\":false", "\"missing_marker\":false"),
    ],
    fn(replacement) {
      record.decode(string.replace(encoded, replacement.0, replacement.1))
      |> should.be_error
    },
  )
  let assert Ok(encoded) = graph_record.encode(graph_root())
  graph_record.decode(string.replace(
    encoded,
    "\"initialized\":false",
    "\"missing_marker\":false",
  ))
  |> should.be_error
}

pub fn graph_cancellation_and_recovery_keep_the_root_budget_declaration_test() {
  let state = graph_root()
  let assert Ok(#(recovered, _)) = graph.recover(state)
  recovered.family_budget
  |> should.equal(Some(budget.Declaration(limits(), False)))
  let assert Ok(#(canceled, _)) = graph.step(recovered, graph.Cancel)
  let assert Ok(encoded) = graph_record.encode(canceled)
  let assert Ok(saved) = graph_record.decode(encoded)
  saved.family_budget |> should.equal(Some(budget.Declaration(limits(), False)))
}

pub fn retention_links_the_ledger_to_either_root_with_matching_limits_test() {
  let assert Ok(graph) = graph_record.encode(graph_root())
  let assert Ok(state) = budget.new(limits())
  let assert Ok(ledger) =
    retention.inspect(budget_record.encode(budget_record.Record("root", state)))
  let assert Some(parent) = ledger.parent
  list.each([record.encode(agent_root()), graph], fn(encoded) {
    let assert Ok(root) = retention.inspect(encoded)
    let assert [link] = root.children
    link.run |> should.equal(ledger.run)
    parent.run |> should.equal(root.run)
    link.key |> should.equal(parent.key)
  })
  ledger.settled |> should.be_true
  ledger.children |> should.equal([])
  let assert Ok(other) = budget.new(quota.Limits(9, 2, 2))
  let assert Ok(changed) =
    retention.inspect(budget_record.encode(budget_record.Record("root", other)))
  let assert Some(changed_parent) = changed.parent
  should.be_false(changed_parent.key == parent.key)
}

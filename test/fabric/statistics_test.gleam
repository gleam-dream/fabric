//// S7 O6/O7/O10: diagnostic classification uses supported saved records.

import fabric/budget as quota
import fabric/graph/job
import fabric/graph/operation
import fabric/internal/budget/model as budget
import fabric/internal/budget/record as budget_record
import fabric/internal/controller as agent
import fabric/internal/graph/attachment
import fabric/internal/graph/controller as graph
import fabric/internal/graph/record as graph_record
import fabric/internal/record
import fabric/model
import fabric/run
import fabric/store/statistics
import fabric/support
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import sinal/correlation

fn state(phase: agent.Phase) -> agent.State {
  agent.State(
    "stats-agent",
    run.DefinitionId("worker", 1),
    1,
    None,
    0,
    agent.Limits(4, None, 3, 3),
    1,
    run.TokenUsage(0, 0, 0),
    [model.UserMessage("private prompt")],
    [],
    0,
    phase,
    None,
    correlation.from_key("stats-agent"),
  )
}

pub fn active_and_finished_agents_have_distinct_run_classifications_test() {
  statistics.inspect(record.encode(state(agent.AwaitingModel(1))))
  |> should.equal(
    Ok(statistics.Run(
      support.id("stats-agent"),
      statistics.Active,
      False,
      False,
    )),
  )
  statistics.inspect(record.encode(state(agent.Ended(run.Completed("answer")))))
  |> should.equal(
    Ok(statistics.Run(
      support.id("stats-agent"),
      statistics.Finished,
      False,
      False,
    )),
  )
}

pub fn unknown_records_have_no_invented_execution_status_test() {
  statistics.inspect("not a record") |> should.equal(Error(Nil))
  statistics.encode(
    "different-id",
    record.encode(state(agent.AwaitingModel(1))),
  )
  |> should.equal("{\"version\":1}")
  record.encode(state(agent.AwaitingModel(1)))
  |> string.replace("\"version\":7", "\"version\":999")
  |> statistics.inspect
  |> should.equal(Error(Nil))
}

fn action(id: String, status: run.ActionState) -> run.ActionRecord {
  run.ActionRecord(
    run.ActionId(1, id),
    model.ToolCall(id, "tool", "{}", None, None),
    status,
    [],
    None,
  )
}

pub fn approval_and_reconciliation_overlap_without_hiding_active_work_test() {
  let requests = [
    action("approval", run.AwaitingApproval(run.Requirement("review", 1), 1)),
    action("uncertain", run.Uncertain("lost reply")),
  ]
  let waiting =
    agent.State(..state(agent.Acting(1, requests)), approvals_issued: 1)
  statistics.inspect(record.encode(waiting))
  |> should.equal(
    Ok(statistics.Run(support.id("stats-agent"), statistics.Waiting, True, True)),
  )
  let active =
    agent.State(
      ..waiting,
      phase: agent.Acting(1, [action("working", run.Running), ..requests]),
    )
  statistics.inspect(record.encode(active))
  |> should.equal(
    Ok(statistics.Run(support.id("stats-agent"), statistics.Active, True, True)),
  )
  let ended =
    agent.State(..state(agent.Ended(run.Cancelled)), history: [
      action("uncertain", run.Uncertain("lost reply")),
    ])
  statistics.inspect(record.encode(ended))
  |> should.equal(
    Ok(statistics.Run(
      support.id("stats-agent"),
      statistics.Finished,
      False,
      True,
    )),
  )
}

fn graph_state(kind: operation.Kind) -> #(graph.State, graph.Activation) {
  let assert Ok(#(state, _)) =
    graph.start(
      "stats-graph",
      graph.Definition(run.DefinitionId("stats", 1), "signature", 2),
      "0",
      graph.Prepared(
        "node",
        run.DefinitionId("operation", 1),
        "0",
        operation.RequireReconciliation,
        kind,
        None,
      ),
    )
  let assert graph.Ready(activation) = state.phase
  #(state, activation)
}

fn projected(state: graph.State) -> statistics.Metadata {
  let assert Ok(encoded) = graph_record.encode(state)
  let assert Ok(metadata) = statistics.inspect(encoded)
  metadata
}

pub fn graph_activity_waits_and_unresolved_cancellation_are_distinct_test() {
  let #(state, a) = graph_state(operation.Activity)
  list.each(
    [graph.Ready(a), graph.Queued(a), graph.Running(a), graph.Stopping(a)],
    fn(phase) {
      projected(graph.State(..state, phase:))
      |> should.equal(statistics.Run(
        support.id("stats-graph"),
        statistics.Active,
        False,
        False,
      ))
    },
  )
  projected(
    graph.State(
      ..state,
      approvals_issued: 1,
      phase: graph.AwaitingApproval(
        a,
        graph.Approval(a.id, a.attempt, 1, run.Requirement("review", 1)),
      ),
    ),
  )
  |> should.equal(statistics.Run(
    support.id("stats-graph"),
    statistics.Waiting,
    True,
    False,
  ))
  projected(
    graph.State(
      ..state,
      phase: graph.Blocked(a, graph.InvalidResult("bad", "decode")),
    ),
  )
  |> should.equal(statistics.Run(
    support.id("stats-graph"),
    statistics.Waiting,
    False,
    True,
  ))
  list.each(
    [
      graph.Cancelled(a, graph.UnresolvedCancellation(graph.Uncertain("lost"))),
    ],
    fn(outcome) {
      projected(graph.State(..state, phase: graph.Ended(outcome)))
      |> should.equal(statistics.Run(
        support.id("stats-graph"),
        statistics.Finished,
        False,
        True,
      ))
    },
  )
  let #(child, a) = graph_state(operation.Subgraph)
  let a =
    graph.Activation(
      ..a,
      prepared: graph.Prepared(..a.prepared, deadline: Some(100)),
      deadline: Some(1000),
    )
  projected(
    graph.State(
      ..child,
      phase: graph.Ended(graph.Expired(
        a,
        graph.UnresolvedCancellation(graph.Uncertain("child lost")),
      )),
    ),
  )
  |> should.equal(statistics.Run(
    support.id("stats-graph"),
    statistics.Finished,
    False,
    True,
  ))
}

pub fn idle_signals_children_and_job_observation_are_waiting_test() {
  let expected =
    statistics.Run(support.id("stats-graph"), statistics.Waiting, False, False)
  let #(signal, a) = graph_state(operation.Signal)
  projected(graph.State(..signal, phase: graph.WaitingSignal(a)))
  |> should.equal(expected)
  list.each([operation.Subgraph, operation.Agent], fn(kind) {
    let #(state, a) = graph_state(kind)
    let child = attachment.reserved_id(state.run, a.id)
    projected(graph.State(..state, phase: graph.WaitingChild(a, child)))
    |> should.equal(expected)
    projected(
      graph.State(
        ..state,
        phase: graph.ChildBlocked(a, child, "definition unavailable"),
      ),
    )
    |> should.equal(expected)
  })
  let #(state, a) = graph_state(operation.OwnedJob(job.Every(1000)))
  projected(graph.State(..state, phase: graph.WaitingJob(a)))
  |> should.equal(expected)
  projected(
    graph.State(
      ..state,
      phase: graph.StoppingJob(
        a,
        job.RequestUncertain("lost reply"),
        operation.CancellationRequested,
      ),
    ),
  )
  |> should.equal(statistics.Run(
    support.id("stats-graph"),
    statistics.Waiting,
    False,
    True,
  ))
  projected(
    graph.State(
      ..state,
      phase: graph.StoppingJob(
        a,
        job.RequestStarted,
        operation.CancellationRequested,
      ),
    ),
  )
  |> should.equal(statistics.Run(
    support.id("stats-graph"),
    statistics.Active,
    False,
    False,
  ))
}

pub fn budget_records_are_not_runs_and_projection_does_not_contain_payloads_test() {
  let assert Ok(limits) = budget.new(quota.Limits(3, 2, 1))
  let encoded = budget_record.encode(budget_record.Record("stats-root", limits))
  statistics.inspect(encoded)
  |> should.equal(
    Ok(statistics.Budget(support.id(budget_record.id("stats-root")))),
  )
  let encoded =
    statistics.encode(
      "stats-agent",
      record.encode(state(agent.AwaitingModel(1))),
    )
  string.contains(encoded, "private prompt") |> should.be_false
  string.contains(encoded, "stats-agent") |> should.be_false
}

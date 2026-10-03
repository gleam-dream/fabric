//// One identical graph for paired decisions; generation is outside its timing.

import fabric/graph
import fabric/graph/definition
import fabric/policy
import fabric/run
import fabric/store
import fabric_writing/domain
import fabric_writing/provider
import gleam/result
import gleam/time/duration

pub fn runtime(
  runs: store.Store,
  reviewer: provider.Reviewer(receipt),
) -> graph.Runtime(Nil, domain.Draft, domain.Decision) {
  let assert Ok(id) = definition.node_id("review")
  let review =
    definition.node(
      id,
      reviewer.operation,
      fn(draft) { Ok(draft) },
      fn(draft, receipt) {
        reviewer.interpret(receipt)
        |> result.map(fn(decision) { definition.Finish(draft, decision) })
      },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.DefinitionId("writing-decision-evaluation", 1),
      id,
      [review],
      domain.draft_codec(),
      domain.decision_codec(),
      1,
    ))
  let assert Ok(runtime) =
    graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
    |> graph.with_timeouts(
      callbacks: duration.milliseconds(5000),
      operations: duration.milliseconds(30_000),
      commands: duration.milliseconds(1000),
    )
  runtime
}

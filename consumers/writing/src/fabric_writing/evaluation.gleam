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
  let id = definition.node_id("review")
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
    definition.build(
      definition.new(
        run.DefinitionId("writing-decision-evaluation", 1),
        entry: id,
        nodes: [review],
        state: domain.draft_codec(),
        answer: domain.decision_codec(),
      )
      |> definition.with_max_activations(1),
    )
  let runtime =
    graph.new(spec, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
    |> graph.with_callback_timeout(duration.milliseconds(5000))
    |> graph.with_operation_timeout(run.After(duration.milliseconds(30_000)))
    |> graph.with_command_timeout(duration.milliseconds(1000))
  runtime
}

//// Submit-and-return graph: its answer is an acceptance receipt. The caller
//// chooses safe interrupted replay only when the service deduplicates keys.

import fabric/graph
import fabric/graph/definition
import fabric/graph/operation
import fabric/policy
import fabric/run
import fabric/store
import fabric_jobs_demo/client

pub type Submit =
  fn(operation.Invocation, client.Request) ->
    Result(client.Receipt, client.Error)

pub fn runtime(
  runs: store.Store,
  submit: Submit,
  recovery: operation.Recovery,
) -> graph.Runtime(Nil, client.Request, client.Receipt) {
  let submit =
    operation.new(
      run.Identity("artifact-submission", 1),
      client.request_codec(),
      client.receipt_codec(),
      fn(_, invocation, request) { submit(invocation, request) },
      client.classify,
    )
  let submit = case recovery {
    operation.RequireReconciliation -> submit
    operation.ReplayInterrupted(attempts) -> {
      let assert Ok(replay) = operation.with_replay(submit, attempts)
      replay
    }
  }
  let assert Ok(node_id) = definition.node_id("submit")
  let node =
    definition.node(
      node_id,
      submit,
      fn(request) { Ok(request) },
      fn(request, receipt) { Ok(definition.Finish(request, receipt)) },
      [],
    )
  let assert Ok(definition) =
    definition.build(definition.Spec(
      run.Identity("artifact-job", 1),
      node_id,
      [node],
      client.request_codec(),
      client.receipt_codec(),
      1,
    ))
  graph.new(definition, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

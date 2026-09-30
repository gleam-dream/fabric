//// Submit-and-return graph: its answer is an acceptance receipt. The caller
//// chooses safe interrupted replay only when the service deduplicates keys.

import fabric/graph
import fabric/graph/definition
import fabric/graph/job
import fabric/graph/operation
import fabric/policy
import fabric/run
import fabric/store
import fabric_jobs_demo/client
import gleam/result
import json/blueprint/codec

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

pub type State {
  Submitting(client.Request)
  Accepted(client.Receipt)
}

fn state_codec() -> codec.Codec(State) {
  let assert Ok(tagged) =
    codec.tagged(
      "submitting",
      client.request_codec(),
      "accepted",
      client.receipt_codec(),
    )
  codec.imap(
    tagged,
    fn(value) {
      case value {
        codec.Left(request) -> Submitting(request)
        codec.Right(receipt) -> Accepted(receipt)
      }
    },
    fn(state) {
      case state {
        Submitting(request) -> codec.Left(request)
        Accepted(receipt) -> codec.Right(receipt)
      }
    },
  )
}

/// Submission saves the receipt before the graph enters its read-only wait.
/// Polling uses the receipt, never another submission or a suspended task.
pub fn waiting_runtime(
  runs: store.Store,
  submit: Submit,
  url: String,
) -> graph.Runtime(Nil, State, String) {
  wait_with(runs, submit, url, job.Manual)
}

/// The registered sweeper can observe this graph's saved job every 100 ms.
pub fn scheduled_runtime(
  runs: store.Store,
  submit: Submit,
  url: String,
) -> graph.Runtime(Nil, State, String) {
  wait_with(runs, submit, url, job.Every(100))
}

fn wait_with(
  runs: store.Store,
  submit: Submit,
  url: String,
  polling: job.Polling,
) -> graph.Runtime(Nil, State, String) {
  let assert Ok(submit_id) = definition.node_id("submit")
  let assert Ok(wait_id) = definition.node_id("wait")
  let submit =
    operation.new(
      run.Identity("artifact-submission", 1),
      client.request_codec(),
      client.receipt_codec(),
      fn(_, invocation, request) { submit(invocation, request) },
      client.classify,
    )
  let assert Ok(submit) = operation.with_replay(submit, 3)
  let submission =
    definition.node(
      submit_id,
      submit,
      fn(state) {
        case state {
          Submitting(request) -> Ok(request)
          Accepted(_) -> Error("already accepted")
        }
      },
      fn(_, receipt) { Ok(definition.Continue(Accepted(receipt), wait_id)) },
      [wait_id],
    )
  let observer =
    job.observe(
      run.Identity("artifact-observation", 1),
      client.receipt_codec(),
      codec.string(),
      fn(_, receipt) {
        client.read(url, receipt)
        |> result.map(fn(status) {
          case status {
            client.Queued -> job.Pending
            client.Complete(digest) -> job.Completed(digest)
          }
        })
      },
    )
  let observer = case polling {
    job.Manual -> observer
    job.Every(ms) -> {
      let assert Ok(scheduled) = job.with_poll_interval(observer, ms)
      scheduled
    }
  }
  let waiting =
    definition.node(
      wait_id,
      operation.await_job(observer),
      fn(state) {
        case state {
          Accepted(receipt) -> Ok(receipt)
          Submitting(_) -> Error("no accepted receipt")
        }
      },
      fn(state, digest) { Ok(definition.Finish(state, digest)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(definition.Spec(
      run.Identity("artifact-submit-and-wait", 1),
      submit_id,
      [submission, waiting],
      state_codec(),
      codec.string(),
      2,
    ))
  graph.new(spec, runs, fn() { Nil }, fn(_, _) { Ok(policy.Allow) })
}

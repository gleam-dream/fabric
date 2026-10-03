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
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration
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
      run.DefinitionId("artifact-submission", 1),
      client.request_codec(),
      client.receipt_codec(),
      fn(_, invocation, request) { submit(invocation, request) },
      client.classify,
    )
  let submit = case recovery {
    operation.RequireReconciliation -> submit
    operation.ReplayInterrupted(attempts) -> {
      let replay = operation.with_replay(submit, attempts)
      replay
    }
  }
  let node_id = definition.node_id("submit")
  let node =
    definition.node(
      node_id,
      submit,
      fn(request) { Ok(request) },
      fn(request, receipt) { Ok(definition.Finish(request, receipt)) },
      [],
    )
  let assert Ok(definition) =
    definition.build(
      definition.new(
        run.DefinitionId("artifact-job", 1),
        entry: node_id,
        nodes: [node],
        state: client.request_codec(),
        answer: client.receipt_codec(),
      )
      |> definition.with_max_activations(1),
    )
  graph.new(definition, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
}

pub type State {
  Submitting(client.Request)
  Accepted(client.Receipt)
}

fn state_codec() -> codec.Codec(State) {
  codec.union({
    use submitting <- codec.variant(
      "submitting",
      client.request_codec(),
      Submitting,
    )
    use accepted <- codec.variant("accepted", client.receipt_codec(), Accepted)
    codec.match(fn(state) {
      case state {
        Submitting(request) -> submitting(request)
        Accepted(receipt) -> accepted(receipt)
      }
    })
  })
}

/// Submission saves the receipt before the graph enters its read-only wait.
/// Polling uses the receipt, never another submission or a suspended task.
pub fn waiting_runtime(
  runs: store.Store,
  submit: Submit,
  url: String,
) -> graph.Runtime(Nil, State, String) {
  wait_with(runs, submit, url, job.Manual, Detached, None)
}

/// The registered sweeper can observe this graph's saved job every 100 ms.
pub fn scheduled_runtime(
  runs: store.Store,
  submit: Submit,
  url: String,
) -> graph.Runtime(Nil, State, String) {
  wait_with(runs, submit, url, job.Every(100), Detached, None)
}

type Lifetime {
  Detached
  Owned(fn(operation.Invocation, client.Receipt) -> Result(Nil, client.Error))
}

/// Submit and retain cancellation ownership. The scheduled observer confirms
/// terminal evidence after `graph.cancel` acknowledges local cancellation intent.
pub fn owned_runtime(
  runs: store.Store,
  submit: Submit,
  request: fn(operation.Invocation, client.Receipt) -> Result(Nil, client.Error),
  url: String,
) -> graph.Runtime(Nil, State, String) {
  wait_with(runs, submit, url, job.Every(100), Owned(request), None)
}

/// Bound the accepted job wait while retaining owned cancellation and terminal
/// evidence after expiration. The service remains independently durable.
pub fn deadline_runtime(
  runs: store.Store,
  submit: Submit,
  request: fn(operation.Invocation, client.Receipt) -> Result(Nil, client.Error),
  url: String,
  within: Int,
) -> graph.Runtime(Nil, State, String) {
  wait_with(runs, submit, url, job.Every(100), Owned(request), Some(within))
}

fn wait_with(
  runs: store.Store,
  submit: Submit,
  url: String,
  polling: job.Polling,
  lifetime: Lifetime,
  deadline: Option(Int),
) -> graph.Runtime(Nil, State, String) {
  let submit_id = definition.node_id("submit")
  let wait_id = definition.node_id("wait")
  let submit =
    operation.new(
      run.DefinitionId("artifact-submission", 1),
      client.request_codec(),
      client.receipt_codec(),
      fn(_, invocation, request) { submit(invocation, request) },
      client.classify,
    )
  let submit = operation.with_replay(submit, 3)
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
      run.DefinitionId("artifact-observation", 1),
      client.receipt_codec(),
      codec.string(),
      fn(_, receipt) {
        client.read(url, receipt)
        |> result.map(fn(status) {
          case status {
            client.Queued | client.CancelRequested -> job.Pending
            client.Cancelled -> job.Cancelled
            client.Complete(digest) -> job.Completed(digest)
          }
        })
      },
    )
  let observer = case polling {
    job.Manual -> observer
    job.Every(ms) -> {
      let scheduled =
        job.with_poll_interval(observer, duration.milliseconds(ms))
      scheduled
    }
  }
  let op = case lifetime {
    Detached -> operation.await_job(observer)
    Owned(request) ->
      operation.own_job(
        observer,
        fn(_, invocation, receipt) { request(invocation, receipt) },
        client.classify,
      )
  }
  let op = case deadline {
    None -> op
    Some(ms) -> {
      let op = operation.with_deadline(op, run.After(duration.milliseconds(ms)))
      op
    }
  }
  let waiting =
    definition.node(
      wait_id,
      op,
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
    definition.build(
      definition.new(
        run.DefinitionId("artifact-submit-and-wait", 1),
        entry: submit_id,
        nodes: [submission, waiting],
        state: state_codec(),
        answer: codec.string(),
      )
      |> definition.with_max_activations(2),
    )
  graph.new(spec, runs, fn(_) { Nil }, fn(_, _) { Ok(policy.Allow) })
}

/// An explicit cancellation workflow proving the remote request boundary.
/// This does not change `graph.cancel` on the ordinary read-only job observer.
pub fn cancellation_runtime(
  runs: store.Store,
  request: fn(operation.Invocation, client.Receipt) ->
    Result(client.CancelReply, client.Error),
  url: String,
  recovery: operation.Recovery,
  gate: policy.Policy(Nil),
) -> graph.Runtime(Nil, client.Receipt, client.CancellationOutcome) {
  let stop_id = definition.node_id("request-stop")
  let wait_id = definition.node_id("confirm-stop")
  let stop =
    operation.new(
      run.DefinitionId("artifact-stop-request", 1),
      client.receipt_codec(),
      client.cancel_reply_codec(),
      fn(_, invocation, receipt) { request(invocation, receipt) },
      client.classify,
    )
  let stop = case recovery {
    operation.RequireReconciliation -> stop
    operation.ReplayInterrupted(attempts) -> {
      let replay = operation.with_replay(stop, attempts)
      replay
    }
  }
  let request_node =
    definition.node(
      stop_id,
      stop,
      fn(receipt) { Ok(receipt) },
      fn(receipt, reply) {
        case reply {
          client.StopRequested -> Ok(definition.Continue(receipt, wait_id))
          client.AlreadyCompleted(digest) ->
            Ok(definition.Finish(receipt, client.Finished(digest)))
        }
      },
      [wait_id],
    )
  let observer =
    job.observe(
      run.DefinitionId("artifact-stop-outcome", 1),
      client.receipt_codec(),
      client.cancellation_outcome_codec(),
      fn(_, receipt) {
        client.read(url, receipt)
        |> result.map(fn(progress) {
          case progress {
            client.Queued | client.CancelRequested -> job.Pending
            client.Cancelled -> job.Completed(client.Stopped)
            client.Complete(digest) -> job.Completed(client.Finished(digest))
          }
        })
      },
    )
  let wait_node =
    definition.node(
      wait_id,
      operation.await_job(observer),
      fn(receipt) { Ok(receipt) },
      fn(receipt, outcome) { Ok(definition.Finish(receipt, outcome)) },
      [],
    )
  let assert Ok(spec) =
    definition.build(
      definition.new(
        run.DefinitionId("artifact-cancellation", 1),
        entry: stop_id,
        nodes: [request_node, wait_node],
        state: client.receipt_codec(),
        answer: client.cancellation_outcome_codec(),
      )
      |> definition.with_max_activations(2),
    )
  graph.new(spec, runs, fn(_) { Nil }, gate)
}

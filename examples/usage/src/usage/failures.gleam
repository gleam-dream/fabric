//// Failures. Every function of `fabric` returns one `fabric.Error`; branch
//// on `fabric.error_kind` and log with `fabric.describe_error`.

import fabric
import fabric/agent
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import gleam/erlang/process
import gleam/option.{None}
import gleam/time/duration
import usage/support

fn desk() -> agent.Agent(Nil, String) {
  let assert Ok(desk) =
    agent.new("desk", support.answering("done"), [], policy.always_allow())
    |> agent.build
  desk
}

/// Opening a run that was never started is `NotFound`.
pub fn missing_run() -> fabric.ErrorKind {
  let runs = store.in_memory(process.new_name("usage-missing"))
  let assert Ok(Nil) = store.start(runs)
  let assert Error(error) = fabric.open(runs, desk(), Nil, run.new_id())
  let kind = fabric.error_kind(error)
  let assert Ok(Nil) = store.stop(runs)
  kind
}

/// Starting a second run under a stored id is `Refused`: the error carries
/// whether the stored run was started with the same input, so a retried
/// start can tell its own run from another start that reused the id.
pub fn retried_start() -> #(fabric.ErrorKind, Bool) {
  let runs = store.in_memory(process.new_name("usage-retry"))
  let assert Ok(Nil) = store.start(runs)
  let id = run.id_from_parts("job", ["42"])
  let start = fn() {
    fabric.start(
      runs,
      desk(),
      id:,
      context: Nil,
      prompt: "hello",
      correlation: None,
    )
  }
  let assert Ok(handle) = start()
  let assert Ok(_) = fabric.await(handle, within: duration.seconds(5))
  let assert Error(error) = start()
  let same_input = case error {
    fabric.AlreadyStarted(_, same_input) -> same_input
    _ -> False
  }
  let assert Ok(Nil) = store.stop(runs)
  #(fabric.error_kind(error), same_input)
}

/// A model fails with an opaque `model.ModelError`: whether to retry and how
/// long to wait come from it, never from its text.
pub fn model_failure() -> #(Bool, String) {
  let error = model.error(model.Overloaded, "the provider is busy")
  #(model.is_retryable(error), model.describe_error(error))
}

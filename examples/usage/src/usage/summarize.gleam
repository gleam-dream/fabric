import fabric
import fabric/agent
import fabric/model
import fabric/policy
import fabric/run
import fabric/store
import fabric/store/backend
import gleam/erlang/process
import gleam/option.{None}
import gleam/result
import gleam/time/duration

pub type Error {
  InvalidAgent(List(agent.ConfigError))
  StoreFailed(backend.StoreError)
  RunFailed(fabric.Error)
}

pub fn summarize(
  model: model.Model,
  text: String,
) -> Result(run.Status(String), Error) {
  use summarizer <- result.try(
    agent.new("summarizer", model, [], policy.always_allow())
    |> agent.with_system_prompt("Summarize the supplied text in one paragraph.")
    |> agent.with_max_turns(2)
    |> agent.with_model_timeout(run.After(duration.seconds(20)))
    |> agent.build
    |> result.map_error(InvalidAgent),
  )
  let runs = store.in_memory(process.new_name("summaries"))
  use Nil <- result.try(store.start(runs) |> result.map_error(StoreFailed))
  let outcome =
    fabric.start(
      runs,
      summarizer,
      id: run.new_id(),
      context: Nil,
      prompt: text,
      correlation: None,
    )
    |> result.try(fabric.await(_, within: duration.seconds(45)))
    |> result.map_error(RunFailed)
  use Nil <- result.try(store.stop(runs) |> result.map_error(StoreFailed))
  outcome
}

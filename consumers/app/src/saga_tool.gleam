import fabric/tool
import gleam/result
import gleam/time/duration.{type Duration}
import saga
import saga/execution
import saga/outcome
import saga/reporting

pub fn tool(
  definition: tool.Definition(input, output),
  workflow: saga.Workflow(workflow_input, output, error, undo_error),
  config: execution.Config,
  input input: fn(context, tool.Call, input) -> workflow_input,
  explain explain: fn(error) -> String,
  rollback_within rollback_within: Duration,
) -> tool.Tool(context) {
  tool.bind_settling(
    definition,
    fn(context, call: tool.Call, value, settlement) {
      reporting.run_owned(
        workflow,
        input(context, call, value),
        execution.with_correlation(config, call.correlation),
        explain,
        fn(stopped, summary) {
          let _ =
            tool.settle(
              settlement,
              result.map_error(stopped, failure),
              summary:,
            )
          Nil
        },
        rollback_within,
      )
    },
    failure,
    settle_within: rollback_within,
  )
}

fn failure(stopped: outcome.Failure) -> tool.Failure {
  case outcome.failure_kind(stopped) {
    outcome.Compensated -> tool.Explain(outcome.describe_failure(stopped))
    _ -> tool.Uncertain(outcome.describe_failure(stopped))
  }
}

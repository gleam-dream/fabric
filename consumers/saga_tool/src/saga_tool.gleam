import fabric/tool
import gleam/result
import gleam/time/duration.{type Duration}
import saga
import saga/execution
import saga/outcome.{Definitely, Unknown}
import saga/reporting

pub fn tool(
  definition: tool.Definition(input, output),
  workflow: saga.Workflow(workflow_input, output, error, undo_error),
  config: execution.Config,
  input input: fn(context, tool.Call, input) -> workflow_input,
  explain explain: fn(error) -> String,
  rollback_within rollback_within: Duration,
) -> tool.Tool(context) {
  let project = fn(result) {
    case result {
      Ok(report) -> #(
        outcome.classify(report, explain)
          |> result.map_error(fn(failure) {
            case failure {
              Definitely(detail) -> tool.Explain(detail)
              Unknown(detail) -> tool.Uncertain(detail)
            }
          }),
        "Saga reported " <> outcome.summary(report),
      )
      Error(error) -> {
        let detail = reporting.describe_error(error)
        let failure = case reporting.effect_status(error) {
          reporting.NotStarted -> tool.Explain(detail)
          reporting.Unknown -> tool.Uncertain(detail)
        }
        #(Error(failure), detail)
      }
    }
  }
  tool.bind_settling(
    definition,
    fn(context, call: tool.Call, value, settlement) {
      let reported =
        reporting.run_owned(
          workflow,
          input(context, call, value),
          execution.with_correlation(config, call.correlation),
          fn(stopped) {
            let #(result, summary) = project(stopped)
            let _ = tool.settle(settlement, result, summary:)
            Nil
          },
          rollback_within,
        )
      project(reported).0
    },
    fn(failure) { failure },
    settle_within: rollback_within,
  )
}

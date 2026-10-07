# fabric

Fabric runs LLM agents and conditional graphs in Gleam. It combines typed
tools, application policy and supervised execution with approval, cancellation
and recovery.

## Setup

Fabric is not yet published to Hex. Check out `fabric`, `llm_wire`, `http_gun`,
`json_blueprint` and `sinal` as sibling repositories. Add Fabric to a sibling
application's `gleam.toml`:

```toml
[dependencies]
fabric = { path = "../fabric" }
```

The package targets Erlang and requires Gleam 1.18 or later.

## Usage

This function runs a short-lived summarizer and stops its in-memory store after
waiting for the result. Supply a model built with
`fabric/llm.model(client, config, model_id)` using the application's started
HTTP Gun client and llm_wire configuration, or a custom `fabric/model.Model`.

```gleam
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
```

The summarizer finishes with `run.Finished(run.Completed(answer))`. This
records the model's final answer. An agent with tools can also complete after
a denied or failed action; inspect [action outcomes](USAGE.md#read-action-outcomes)
before treating its answer as business success. Other statuses preserve refusal,
exhaustion or unfinished work. The example discards stored runs when the store
stops; a service that needs later recovery should supervise a durable store and
retain each run id. See the complete [payment agent](USAGE.md#payment-agent)
for typed tools, approval and recovery.

## Ownership and defaults

The application starts and stops HTTP clients, database pools and store
supervision. Fabric never starts or stops a supplied HTTP Gun client. Context
and credentials stay live; they are not stored with a run. Dropping a run handle
does not cancel it.

Default agent bounds are eight model attempts, four concurrent tools, 600
seconds per model call and 60 seconds per tool body. Approval requests expire
after seven days. Token and family budgets are opt-in. The
[defaults table](USAGE.md#defaults) names each setting and its failure outcome.

Interrupted external effects can require reconciliation. Enable replay only
when the application can guarantee that repeating the effect is safe. Directory
storage supports process and VM restart on one host; use a database backend for
production power-loss durability. The
[operations runbook](docs/OPERATIONS.md) covers recovery, deployment and retention.

## More examples

| Task                                                | Example or guide                                                                                             |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Typed answers, approvals and failures               | [Usage guide](USAGE.md#typed-answers)                                                                        |
| Conditional routing, signals and managed agents     | [Graph guide](USAGE.md#graph-runs), [graph consumer](consumers/graph/README.md)                              |
| Structured LLM or TypeSafe decisions                | [Classification guide](USAGE.md#classification-decisions), [decision consumer](consumers/decision/README.md) |
| External job completion, cancellation and deadlines | [Job consumer](consumers/jobs/README.md)                                                                     |
| Generation, review and artifact publication         | [Writing consumer](consumers/writing/README.md)                                                              |
| A Saga workflow as a tool                           | [Compiled Saga recipe](USAGE.md#a-saga-workflow-as-a-tool)                                                   |
| MCP calls, discovery and serving                    | [Compiled Relay recipes](USAGE.md#composing-with-relay)                                                      |
| Authenticated Warden approval                       | [Compiled approver recipe](USAGE.md#who-may-answer-approvers)                                                |
| PostgreSQL leases, migrations and pruning           | [PostgreSQL adapter](integrations/fabric_postgres/README.md)                                                 |

The writing consumer retains [historical review-call timings](consumers/writing/README.md#retained-timings)
from a twelve-case workload. They include network and adapter time and do not
measure Fabric-only overhead or production throughput.

## Development

```sh
nix develop -c gleam test
```

See [verification](docs/VERIFICATION.md) for the recipe checks, separate consumer
packages, local services and disposable PostgreSQL suite.

The [design source](docs/design/design.typ),
[rendered design](docs/design/design-layer.pdf),
[vocabulary](docs/design/CONTEXT.typ), [coverage](docs/COVERAGE.md) and
[ADRs](docs/adr/) describe supported contracts and unresolved capabilities.
The design's pending entries retain unbuilt streaming, whole-run elapsed and
family token bounds, approval editing and context compaction. The
[oracle notes](docs/ORACLE.md) identify the scoped BeamWeaver comparison and its
limits.

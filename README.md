# fabric

Fabric runs LLM agents and conditional graphs in Gleam. It combines typed
tools, application policy and supervised execution with approval, cancellation
and recovery.

## Setup

Fabric is not yet published to Hex. Its dependencies use immutable Git revisions
and Gleam fetches them automatically. For local development, add a Fabric
checkout to your application's `gleam.toml`:

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

The summarizer finishes with `run.Finished(run.Completed(answer))`, which
records the model's final answer. A completed run does not prove that every
action succeeded: an agent with tools can complete after a denied or failed
action, so read the action records from `fabric.snapshot` before treating its
answer as business success. Other statuses preserve refusal, exhaustion or
unfinished work. The example discards stored runs when the store stops; a
service that needs later recovery supervises a durable store and retains each
run id.

## Ownership and defaults

The application starts and stops HTTP clients, database pools and store
supervision. Fabric never starts or stops a supplied HTTP Gun client. Context
and credentials stay live and are not stored with a run. Dropping a run handle
does not cancel it.

Agent bounds default to eight model attempts, four concurrent tools, 600
seconds per model call and 60 seconds per tool body, and approval requests
expire after seven days. Token and family budgets are opt-in. Interrupted
external effects can require reconciliation, and replay is enabled only when
repeating the effect is safe. Directory storage supports process and VM restart
on one host; production power-loss durability needs a database backend. The
[design](docs/design/design.typ) states every bound, its setting and its
outcome, and how to operate, recover and upgrade a worker.

## Examples

| Task                                                                                      | Example                                                                                                                                                                           |
| ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Bounds, failures, correlation, waiting, budgets, stored reconciliation and sweeper wiring | [Usage examples](examples/usage/README.md), run by `scripts/check.py fast`                                                                                                        |
| Typed tool, approval, restart and reconciliation                                          | The payment desk in [`test/fabric/readme_example.gleam`](test/fabric/readme_example.gleam), run by [`test/fabric/readme_test.gleam`](test/fabric/readme_test.gleam)               |
| Typed answers, delegation and application settings                                        | [Application consumer](consumers/app/test/app_test.gleam)                                                                                                                         |
| Conditional routing, signals and managed agents                                           | [Graph consumer](consumers/graph/README.md)                                                                                                                                       |
| Structured LLM or TypeSafe decisions                                                      | [Decision consumer](consumers/decision/README.md)                                                                                                                                 |
| External job completion, cancellation and deadlines                                       | [Job consumer](consumers/jobs/README.md)                                                                                                                                          |
| Generation, review and artifact publication                                               | [Writing consumer](consumers/writing/README.md)                                                                                                                                   |
| A Saga workflow as a tool                                                                 | The `With saga` recipe described in the `fabric/tool` module documentation, compiled by [`consumers/saga_tool`](consumers/saga_tool)                                              |
| MCP calls, discovery and serving                                                          | The Relay recipes described in the `fabric/tool`, `fabric/graph/operation` and `fabric/invoke` module documentation, compiled by [`consumers/relay_tools`](consumers/relay_tools) |
| Authenticated Warden approval                                                             | The `With warden` recipe described in the `fabric/approvers` module documentation, compiled by [`consumers/approvers_warden`](consumers/approvers_warden)                         |
| PostgreSQL leases, migrations and pruning                                                 | [PostgreSQL adapter](integrations/fabric_postgres/README.md)                                                                                                                      |

## Generation settings

Generation controls can be configured without rebuilding the model adapter:

```gleam
import llm_wire/generation

let settings = generation.default()
  |> generation.with_max_tokens(128)
  |> generation.with_temperature(0.2)
let model = llm.configured_model(client, config, model_id, settings)
```

Settings are fixed for that model instance. Fabric owns messages, tools, answer
decoding and correlation. Applications supply their live settings again when
reconstructing a runtime, and no settings enter persisted execution records.
This coordinated API is unpublished; the recorded immutable LLM Wire dependency
does not contain it yet.

## Development

```sh
nix develop -c gleam test
nix develop -c python3 scripts/check.py full
```

[AGENTS.md](AGENTS.md) lists the gate profiles, design-layer commands and references. The oracle pin and comparison ledger are in [docs/ORACLE.md](docs/ORACLE.md) and the dated live-provider measurements in [docs/BENCHMARKS.md](docs/BENCHMARKS.md). The
[design](docs/design/design.typ), its [vocabulary](docs/design/CONTEXT.typ),
[coverage](docs/COVERAGE.md) and [decision records](docs/adr/) describe the
supported contracts and the capabilities that remain unbuilt.

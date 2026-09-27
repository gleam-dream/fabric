# fabric

A bounded, typed LLM agent runtime for Gleam: typed application tools, an explicit policy gate, a pure agent controller, and a thin OTP runner with cancellation. It consumes llm_wire for providers and json_blueprint for tool codecs; typed workflows (DAGs) belong to Saga.

Status: slice 1 (bounded agent execution) implemented; see [docs/PLAN.md](docs/PLAN.md), [docs/CAPABILITIES.md](docs/CAPABILITIES.md) and [docs/ORACLE.md](docs/ORACLE.md). Design: see [fabric-design.md](https://github.com/gleam-dream/oversight/blob/master/fabric-design.md) in [gleam-dream/oversight](https://github.com/gleam-dream/oversight). Not yet published to Hex.

Behavioural oracle: BeamWeaver (partial migration of its agent loop).

Dependencies on `llm_wire` and `json_blueprint` are path dependencies (`../llm_wire`, `../json_blueprint`); check out the sibling repositories next to this one.

## Usage

```gleam
import fabric
import fabric/agent
import fabric/policy
import fabric/run
import fabric/tool

let weather =
  tool.define("lookup_weather", "Look up a forecast.", city_codec, forecast_codec)
  |> tool.bind_reporting(lookup_weather, fn(error) { tool.Explain(describe(error)) })

let agent =
  agent.new(model, [weather], my_policy)   // fabric/llm.model(settings, model_id)
  |> agent.with_max_turns(6)
  |> agent.with_token_budget(20_000)

let assert Ok(handle) = fabric.start(agent, context, "What is the weather in Paris?")
case fabric.await(handle, 30_000) {
  Ok(run.Finished(run.Completed(answer))) -> answer
  Ok(run.Suspended(approvals, uncertain)) -> ...   // no process holds the run
  ...
}
```

`consumers/app` is a complete external application using public imports only.

## Development

```sh
nix develop
gleam format --check src test
gleam build --warnings-as-errors
gleam test
(cd consumers/app && gleam test)
nix flake check
```

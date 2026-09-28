# fabric

A bounded, typed LLM agent runtime for Gleam: typed application tools, an explicit policy gate, a pure agent controller, and a thin OTP runner with cancellation. It consumes llm_wire for providers and json_blueprint for tool codecs; typed workflows (DAGs) belong to Saga.

Status: slice 1 (bounded agent execution), slice 2a (durable pause, approval, resume, cancellation, and restart), slice 2b (approval-gated sub-agents, Sinal observations, and Saga workflows as tools), and the public API ergonomics pass (a built agent, one policy gate, typed run ids, a named supervisable store) implemented; see [docs/PLAN.md](docs/PLAN.md), [docs/CAPABILITIES.md](docs/CAPABILITIES.md) and [docs/ORACLE.md](docs/ORACLE.md). Design: see [fabric-design.md](https://github.com/gleam-dream/oversight/blob/master/fabric-design.md) in [gleam-dream/oversight](https://github.com/gleam-dream/oversight). Not yet published to Hex.

Behavioural oracle: BeamWeaver (partial migration of its agent loop).

Dependencies on `llm_wire`, `json_blueprint`, and `sinal` are path dependencies (`../llm_wire`, `../json_blueprint`, `../sinal`); check out the sibling repositories next to this one. The optional Saga integration, `integrations/fabric_saga`, is a separate package that also needs `../saga`.

## Usage

```gleam
import fabric
import fabric/agent
import fabric/policy
import fabric/run
import fabric/store
import fabric/tool

let weather_definition =
  tool.define("lookup_weather", "Look up a forecast.", city_codec, forecast_codec)
let weather =
  tool.bind(weather_definition, lookup_weather, fn(error) {
    tool.Explain(describe(error))
  })

// One policy gates every effect. `tool.input` matches an action on a
// tool's definition and gives its typed input (`None` for another tool);
// arguments that definition cannot read are an error, which stops the run.
let my_policy = fn(context, action: policy.Action) {
  use transfer <- result.try(tool.input(transfer_definition, action))
  case transfer {
    Some(transfer) if transfer.amount > 100 ->
      Ok(policy.RequireApproval(run.Requirement("treasurer", 1)))
    _ -> Ok(policy.Allow)
  }
}

// An agent is described, then built once: `build` reports every problem.
let assert Ok(desk) =
  agent.new("desk", model, [weather, transfer], my_policy)  // fabric/llm.model(settings, model_id)
  |> agent.with_limits(
    agent.Limits(..agent.default_limits(), max_turns: 6, token_budget: Some(20_000)),
  )
  |> agent.build

// A store is a named value; its process runs under the application's
// supervisor (or `store.start(runs)` in a script or test).
let runs = store.directory(process.new_name("runs"), "/var/lib/app/runs")
let children = [store.supervised(runs)]   // static_supervisor.add(builder, ..)

let assert Ok(handle) = fabric.start(runs, desk, context, "Pay Bob 120")
case fabric.await(handle, 30_000) {
  Ok(run.Finished(run.Completed(answer))) -> answer
  Ok(run.Suspended([pending, ..], _)) ->
    // No process holds the run. The application authenticates the reviewer;
    // the policy is checked again with the context passed here.
    fabric.approve(handle, pending.reference,
      reviewer: Some("alice"), context: current_context)
    // or: fabric.reject(handle, pending.reference, reason: "not today", reviewer: Some("alice"))
  Ok(run.Suspended([], [uncertain, ..])) ->
    // An effect of unknown status: record what actually happened.
    fabric.reconcile(handle, uncertain.reference, "{\"receipt\":\"r-1\"}")
  Ok(run.Working) -> ...     // the time ran out
  Ok(run.Unattended) -> ...  // its runner was lost: `recover` takes it over
  ...
}

// In a later request: parse the run id from wherever it was kept, and open
// the run. Opening takes nothing over; commands through the handle are
// checked against the stored record.
let assert Ok(id) = run.parse_id(stored_id)
let assert Ok(handle) = fabric.open(runs, desk, context, id)

// At boot, when the previous owner is known to be gone: `recover` takes
// over work whose runner was lost (running tools become uncertain effects).
let assert Ok(handle) = fabric.recover(runs, desk, context, id)

// A sub-agent: a typed delegation whose start the policy gates like a tool
// (`action.target` is `policy.StartAgent(..)`). Its approvals surface in the
// parent's `pending`, cancelling the parent cancels it, and recovering the
// parent recovers it. `output` parses a completed sub-agent's answer; any
// other ending is a definite failure the model sees.
let assert Ok(front_desk) =
  agent.new("front-desk", model, [weather], my_policy)
  |> agent.with_sub_agent(research_definition, to: researcher,
       prompt: fn(topic) { topic.name },
       output: fn(answer) { Ok(Summary(answer)) })
  |> agent.build

// A Saga workflow as one typed tool (package fabric_saga). A cancelled call
// waits up to `rollback_within` ms for Saga's rollback: every completed step
// undone is a definite failure, anything left in place an uncertain effect.
let assert Ok(book_trip) =
  fabric_saga.tool(trip_definition, book_trip_workflow, execution.config(),
    explain: describe_trip_error, rollback_within: 10_000)

// A tool whose effect outlives its task settles its result late: the handler
// gets a typed `tool.Settlement(output)`, and a stopped run waits up to
// `within` ms for `tool.settle(settlement, result, summary:)`. The summary
// is observed if the settlement is refused, so it must not carry secrets.
let lookup =
  tool.bind_settling(weather_definition, handler, classify, within: 5000)
```

`test/fabric/readme_test.gleam` runs this example (without the Saga tool,
which `consumers/app` covers).

Observations: attach Sinal handlers to the events of `fabric/observation`.
They run in the committing process unless the application routes `[fabric]`
through a `sinal/forwarder` (`forwarder.route` at start, `forwarder.unroute`
at shutdown), which keeps a slow handler from holding up a run; handlers that
call Fabric should run there.

`consumers/app` is a complete external application using public imports only.

## Development

```sh
nix develop
gleam format --check src test
gleam build --warnings-as-errors
gleam test
(cd consumers/app && gleam test)
(cd integrations/fabric_saga && gleam test)
nix flake check
```

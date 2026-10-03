# Round 5: caller run ids, run correlation, durations and `await_with`

This round implements three items of the release review
([fabric.md](https://github.com/gleam-dream/oversight/blob/master/docs/release-api/fabric.md)):

- **FABRIC-R8 and the run-id part of FABRIC-R2.** The caller chooses a
  run's id and its correlation. `model.Request` names the run, the turn and
  the correlation; `fabric/llm` tags each turn's HTTP Gun client view with it,
  so one agent serves every run. Fabric's events and every tool's call carry
  it, and `fabric_saga` starts its Saga run with it and with the run context.
- **FABRIC-R3 and FABRIC-R7, units part.** Every public timeout, deadline,
  interval and lease is a `gleam/time/duration.Duration`, with
  `run.Timeout = After(Duration) | Infinity` where unbounded is allowed. A
  model call is bounded at 600 s, a tool body at 60 s (expiry: an uncertain
  effect) and a tool result at 1 MiB by default.
- **`fabric.await_with`.** One receive waits for the run or for a caller's
  selector, so a Relay handler no longer needs a waiter process to react to
  `tool.cancelled`.

Stored records keep their bytes. A run with the default correlation writes
no new key; a run with a chosen or inherited correlation adds
`"correlation"`, which earlier readers ignore (they then derive the
correlation from the run id). Graph records, receipts and the event metadata
keys are unchanged; events gain the `correlation` key.

Two decision 5 defaults are not applied, because each needs a durable clock
or changes a persisted contract, which waits for the durability decisions
(D1, D2): agent approvals still wait for their answer without expiry, and
graph signal, job, child and fork waits stay unbounded unless
`operation.with_deadline` bounds them (a default deadline would change the
operation contract that stored graph runs are checked against).

## Changed public items

### `fabric.start` and `fabric.start_with_budget`: caller id and correlation

```gleam
// before
fabric.start(runs, agent, context, "Pay Bob")
fabric.start_with_budget(runs, agent, context, "Pay Bob", limits)

// after
fabric.start(runs, agent, id: run.new_id(), context:, prompt: "Pay Bob",
  correlation: None)
fabric.start_with_budget(runs, agent, id: run.new_id(), context:,
  prompt: "Pay Bob", correlation: Some(request_correlation), limits:)
```

A job derives the id from itself (`run.parse_id(job_id)`): a start retried
with the same id returns `Error(fabric.AlreadyStarted(id))` and stores
nothing, and the job then `open`s the run. `StartUnconfirmed` can be retried
with the same id. `correlation: None` derives it with
`correlation.from_key(run.id_to_string(id))`.

### `fabric.StartError`

```gleam
// before: a taken id was StartRefused("the store reported the new run id taken")
// after
pub type StartError {
  AlreadyStarted(id: RunId)
  StartUnconfirmed(id: RunId, reason: String)
  StartRefused(reason: String)   // only a refused budget configuration now
}
```

### `run.new_id`, `run.Timeout`

New: `run.new_id() -> RunId` (`run-` and 32 random hex characters) and
`run.Timeout { After(Duration) Infinity }`. `run.RunId` is now an alias of
`fabric/internal/run_id.RunId`, so `fabric/model` can name it; code that
uses `run.RunId` is unchanged.

### `model.Request`

```gleam
// before
model.Request(system:, messages:, tools:)
// after: read by label
model.Request(run: RunId, turn: Int, correlation: Correlation, system:,
  messages:, tools:)
```

A custom model built with `model.new` reads `request.correlation` for its
own HTTP calls. Positional construction or matching breaks.

### `fabric/llm.model`

The signature is unchanged. Each turn now runs through
`http_gun.with_correlation(client, request.correlation)`. Apps that built
one agent per request to correlate model calls build one agent and pass the
correlation to `fabric.start`.

### `tool.bind`, `tool.bind_settling`: the handler gets a `tool.Call`

```gleam
// before
tool.bind(definition, fn(context, input) { .. }, classify)
tool.bind_settling(definition, fn(context, input, settlement) { .. },
  classify, within: 5000)

// after
tool.bind(definition, fn(context, call, input) { .. }, classify)
tool.bind_settling(definition, fn(context, call, input, settlement) { .. },
  classify, within: duration.seconds(5))
```

`tool.Call(run: RunId, action: ActionId, correlation: Correlation)` is read
by label. A handler that ignores it writes `fn(context, _call, input)`.

New: `tool.with_timeout(tool, run.Timeout)` overrides the agent's
`tool_timeout` for one tool.

### `agent.Limits`

```gleam
// before
agent.Limits(..agent.default_limits(), policy_timeout: 1000,
  model_retry_delay: 50, command_timeout: 1000)

// after
agent.Limits(..agent.default_limits(),
  policy_timeout: duration.seconds(1),
  model_retry_delay: duration.milliseconds(50),
  command_timeout: duration.seconds(1),
  model_timeout: run.After(duration.seconds(600)),   // new, default 600 s
  tool_timeout: run.After(duration.seconds(60)),     // new, default 60 s
  max_result_bytes: 1_048_576,                       // new, default 1 MiB
)
```

Behaviour: a model call past `model_timeout` is stopped and is a retryable
`ModelError` that spends a turn; a tool body past `tool_timeout` is stopped
and its action is an uncertain effect; a result over `max_result_bytes`
ends the run with `run.Failed(run.OutputEncodingFailed(id, detail))`, whose
detail names the limit. `run.Infinity` lifts the two timeouts. Code that
updates from `default_limits()` keeps compiling except for the three
`Int` fields.

### `agent.ConfigError`

The payloads of `PolicyTimeoutNotPositive`, `PolicyTimeoutTooLarge`,
`ModelRetryDelayNegative`, `ModelRetryDelayTooLarge`,
`CommandTimeoutNotPositive`, `CommandTimeoutTooLarge`,
`SettlementBoundNotPositive` and `SettlementBoundTooLarge` are `Duration`s.
New: `InvalidToolTimeout(name, timeout)`, `ModelTimeoutNotPositive`,
`ModelTimeoutTooLarge`, `ToolTimeoutNotPositive`, `ToolTimeoutTooLarge`,
`MaxResultBytesNotPositive`.

### `fabric.await`, `fabric.await_with`, `graph.await`

```gleam
// before
fabric.await(handle, 5000)
graph.await(handle, 5000)

// after
fabric.await(handle, within: duration.seconds(5))
graph.await(handle, within: duration.seconds(5))
```

A `within` of zero or less reads the status now; `graph.await` no longer
returns `InvalidTimeout`.

New, for a handler that must also react to its caller:

```gleam
// before (tool_hub): an unlinked waiter process sent `fabric.await`'s result
// after
case fabric.await_with(handle, within: budget, or: relay_tool.cancelled(call)) {
  Ok(fabric.Interrupted(Nil)) -> {
    let _ = fabric.cancel(handle)
    Error(Cancelled)
  }
  Ok(fabric.Reached(status)) -> answer(status)
  Error(error) -> Error(Failed(error))
}
```

### `fabric.sweeper`, `fabric.SweeperError`

```gleam
// before
fabric.sweeper(runs, recoveries, every: 1000)
// after
fabric.sweeper(runs, recoveries, every: duration.seconds(1))
```

`EveryNotPositive(Duration)` and `EveryTooLarge(value: Duration, limit:
Duration)`.

### `store.leased`, `store.with_drain` and their errors

```gleam
// before
store.leased(name, node: "app-1", lease: 30_000, backend:)
store.with_drain(runs, 10_000)
// after
store.leased(name, node: "app-1", lease: duration.seconds(30), backend:)
store.with_drain(runs, duration.seconds(10))
```

`LeaseTooShort`, `LeaseTooLong`, `DrainNotPositive` and `DrainTooLarge`
carry `Duration`s. The backend port (`store.Lease`, `LeasedBackend`,
`discovery.Trigger`) keeps integer milliseconds: backends store them.

### `graph.with_timeouts`, `graph.Error.InvalidTimeout`

```gleam
// before
graph.with_timeouts(runtime, 1000, 60_000, 1000)
// after
graph.with_timeouts(runtime,
  callbacks: duration.seconds(1),
  operations: duration.seconds(60),
  commands: duration.seconds(1))
```

`InvalidTimeout(Duration)` names the value refused.

### `operation.with_deadline`, `job.with_poll_interval`

```gleam
// before
operation.with_deadline(wait, 60_000)
job.with_poll_interval(observer, 1000)
// after
operation.with_deadline(wait, duration.minutes(1))
job.with_poll_interval(observer, duration.seconds(1))
```

`InvalidDeadline(Duration)` and `InvalidPollInterval(Duration)`. The stored
contract (`job.Every(milliseconds)`, a deadline in milliseconds) is
unchanged.

### `fabric/observation`

The metadata of every run event gains `correlation: Correlation`
(`RunStarted`, `RunRecovered`, `RunHandedOff`, `RunTakenOver`, `ModelTurn`,
`ApprovalRequested`, `ApprovalAnswered`, `ToolDispatched`, `ToolSettled`,
`ChildStarted`, `ChildSettled`, `SettlementRefused`, `RunCancelled`,
`RunFinished`), written under the `correlation` key. Handlers that read by
label are unchanged.

### `fabric_saga.tool`

```gleam
// before
fabric_saga.tool(definition, workflow, config, explain:, rollback_within: 10_000)
// after
fabric_saga.tool(definition, workflow, config,
  input: fn(context, call, input) { WorkflowInput(input, context.approver) },
  explain:, rollback_within: duration.seconds(10))
```

`input` is the SD-2 run context; `fn(_, _, input) { input }` keeps the old
behaviour. Each call's Saga run is configured with
`execution.with_correlation(config, call.correlation)`. The tool's body is
bounded by the agent's `tool_timeout`: give a workflow longer than 60 s
`tool.with_timeout`.

### `fabric_postgres`

```gleam
// before
fabric_postgres.with_lease(settings, 30_000)
fabric_postgres.prune(settings, ended_for: 604_800_000, limit: 100)
// after
fabric_postgres.with_lease(settings, duration.seconds(30))
fabric_postgres.prune(settings, ended_for: duration.hours(7 * 24), limit: 100)
```

`PruneAgeNegative(Duration)`.

### `fabric_mcp` and `fabric_typesafe`

`fabric_mcp/client.Options.timeout`, `request_with_timeout(.., timeout)`
and `fabric_typesafe/client.Bounds.timeout` are `Duration`s.

## Dependents

Line numbers are at the dependents' current heads; none was edited.

| Dependent                              | Site                                                          | Uses                                                                                                                                                        | Breaks                                                                                                                                                                                                                        |
| -------------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| support_desk                           | `src/support_desk/desk.gleam`                                 | `fabric.start` (4 args), `tool.bind` handlers, `fabric_saga.tool`, `fabric.StartRefused` as a mapper, an agent built per ticket for `llm.model` correlation | compile errors: labelled `start`, `_call` parameter, `input:` and `Duration` `rollback_within`; the per-ticket agent can become one agent with `correlation: Some(ticket)`; the ticket's saga events now join it (SD-2, SD-3) |
| support_desk                           | `src/support_desk.gleam`, `test/support_desk_test.gleam`      | `fabric.await(handle, ms)`, `agent.Limits(..)` with `max_turns`                                                                                             | `await` needs `within: Duration`; the `Limits` updates compile                                                                                                                                                                |
| tool_hub                               | `src/tool_hub/assistant.gleam`                                | `fabric.start`, `fabric.await`, `agent_for` per question, `await_or_cancel` waiter (33 lines)                                                               | compile errors; the waiter becomes `fabric.await_with(.., or: cancelled)` and the agent can be built once                                                                                                                     |
| tool_hub                               | `src/tool_hub/remote_tools.gleam`, `test/tool_hub_test.gleam` | `tool.bind` handlers, `fabric.await`                                                                                                                        | `_call` parameter; `within:`                                                                                                                                                                                                  |
| research_agent                         | `src/research_agent/jobs.gleam`                               | `fabric.start`, `fabric.await`                                                                                                                              | compile errors; the job can start under `run.parse_id(job_id)` and drop its job-to-run table (RA-3)                                                                                                                           |
| research_agent                         | `src/research_agent/researcher.gleam`                         | `tool.bind`, `agent.Limits(.., model_retry_delay: 50)`                                                                                                      | `_call` parameter; `duration.milliseconds(50)`                                                                                                                                                                                |
| research_agent                         | `src/research_agent/app.gleam:113`                            | `fabric_postgres.with_lease(settings.fabric_lease_ms)`                                                                                                      | needs a `Duration`                                                                                                                                                                                                            |
| research_agent, support_desk, tool_hub | `src/*/telemetry.gleam`                                       | `fabric/observation` metadata read by label                                                                                                                 | compile unchanged; `metadata.correlation` is available                                                                                                                                                                        |
| fabric consumers and experiments       | `consumers/*`, `experiments/*`                                | the items above                                                                                                                                             | migrated in this round                                                                                                                                                                                                        |

No other gleam-dream package imports fabric.

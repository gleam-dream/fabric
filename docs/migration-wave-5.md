# Migrating to wave 5

Wave 5 runs as several slices. This guide records each slice's public
changes with a before and after snippet, and the dependents that use each
item. Dependents were found by searching the `src`, `test`, `integrations`,
`consumers` and `examples` directories of every gleam-dream repository and
`oversight/apps`. Inside this repository, every integration, consumer and
test is already migrated.

Stored records stay compatible: records written before wave 5 read
unchanged. A sub-agent record now also stores its family's root (see
[Telemetry](#telemetry-root-and-lease_lost)).

## Slice F1: structure

### `fabric/observation` is `fabric/telemetry`

```gleam
// Before
import fabric/observation as o
o.ActionRef(run:, turn:, call_id:, tool:)

// After
import fabric/telemetry as o
o.Action(run:, turn:, call_id:, tool:)
```

Dependents: `oversight/apps/tool_hub/src/tool_hub/telemetry.gleam`,
`oversight/apps/support_desk/src/support_desk/telemetry.gleam` and
`oversight/apps/research_agent/src/research_agent/telemetry.gleam` import the
module (only the import changes; they read metadata by label). No dependent
names `ActionRef`.

### Telemetry: `root` and `lease_lost`

Every run event's metadata record gains `root: String`, the id of the
family's root run, before `correlation`. `LeaseLost` gains `root` and
`correlation`. Code that reads fields by label is unaffected; code that
builds or matches these records positionally adds the field.

```gleam
// Before
fn(_, m: o.LeaseLost) { #(m.run, m.owner) }

// After: the lost run joins its family and its request
fn(_, m: o.LeaseLost) { #(m.run, m.root, m.correlation) }
```

A sub-agent record stores `"root"`; a root record writes no key, so its
bytes are unchanged. A sub-agent record written before wave 5 reads its
parent as its root, which is exact for sub-agents one level deep. A graph
run's `lease_lost` derives its correlation from the run id and names the
graph run as its root until graph telemetry lands (planned for wave 5).

Dependents: the three app telemetry modules above (by label only).

### The store port: `fabric/store/backend`

The types a backend implements or returns move out of `fabric/store`.

```gleam
// Before
import fabric/store
case store.get_record(..) { Error(store.NotFound) -> .. }
store.leased(name, node:, lease:, backend: store.LeasedBackend(..))
fn get(run) -> Result(store.Stored, store.StoreError)

// After
import fabric/store
import fabric/store/backend
case .. { Error(backend.NotFound) -> .. }
store.leased(name, node:, lease:, backend: backend.LeasedBackend(..))
fn get(run) -> Result(backend.Stored, backend.StoreError)
```

Moved: `StoreError` (`NotFound`, `AlreadyExists`, `Conflict`,
`LeaseRefused`, `Unavailable`), `Stored`, `Holder` (`Free`, `Held`),
`Current`, `Lease` (`Hold`, `Claim`, `Seize`, `Release`) and
`LeasedBackend`. `fabric/store` keeps `Store`, `Message`, `Readiness`, the
configuration errors and every function.

Dependents: none outside this repository (`oversight/apps/webhooks` matches
`store.NotFound` of its own store).

### Backend projections and checks under `fabric/store/`

```gleam
// Before
import fabric/discovery
import fabric/retention
import fabric/statistics
import fabric/testing
testing.leased_backend_checks(new)
testing.leased_memory()

// After
import fabric/store/discovery
import fabric/store/retention
import fabric/store/statistics
import fabric/store/conformance
conformance.checks(new)
conformance.leased_memory()
```

`fabric/testing` keeps `call`. Dependents: `integrations/fabric_postgres`
(migrated); none outside this repository.

### Lifecycle: `fabric/sweeper`, `store.stop`, `fabric.cancel_when_down`

The sweeper had to be added after the store in a rest-for-one supervisor,
which only its documentation said. `sweeper.supervised` now supervises the
store's subtree and then its sweeper, in place of `store.supervised`.

```gleam
// Before
let recoveries = [
  fabric.recovery(desk, context_for),
  graph.recovery(graph_id, build_runtime),
]
let assert Ok(sweeper) =
  fabric.sweeper(runs, recoveries, every: duration.seconds(1))
static_supervisor.new(static_supervisor.RestForOne)
|> static_supervisor.add(store.supervised(runs))
|> static_supervisor.add(sweeper)

// After
let roots = [
  sweeper.agent(desk, context: context_for),
  sweeper.graph(graph_id, build: build_runtime),
]
let assert Ok(subtree) =
  sweeper.supervised(runs, roots, every: duration.seconds(1))
static_supervisor.new(static_supervisor.OneForOne)
|> static_supervisor.add(subtree)
```

`fabric.Recovery` is `sweeper.Root`, `fabric.SweeperError` is
`sweeper.SweeperError`, and `DuplicateRecovery` is `DuplicateRoot`. For
scripts and tests, `sweeper.start(runs, roots, every:)` starts a sweeper
beside a store started with `store.start` and returns its process
(`StoreNotRunning` otherwise).

A store started with `store.start` stops with `store.stop`, which drains its
runners as a supervisor would and waits for its process:

```gleam
// Before: kill the starter and wait for the store's process by its pid
let assert Ok(pid) = store.pid(runs)    // @internal
process.kill(owner)
// ... monitor pid ...

// After
let assert Ok(Nil) = store.stop(runs)
```

A run that must not outlive the process that asked for it is tied to it:

```gleam
// Before: a monitor process in the application (tool_hub, 11 lines)
// After
fabric.cancel_when_down(handle, owner: connection_pid)
```

Dependents: no app registers a sweeper; `oversight/apps/research_agent`
uses `store.supervised` (unchanged). `oversight/apps/tool_hub` can replace
its disconnect bridge with `cancel_when_down`.

### Renames

```gleam
// Before                                   // After
run.Identity("desk", 1)                     run.DefinitionId("desk", 1)
graph.AwaitingApproval(approval: graph.Approval)
                                            graph.AwaitingApproval(graph.ApprovalRef)
graph.approval_requirement(approval)        approval.requirement
receipt.route == graph.Canceled             receipt.route == graph.Stopped
tool.bind_settling(d, h, c, within: d2)     tool.bind_settling(d, h, c, settle_within: d2)
```

`graph.Route.Canceled` becomes `Stopped`, not `Cancelled`: a variant
`Cancelled` would clash with `graph.Status.Cancelled` in the same module,
and the route also covers a deadline's stop. The stored tag is unchanged.

Dependents: none outside this repository.

### Machinery leaves the public modules

No public module has an `@internal` item. These were callable but
undocumented, and are now in `fabric/internal/*`: `run.issued`,
`model.call`, `agent.Admitted` and `agent.admitted`, `tool.Late`,
`tool.Kind`, `tool.delegation`, `tool.call`, `tool.name`,
`tool.description`, `tool.input_schema`, `tool.check`, `tool.kind`,
`tool.settles_within`, `tool.timeout`, `tool.invoke`, the store's process
functions (`store.get`, `insert`, `commit`, `pid`, `watch`, …),
`graph.backing_store`, `child.attachment`, `child.reserved_id`,
`child.branch_id`, `signal.output`, `signal.encode`, the `job` observer
accessors, the `operation` machinery and the `definition` machinery.
`operation.input_codec` and `operation.output_codec` stay public and are now
documented (`consumers/writing` reads receipts with them). In the
integrations: `fabric_postgres/statistics.read` and `refresh`,
`fabric_mcp/client.Frame` and `admit_frame`, and
`fabric_typesafe/question.placeholder`.

```gleam
// Before: a test stopped a store through its process
let assert Ok(pid) = store.pid(runs)
// After
let assert Ok(Nil) = store.stop(runs)
```

The opaque types (`model.Model`, `agent.Agent`, `tool.Tool`,
`tool.Definition`, `store.Store`, `graph.Runtime`, `graph.Handle`,
`definition.Definition`, `operation.Operation`, `job.Observer`,
`signal.Signal`) are now aliases of internal representations. Code that
names them is unchanged.

Dependents: `oversight/apps/tool_hub/src/tool_hub/remote_tools.gleam` uses
Relay's `tool.name`, not Fabric's. No other dependent calls these items.

## Slice F2: failures and configuration

Records written before this slice still read: a reviewer stored as a
string reads as `reviewer.new(subject)`, a missing reviewer as `None`, an
approval request without a deadline never expires, an action without
`"replays"` was never replayed, and a model failure without a kind reads as
`model.Other` (`model.Overloaded` when it was retryable). The fixtures
`test/fixtures/records/pre-wave-5-*.json` were written by the fabric of
slice F1. New keys (`expires_at`, `reviewer_issuer`, `expired`, `replays`,
`kind`, `retry_after_ms`) are written only when they say something, so a
reader that ignores them sees the record it saw before; an expired request
reads there as a rejection.

### One `fabric.Error`

`StartError`, `RecordError` and `CommandError` are one `fabric.Error`.
`Unreadable(RecordError)` is gone: its variants are `Error`'s own.
`StartRefused(String)` is gone: a family budget is checked by `agent.build`
(`InvalidLimit`), and a store that cannot hold one is
`FamilyBudgetUnsupported`. New variants: `ApprovalExpired`.
`error_kind(error)` classifies it as `NotFound`, `Refused`, `Retry`,
`Unavailable` or `Incompatible`; `describe_error(error)` is one line for
logs.

```gleam
// Before
fn review(..) -> Result(run.Status, fabric.CommandError) {
  use handle <- result.try(
    fabric.open(runs, desk, context, id) |> result.map_error(fabric.Unreadable),
  )
  ..
}
case fabric.start(..) {
  Error(fabric.AlreadyStarted(id)) -> fabric.open(..)
  Error(fabric.StartRefused(reason)) -> ..
  Error(fabric.Unreadable(fabric.StoreUnavailable(_))) -> retry()
}

// After
fn review(..) -> Result(run.Status, fabric.Error) {
  use handle <- result.try(fabric.open(runs, desk, context, id))
  ..
}
case fabric.start(..) {
  Error(fabric.AlreadyStarted(id, same_input: True)) -> fabric.open(..)
  Error(fabric.AlreadyStarted(_, same_input: False)) -> Error(IdTaken)
  Error(error) ->
    case fabric.error_kind(error) {
      fabric.Retry | fabric.Unavailable -> retry()
      _ -> Error(Failed(fabric.describe_error(error)))
    }
}
```

`AlreadyStarted` gains `same_input`: whether the stored run was started by
the same agent with the same prompt and correlation. A run's context is
never stored, so it is not compared.

Unions that may grow, documented as such: `fabric.Error`,
`agent.ConfigError`, `agent.Limit`, `model.ErrorKind`, `run.Outcome`,
`run.HostFailure`, `run.ActionState` and `graph.Status`. Match the variants
you handle and keep a catch-all, or branch on the kind.

Dependents:

- `oversight/apps/support_desk/src/support_desk/desk.gleam` breaks: it
  names `fabric.StartError`, builds `StartRefused` and matches
  `AlreadyStarted(id)`;
- `oversight/apps/research_agent/src/research_agent/jobs.gleam` breaks: it
  matches `AlreadyStarted(_)` (now two fields; use `AlreadyStarted(..)`);
- `oversight/apps/tool_hub` matches only `fabric.Reached` and
  `fabric.Interrupted` and reads errors with `string.inspect`: unaffected;
- `consumers/app` and the core tests (migrated).

### `model.ModelError` is opaque, with a kind and a provider delay

```gleam
// Before
Error(model.ModelError("rate limited", retryable: True))
case error { model.ModelError(retryable: True, ..) -> .. }

// After
Error(
  model.error(model.RateLimited, "rate limited")
  |> model.with_retry_after(duration.seconds(2)),
)
case model.is_retryable(error) { True -> .. }
model.error_kind(error)      // Unreachable | TimedOut | RateLimited | Overloaded
                             // | Rejected | InvalidRequest | InvalidReply
                             // | Crashed | Other
model.retry_after(error)     // Option(Duration)
model.describe_error(error)  // "rate limited: .. (retry after 2000 ms)"
```

The first four kinds are retryable. Fabric waits at least an error's
`retry_after` before the retry (at most 10 minutes), instead of only its own
backoff. `fabric/llm` maps llm_wire's typed failure instead of
`string.inspect`: a failure `llm_wire.advise` says another attempt may help
becomes `RateLimited` (429 or a rate-limit code), `TimedOut` (a timer or
408), `Unreachable` or `Overloaded`, and `advise`'s `ProviderDelay` becomes
`retry_after` (the wave 4 follow-up: Retry-After was dropped). Other
failures are `Rejected`, `InvalidRequest`, `InvalidReply` or `Other`. A
model timeout is `TimedOut`, a crashed model `Crashed`.

Dependents: no app builds or reads a `model.ModelError` (their models are
`fabric/llm` models over scripted providers); `test/fabric/llm_*_test` read
`model.is_retryable` (migrated).

### `model.ToolCall` is built with `tool_call`

```gleam
// Before
model.ToolCall("c1", "lookup", "{\"city\":\"Paris\"}", None, None)
model.ToolCall(id:, name:, arguments_json:, provider_id: Some(p), provider_state: None)

// After
model.tool_call(id: "c1", name: "lookup", arguments_json: "{\"city\":\"Paris\"}")
model.tool_call(id:, name:, arguments_json:)
|> model.with_provider_replay(id: Some(p), state: None)
```

A call is still read by label (`call.name`, `call.arguments_json`).

Dependents: no app builds a `model.ToolCall` (their `tool_calls` are
llm_wire's); `consumers/app`, `integrations/fabric_postgres/test` and the
core tests (migrated).

### `agent.Limits` is gone: setters on the spec

```gleam
// Before
agent.new("desk", model, tools, policy)
|> agent.with_limits(
  agent.Limits(..agent.default_limits(), max_turns: 6, token_budget: Some(20_000)),
)

// After
agent.new("desk", model, tools, policy)
|> agent.with_max_turns(6)
|> agent.with_token_budget(20_000)
```

| Before (`agent.Limits` field) | After                                     |
| ----------------------------- | ----------------------------------------- |
| `max_turns`                   | `agent.with_max_turns(spec, Int)`         |
| `max_concurrency`             | `agent.with_max_concurrency(spec, Int)`   |
| `token_budget: Some(n)`       | `agent.with_token_budget(spec, n)`        |
| `max_children`, `max_depth`   | `with_max_children`, `with_max_depth`     |
| `policy_timeout`              | `with_policy_timeout(spec, Duration)`     |
| `model_retry_delay`           | `with_model_retry_delay(spec, Duration)`  |
| `command_timeout`             | `with_command_timeout(spec, Duration)`    |
| `model_timeout`               | `with_model_timeout(spec, run.Timeout)`   |
| `tool_timeout`                | `with_tool_timeout(spec, run.Timeout)`    |
| `max_result_bytes`            | `with_max_result_bytes(spec, Int)`        |
| (new)                         | `with_approval_expiry(spec, run.Timeout)` |
| (new)                         | `with_family_budget(spec, budget.Limits)` |

`agent.default_limits()` and `agent.with_limits` are gone; the defaults
are listed in `fabric/agent`'s module documentation.

`ConfigError`'s per-field variants collapse into one shape. `build` still
reports every problem at once.

```gleam
// Before
Error([agent.MaxTurnsNotPositive(0), agent.MaxChildrenTooLarge(value: 1000, limit: 999)])
agent.InvalidToolTimeout("lookup", duration.milliseconds(0))
agent.SettlementBoundNotPositive("lookup", duration.milliseconds(0))

// After
Error([
  agent.InvalidLimit(limit: agent.MaxTurns, value: 0, minimum: 1, maximum: 9_007_199_254_740_991),
  agent.InvalidLimit(agent.MaxChildren, 1000, 0, 999),
])
agent.InvalidToolLimit("lookup", agent.ToolTimeout, 0, 1, 4_294_967_295)
agent.InvalidToolLimit("lookup", agent.SettleWithin, 0, 1, 4_294_967_295)
agent.describe_config_error(error)  // names the setter
```

Durations are in milliseconds. A bound with no other maximum allows up to
2^53 - 1, the largest integer a JSON record keeps exactly.

Dependents: `oversight/apps/support_desk/src/support_desk/desk.gleam` and
`support_desk/app.gleam` break (`agent.Limits` in their settings,
`agent.with_limits`, `agent.default_limits()`);
`oversight/apps/research_agent/src/research_agent/researcher.gleam` breaks
(`agent.with_limits(agent.Limits(..))`); `consumers/app` (migrated).

### `budget.Limits` is opaque; the family budget is on the agent

```gleam
// Before
fabric.start_with_budget(runs, desk, id:, context:, prompt:, correlation: None,
  limits: budget.Limits(work: 40, children: 6, depth: 3))

// After
let desk =
  agent.new(..)
  |> agent.with_family_budget(
    budget.limits(work: 40) |> budget.with_children(6) |> budget.with_depth(3),
  )
  |> agent.build
fabric.start(runs, desk, id:, context:, prompt:, correlation: None)
```

`budget.limits(work:)` allows as many children as units of work and 16
levels; `with_children` and `with_depth` narrow it. `fabric.start_with_budget`
is gone (the graph's `graph.start_with_budget` takes the opaque limits and
is otherwise unchanged; it moves with the graph vocabulary in slice F5).

Dependents: none outside this repository.

### A typed `Reviewer`

`fabric.approve` and `fabric.reject` require a `reviewer.Reviewer`, built
by the application from an identity it authenticated. `run.Approval.reviewer`
is `Option(Reviewer)`: `None` for an expired request and for answers stored
before reviewers were required.

```gleam
// Before
fabric.approve(handle, pending.reference, reviewer: Some("alice"), context:)
fabric.reject(handle, pending.reference, reason: "no", reviewer: None)
let assert [run.Approval(reviewer: Some("alice"), ..)] = action.approvals

// After
let alice = reviewer.new(claims.subject) |> reviewer.with_issuer(claims.issuer)
fabric.approve(handle, pending.reference, reviewer: alice, context:)
fabric.reject(handle, pending.reference, reason: "no", reviewer: alice)
let assert [run.Approval(reviewer: Some(who), ..)] = action.approvals
reviewer.subject(who)  // "alice"
```

Dependents: `oversight/apps/support_desk/src/support_desk.gleam` and
`support_desk/test/support_desk_test.gleam` break (`reviewer: Some(..)`,
`reviewer: None`, matching `run.Approval(reviewer: Some("alice"), ..)`);
`consumers/app`, `integrations/fabric_postgres/test` (migrated).

### Approval requests expire

New requests expire after 7 days by default; `agent.with_approval_expiry(spec,
run.After(d))` changes it and `run.Infinity` keeps a request forever. The
deadline is stored with the request:

```gleam
// Before
run.AwaitingApproval(requirement, revision)
run.PendingApproval(reference, tool, arguments_json)

// After
run.AwaitingApproval(requirement, revision, expires: Option(Timestamp))
run.PendingApproval(reference, tool, arguments_json, expires: Option(Timestamp))
run.Expired          // a new run.Answer
telemetry.Expired    // a new telemetry.Answered
```

An expired request rejects its action: the model sees that its approval
expired, and the run goes on. It is rejected by whoever touches the run
next: `fabric.await`, an answer (which then fails with `ApprovalExpired`),
`fabric.recover`, or on a leased store the sweeper, which discovers the
deadline (`store/discovery` version 11; backends refresh their projection as
for any version change). Requests stored without a deadline never expire.

Dependents: no app builds or matches `AwaitingApproval` or
`PendingApproval` positionally (`support_desk/test` reads them by label).
An app whose approvals may wait longer than 7 days sets
`agent.with_approval_expiry`.

### Tools: replay, accessors, typed reconciliation

```gleam
// Before: research_agent reconciled a read-only fetch after a crash (77 lines)
// After
tool.bind(fetch_definition, fetch, classify) |> tool.with_replay(3)
```

`tool.with_replay(tool, max_attempts)` starts a body again, up to
`max_attempts` starts in all, after it crashed, ran past its timeout or
lost its runner, instead of recording an uncertain effect. A handler's own
`Explain` or `Uncertain` is never replayed. `run.ActionRecord` gains
`replays: Int`.

```gleam
// New
tool.name(definition)          // also description, input_codec, output_codec
tool.action(settlement)        // the run.ActionRef a settlement settles
tool.reconciliation(definition, Ok(Receipt(id: "r-1")))  // Result(String, EncodeError)
tool.reconciliation(definition, Error("declined"))       // Ok("{\"error\":\"declined\"}")

// Before
fabric.reconcile(handle, effect.reference, "{\"receipt\":\"r-1\"}")
// After
let assert Ok(content) = tool.reconciliation(definition, Ok(Receipt("r-1")))
fabric.reconcile(handle, effect.reference, content)
```

Dependents (all additive): `oversight/apps/research_agent/src/research_agent/jobs.gleam`
reconciles its read-only `read` tool after a crash (`fabric.reconcile` at
line 314 and its helpers): `tool.with_replay` on that tool replaces it.
`oversight/apps/support_desk/src/support_desk.gleam` (line 146) writes
reconciliation content by hand: `tool.reconciliation` builds it.
`oversight/apps/tool_hub/src/tool_hub/remote_tools.gleam` can read a fabric
definition's name and codecs (slice F4).

### Run ids from known parts

```gleam
// Before
let assert Ok(id) =
  run.parse_id("research-" <> int.to_string(job_id) <> "-" <> int.to_string(attempt))

// After
let id = run.id_from_parts("research", [int.to_string(job_id), int.to_string(attempt)])
```

`id_from_parts` is total: parts that do not make a valid id are hashed
(`prefix_<sha256>`), the same way every time. The prefix is source code and
must be 1 to 32 letters and digits (it panics otherwise).

**Job ids.** A job that starts a run under its job id finds that run again
when it is delivered again (`AlreadyStarted`), which is what a replay wants.
A retry that must start afresh (the job's next attempt after a business
failure) must include the attempt in the id, or it reopens the finished run
of the earlier attempt:

```gleam
run.id_from_parts("research", [int.to_string(job_id), int.to_string(attempt)])
```

Dependents (additive): `oversight/apps/research_agent/src/research_agent/jobs.gleam`
(`run_id` asserts on `parse_id`) and
`oversight/apps/support_desk/src/support_desk/desk.gleam` (maps a
`parse_id` failure to `StartRefused`, which is gone) can use
`id_from_parts`.

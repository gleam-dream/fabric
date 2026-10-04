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

### `sweeper.start` stops with its caller

A sweeper started with `sweeper.start` (outside a supervisor) now stops
when the process that started it exits, also normally. It used to keep
scanning after a script or a test ended. `sweeper.supervised` is
unchanged.

Dependents: none outside this repository (no app starts a sweeper).

## Slice F5: one vocabulary for agents and graphs

The graph runtime ships in fabric 1.0 (release decision 2), so it now speaks
the agent runtime's vocabulary: one `policy.Action`, one `tool.Failure`,
one approval shape with a typed reviewer and a 7-day expiry, the context
built from the run id, and one classified error. Graph waits are bounded by
default, every deadline is judged by the store's clock, and graph runs emit
telemetry with a correlation.

Graph records are now version 15. Records written before this slice
(version 14 and earlier) still read and recover: a run stored without a
correlation derives it from its id, a child stored without a root names its
parent, and an approval request or wait stored without a deadline keeps
none, even under the new 7-day defaults. The fixtures
`test/fixtures/records/graph-*.json` were written by the fabric of slice F2
(`graph_stored_record_test`). New keys (`correlation`, `root`,
`expires_at`, `approvals`) are written only when they say something, so a
version-14 reader of a new record that has none of them sees its old shape.

No `oversight/apps` program uses `fabric/graph`; the graph dependents are
this repository's consumers and integrations (migrated). The agent-side
changes (`reviewer.new`, `policy.Action`) are listed with their dependents.

### `reviewer.new` and `reviewer.with_issuer` check their input

A subject and an issuer come from a token, so they are runtime data: both
functions return `Result(Reviewer, reviewer.Error)` and refuse an empty part
or one longer than 256 bytes (`reviewer.Empty(part)`,
`reviewer.TooLong(part:, bytes:, limit:)`, `reviewer.describe_error`).
Stored reviewers read unchecked.

```gleam
// Before
let alice = reviewer.new(claims.subject) |> reviewer.with_issuer(claims.issuer)

// After
use alice <- result.try(
  reviewer.new(claims.subject)
  |> result.try(reviewer.with_issuer(_, claims.issuer))
  |> result.replace_error(Unauthenticated),
)
```

Dependents: no app calls `reviewer.new` yet (they move to the typed
reviewer of slice F2 and build it this way); `consumers/app/test`,
`integrations/fabric_postgres/test` (migrated).

### Approval deadlines by the store's clock

Agent approval deadlines are now set and judged by the store's clock
(`store.now`), like graph deadlines, not by the clock of the node that
checks them. A command or a recovery reads the store's clock first; a store
that cannot be read is `fabric.StoreUnavailable`, and nothing is judged
expired while it cannot be read. No signature changed. Dependents: none.

### One `policy.Action`

`policy.Action` serves both runtimes. `id` became `step`, which says where
the action comes from, and `tool` became `name`, what the action calls.
`policy.Target` gains `RunOperation` for graph nodes. `graph.Action` and
`graph.Policy` are gone: a graph runtime takes a `policy.Policy`.

```gleam
// Before (agent)
policy.Action(run:, id: ActionId(turn, call_id), tool: "refund", arguments_json:, target: policy.InvokeTool)
case action.tool { "refund" -> .. }
// Before (graph)
graph.Action(invocation:, node: "publish", operation:, input_json:, recovery:, kind:)
fn(_, action: graph.Action) { case action.node { "publish" -> .. } }

// After (both)
policy.Action(run:, step: policy.ToolCall(id), name: "refund", arguments_json:, target: policy.InvokeTool)
policy.Action(run:, step: policy.Activation(activation, attempt), name: "publish-post",
  arguments_json:, target: policy.RunOperation(node: "publish", operation:, kind: policy.Activity))
case action.name { "refund" -> .. }
case action.target { policy.RunOperation(node: "publish", ..) -> .. }
```

`policy.OperationKind` (`Activity`, `Signal`, `Job`, `OwnedJob`, `Subgraph`,
`Agent`, `Fork`) is the graph kind a policy sees. A `case` on
`action.target` needs a branch for `RunOperation` (or a catch-all).
`tool.input(definition, action)` matches `action.name`, so it also reads a
graph node whose operation has the tool's name.

Dependents: `oversight/apps/support_desk/src/support_desk/desk.gleam` and
`research_agent/src/research_agent/researcher.gleam` take a
`policy.Action` and read it only through `tool.input`: they compile
unchanged. `consumers/app/src/app.gleam` (`case action.target`), core tests
(migrated).

### One `tool.Failure`; `operation.Failure` is gone

A graph operation classifies its errors with the agent's `tool.Failure`.

```gleam
// Before
operation.new(identity, input, output, perform, fn(_) { operation.DefiniteFailure("declined") })
operation.UncertainEffect("gateway timed out")
operation.BodyFailed(operation.DefiniteFailure(reason))

// After
operation.new(identity, input, output, perform, fn(_) { tool.Explain("declined") })
tool.Uncertain("gateway timed out")
operation.BodyFailed(tool.Explain(reason))
```

`Explain` fails the run (`graph.OperationFailed`), `Uncertain` blocks it
for reconciliation, as before. `operation.own_job`'s `classify` and
`fabric/graph/llm` use it too. Dependents: `integrations/fabric_mcp`,
`fabric_typesafe`, `consumers/jobs`, `decision`, `writing` (migrated).

### A graph runtime: context from the run id, setters, family budget

```gleam
// Before
graph.new(definition, runs, fn() { ctx }, policy)
|> graph.with_timeouts(callbacks: d1, operations: d2, commands: d3)  // Result
graph.start_with_budget(runtime, id, initial, limits)

// After
graph.new(definition, runs, context: fn(run_id) { ctx }, policy:)
|> graph.with_callback_timeout(d1)
|> graph.with_operation_timeout(run.After(d2))   // or run.Infinity
|> graph.with_command_timeout(d3)
|> graph.with_approval_expiry(run.After(duration.hours(24)))
|> graph.with_family_budget(limits)
```

The context function gets the run's id, as the sweeper's agent roots do.
A setter's bound is written in source code, so a value out of range is a
bug and panics with the setter's name (release decision 4);
`InvalidTimeout` is gone. `start_with_budget` is gone: a runtime with a
family budget declares it for every root it starts, and a store that cannot
hold one is `FamilyBudgetUnsupported`. An activity body is now bounded by
the executor that runs it (still 60 s by default; `Infinity` allowed).

Dependents: every graph consumer and integration test (migrated).

### `graph.start`, `open`, `snapshot`, `cancel`, `cancel_stored`

```gleam
// Before
let assert Ok(handle) = graph.start(runtime, id, initial)
let handle = graph.attach(runtime, id)
let assert Ok(snapshot) = graph.read(handle)
let assert Ok(Nil) = graph.cancel(handle)

// After
let assert Ok(handle) = graph.start(runtime, id:, initial:, correlation: None)
let assert Ok(handle) = graph.open(runtime, id)   // reads and checks the record
let assert Ok(snapshot) = graph.snapshot(handle)
let assert Ok(cancelled) = graph.cancel(handle)   // the snapshot after the commit
graph.cancel_stored(runs, id)                     // a run that no longer opens
```

`start` takes the run's correlation (`None` derives it from the id) and
stores it: it reaches every operation (`operation.Invocation.correlation`),
every child run and every event. A second start with a stored id is
`AlreadyStarted(id, same_input:)`. `open` reads the record and checks it
against the definition, as `fabric.open` does: a run whose definition
changed is `IncompatibleDefinition`, and `cancel_stored(store, id)`
cancels it without one. `cancel` on an ended run is `RunEnded`.

Dependents: every graph consumer and integration (migrated).

### Approvals: reviewer, current context, expiry

```gleam
// Before
graph.approve(handle, approval)
graph.reject(handle, approval, "not today")

// After
graph.approve(handle, approval, reviewer:, context: current_context)
graph.reject(handle, approval, reason: "not today", reviewer:)
```

The policy is checked again with `context`, and the approved operation runs
with it, as for agents. The reviewer is stored with the answer:
`graph.Snapshot.approvals` (the current activation's) and
`graph.Receipt.approvals` hold `run.Approval`s. A policy that now requires
another approval refuses the answer with `RequirementChanged(new_ref)`; a
superseded request is `StaleReference`, an answered one `AlreadyAnswered`.

Approval requests expire after 7 days by default
(`graph.with_approval_expiry`, `run.Infinity` to keep them). The deadline
is stored with the request and shown as `Snapshot.deadline`. An expired
request fails the run with `graph.ExpiredApproval(due)`; a late answer is
`ApprovalExpired`. `await`, an answer, `recover` and the sweeper expire it
(`store/discovery` version 12 projects its deadline). Requests stored
without a deadline never expire.

Dependents: graph consumers and integrations (migrated).

### Typed graph errors

`CommandRefused(String)` and the strings built with `string.inspect` are
gone. `graph.Error` names each refusal like the agent's, and
`graph.error_kind` classifies it with `fabric.ErrorKind`;
`graph.describe_error` gives a line for logs.

| Before                                                             | After                                                                                                  |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| `StoreFailed(backend.NotFound)`                                    | `RunNotFound`                                                                                          |
| `StoreFailed(..)`                                                  | `StoreUnavailable(reason)`, `Contended`, `RunUnattended`                                               |
| `UnsupportedRecordVersion(n)`                                      | `UnsupportedVersion(n)`                                                                                |
| `DefinitionRejected(e)`                                            | `IncompatibleDefinition(e)`; a delivered or reconciled value the definition refuses: `ValueRefused(e)` |
| `CommandRefused("… belongs to another run")`                       | `WrongReference`                                                                                       |
| `CommandRefused("… is not current")`, `"no signal is awaited"`     | `StaleReference`, or `RunEnded` for an ended run                                                       |
| `CommandRefused("signal conflicts …")`                             | `SignalConflict`                                                                                       |
| `CommandRefused("no unresolved result")`                           | `NotReconcilable`                                                                                      |
| `CommandRefused("reconcile the child …")`                          | `ReconcileChildFirst`                                                                                  |
| `CommandRefused("child runtime does not use the parent store")`    | `ChildMismatch(DifferentStore)`                                                                        |
| `CommandRefused("child belongs to a different parent activation")` | `ChildMismatch(OtherParent)`                                                                           |
| `CallbackFailed("parent no longer accepts child work")`            | `RunEnded`                                                                                             |
| `Busy`, `OwnerUnknown`                                             | `RunnerBusy`, `RunUnattended`                                                                          |
| `InvalidTimeout(d)`                                                | gone (setters panic)                                                                                   |

New variants: `AlreadyStarted`, `FamilyBudgetUnsupported`,
`AlreadyAnswered`, `ApprovalExpired`, `RequirementChanged`, `ValueRefused`.
`graph.Failure` gains `ExpiredApproval(due)`; `graph.describe_failure`.

Dependents: graph consumers and integrations (migrated).

### Definitions are built, with every problem at once

```gleam
// Before
let assert Ok(id) = definition.node_id("review")
definition.build(definition.Spec(identity, id, nodes, state_codec, answer_codec, 20))
let assert Ok(op) = operation.with_deadline(op, duration.minutes(5))
let assert Ok(op) = operation.with_replay(op, 3)
let assert Ok(observer) = job.with_poll_interval(observer, duration.seconds(5))

// After
let id = definition.node_id("review")
definition.new(identity, entry: id, nodes:, state: state_codec, answer: answer_codec)
|> definition.with_max_activations(20)        // default 100
|> definition.build                           // Result(Definition, List(BuildError))
let op = operation.with_deadline(op, run.After(duration.minutes(5)))  // or run.Infinity
let op = operation.with_replay(op, 3)
let observer = job.with_poll_interval(observer, duration.seconds(5))
```

`definition.Spec` is opaque. `build` checks the graph and every operation's
settings and reports every problem: `InvalidNodeId(name)`,
`InvalidOperation(node, operation.ConfigurationError)` (now including
`InvalidPollInterval`; `job.ConfigurationError` is gone), and the others
as before; `definition.describe_build_error`.

### Waits are bounded by default

A signal, job, child or fork wait without `operation.with_deadline` now
expires 7 days after admission. `operation.with_deadline(op, run.Infinity)`
waits without one. The default, and 7 days set explicitly, leave the
definition's stored structure as it was, so stored runs keep opening; a
run stored without a deadline keeps none. A deployment whose waits may
last longer than a week sets the deadline.

### `fabric/graph/agent` and `fabric/graph/llm` are built with constructors

```gleam
// Before
agent_node.new(agent_node.Definition(identity, agent, input, output, prompt, answer), runs, fn() { ctx })
graph_llm.new(identity, input, output, "review", fn(ctx, text) { #(client, config, request) })

// After
agent_node.new(identity, agent, input:, output:, prompt:, answer:)
|> agent_node.runtime(runs, context: fn(child_run) { ctx })
graph_llm.decision(identity, input:, output:, name: "review", call: fn(ctx, text) {
  graph_llm.call(client:, config:, request:)
})
```

A decision's HTTP requests carry the run's correlation
(`http_gun.with_correlation`); a managed agent child inherits its graph
parent's correlation and root. Dependents: `consumers/graph`, `decision`,
`writing`, `integrations/fabric_postgres/test` (migrated).

### Graph telemetry

Graph runs now emit `graph_started` (`[fabric, graph, start]`),
`activation_started` (`[fabric, graph, activation, start]`: an activity
queued or a wait begun, with its kind and deadline), `activation_settled`
(`[fabric, graph, activation, stop]`), `graph_approval_requested` and
`graph_approval_answered` (`[fabric, graph, approval, request|answer]`),
`graph_cancelled` (`[fabric, graph, cancel]`) and `graph_finished`
(`[fabric, graph, stop]`). Each carries the run's `correlation` and its
family's `root`; a graph run's `lease_lost` now carries its stored
correlation and root. Additive: no dependent breaks.

## Slice F3: typed answers

An agent's final answer is now typed. `agent.with_answer(spec, codec)` gives
it a codec: the model is asked for the codec's JSON Schema, and a run
completes with the decoded value. The answer type flows through `Agent`,
`fabric.Run`, `run.Status`, `run.Outcome` and `run.Snapshot`, through
sub-agents (a delegation's output is its child's answer) and through graph
agents (the operation's output codec is the agent's). Commands return the
run's status in both runtimes.

Stored records keep their format: a run stores the text the model sent, as
before. The fixtures `test/fixtures/records/pre-answer-*.json` were written
by the fabric of slice F5 (`stored_answer_test`): a completed run stored with
a text answer reads as `run.Completed(text)` under a plain agent, and through
the agent's codec when the text decodes (`run.Completed(value)`); a stored
text the codec refuses reads as `run.AnswerInvalid(raw:, reason:)`. A run that
ends on an invalid answer is stored as a completion with an
`"answer_invalid"` key, which a reader that ignores the key reads as the text
answer it would have read before.

### `agent.with_answer`; `Spec`, `Agent` and the run types gain the answer

```gleam
// Before
let assert Ok(desk) = agent.new("desk", model, tools, policy) |> agent.build
// desk: Agent(Ctx)
case fabric.await(handle, within: duration.seconds(30)) {
  Ok(run.Finished(run.Completed(text))) -> parse_resolution(text)
  ...
}

// After
let assert Ok(desk) =
  agent.new("desk", model, tools, policy)
  |> agent.with_answer(resolution_codec)   // a record codec with a schema
  |> agent.build
// desk: Agent(Ctx, Resolution); without with_answer: Agent(Ctx, String)
case fabric.await(handle, within: duration.seconds(30)) {
  Ok(run.Finished(run.Completed(resolution))) -> Ok(resolution)
  Ok(run.Finished(run.AnswerInvalid(raw:, reason:))) -> Error(#(raw, reason))
  ...
}
```

| Before                                      | After                                                                      |
| ------------------------------------------- | -------------------------------------------------------------------------- |
| `agent.Spec(context)`                       | `agent.Spec(context, answer)`; `agent.new` returns `Spec(context, String)` |
| `agent.Agent(context)`                      | `agent.Agent(context, answer)`                                             |
| `fabric.Run(context)`                       | `fabric.Run(context, answer)`                                              |
| `run.Status`, `run.Outcome`, `run.Snapshot` | `run.Status(answer)`, `run.Outcome(answer)`, `run.Snapshot(answer)`        |
| `run.Completed(text: String)`               | `run.Completed(answer: answer)`                                            |
| (none)                                      | `run.AnswerInvalid(raw: String, reason: String)`                           |
| `run.ChildSettled(outcome: Outcome)`        | `run.ChildSettled(outcome: Outcome(String))`                               |
| `fabric.Awaited(message)`                   | `fabric.Awaited(answer, message)`                                          |
| `sweeper.agent(Agent(context), ..)`         | `sweeper.agent(Agent(context, answer), ..)`                                |
| (none)                                      | `agent.AnswerSchemaUnavailable` (`build` refuses a codec without a schema) |
| (none)                                      | `telemetry.OutcomeKind.AnswerInvalid` (`"answer_invalid"`)                 |

A plain agent changes only in its types: `Agent(Ctx)` becomes
`Agent(Ctx, String)` and `run.Status` becomes `run.Status(String)`. An
exhaustive `case` on `run.Outcome` adds `AnswerInvalid`.

`fabric.child(run, id)` returns `Run(context, String)`: a sub-agent's answer
reads as the text it stored (its delegation reads it with the child's
codec). Commands on the store with no agent read the stored text:
`fabric.cancel_stored` returns `Status(String)`, `reconcile_stored` and
`settle_stored` return `Snapshot(String)`.

Dependents:

- `oversight/apps/support_desk`: `desk.gleam` (`Agent(Session)`,
  `fabric.Run(Session)`, `run.Outcome`, the 23-line JSON parser in
  `answer` that `with_answer` replaces), `support_desk.gleam`
  (`fabric.Run(desk.Session)`), `test/support_desk_test.gleam`.
- `oversight/apps/research_agent`: `domain.gleam` (the 46-line `TITLE:`
  parser that `with_answer` replaces), `jobs.gleam` (`Agent(Context)`,
  `fabric.Run(Context)`, `fabric.Reached(run.Finished(run.Completed(text)))`),
  `researcher.gleam` (`Agent(Context)`, `run.Snapshot`), `app.gleam`
  (`run.Snapshot`), `test/research_agent_test.gleam`.
- `oversight/apps/tool_hub`: `assistant.gleam` (`agent.Agent(Context)`,
  `fabric.Reached(run.Finished(run.Completed(text)))`),
  `test/tool_hub_test.gleam` (`run.Status`).

### The model is given the answer's schema

`model.Request` gains `answer: Option(codec.Schema)`: the schema of an agent
with `with_answer`, `None` for a plain one. Fabric checks a `FinalAnswer`
against the agent's codec whatever the model did with it. `fabric/llm` asks
the provider for structured output through `llm_wire.with_output(request,
"answer", contract.value_codec(..))`: OpenAI's and Anthropic's JSON Schema
output format, Google's response schema. A final text llm_wire refuses
against the schema is still returned as the `FinalAnswer`, so the run ends
with `AnswerInvalid` and keeps the text; a schema the provider cannot take
(OpenAI and Anthropic need an object at the root) fails the turn as
`model.InvalidRequest`.

```gleam
// Before: a model built by hand
model.Request(run:, turn:, correlation:, system:, messages:, tools:)

// After
model.Request(run:, turn:, correlation:, system:, messages:, tools:, answer: None)
```

A model that reads the request by label is unaffected. Dependents: none in
`oversight/apps` builds a `Request`.

### Sub-agents use the child's answer type

```gleam
// Before
agent.with_sub_agent(spec, research, to: researcher, prompt: fn(topic) { topic.name },
  output: fn(text) { parse_summary(text) })   // research: Definition(Topic, Summary)

// After: the child's answer is the delegation's output
let researcher = agent.new(..) |> agent.with_answer(summary_codec) |> agent.build
agent.with_sub_agent(spec, research, to: researcher, prompt: fn(topic) { topic.name })
```

`definition`'s output type is the child's answer type (`String` for a plain
child), and its output codec encodes the result the model sees. A child that
ends with `AnswerInvalid` is a definite failure the model sees ("the
sub-agent's answer is invalid: ..."). Dependents: none in `oversight/apps`
calls `with_sub_agent`.

### Graph agents take their output from the agent

```gleam
// Before
graph_agent.new(identity, agent, input: topic_codec, output: summary_codec,
  prompt: fn(topic) { .. }, answer: parse_summary)

// After
graph_agent.new(identity, agent, input: topic_codec, prompt: fn(topic) { .. })
// agent: Agent(context, Summary), built with agent.with_answer(summary_codec)
```

The operation's output codec is the agent's answer codec (`codec.string()`
for a plain agent, which encodes its text as a JSON string, as an `output:
codec.string(), answer: Ok` pair did). A child agent that ends with
`AnswerInvalid` blocks its parent with `graph.InvalidResult(output:, reason:)`,
as an `answer` callback's `Error` did. `graph_agent.child` returns
`fabric.Run(context, output)`. Dependents: none in `oversight/apps` uses
`fabric/graph`.

### Commands return the run's status in both runtimes

The agent runtime's commands returned the run's `Status`, the graph
runtime's its `Snapshot`. Both now return the status, as `await` does, and
`snapshot` reads the whole record:

```gleam
// Before
let assert Ok(graph.Snapshot(status: graph.AwaitingApproval(pending), ..)) =
  graph.await(handle, within: duration.seconds(5))
let assert Ok(done) = graph.approve(handle, pending, reviewer:, context:)
done.value

// After
let assert Ok(graph.AwaitingApproval(pending)) =
  graph.await(handle, within: duration.seconds(5))
let assert Ok(graph.Completed(answer)) = graph.approve(handle, pending, reviewer:, context:)
let assert Ok(snapshot) = graph.snapshot(handle)   // the state value, receipts, deadline
snapshot.value
```

`graph.await`, `recover`, `poll_job`, `cancel`, `approve`, `reject`,
`deliver`, `deliver_json` and `reconcile` return `Result(Status(answer),
Error)`. `graph.cancel_stored` still returns `Nil`: with no definition there
is no status to read. Dependents: none in `oversight/apps` uses
`fabric/graph`; this repository's consumers and integrations are migrated.

### `graph.status_kind`

`graph.Status` grows, so it has a stable classification:
`graph.status_kind(status) -> graph.StatusKind`, one of `Active` (await it),
`NeedsRecovery` (`Unattended`: recover it), `NeedsInput` (an approval, a
signal or a reconciliation) and `Ended`; `graph.describe_status` gives one
line for logs. Additive.

## Slice F4: a corrective answer turn, Relay and docs

Slice F4 gives a refused typed answer a corrective turn, replaces
`fabric_mcp` with `fabric_relay`, and reorders the README around the common
path. Stored records keep their format: a corrective turn is an assistant
turn and a user message in the transcript, which every reader of record
versions 1 to 7 already reads. The fixture
`test/fixtures/records/answer-correction-pending.json` (written by this
slice, `answer_retry_test`) holds a run whose corrective turn was in flight
when its runner was lost; `recover` issues that turn again.

### A refused answer gets a corrective turn

```gleam
// Before: the first answer the codec refused ended the run
Ok(run.Finished(run.AnswerInvalid(raw:, reason:)))   // after one model call

// After: the model is told why and asked again, once by default
agent.new("desk", model, tools, policy)
|> agent.with_answer(resolution_codec)
|> agent.with_answer_attempts(2)   // the default; 1 ends on the first refusal
|> agent.build
```

The corrective request holds the refused answer as an assistant turn and a
user message: `Your final answer could not be read: <reason>` and the
answer's JSON Schema. It is a model attempt like any other: it counts
against `with_max_turns` and `with_token_budget`, and with no turn or token
left the run ends with `AnswerInvalid` (not `BudgetExhausted`). The count of
refused answers is read from the stored transcript, so a recovered run does
not get its attempts back. `telemetry.model_turn` reports the refused turn
as `AnswerRejected`; an exhaustive `case` on `telemetry.TurnResult` or
`agent.Limit` adds an arm.

Dependents: none in `oversight/apps` uses `with_answer` yet (the apps are
migrated to slice F3 afterwards); a test that counts model calls on a refused
answer counts two, or sets `with_answer_attempts(1)`.

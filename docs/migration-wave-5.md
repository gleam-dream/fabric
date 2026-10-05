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
parent as its root, which is exact for sub-agents one level deep (round 7
derives the exact root at any depth). A graph
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

### `fabric_mcp` is gone: `integrations/fabric_relay`

`fabric_mcp` shipped its own stdio JSON-RPC client, bound MCP tools only as
graph operations, mapped a remote `isError` to an uncertain effect and
reported `Result(_, String)` errors. The new package `fabric_relay` works
over Relay's client, which speaks stdio and Streamable HTTP, in agents and
graphs, and serves agents as MCP tools.

```gleam
// Before: a stdio client of its own, a pinned descriptor, a graph binding
let assert Ok(connection) =
  fabric_mcp_client.start("counter", fabric_mcp_client.options("python3", ["server.py"]))
let assert Ok(pinned) = fabric_mcp.discover(connection, "increment")
let assert Ok(increment) =
  fabric_mcp.bind(run.DefinitionId("increment", 1), pinned, input_codec, output_codec,
    fn(context) { context.counter }, convert)
// increment: Operation(context, Input, Receipt(Output))

// After: Relay's client and the tool's Relay definition
let assert Ok(peer) = client.connect(client.stdio("python3", ["server.py"]))
let increment = fabric_relay.operation(increment_definition(), version: 1,
  peer: fn(context) { context.counter })
// increment: Operation(context, Input, Output)
let agent_tool = fabric_relay.tool(increment_definition(), peer: fn(context) { context.counter })
let listed = fabric_relay.discover(peer, peer: fn(context) { context.counter })
```

| `fabric_mcp`                                               | `fabric_relay`                                                                                                     |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `fabric_mcp/client.start`, `request`, `stop`               | `relay/client` (`client.stdio`, `client.http`, `connect`, `close`)                                                 |
| `discover(connection, name) -> Result(Tool, String)`       | `discover(client, peer:)`, `discovered(declaration, peer:)` (typed `DiscoveryError`), or the server's `Definition` |
| `bind(identity, tool, input, output, connection, convert)` | `operation(definition, version:, peer:)`; agents: `tool(definition, peer:)`                                        |
| `Receipt(output)` with the raw response                    | the output; the graph stores its JSON as for any operation                                                         |
| `tool_codec` (a pinned descriptor)                         | none: the `Definition` is in source code; a listed tool is rediscovered at start                                   |
| remote `isError` -> uncertain effect                       | remote `isError` -> `tool.Explain`; a call that may have reached the server -> `tool.Uncertain` unless read-only   |
| (none)                                                     | the run's correlation and an idempotency key on every call                                                         |
| (none)                                                     | `serve(definition, service(runs, agent, start:))`, `with_wait`, `run_id`                                           |

A stored graph run whose node used `fabric_mcp.bind` continues only under an
operation with the same identity and output codec. `fabric_relay.operation`
outputs the bare value, not a `Receipt`, so give the operation a new version
and let runs stored under the old one finish first.

`fabric_relay.serve` publishes an agent as one Relay tool. Each call starts
a run with the call's correlation; a call with an idempotency key
(`client.with_idempotency_key`) names its run
(`fabric_relay.run_id(definition, principal:, key:)`), so a retried call
reaches the same run and waits for it again. A keyed run outlives its call;
a call without a key owns its run, which is cancelled when the call is
cancelled or its wait (25 s, `with_wait`) ends. A run that does not complete
in time answers `isError: true` with structured `error` and `run_id`.

Dependents: no package depends on `fabric_mcp`. `oversight/apps/tool_hub`
wrote the adapter itself, and can delete it:

- `src/tool_hub/remote_tools.gleam` (204 lines): `mount(definition, peer)`
  is `fabric_relay.tool(definition, peer:)`, `discover(connected, peer)` is
  `fabric_relay.discover(connected, peer:)`, `mount_discovered` is
  `fabric_relay.discovered`; `classify` and `RemoteFailure` are built in, with
  the same evidence rule (the app's wording "the inventory is unavailable"
  becomes "the MCP call failed: ..."). `fabric_definition` has no
  replacement: `fabric_relay.tool` derives it.
- `src/tool_hub/assistant.gleam`: `serve`, `ask`, `render` and `tool_error`
  (about 120 lines) are `fabric_relay.serve(ask_assistant(),
fabric_relay.service(store, agent, start:) |> fabric_relay.with_wait(budget))`
  with an agent built with `agent.with_answer(answer_codec())`. `Answer`
  loses `run_id` (the answer is the agent's; a failed call's structured
  content names the run), the `AskError` texts become the `error` values
  above, and `cancel_with_caller` becomes the key rule: an unkeyed call is
  cancelled with its caller, a keyed one is not.

### `run.describe_outcome` (added)

```gleam
pub fn describe_outcome(outcome: run.Outcome(answer)) -> String
```

One line for logs and for a caller that reports why a run did not complete,
such as `fabric_relay.serve`'s `isError` text. It replaces
`string.inspect(outcome)` in `oversight/apps/tool_hub/src/tool_hub/assistant.gleam`
(`Failed(string.inspect(other))`).

## Slice F6: leftovers

Slice F6 finishes FABRIC-R11 and R12, adds the classifications the README
promised, and takes up what the app migrations found. Stored records keep
their format: an answer wrapped for the provider is stored as its own JSON,
which is what an unwrapped answer always stored.

### `fabric_saga`: the held error is in the evidence (R11)

Saga's `Unresolved(step, evidence, settlement)` carries the error a step
held its effects on (the error `saga.unknown_when` marked, or a recovery
decision's `Hold(evidence)`). The uncertain effect's evidence now renders it
with the tool's `explain`, after the held step:

```text
// Before
the workflow's effects are not known: the workflow held the effects of step
refund unresolved; ... (Saga reported unresolved at refund)

// After
the workflow's effects are not known: the workflow held the effects of step
refund unresolved: <explain(error)>; ... (Saga reported unresolved at refund)
```

Saga's report in the evidence still names kinds, actions and step addresses
only. No signature changes. Dependents: code that matches the evidence text
(`oversight/apps/support_desk` shows it; its tests read substrings that
still match).

### A Saga step reads the run's correlation

Nothing changes in `fabric_saga`: each Saga run already carries the Fabric
run's correlation, and since saga 9a0b1d8 every step reads it from its
`EffectKey`. The docs now say so, and the tool's `input` need not carry it:

```gleam
// Before: the correlation passed through the workflow's input
input: fn(_, call, loan) { #(loan, call.correlation) }

// After
input: fn(_, _, loan) { loan }
saga.effect("book_courier", fn(loan, key) {
  courier |> http_gun.with_correlation(saga.correlation_of(key)) |> book(loan)
})
```

Dependents: `oversight/apps/support_desk` and `research_agent` correlate the
saga's HTTP client by hand and can use `saga.correlation_of`.

### `fabric_typesafe` posts through a caller's `http_gun.Client` (R12)

The classifier no longer opens Gun itself; `src/fabric_typesafe_http.erl` and
the `gun` dependency are gone. A request goes through the client view the
caller passes, so its timeout, body and header limits, destination policy
and telemetry are HTTP Gun's, and it carries the graph run's correlation
(`operation.Invocation.correlation`).

```gleam
// Before
let assert Ok(settings) = client.new(api_key)
let assert Ok(settings) =
  client.with_bounds(settings, client.Bounds(..client.bounds(), timeout: duration.seconds(20)))

// After
let assert Ok(settings) =
  client.new(
    http |> http_gun.with_timeout(config.After(duration.seconds(20))),
    key: api_key,
  )
```

| Before                                           | After                                                                                                                                                                                                                               |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `client.new(key)`                                | `client.new(http_gun.Client, key:)`                                                                                                                                                                                                 |
| `client.Bounds`, `bounds()`, `with_bounds`       | the view's `http_gun.with_timeout` (client default 30 s, was 20 s); `config.with_max_request_body_bytes` (1 MiB), `with_max_response_body_bytes` (8 MiB, was 1 MiB) or `http_gun.with_body_limit`; `with_max_header_bytes` (16 KiB) |
| `client.post`, `client.Error`, `client.Response` | internal: the operation posts                                                                                                                                                                                                       |
| plaintext to `localhost`, `127.0.0.1`, `::1`     | the same names, and HTTP Gun admits plaintext only to loopback addresses; a client for a loopback endpoint needs `config.allow_loopback`                                                                                            |

A failure HTTP Gun proves unsent (`NotSent`) is still definite
(`tool.Explain`), any other is uncertain. Dependents: `consumers/decision`
and `consumers/writing` (migrated); none outside this repository.

### `run.HostFailure` and `run.ActionState` are classified (added)

```gleam
pub fn host_failure_kind(failure: run.HostFailure) -> run.HostFailureKind
// PolicyFault | ToolFault | ModelFault
pub fn describe_host_failure(failure: run.HostFailure) -> String
pub fn action_state_kind(state: run.ActionState) -> run.ActionStateKind
// Active | NeedsApproval | NeedsReconciliation | Ended
pub fn describe_action_state(state: run.ActionState) -> String
```

The kinds never gain variants. `describe_action_state` names a tool's
result and a sub-agent's answer only by their presence. `describe_outcome`
uses `describe_host_failure` for `Failed`, with the same text as before.
Dependents: none; an app that matches every `ActionState` to log it can
call `describe_action_state`.

### `agent.describe_config_errors` (added)

```gleam
// Before
string.join(list.map(errors, agent.describe_config_error), "; ")
// After
agent.describe_config_errors(errors)
```

Dependents: `oversight/apps/support_desk/src/support_desk/desk.gleam`.

### `tool.unconfirmed_reconciliation` (added)

A person who cannot yet say what happened had to write the content by hand.

```gleam
// Before
fabric.reconcile(handle, effect, "{\"status\":\"unconfirmed\",\"note\":\"finance is checking\"}")
// After
fabric.reconcile(handle, effect, tool.unconfirmed_reconciliation("finance is checking"))
// The model sees {"unconfirmed":"finance is checking"}
```

The action ends `Reconciled` and leaves the run's uncertain effects, so the
application tracks the open question from there. To keep the run waiting
for the answer instead, do not reconcile. Dependents:
`oversight/apps/support_desk/src/support_desk.gleam` (`unconfirmed`).

### A taken id whose record cannot be read is not `same_input: False`

`fabric.start` and `graph.start` answered `AlreadyStarted(id, same_input:
False)` both for another start's run and for a stored run they could not
read. They now return the read's error for the second: `StoreUnavailable`
(an `Unavailable` kind: start again to compare), or `CorruptRecord` or
`UnsupportedVersion` (`Incompatible`). `AlreadyStarted` always means the
stored run was compared; its type is unchanged.

```gleam
// Before: an unreadable record looked like someone else's run
Error(fabric.AlreadyStarted(_, same_input: False)) -> Error(IdTaken)
// After: the same arm means another start's run; an unreadable one is
Error(fabric.StoreUnavailable(_)) -> retry()
```

Dependents: `oversight/apps/research_agent/src/research_agent/jobs.gleam`
and `oversight/apps/support_desk/src/support_desk/desk.gleam` match
`AlreadyStarted(_, same_input: True)` or `AlreadyStarted(id, ..)` and keep
compiling; an unreadable record now reaches their catch-all instead.

### Answers without an object root are wrapped for the provider

Providers need an object at the root of an output schema, so a typed answer
that was a list, a string, a number, a boolean or a nullable value failed
every turn through `fabric/llm` with `InvalidRequest`. `fabric/llm` now
sends such a schema as `{"answer": <schema>}` and unwraps the reply before
Fabric reads it, for agents and graph agents alike (both use `fabric/llm`):
the codec stays the natural type and the run stores the answer's own JSON.

```gleam
// Before: a wrapper record in the application
agent.with_answer({
  use cities <- codec.field("cities", codec.list(codec.string()), get: fn(c) { c })
  codec.success(cities)
})
// After
agent.with_answer(codec.list(codec.string()))
// The provider sees {"answer": [...]}; the run stores ["Paris","Rome"]
```

A `codec.union` answer is wrapped too, but llm_wire's strict structured
output refuses a union at any depth, so through `fabric/llm` it still fails
the turn with `InvalidRequest`; a model built with `model.new` answers it
directly. Dependents: `oversight/apps/research_agent` flattens its
`Written | NoSources` answer into a record and must keep doing so until
llm_wire takes unions.

### `fabric_relay.service` takes the definition; `start` returns a `Start`

```gleam
// Before: `question` needed an annotation, `principal` a constant, and the
// result an `Ok` that could not fail
let service =
  fabric_relay.service(runs, assistant, start: fn(call, question: Question) {
    Ok(fabric_relay.start(ctx, prompt: question.text, principal: "local"))
  })
server.new([fabric_relay.serve(ask_assistant(), service)])

// After
fabric_relay.service(ask_assistant(), runs:, agent: assistant, start: fn(call, question) {
  fabric_relay.start(ctx, prompt: question.text)
  |> fabric_relay.with_principal(tool.context(call).subject)  // optional
})
|> fabric_relay.serve
```

| Before                                               | After                                                                                              |
| ---------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `service(runs, agent, start:)`                       | `service(definition, runs:, agent:, start:)`                                                       |
| `serve(definition, service)`                         | `serve(service)`                                                                                   |
| `start: fn(call, input) -> Result(Start, ToolError)` | `start: fn(call, input) -> Start`; `refuse(tool_error)` refuses                                    |
| `start(context, prompt:, principal:)`                | `start(context, prompt:)`, principal `anonymous`; `with_principal(start, p)`                       |
| a completed call names no run                        | its text block's `_meta` has `io.github.gleam-dream/run-id`, as an `isError` result's now does too |

Relay's call carries no authenticated subject of its own (the server's
context holds it), so the default principal is the constant
`fabric_relay.anonymous`, which suits one trusted client; a server with
several clients names it. A content-only definition's answer names no run.
`serve` documents what bounds a keyed run whose client never retries: the
agent's turn, timeout and token limits and the 7-day approval expiry. A run
stopped on an effect of unknown status has no bound, by design: it waits
for a person.

Dependents: `oversight/apps/tool_hub/src/tool_hub/assistant.gleam`
(`service`, `start`, `serve`) breaks at compile time.

### `fabric_relay.run_of` reads the run a served call names (added)

```gleam
// Before: the raw `_meta` key
let assert Ok(client.Succeeded(answer, [content.TextContent(meta:, ..), ..])) =
  client.call(peer, ask_assistant(), question)
let assert Ok(value.String(id)) =
  list.key_find(meta, "io.github.gleam-dream/run-id")

// After
let assert Ok(result) = client.call(peer, ask_assistant(), question)
let assert Some(id) = fabric_relay.run_of(result)  // a `run.RunId`
```

`run_of(result: client.ToolResult(output)) -> Option(RunId)` reads an
answered or failed result alike; it is `None` for a result that names no
run (a content-only definition's answer, a result waiting for input, or a
tool not published with `serve`). Nothing breaks: the `_meta` key stays.

Dependents: `oversight/apps/tool_hub/test/tool_hub_test.gleam` reads the
raw key and can switch to `run_of`.

## Round 6: bounds are checked by a build step

A bound often comes from runtime configuration, so an out-of-range value
gets a typed error (release decision 4), not a panic. The agent runtime
already worked so: its setters store, and `agent.build` reports every
problem at once as `InvalidLimit(limit:, value:, minimum:, maximum:)`. The
graph runtime, `graph.map` and `fabric_relay.with_wait` panicked instead.
They now follow the agent, with the same error shape and
`describe_config_error(s)`. This supersedes the panicking setters of
[A graph runtime](#a-graph-runtime-context-from-the-run-id-setters-family-budget).

Kept as panics, because each value is a definition written in source code
and wrong in every run, never configuration:

- `run.id_from_parts(prefix, ..)` with a prefix that is not 1 to 32 ASCII
  letters and digits: the prefix names a kind of work in code.
- `fabric_relay.tool`, `operation` and `service` given a content-only Relay
  definition: the definition is code, and `discovered` serves listed tools.

Graph definition bugs (a duplicate or blank node, an unknown destination, a
missing entry, a bad identity) were already typed errors of
`definition.build`, and stay so.

### `graph.build` makes the runtime; the setters only store

```gleam
// Before: `new` returned the runtime and a setter panicked out of range
let runtime =
  graph.new(publishing, runs, context: fn(_run) { ctx }, policy:)
  |> graph.with_operation_timeout(run.After(config.operation_timeout))
  |> graph.with_family_budget(budget.limits(work: config.work))

// After
let assert Ok(runtime) =
  graph.new(publishing, runs, context: fn(_run) { ctx }, policy:)
  |> graph.with_operation_timeout(run.After(config.operation_timeout))
  |> graph.with_family_budget(budget.limits(work: config.work))
  |> graph.build
// or, reporting every problem:
case graph.build(spec) {
  Ok(runtime) -> runtime
  Error(errors) -> panic as graph.describe_config_errors(errors)
}
```

| Before                                                        | After                                                                                               |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `graph.new(..) -> Runtime`                                    | `graph.new(..) -> Spec`; `graph.build(Spec) -> Result(Runtime, List(ConfigError))`                  |
| `with_callback_timeout(Runtime, Duration) -> Runtime`, panics | `with_callback_timeout(Spec, Duration) -> Spec`; `InvalidLimit(CallbackTimeout, ..)`                |
| `with_operation_timeout(Runtime, Timeout)`, panics            | `with_operation_timeout(Spec, Timeout)`; `InvalidLimit(OperationTimeout, ..)`                       |
| `with_command_timeout(Runtime, Duration)`, panics             | `with_command_timeout(Spec, Duration)`; `InvalidLimit(CommandTimeout, ..)`                          |
| `with_approval_expiry(Runtime, Timeout)`, panics over 2^32 ms | `with_approval_expiry(Spec, Timeout)`; 1 ms to 2^53 - 1 ms, as for agents                           |
| `with_family_budget(Runtime, Limits)`, panics                 | `with_family_budget(Spec, Limits)`; `InvalidLimit(FamilyWork \| FamilyChildren \| FamilyDepth, ..)` |
| (none)                                                        | `graph.ConfigError`, `graph.Limit`, `describe_config_error`, `describe_config_errors`               |

`build` reports the bounds in the order above; durations are in
milliseconds. The approval expiry is a stored deadline, not a timer, so it
now takes the agent's range; every other bound keeps its range. The
defaults are unchanged. `Runtime` is still what `start`, `open`,
`as_subgraph`, `both`, `map`, `branch`, `child` and `sweeper.graph` take,
and only `build` makes one, so a run never starts under unchecked bounds.

A test that builds its runtime in a helper and sets a budget per test can
return the `Spec` from the helper (`fabric/graph`'s tests do both).

Dependents: none outside this repository (no `oversight/apps` package and
no sibling imports `fabric/graph`). Inside it, every graph test, the
fabric_postgres, fabric_relay and fabric_typesafe graph tests and the
`graph`, `decision`, `jobs` and `writing` consumers are migrated; the
`jobs` consumer gains `scheduled_spec` and `deadline_spec`.

### `graph.map` bounds are reported by `definition.build`

```gleam
// Before: a panic at the call
graph.map(id, child, max_members: config.batch, concurrency: config.parallel)

// After: the same call; a bound below 1 is reported when the definition is built
definition.build(spec)
// Error([InvalidOperation(node, operation.InvalidLimit(operation.MaxMembers, 0, 1, 9007199254740991))])
```

Dependents: none outside this repository.

### Range problems of a definition have the agent's shape

```gleam
// Before
definition.InvalidActivationLimit(0)
operation.InvalidAttemptBound(0)
operation.InvalidDeadline(duration)
operation.InvalidPollInterval(duration)

// After
definition.InvalidLimit(definition.MaxActivations, 0, 1, 9_007_199_254_740_991)
operation.InvalidLimit(operation.ReplayAttempts, 0, 1, 100)
operation.InvalidLimit(operation.Deadline, ms, 1, 4_294_967_295)
operation.InvalidLimit(operation.PollInterval, ms, 1, 4_294_967_295)
// and, new: operation.MaxMembers, operation.Concurrency (`graph.map`)
definition.describe_build_errors(errors)  // added, as agent.describe_config_errors
```

`operation.with_replay` now takes at most 100 attempts, as
`tool.with_replay` does, and `definition.with_max_activations` at most
2^53 - 1; both were unbounded above. `ReplayRequiresActivity` and
`DeadlineRequiresWait` are unchanged. Every line of
`definition.describe_build_error` names the setter, the value and the
range, as the agent's does.

Dependents: none outside this repository.

### `fabric_relay.serve` checks the wait

```gleam
// Before: `with_wait` panicked out of range
server.new([
  fabric_relay.service(ask_assistant(), runs:, agent:, start:)
  |> fabric_relay.with_wait(config.budget)
  |> fabric_relay.serve,
])

// After
use assistant <- result.try(
  fabric_relay.service(ask_assistant(), runs:, agent:, start:)
  |> fabric_relay.with_wait(config.budget)
  |> fabric_relay.serve   // Result(Tool, List(fabric_relay.ConfigError))
  |> result.map_error(fabric_relay.describe_config_errors),
)
server.new([assistant])
```

`fabric_relay.ConfigError` is `InvalidLimit(limit: Wait, value:, minimum:,
maximum:)` with `describe_config_error(s)`; the range is still 1 ms to
2^32 - 1 ms.

Dependents: `oversight/apps/tool_hub/src/tool_hub/assistant.gleam`
(`server.new([fabric_relay.serve(service)])`, with `with_wait` fed from its
`budget` setting) breaks at compile time: `serve` returns a `Result`. Its
surrounding function already returns a `Result`, so a `result.try` fits.

## Round 6: llm_wire's content filters and opaque test replies

llm_wire's round 6 (its `docs/migration-wave-5.md`, "Round 6") changed two
things Fabric uses: a provider's content filter is a failure, and the
scripted test replies are opaque.

### llm_wire content filters end a run as `run.Refused`

llm_wire's round 6 reports a provider's content filter as the failure
`error.ContentFiltered(stage: InPrompt | InOutput, reason)`, where a Gemini
or Anthropic safety stop was the outcome `Refused` before. Unhandled, the
new failure fell through `fabric/llm`'s classification to the non-retryable
`model.Other`, so such a run ended as `run.Failed(ModelFailed(..))`, and a
graph decision blocked as `EffectUncertain`. Fabric keeps the earlier
behaviour: a filter is the provider's refusal. No `model.ErrorKind` was
added; the failure becomes the existing `model.Refusal` reply.

```gleam
// fabric/llm, inside `execute`
Error(llm_wire.Failure(error: error.ContentFiltered(..) as filtered, usage:, ..)) ->
  Ok(model.Refusal(error.describe(filtered), usage_of(usage)))

// fabric/graph/llm, inside `perform`
Error(llm_wire.Failure(error: error.ContentFiltered(..) as filtered, usage:, ..)) ->
  Ok(Receipt(model, Refusal(error.describe(filtered)), usage))
```

| Provider signal                                    | Before (llm_wire round 5)                                      | After                                                                       |
| -------------------------------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Gemini `promptFeedback.blockReason: SAFETY`        | `run.Refused("Prompt blocked by safety policy: SAFETY")`       | `run.Refused("Provider content filter blocked the prompt: SAFETY")`         |
| Gemini `finishReason: SAFETY` (and `RECITATION`..) | `run.Refused("Google refused generation with reason: SAFETY")` | `run.Refused("Provider content filter stopped the output: SAFETY")`         |
| Anthropic `stop_reason: "refusal"`                 | `run.Refused(<streamed text>)`                                 | `run.Refused("Provider content filter stopped the output: refusal")`        |
| OpenAI `incomplete_details.reason: content_filter` | `run.OutputLimited(<partial text>)`                            | `run.Refused("Provider content filter stopped the output: content_filter")` |
| OpenAI refusal content                             | `run.Refused(<model's words>)`                                 | unchanged                                                                   |

The same reasons appear in a graph decision's `llm.Refusal(reason)` receipt.
The run still records the reported usage, and the refusal is not retried.
Tests: `llm_test.provider_content_filters_end_the_run_as_refused_test`
(prompt blocked and output stopped on the scripted wire, Gemini, Anthropic
and OpenAI) and `graph_llm_test.provider_content_filters_are_refusal_receipts_test`
(both stages).

Dependents: no public item changed, so nothing breaks at compile time.
Code that matches the text of a `run.Refused` reason or a `llm.Refusal`
receipt sees the new lines; none does in `/code/gleam-dream/*` or
`oversight/apps` (`fabric/consumers/decision` and `fabric/consumers/writing`
match the constructors only).

### Tests use llm_wire's opaque `testing.Reply`

llm_wire's `testing.Reply` and `ScriptedCall` are opaque. Only Fabric's
tests built or matched them; the replacements are those listed in llm_wire's
`docs/migration-wave-5.md` "Round 6" call sites:

```gleam
// Before: test/fabric/support/fake_provider.gleam
fn wire(reply: testing.Reply) -> #(Int, List(String), Bool) {
  case reply {
    testing.Events(chunks) -> #(200, chunks, True)
    testing.Interrupted(chunks) -> #(200, chunks, False)
    testing.Status(code, body) -> #(code, [body], True)
  }
}

// After
fn wire(reply: testing.Reply) -> #(Int, List(String), Bool) {
  #(testing.status(reply), testing.chunks(reply), !testing.is_interrupted(reply))
}
```

`testing.ScriptedCall(..)` is `testing.tool_call(..)`, `testing.Status(code,
body)` is `testing.http_status(message.Custom("scripted"), code, body)`,
`testing.Events([..])` is `testing.events([..])` and `testing.Interrupted([])`
is `testing.interrupted(testing.text(""))`, in `llm_test`, `graph_llm_test`,
`llm_recovery_test` and `llm_turn_format_test`.

Dependents: none; the change is internal to Fabric's tests.

## Round 7: exact roots for records stored before roots

Since slice F1 a sub-agent record stores `"root"`, and every event carries
it. A record written before then stores none; its reader took the parent as
the root, which is wrong for a grandchild and below: a pre-wave-5
grandchild's events named its parent, not its family's root.

### A read of the store derives the root; the next commit stores it

`runner.load` (agent records) and the graph runner's `load_raw` (graph
records) are the reads behind `open`, `recover`, `child`, commands, the
sweeper and settlement. For a child record with no `"root"`, they follow the
stored parent links up to a root run or to the first ancestor that stores
its root. The walk is bounded by the 64 links every ancestry walk allows
and never visits a run twice; one level deep it costs one read of the
parent. The resolved root is in the runner's state, so the run's next
commit (any normal commit, for example an approval) writes it, and later
reads take it from the record without walking.

When an ancestor's record is missing or unreadable (cannot be decoded, or
names another run), or the chain repeats or passes the bound, the root is
the topmost ancestor that could be read, or the parent when none could.
That root is marked inexact: the record keeps storing no root, so a later
reader derives it again once the ancestors can be read, and the reader
emits `root_inferred` each time. An unavailable store fails the read with
its `StoreFailed` error instead: nothing is inferred from a store that
cannot answer. A child started by a run whose root is inexact inherits it
inexact.

Internally `controller.State` and the graph `State` gain `root_exact: Bool`
(their records write `"root"` only when it is `True`), and
`graph_runner.lineage` returns it with the correlation and root. These are
internal; no public type changed shape.

### `telemetry.root_inferred` (added)

```gleam
// After
sinal.observe(telemetry.root_inferred(), fn(_, m: telemetry.RootInferred) {
  // m.run took m.root, its topmost readable ancestor, because of
  // m.problem at m.ancestor.
  log.warning(m.run <> ": root inferred as " <> m.root)
})
```

`[fabric, run, root, infer]`, metadata
`RootInferred(run:, root:, ancestor:, problem:, correlation:)`, with
`problem: RootProblem` one of `AncestorMissing`, `AncestorUnreadable`,
`AncestryCycle` and `AncestryTooLong` (metadata names `ancestor_missing`,
`ancestor_unreadable`, `ancestry_cycle`, `ancestry_too_long`). Like the
lease events, it describes no commit: the reading process emits it.
Records written by the current decoder cannot form a cycle (a child's id
derives from its parent's), so `AncestryCycle` guards only foreign or
damaged stores.

Tests: `legacy_root_test` loads fixtures written in the pre-wave-5 shape
(`test/fixtures/records/pre-wave-5-family/`, a root, a child and a
grandchild waiting for two approvals, with no `root`, `correlation` or
`expires_at`). The grandchild's events carry the true root before the
write-back (its first approval and tool) and after it (the second approval,
through another store over the same files, to the family's end); the record
stores `"root":"legacy"` after its first commit. Further cases: a missing
root record (topmost readable ancestor, `root_inferred`, nothing stored), an
unreadable parent, a chain past the bound, and a pre-wave-5 graph child.

Dependents: none break. `root_inferred` is a new event; the three app
telemetry modules (`research_agent`, `support_desk`, `tool_hub`) attach
events one by one and are unaffected. Their stored records written before
wave 5 now report the exact root.

### `fabric_relay`'s tests match relay's opaque `client.Error`

relay's round 7 makes `client.Error` opaque. `fabric_relay`'s source does
not match it; one test did:

```gleam
// Before: integrations/fabric_relay/test/serve_test.gleam
let assert Error(client.TimedOut(_)) =
  client.call(peer, ask(), Question("slow"))

// After
let assert Error(error) = client.call(peer, ask(), Question("slow"))
let assert client.TimedOut(_) = client.reason(error)
```

Dependents: none; the change is internal to the integration's tests.

## Round 8: approvers and proofs

Until round 7 an answer took a `reviewer.Reviewer`, and any code could build
one with `reviewer.new(subject)`. Fabric could not tell a reviewer that a
sign-in produced from one a form field named. Gleam cannot make a value
unforgeable across packages, and a type that only warden could build would
make warden a dependency of fabric. Fabric therefore stops trusting a
reviewer value: the application configures a verifier once, on the agent
or graph runtime, and an answer takes a proof that only that verifier's
`check` makes.

### `fabric/approvers` (added)

```gleam
// After
let desk_approvers =
  approvers.new("sso", fn(token: String, requirement: run.Requirement) {
    // authenticate the token, then authorize it for requirement.name
    use claims <- result.try(verify(token) |> result.map_error(approvers.NotAuthenticated))
    use <- bool.guard(!may_approve(claims, requirement.name),
      Error(approvers.NotAuthorized("not a " <> requirement.name)))
    reviewer.new(claims.sub)
    |> result.map_error(fn(e) { approvers.NotAuthenticated(reviewer.describe_error(e)) })
  })
let proof = approvers.check(desk_approvers, token, pending.reference.requirement)
// Ok(Proof) | Error(NotAuthenticated(_) | NotAuthorized(_) | Unavailable(_))
```

- `Approvers(credential)` is opaque. `new(name, verify)` takes the name
  stored with every answer (1 to 64 bytes; another name is a definition bug
  and panics) and `verify: fn(credential, run.Requirement) ->
Result(Reviewer, Denial)`. `verify` runs in the caller of `check`.
- `Denial` is `NotAuthenticated(reason)`, `NotAuthorized(reason)` or
  `Unavailable(reason)`, with `describe_denial`. The three cases are the
  classification (401, 403, 503), so there is no `denial_kind`.
- `Proof` is opaque, made only by `check`, and read with `reviewer`,
  `verifier` and `requirement`.
- `ProofError` is `NoApprovers`, `OtherApprovers(verifier)`,
  `OtherRequirement(proof:, request:)` or `ProofExpired(age:, lifetime:)`,
  with `describe_proof_error`.
- `with_proof_lifetime(approvers, run.Timeout)`: 60 s by default.

Authorization maps from the request's existing `run.Requirement`, for
example the scope `"approve:" <> requirement.name`. No role field was
added: a requirement already names what the approval is for and carries a
version that stale approvals are refused by.

### Answers take a proof

```gleam
// Before
fabric.approve(handle, pending.reference, reviewer:, context:)
fabric.reject(handle, pending.reference, reason:, reviewer:)
graph.approve(handle, pending, reviewer:, context:)
graph.reject(handle, pending, reason:, reviewer:)

// After
let assert Ok(proof) =
  approvers.check(desk_approvers, token, pending.reference.requirement)
fabric.approve(handle, pending.reference, proof:, context:)
fabric.reject(handle, pending.reference, proof:, reason:)
graph.approve(handle, pending, proof:, context:)  // pending.requirement
graph.reject(handle, pending, proof:, reason:)
```

The labelled order of `reject` changes: `proof:` comes before `reason:`, as
it does before `context:` in `approve`. A call that passed `reason` and
`reviewer` by position must name them.

A proof is checked before the request is. It is refused with
`fabric.ProofRefused(error)` or `graph.ProofRefused(error)` (kind `Refused`),
and nothing changes, when:

- the agent or runtime has no approvers (`NoApprovers`);
- another approvers value made it (`OtherApprovers`), even one with the same
  name and the same function;
- it was checked for another requirement than the reference's
  (`OtherRequirement`). The reference's requirement is the stored request's,
  or the reference is `StaleReference`, so a proof for requirement A never
  answers requirement B;
- it is older than the receiving approvers' lifetime (`ProofExpired`).

`RequirementChanged` after an approval's policy recheck needs a new proof,
for the new requirement.

### `agent.with_approvers`, `graph.with_approvers` (added)

```gleam
// After
let assert Ok(desk) =
  agent.new("desk", model, tools, policy)
  |> agent.with_approvers(desk_approvers)
  |> agent.build
let assert Ok(runtime) =
  graph.new(definition, runs, context:, policy:)
  |> graph.with_approvers(editors)
  |> graph.build
```

The approvers are not stored with the run. A run is answered with the
approvers of the agent value it was started, opened or recovered with, so a
deployment that forgot them is fixed by deploying an agent that has them;
no stored run is lost. A sub-agent without approvers of its own is answered
with its parent's (the parent's requests and its children's surface
together). A graph child runtime (`as_subgraph`, `both`, `map`) is opened
with its own runtime and answers with that runtime's approvers.

### `run.Approval.verifier` and the stored record

```gleam
// Before
Approval(requirement:, revision:, answer:, reviewer: Option(Reviewer))
// After
Approval(requirement:, revision:, answer:, reviewer: Option(Reviewer), verifier: Option(String))
```

The reviewer is the one `verify` returned, and `verifier` the approvers'
name. Both are `None` for an `Expired` answer. The record stores
`"verifier"` beside `"reviewer"` and `"reviewer_issuer"` in agent and graph
records alike. A record without it reads with `verifier: None`: string
reviewers (before wave 5), typed reviewers with an issuer (round 7), and
none. `test/fixtures/records/pre-round-8-suspended.json` is a round-7 run
waiting for an approval: it reads, and the new approvers reject it
(`approvers_test`); `graph_stored_record_test` answers a pre-F5 graph
approval and finds the verifier recorded.

### `testing.trusting_approvers()` (added)

```gleam
// After: a test that is not about who answers
let assert Ok(proof) =
  approvers.check(testing.trusting_approvers(), alice, pending.reference.requirement)
```

The credential is the reviewer itself, and every requirement is granted.
The answers record the verifier `"fabric/testing.trusting_approvers"`, so a
shortcut that reaches production shows in the records and in a grep. Unlike
`approvers.new`, every call returns the same approvers (memoized in the VM),
so a test can give them to an agent in one helper and check proofs in
another.

### Decisions

**Binding.** Each `approvers.new` mints a unique reference. A proof records
that reference, the requirement it was checked for, the reviewer, the
approvers' name and the time of the check. An answer accepts it only when
the reference is the one of the approvers the agent or runtime holds, and
the requirement is the reference's. An application cannot build permissive
approvers elsewhere and slip their proofs in: they carry another reference.
The agent keeps the approvers in a closure, so `Agent(context, answer)`
gains no credential type parameter.

Comparing the `verify` function instead of a reference was tried and
rejected: the compiler specializes a closure at each call site (a test that
called `desk_approvers("sesame")` twice got two unequal functions), so "the
same function" was not stable. The cost of the reference is a rule: build
the approvers once, at boot, and share the value. `trusting_approvers` is
the one exception, by memoization.

**Expiry: yes, 60 s by default.** A proof is evidence that a credential was
verified for one answer, made right before it. A proof that is kept, in a
session or a cache, would turn one sign-in into standing authority and
outlive the credential's revocation or expiry. The lifetime bounds that.
It is judged by the receiving approvers with this node's clock, so
`with_proof_lifetime(run.Infinity)` on the agent's approvers lifts it. A
request handler that checks and answers at once never comes near 60 s.

**Single use: no.** An approval request already takes one answer: the
commit is compare-and-set, and a second answer is `AlreadyAnswered`. A
proof is limited to one requirement and to its lifetime. Single use would
need shared state across nodes for an in-memory value, and it would forbid
a reviewer answering several requests of the same requirement with one
check, which is a legitimate "approve all" action.

**No approvers: answers fail with a typed error.** `build` cannot know
whether a policy requires approvals: a `Policy` is a function whose
decision depends on the action's arguments and the context. Refusing at
`build` every agent without approvers would force approvers on agents that
never ask for one, including every `policy.always_allow()` agent. Refusing
when a request is issued would end runs that a corrected deployment could
still answer. So `approve` and `reject` return `ProofRefused(NoApprovers)`,
whose description names the setters. The request waits until it expires (7
days by default) or the run is cancelled.

**Entry points.** `fabric.approve`, `fabric.reject`, `graph.approve` and
`graph.reject` are the only ones. `fabric_relay` serves runs and tools but
answers no approval, and the store commands (`cancel_stored`,
`reconcile_stored`, `settle_stored`) answer none either.

### The warden recipe and its gate step (added)

Fabric does not depend on warden. The README (after
`<!-- approvers-recipe -->`) and the module doc of `fabric/approvers` (under
`## With warden`) carry the same block, about 30 lines:
`warden_approvers(validator)` verifies an access token for the validator's
audience, requires the scope `approve:<requirement name>`, and builds the
reviewer from the token's `sub` and `iss`. `consumers/approvers_warden` is
that block verbatim (`src/approvers_warden.gleam`), and its tests run it
against warden's test provider, whose `with_granted_scopes` (warden round 8)
grants `approve:refund` to one user only:

- a signed-in user with the scope gets a proof, and the approval records
  `sub`, `iss` and the verifier `"warden"`;
- a signed-in user without it gets `NotAuthorized`;
- expired, unsigned, HMAC-forged, wrong-audience, foreign-issuer, malformed
  and empty tokens get `NotAuthenticated`;
- a key source that cannot be reached gets `Unavailable`;
- a proof from the trusting approvers, from a permissive verifier named
  `"warden"`, from the recipe built a second time, and from the recipe over
  another validator is refused by `approve` with `OtherApprovers`.

`scripts/check.py` gains the package and the step `approvers-recipe`
(`python3 scripts/check.py recipe`), which fails with a diff when the
README or module doc copy differs from the consumer's file. The gate's own
unit tests cover the extraction.

### Migration inside this repository

Every test, integration, consumer and experiment is migrated. Tests that
are not about who answers give their agents and runtimes
`testing.trusting_approvers()` and check proofs with it (`support.agent`
and `support.proof` in the core tests). `consumers/app` gained
`app.staff()`, approvers over staff badges whose roles name the
requirements they may answer; `librarian`, `librarian_spec`,
`misconfigured` and `front_desk` take it, and the purchaser sub-agent is
answered with the desk's. `consumers/writing`'s `fabric_writing.runtime`
and `consumers/jobs`'s `cancellation_runtime` take approvers; the writing
CLI answers as the operator at the terminal (`FABRIC_WRITING_OPERATOR`).

Dependents:

| Item                                                                | Dependent                                                                  | How it breaks                                                                                                                                                        |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fabric.approve(.., reviewer:, ..)`, `fabric.reject(.., reviewer:)` | `oversight/apps/support_desk/src/support_desk/desk.gleam` (lines 243, 257) | does not compile: the label is `proof:` and the value an `approvers.Proof`                                                                                           |
| `reviewer.new` inside the verifier                                  | `oversight/apps/support_desk/src/support_desk/approvers.gleam` (line 63)   | compiles; its `authenticate` becomes the `verify` of `approvers.new`, and should also check the approver's scope (support_desk authenticates but does not authorize) |
| no approvers on the agent                                           | support_desk's desk agent                                                  | answers fail with `ProofRefused(NoApprovers)` until it calls `agent.with_approvers`                                                                                  |
| `run.Approval`                                                      | `oversight/apps/support_desk/test/support_desk_test.gleam` (line 105)      | compiles (label pattern with `..`); can assert `verifier:`                                                                                                           |

No other app answers approvals (`research_agent` and `tool_hub` build
agents whose policies never require one), and no sibling repository uses
these items.

### A graph child admitted after its parent closed is cancelled (fixed)

A child graph run checks its family's capacity when it admits an activation.
When the parent had already closed (a sibling fork member was refused, or
the parent was stopping), the check reported `Closed`, which the runner
treated as a policy failure: the child ended
`Failed(PolicyFailed("parent no longer accepts child work"))` and the
parent's fork recorded `Admitted(Failed(..))` instead of
`Admitted(Cancelled)`. The internal `AdmissionError` gains
`AncestorStopping`; the runner cancels the run (`Cancelled(BeforeStart)`),
an approval answered in that window is `RunEnded`, and fork admission stops
as for a closed ancestry check. No public type changed. The order predates
round 8 (1 failure in 300 runs under CPU load at bc99f0e).

Dependents: none; no app or sibling matches on that failure text.

## Round 9: ports and compiled recipes

### Classification replaces the TypeSafe bridge

Remove the `fabric_typesafe` dependency. Question definitions move to
`llm_wire/classify/question`; `Alternative(label, value, description)` becomes
`alternative(label, value, description)`. `noul`, `choice`, `score`, `ask` and
`combine` are total for source definitions (drop `let assert Ok`); their
`check_*` counterparts accept runtime definitions and return typed errors.
`question.decode` returns typed `question.Error`, with `error_kind` and
`describe_error`. Returned `Noul`, `Choice`, `Score` and `Probability` values
keep their fields; read them by label.

Before:

```gleam
let assert Ok(config) = client.new(http, key: key)
let assert Ok(config) = client.with_endpoint(config, url)
let op = fabric_typesafe.new(id, input_codec, questions, fn(context, input) {
  #(config, fabric_typesafe.Request(model, value.String(input)))
})
let saved = fabric_typesafe.receipt_codec(questions)
```

After:

```gleam
import fabric/graph/classify as decision
import llm_wire/classify

let config = classify.typesafe(fn() { key }) |> classify.with_endpoint(url)
let op = decision.decision(id, input_codec, questions, config, fn(context, input) {
  decision.call(http, model, value.String(input))
})
let saved = classify.receipt_codec(config, questions)
```

Without fabric, use `classify.request(model, state, questions)`,
`classify.prepare(config, request)` and `classify.run(http, prepared)`.
The request, settings and prepared call are opaque; settings use `with_*`.
Preparation returns `error.PrepareError`; execution returns `llm_wire.Failure`
with submission evidence, `error.kind`, `describe_failure` and `advise`.
`with_timeout` takes `llm_wire.After(Duration)` or `Infinity`, default 600 s;
request and response byte limits default to 1 MiB. Endpoint and credential
validation happens at preparation, not at the settings constructor.

`Receipt(answer)` becomes `classify.Outcome(answer)`. It retains answer,
requested/resolved model, request/response JSON and usage, and adds the input
state. Usage is `message.Usage(input_tokens, output_tokens, total_tokens)`.
Native outcomes have no public constructor. For tests, opaque
`testing.classification_response(body)`, `with_classification_status`,
`with_classification_header` and `classification_exchange(prepared, reply)`
replace the bridge's private fixture transport. A second provider uses
`classify.wire` and `classify.decoded`; core HTTP behaviour stays shared.

Receipts write `llm.classification.receipt.v1` and still read
`fabric.typesafe.receipt.v1`. The old-code fixtures include a completed graph
store; the compatibility test opens it offline. Keep application operation
identities and versions unchanged when only migrating this wiring.
The decision and writing consumers migrate together and keep their native
business routes, rubric evidence, approval and recovery semantics.

### Nested graph execution on slower hosts

No public API or record shape changes. The full gate exposed a nested fork
that exceeded its unchanged five-second test deadline. Profiling identified
copies of repeated callback environments, not a lost wakeup: the two-level
fixture copied 20,488,572 machine words. Lazy callback construction and narrow
managed-child input contracts reduce that to 3,796,381 words. A structural
regression bounds copied size, and the original deadline test passed 20 times.

### A saga workflow as a tool

Before:

```gleam
import fabric_saga
let refund = fabric_saga.tool(definition, workflow, config,
  input: input, explain: explain, rollback_within: duration.seconds(5))
```

After, copy the 47-line README recipe into `src/saga_tool.gleam` and remove
`fabric_saga` from `gleam.toml`:

```gleam
import saga_tool
let refund = saga_tool.tool(definition, workflow, config,
  input: input, explain: explain, rollback_within: duration.seconds(5))
```

The arguments keep their meaning. `saga/outcome` owns complete effect
classification, including held effects; `saga/reporting.run_owned` owns the
surviving receiver. The recipe carries `call.correlation` and maps typed
failures to `Explain` or `Uncertain`. Fabric still owns settlement deadlines and
observes refused late reports. All 19 integration behaviors remain tested in
`consumers/saga_tool`; the 24 pure verdict tests moved to saga. The gate compares
README and `fabric/tool` docs against the compiled recipe and emits a diff.

Dependents migrated: `consumers/app` and oversight's `apps/support_desk` each
own a verbatim copy. Fabric's core manifest has no saga dependency. The former
bridge package is deleted; no stored record shape changed.

### MCP bridges become explicit composition

Copy only the modules needed from the README into the application's `src`.
Remove `fabric_relay` from its manifest. Fabric gains no Relay dependency.
All 23 old tests now compile in `consumers/relay_tools`; graph operations are
retained as a 28-line variant. The main recipes are 40-line typed calling and
41-line serving, plus 50-line discovery and a 12-line result-id accessor.

```gleam
// Before
let mounted = fabric_relay.tool(definition, peer:)
let listed = fabric_relay.discover(peer, peer:)
let operation = fabric_relay.operation(definition, version: 1, peer:)
// After
let mounted = relay_tools.tool(definition, peer:)
let assert Ok(declarations) = client.list_tools(peer)
let listed = list.try_map(declarations, relay_discovery.discovered(_, peer:))
let operation = relay_operation.operation(definition, version: 1, peer:)
```

`discovered` now reports the recipe's `UnsupportedName` or
`UnsupportedSchema(contract.DocumentError)`, described by `describe_error`.
Listing failures remain Relay's opaque `client.Error`, with `kind`, `reason`,
`evidence` and `describe_error`. The old `DiscoveryError.ListingFailed` wrapper
and `describe_discovery_error` disappear; no delivery evidence is discarded.
`tool` and `operation` still require structured output definitions. Discovery
retains schema validation and projects content-only results to their text.

```gleam
// Before
fabric_relay.service(definition, runs:, agent:, start: fn(call, input) {
  fabric_relay.start(context, prompt: input.question)
  |> fabric_relay.with_principal(tool.context(call).subject)
}) |> fabric_relay.with_wait(wait) |> fabric_relay.serve
// After
let service = invoke.agent(tool.name(definition), runs, agent)
  |> invoke.with_wait(wait)
relay_serve.serve(definition, service, fn(call, input) {
  Ok(invoke.request(context, input.question)
    |> invoke.with_principal(tool.context(call).subject))
})
```

The old `Start` wrapper becomes `Result(invoke.Request, tool.ToolError)`:
`refuse(error)` becomes `Error(error)`, `start(context, prompt:)` becomes
`invoke.request(context, prompt)`. The anonymous principal remains `"anonymous"`.
Set a verified principal for shared servers. Service configuration is now
`invoke.Service`; `check` returns `Result(Nil, invoke.ConfigError)` and the
single `InvalidWait(value, minimum, maximum)` replaces the list containing
`InvalidLimit(Wait, ...)`. Use `invoke.describe_config_error`.

For an HTTP handler or job, bypass the Relay recipe entirely:

```gleam
let request = invoke.request(context, prompt)
  |> invoke.with_principal(subject)
  |> invoke.with_key(key)
  |> invoke.with_correlation(correlation)
  |> invoke.with_cancelled(disconnected)
let response = invoke.call(service, request)
let id = invoke.id(response)
let answer = invoke.answer(response)  // Option(native_answer)
let kind = invoke.response_kind(response)
let description = invoke.describe_response(response)
let structured = invoke.details(response)  // error, run_id, evidence
```

`invoke.code` supplies detailed machine codes (keep a fallback). `Working`,
`AwaitingApproval`, `AwaitingInput`, `OutcomeUnknown`, `Unattended`, `Ended`
and `Refused` tell the caller what to do next. Cancellation that is still
settling is `Working`; a failed cancellation is `OutcomeUnknown`, never a
claim that effects stopped. Approval and uncertain effects are handed back
with the run id, even for an unkeyed request. Follow them up or cancel them.

For graphs, `invoke.graph(name, runtime)` accepts
`invoke.request(Nil, initial_state)` and returns the native answer. Retries
compare the stored initial state through `graph.matches_initial(handle, state)`,
not the current state. `graph.await_with(handle, within:, or: selector)` adds
`Reached(status)`/`Interrupted(message)` without changing `graph.await`.

```gleam
// Before
let id = fabric_relay.run_id(definition, principal:, key:)
let found = fabric_relay.run_of(result)
// After
let id = invoke.keyed_id(service, principal, key)
let found = relay_run.run_of(result)
```

Both successful replies, including content-only replies, and failures name the
run in content `_meta` under `io.github.gleam-dream/run-id`.

**Identity migration:** the old bridge joined free-form parts with hyphens;
`("ada-bob", "order")` could alias `("ada", "bob-order")`. Invocation ids now
hash a JSON-framed tuple including the runtime family, service, principal and
key. External action keys now come from `tool.idempotency_key(call)` or
`operation.idempotency_key(invocation)` and frame parts the same way. These
are new mappings. Finish or reconcile pre-upgrade keyed runs and interrupted
remote calls before resubmitting their keys under the new recipe, or retain an
application migration mapping to their original ids/remote keys. No record
shape changed: `fabric.open` and `graph.open` still read old ids. Do not use
principal-less legacy ids as an authentication check.

Name admission is now the fabric-owned `tool.valid_name(name)` Boolean port,
using the same grammar as agent admission. The local recipe only joins ports;
Relay owns output extraction and metadata, and fabric owns run lifecycle.
Dependents: oversight `apps/tool_hub`, including its discovery mode and both
MCP directions, plus the compiled consumer.

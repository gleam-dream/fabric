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

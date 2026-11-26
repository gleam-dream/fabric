# Migrating from Fabric 0.5 to 0.6

Fabric 0.6.0 is a breaking release. Change the dependency to `fabric >= 0.6.0 and < 0.7.0` in `gleam.toml`, then work through the sections below in order. The first one affects every application.

| Change                                                                                                    | Who must act                                                                       |
| --------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| [`agent.build_with` is renamed `agent.build`](#agentbuild_with-is-renamed-agentbuild)                     | Every application that builds an agent                                             |
| [Sibling packages moved to new ranges](#sibling-packages-moved-to-new-ranges)                             | Every application that also depends on llm_wire, http_gun, json_blueprint or sinal |
| [A proof answers one request](#a-proof-answers-one-request)                                               | Applications that answer approvals with `approvers`                                |
| [An unrecognized provider stop fails the model call](#an-unrecognized-provider-stop-fails-the-model-call) | Applications that use `fabric/llm` or `fabric/graph/llm`                           |
| [A graph runner retries its commits](#a-graph-runner-retries-its-commits)                                 | Applications that observe graph runs during store outages                          |
| [The PostgreSQL adapter follows later](#the-postgresql-adapter-follows-later)                             | Applications that use `fabric_postgres`                                            |

New in 0.6.0 and not breaking: `graph.check_approval`, `approvers.Request`, the `fabric/store/projection` module, and `encode_stored` and `inspect_stored` in `fabric/store/discovery`, `fabric/store/retention` and `fabric/store/statistics`.

## `agent.build_with` is renamed `agent.build`

**What changed.** Fabric 0.5.1 had two constructors: `agent.build(spec)`, which took a built spec and was deprecated, and `agent.build_with(builder)`, which took a function that makes the spec. Fabric 0.6 removes the first and gives the second its name. `agent.build` now takes `fn() -> Spec(context, answer)`; its result is unchanged.

**Why.** A built agent sent to each runner and tool task is copied whole, codecs included. Building the agent from its builder in each process is the only path Fabric keeps.

**What to do.** Rename every `agent.build_with` call to `agent.build`. Wrap a spec passed to the old `agent.build` in a function, and move the construction of its tools and codecs inside that function so that the builder does not capture them built:

```gleam
// 0.5
let assert Ok(summarizer) = agent.build_with(fn() { summarizer_spec(model) })
let assert Ok(legacy) = agent.build(summarizer_spec(model))

// 0.6
let assert Ok(summarizer) = agent.build(fn() { summarizer_spec(model) })
let assert Ok(legacy) = agent.build(fn() { summarizer_spec(model) })
```

The rules for what a builder may capture are in the README section [Codecs in tools and answers](https://github.com/gleam-dream/fabric/blob/main/README.md#codecs-in-tools-and-answers).

## Sibling packages moved to new ranges

**What changed.** Fabric 0.6 depends on these ranges:

| Package          | 0.5.1                  | 0.6.0                  | Its migration guide                                                                         |
| ---------------- | ---------------------- | ---------------------- | ------------------------------------------------------------------------------------------- |
| `llm_wire`       | `>= 0.2.0 and < 0.3.0` | `>= 0.3.0 and < 0.4.0` | [llm_wire](https://github.com/gleam-dream/llm_wire/blob/main/docs/MIGRATION.md)             |
| `http_gun`       | `>= 0.2.0 and < 0.3.0` | `>= 0.4.0 and < 0.5.0` | [http_gun](https://github.com/gleam-dream/http_gun/blob/main/docs/MIGRATION.md)             |
| `json_blueprint` | `>= 2.2.0 and < 3.0.0` | `>= 3.0.0 and < 4.0.0` | [json_blueprint](https://github.com/gleam-dream/json_blueprint/blob/main/docs/MIGRATION.md) |
| `sinal`          | `>= 0.1.0 and < 0.2.0` | `>= 0.2.0 and < 0.3.0` | [sinal](https://github.com/gleam-dream/sinal/blob/main/docs/MIGRATION.md)                   |

**Why.** These releases bound every HTTP call and every JSON parse, report provider stops they do not recognize, and bind telemetry handlers to their owner process.

**What to do.** Move the same packages in your `gleam.toml` to these ranges, then follow each package's own guide for the code that calls it directly. A Gleam project resolves one version of each package, so an application that keeps an older range cannot resolve Fabric 0.6. Packages that depend on Sinal 0.1 or an older Fabric-facing range must move too: Saga `>= 0.3.0 and < 0.4.0` ([guide](https://github.com/gleam-dream/saga/blob/main/docs/MIGRATION.md)), Relay `>= 0.3.0 and < 0.4.0` ([guide](https://github.com/gleam-dream/relay/blob/main/docs/MIGRATION.md)) and Hellhound `>= 0.4.0 and < 0.5.0` ([guide](https://github.com/gleam-dream/hellhound/blob/main/docs/MIGRATION.md)), the versions the Saga, Relay and Hellhound recipes in `consumers/` build against. The parts that meet Fabric's own API:

- **The model turn has a second bound.** `fabric/llm.model` sends each request through `llm_wire.run`, whose whole-call timeout (`llm_wire.with_call_timeout`, a `Duration`, 600 s by default) replaces HTTP Gun's 30 s request default. A turn ends at the earlier of that bound and the agent's model timeout (`agent.with_model_timeout`). Set both to the longest generation the agent accepts:

  ```gleam
  // 0.5: http_gun's request timeout ended a slow generation after 30 s.
  // 0.6
  let config = llm_wire.with_call_timeout(config, duration.seconds(120))
  agent.new("writer", llm.model(client, config, model_id), tools, policy)
  |> agent.with_model_timeout(run.After(duration.seconds(120)))
  ```

- **Parse limits.** Tool and answer codecs are json_blueprint 3 codecs. Fabric decodes the model's tool arguments and final answers with json_blueprint's default parse limits (1 MiB, depth 128), so a larger argument or answer fails to decode like any other invalid one. Fabric reads its own stored records without those limits.

## A proof answers one request

**What changed.** A proof from `approvers.check` was bound to a requirement: a proof checked for one run's `"refund"` request could answer another run's `"refund"` request. Fabric 0.6 binds a proof to the exact request it answers: the run, the action or graph activation, and the revision of the request. Consequences:

- `approvers.check(approvers, credential, requirement)` becomes `approvers.check(approvers, credential, reference)`, with the agent request's `run.ApprovalRef`.
- A graph request is checked with the new `graph.check_approval(approvers, credential, reference)`, with the `graph.ApprovalRef` from `AwaitingApproval`.
- The `verify` callback of `approvers.new` receives an `approvers.Request` (`Request(run:, requirement:)`) instead of a `run.Requirement`. A multi-tenant application can check there that the credential may see `run`.
- `approvers.requirement(proof)` becomes `approvers.request(proof)`.
- `ProofError.OtherRequirement(proof, request)` becomes `OtherRequest(proof: Request, request: Request)`.
- A proof checked for an earlier revision of a request, for example before its requirement changed, no longer answers the new revision.

**Why.** An approval must answer the request the reviewer saw, not every request with the same name.

**What to do.**

```gleam
// 0.5
use token, requirement <- approvers.new("tokens")
let scope = "approve:" <> requirement.name
// ...
let assert Ok(proof) =
  approvers.check(approvers, token, pending.reference.requirement)
let assert Ok(proof) = approvers.check(approvers, token, graph_ref.requirement)

// 0.6
use token, request <- approvers.new("tokens")
let scope = "approve:" <> request.requirement.name
// ...
let assert Ok(proof) = approvers.check(approvers, token, pending.reference)
let assert Ok(proof) = graph.check_approval(approvers, token, graph_ref)
```

Check the credential again for each request, right before answering it; do not keep one proof for several requests. A `case` on `ProofError` that names `OtherRequirement` must name `OtherRequest`.

## An unrecognized provider stop fails the model call

**What changed.** llm_wire 0.3 reports a stop reason it does not recognize as `UnrecognizedStop`. Fabric's agent adapter (`fabric/llm`) turns it into a model error of kind `model.InvalidReply`, which ends the turn without retrying it. The graph decision adapter (`fabric/graph/llm`) fails the decision with `tool.Explain`. In 0.5 llm_wire did not report such a stop.

**Why.** An unknown stop says nothing about whether the text is complete, and its tool calls were never admitted. The same request would likely stop the same way.

**What to do.** Nothing, unless the application treats every `InvalidReply` as a schema problem. The error detail names the provider's reason and the size of the discarded text.

## A graph runner retries its commits

**What changed.** A graph runner now commits a transition by the agent runner's rule: it retries a store that reports `Unavailable`, with a bounded backoff of about 0.6 seconds, and reads the record back after a conflict to confirm whether the write was its own. In 0.5 one transient store error stopped the graph run. A start fence whose write lands late is now confirmed as the runner's own write, and its body runs once; in 0.5 the run became `Unattended` and then blocked on an uncertain effect.

**Why.** Both runners now share one commit rule, so a short store outage no longer stops graph runs.

**What to do.** Nothing in code. Tests that simulate an unconfirmed graph commit with a single store fault must inject faults for longer than the retries last.

## The PostgreSQL adapter follows later

**What changed.** The released `fabric_postgres-v0.4.0` requires `fabric >= 0.5.0 and < 0.6.0`. Its next release, which accepts Fabric 0.6, is tagged after Fabric 0.6.0 is published on Hex. That release changes no adapter API and no table: it derives a record's phase from the decoded record (`fabric/store/projection`), and its records stay byte for byte the same.

**What to do.** An application that uses `fabric_postgres` stays on Fabric 0.5 until that tag exists. Then move both together:

```toml
[dependencies]
fabric = ">= 0.6.0 and < 0.7.0"
fabric_postgres = { git = "https://github.com/gleam-dream/fabric.git", ref = "<the new fabric_postgres tag>", path = "integrations/fabric_postgres" }
```

Rename `agent.build_with` and update approval checks as described above. Stored runs need no migration.

## Store changes that need no action

The store process no longer keeps an entry for an ended watch, handles a runner exit or a commit without reading every run, and derives the retention, discovery and statistics projections from one decode of each record (`fabric/store/projection.project`). Record formats, phase tags and the versions of discovery and retention metadata are unchanged. A custom store backend may call `projection.project` instead of decoding a record once per projection.

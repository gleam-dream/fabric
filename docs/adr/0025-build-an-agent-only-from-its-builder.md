# Build an agent only from its builder

<a id="adr-0025"></a>

Accepted by the owner's ruling that the redesign keeps no deprecated
functions or legacy paths and that breaking changes are welcome before the
first stable release. Supersedes the "`agent.build` is deprecated" point and
the compatibility section of [ADR 0023](0023-build-the-agent-in-each-process-from-its-builder.md).

ADR 0023 added `agent.build_with`, which keeps a builder function and builds
the agent in each process that runs it, and kept the old `agent.build`,
which took the spec and returned a built agent copied whole into every
process. The second name existed only because the first was taken. Keeping
both left two ways to make an agent, a runtime branch for an agent with no
builder in every place that hands a setup to another process, and a test
mode that reran part of the core suite on the old path.

## Decision

An agent is made only from its builder, and that function is named
`agent.build`.

- **One constructor.** `agent.build(fn() -> Spec)` checks the spec the
  function makes and returns an `Agent` that keeps the function, or every
  `ConfigError`. The old `agent.build(Spec)` is removed, and
  `agent.build_with` is renamed `agent.build`.
- **One runtime path.** Every runner setup carries the function that makes
  it again in another process. The branch that copied a built-once setup
  whole is removed, and a prepared runner is always told to build its setup
  before its first state.
- **Graphs keep `graph.build(Spec)`.** A graph runtime is still built once
  and copied into each graph runner; a graph builder is still pending.

## Rejected alternatives

- **Keep the name `build_with`.** It reads as "build with options" and
  pairs with nothing once `build` is gone. The plain verb matches
  `graph.build` and the setters' `with_` prefix stays reserved for
  settings.
- **Keep `build(Spec)` as a shorthand for `build(fn() { spec })`.** The
  shorthand captures the spec's tools and codecs, built once, which is the
  copy ADR 0023 removed.

## Compatibility

Breaking. A caller of the old `agent.build(spec)` passes
`agent.build(fn() { spec })`, or better a function that makes the spec. A
caller of `agent.build_with(builder)` calls `agent.build(builder)`.
`fabric_postgres` compiles against the published Fabric 0.5 release and
keeps `agent.build_with` until its requirement moves to the release that
contains this change.

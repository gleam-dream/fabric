# Build the agent in each process from its builder

<a id="adr-0023"></a>

Accepted by the owner's ruling (option A, "maybe we should consider
deprecate the other one unless there is some benefit to keep them"), after a
production deployment of Fabric 0.4.0 ran out of memory.

A run executes in its own runner process, and its tool bodies and model
calls in tasks of that runner. A value sent to another BEAM process is
copied whole. An agent holds every tool with its input and output codecs, its
answer codec, its policy and its sub-agents, and Fabric 0.4.0 copied it into
every run: the runner's start closure went through a helper, the runner
factory and the runner's spawn, the first message carried the run's work,
which held the agent twice, and every tool call copied it into the executor
and again into the tool's task. For an agent of twelve tools with nested
combinator codecs (240.4 kB built), one run with a sub-agent, an approval and
two tool calls copied 3.08 MB into its runners. json_blueprint releases up
to 2.1.0 also multiplied a combinator codec's size per nesting layer; 2.1.1
fixed that, and Fabric now requires it.

## Decision

An agent is made from a builder and built in each process that runs it.

- **The builder.** `agent.build_with` takes a function that makes the
  agent's spec, checks the spec once and returns every problem as `build`
  did. The `Agent` it returns keeps only that function. Each process that
  needs the agent (the caller of `fabric.start`, `open` or `recover`, a
  runner, a sub-agent's runner, the sweeper) builds it there. A runner is
  told how to build its agent, never sent one.
- **A deterministic builder.** The builder must build the same agent every
  time, from small values it captures. A build whose name or version differs
  from the first is refused by crashing the process that built it, before
  that process stores or runs anything. Fabric cannot see what a builder
  captures: one that captures a built codec or tool brings the copy back.
- **`agent.build` is deprecated.** Its built agent is copied whole into
  every process, as before. A snapshot taken once (settings read at boot,
  say) is still possible with the builder, by capturing those values. A
  built-once agent therefore offers nothing the builder lacks.
- **Copies that need no agent change.** Independently of the builder, the
  runner's start closures hold no definition: a runner receives its setup
  once, in its first message, and a graph runner its work. A tool's task
  receives that one tool and its bound, not the agent. Only a tool that
  takes late settlements (`tool.bind_settling`) carries the setup, since
  committing one needs it.

The same run copies 54.5 kB into its runners with a builder. That is the
run's record and each runner's first model request with its tool
declarations; the largest single copy anywhere is 17.6 kB. With the
deprecated `build` and the internal changes alone, it copies 1.06 MB, and its
largest single copy is 317 kB.

## Rejected alternatives

- **`fabric.start_with` beside `start`.** It is explicit at the start site,
  but only starts benefit. `open`, `recover`, `invoke.agent`,
  `sweeper.agent` and graph agent nodes would each need a twin, and a handle
  opened the old way would keep copying.
- **Changing `start` to take a builder.** It breaks every consumer and still
  leaves the other entry points.
- **No new API.** The internal changes alone still copy the built agent once
  per runner start: 250.8 kB for the deployment's internal agent and
  476.7 kB for its curator, against 4.0 kB and 2.6 kB with a builder, built
  in 0.39 ms and 0.12 ms.
- **`persistent_term` or a holder process.** Agents differ per run in
  context and captured values, an update of `persistent_term` triggers a
  global collection, and a long-lived holder would serve every decode
  through one process.

## Compatibility

`agent.build_with` is new. `agent.build` keeps its behavior with a
deprecation warning, which fails a build that treats warnings as errors.
Stored records are unchanged: a run records the agent's name and version as
before, and a run started under a built agent continues under a builder of
the same agent. `fabric_postgres` compiles against the published Fabric
release and keeps `agent.build` until its requirement moves.

Graph runtimes are still built once and copied into each graph runner; a
graph builder is pending.

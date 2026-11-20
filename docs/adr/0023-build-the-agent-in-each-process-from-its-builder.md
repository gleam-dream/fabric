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
  did. The `Agent` it returns keeps only that function and the few settings
  callers read without running it. A process that needs the agent builds
  it there: the caller once per `fabric.start`, `open` or `recover`, each
  runner once (its live commands reuse that build), and a process that
  settles a late result or cancels a child once more. A runner is told how
  to build its agent, never sent one.
- **A deterministic builder.** The builder must build the same agent every
  time, from small values it captures. A build that fails, or whose name or
  version differs from the first, is refused before anything is stored: in
  the caller, and in the runner, which builds the agent before the start
  or command that needs it writes anything. Either way the caller gets
  `fabric.AgentUnbuildable`. Fabric cannot see what a builder captures: one
  that captures a built codec or tool brings the copy back, and `open`,
  `recover` and the sweeper, which check only the name and version, cannot
  tell a builder that captured other values. A per-run capture therefore
  makes a per-run agent that the application must rebuild itself.
- **`agent.build` is deprecated.** Its built agent is copied whole into
  every process, as before. A snapshot taken once (settings read at boot,
  say) is still possible with the builder, by capturing those values. A
  built-once agent therefore offers nothing the builder lacks.
- **Copies that need no agent change.** Independently of the builder, the
  runner's start closures hold no definition: a runner receives its setup
  once, in its first message, and a graph runner its work. A tool's task
  receives that one tool and its bound, not the agent. Only a tool that
  takes late settlements (`tool.bind_settling`) carries the setup, since
  committing one needs it. A live command's step reads the runner's own
  setup. The process that reads a leased parent's children, and the
  watcher of `fabric.cancel_when_down`, hold ids, not the runner or the
  handle.

The same run copies 57.3 kB into its runners with a builder. That is the
run's record and each runner's first model request with its tool
declarations; the largest single copy anywhere is 17.3 kB. With the
deprecated `build` and the internal changes alone, it copies 1.06 MB, and its
largest single copy is 318 kB. On a leased store, a parent whose sub-agent
works read its children every third of the lease from a process that held
the whole runner: 578.7 kB per read for a 196.8 kB agent. Such a run now
copies 60.6 kB in all. A `fabric.Run` handle still holds the agent built
(241.8 kB here), so an application sends a run's id, not its handle.

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
- **Building each tool in its task.** A tool is made inside the agent's
  spec function, so a task could build its own tool only by building the
  whole spec per call. Copying the one tool instead costs its codecs twice
  per call (into the executor, then the task): 11 kB per copy for the
  nested batch codecs of the test agent. The copy is bounded by the size
  test's largest-copy check.
- **`persistent_term` or a holder process.** Agents differ per run in
  context and captured values, an update of `persistent_term` triggers a
  global collection, and a long-lived holder would serve every decode
  through one process.

## Compatibility

`agent.build_with` is new. `agent.build` keeps its behavior with a
deprecation warning, which fails a build that treats warnings as errors;
a representative part of the core suite still runs on it. `fabric.Error`
gains `AgentUnbuildable(detail)`, of kind `Incompatible`: a caller that
matches every variant without a catch-all must add it.
Stored records are unchanged: a run records the agent's name and version as
before, and a run started under a built agent continues under a builder of
the same agent. `fabric_postgres` compiles against the published Fabric
release and keeps `agent.build` until its requirement moves.

Graph runtimes are still built once and copied into each graph runner; a
graph builder is pending.

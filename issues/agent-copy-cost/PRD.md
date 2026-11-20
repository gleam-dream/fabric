# A run copies its agent's builder, never the built agent

Source: a production deployment of Fabric 0.4.0 ran out of memory. Each run
copied the fully built agent (tools with their json_blueprint codecs, policy,
answer codec, sub-agents) across processes several times, and json_blueprint
up to 2.1.0 multiplied a combinator codec's copy size per nesting layer.

## Problem

A run executes in its own runner process, its tool bodies and model calls in
tasks of that runner, and the BEAM copies a value whole into each process it
reaches. Fabric 0.4.0 sent the runner's setup through a helper, the runner
factory and the runner's spawn. Its first message carried work that held the
setup twice. Every tool call copied the setup into the executor and again
into the tool's task. For an agent of twelve tools with nested codecs
(240.4 kB built), a run with a sub-agent, an approval and two tool calls
copied 3.08 MB into its runners. Its largest single copy was 626 kB.

## Outcome

- Every package requires `json_blueprint >= 2.1.1`.
- `agent.build_with(fn() -> Spec)` checks the spec once and returns an agent
  that keeps the builder. Each process that runs the agent builds it there,
  and a rebuild of another name or version is refused. `agent.build` is
  deprecated.
- A runner receives its setup or graph work once, in its first message; a
  tool's task receives only that tool; a command to a live runner makes its
  step there from the builder.
- The same run copies 54.5 kB into its runners with a builder, and 1.06 MB
  with the deprecated `build`. Its largest single copy is 17.6 kB with a
  builder.
- README, `fabric/agent` and `fabric/tool` document what Fabric copies and
  link the json_blueprint codec practice. A compiled example shows codecs
  made inside fields and a run-time enum from the run's own ids.

The rationale is in `docs/adr/0023-build-the-agent-in-each-process-from-its-builder.md`.

## Issues

- `issues/01-build-the-agent-in-each-process.md`: the runtime change, the
  copy-size test, the migration, docs and design layer.
- `issues/02-graph-builder.md`: graph runtimes are still copied into each
  graph runner.
- `issues/03-model-request-copies.md`: a model request is copied three times
  per model call.

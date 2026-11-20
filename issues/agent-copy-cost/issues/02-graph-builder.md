# Build graph runtimes in each graph runner

Status: needs-triage
Category: enhancement

## What

A graph runner now receives its work once, in its first message, but the
runtime is built once by the application and copied whole into every graph
runner, with its operations and codecs, and again into the process of each
bounded callback, whose closure reads the runner's work. An agent node made
with `agent.build_with` keeps its agent as a builder, but
`graph/agent.as_operation` embeds the built answer codec in the operation.
A graph builder like the agent builder (`graph.build_with`) would remove
these copies. The design layer records it as a pending build entry.

## Acceptance

- A copy-size test like `test/fabric/agent_copy_test.gleam` for a graph with
  nested codecs bounds what crosses into its runners.

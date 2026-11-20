# Build graph runtimes in each graph runner

Status: needs-triage
Category: enhancement

## What

A graph runner now receives its work once, in its first message, but the
runtime is built once by the application and copied whole into every graph
runner, with its operations, codecs and agent nodes. An agent node made with
`agent.build_with` is already small. A graph builder like the agent builder
(`graph.build_with`) would remove the remaining copy. The design layer
records it as a pending build entry.

## Acceptance

- A copy-size test like `test/fabric/agent_copy_test.gleam` for a graph with
  nested codecs bounds what crosses into its runners.

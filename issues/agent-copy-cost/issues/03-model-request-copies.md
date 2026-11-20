# A model request is copied three times per model call

Status: needs-triage
Category: enhancement

## What

The runner sends each model request, with every tool declaration's schema,
into the model task. `bounded.call` then copies it twice more, into its
guardian and its worker. For twelve tools that is about 15 kB per copy, so
about 45 kB per model turn. It is not the agent, but it grows with the
agent's tool count. Running the call in the model task under its own timer
would leave one copy.

## Acceptance

- The copy-size test bounds the model task's copies to one request per call.

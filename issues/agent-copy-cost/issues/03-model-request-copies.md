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

The same model turn copies llm_wire's tool list about five times inside
llm_wire
([`issues/hold-tools-once-per-call/issues/01-tools-copied-five-times-per-call.md`](https://github.com/gleam-dream/llm_wire/blob/main/issues/hold-tools-once-per-call/issues/01-tools-copied-five-times-per-call.md),
from gleam-dream/llm_wire#11); the two together describe one turn's path.

## Acceptance

- The copy-size test bounds the model task's copies to one request per call.

# Build the agent in each process from its builder

Status: done
Category: enhancement

## What

Add `agent.build_with`, deprecate `agent.build`, and stop every Fabric path
from copying a built agent between processes: runner start, first message,
tool jobs, live commands, sub-agent runners and child cancellation.

## Acceptance

- `test/fabric/agent_copy_test.gleam` measures `erts_debug:flat_size * 8`
  of everything copied into a run's runners, and of the largest single copy
  anywhere. The agent has nested combinator codecs and a sub-agent, and the
  run makes an approval and two tool calls. The runners together receive
  under a quarter of one agent copy, and no copy reaches a tenth of one.
- A builder that builds another version is refused before anything is
  stored.
- The core suite runs on the builder path: every test agent is made with
  `agent.build_with` (`support.build`), covering records, replay,
  cancellation, recovery and sub-agents.
- Examples, consumers and README snippets use `agent.build_with`;
  `fabric_postgres` keeps `agent.build` while it compiles against the
  published release.
- ADR 0023, the agent-builder term and the agent definition contract record
  the decision.

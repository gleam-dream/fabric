# Build the agent in each process from its builder

Status: done
Category: enhancement

## What

Add `agent.build_with`, deprecate `agent.build`, and stop every Fabric path
from copying a built agent between processes: runner start, first message,
tool jobs, live commands, sub-agent runners and child cancellation.

## Acceptance

- `test/fabric/agent_copy_test.gleam` measures `erts_debug:flat_size` times the word size, in bytes,
  of everything copied into a run's runners, and of the largest single copy
  anywhere. The agent has nested combinator codecs and a sub-agent, and the
  run makes an approval and two tool calls. The runners together receive
  under a third of one agent copy, and no copy reaches a tenth of one. The
  same holds on a leased store with a parent that reads its working child,
  and for `cancel_when_down`'s watcher.
- A builder that fails or builds another version is refused before
  anything is stored, in the caller and in the runner, as
  `fabric.AgentUnbuildable`; `open` and `recover` return it.
- A sub-agent kept as its builder is built once per parent build.
- Representative tests run again on the deprecated `agent.build`
  (`test/fabric/deprecated_build_test.gleam`).
- The core suite runs on the builder path: every test agent is made with
  `agent.build_with` (`support.build`), covering records, replay,
  cancellation, recovery and sub-agents.
- Examples, consumers and README snippets use `agent.build_with`;
  `fabric_postgres` keeps `agent.build` while it compiles against the
  published release.
- ADR 0023, the agent-builder term and the agent definition contract record
  the decision.

## Comments

AI-assisted contribution. Review of gleam-dream/fabric#16 found the leased
child reader copying the whole runner per poll, the owner watcher copying
the handle, a drifting builder refused only after the start was stored, a
sub-agent built three times per parent build, and no tests left on the
deprecated `agent.build`. Each is fixed with a test that failed first; the
acceptance list above includes them.

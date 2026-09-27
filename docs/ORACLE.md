# Fabric oracle ledger

BeamWeaver is a partial behavioural oracle for the agent-loop subset Fabric
migrates. This ledger records the pin, the fixture rules, and the status of
every compared or deliberately divergent behaviour. Source inspection is never
recorded as a passing comparison.

## Pin

| Item         | Value                                                                                                                                        |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Oracle       | BeamWeaver fork `lostbean/beam_weaver`, commit `d0aa1f90d31c55d49be2f7b5a24224b5e18145a1`                                                    |
| Relationship | Upstream `caudena/beam_weaver` tag `v0.1.23` (`60fdcd7`) plus four fork-only durability commits (`3c36caa`, `caaa129`, `9bd7057`, `d0aa1f9`) |
| Pin by       | SHA only. The fork's `mix.exs` still says `0.1.23`, which differs from the Hex 0.1.23 release.                                               |
| Toolchain    | Elixir 1.19.5 on OTP 28.5 (nix store paths recorded in research/beamweaver-oracle.md §1.6), `MIX_ENV=test`                                   |
| License      | Apache-2.0. No NOTICE file. The LICENSE appendix copyright line is the unfilled template.                                                    |
| Local copy   | Read-only fork at `/code/edgar/forks/beam_weaver`; fixtures are produced from a scratch clone, never from the fork itself.                   |

## Categories

- **Faithful port** — Fabric reproduces a BeamWeaver behaviour and a fixture
  or test proves the correspondence.
- **Executed differential** — a fixture captured by running BeamWeaver at the
  pin is compared by a Fabric test over a normalized observable sequence.
- **Inspired test** — an original Fabric test motivated by a BeamWeaver test
  or source; it compares nothing.
- **Original Fabric contract** — behaviour BeamWeaver lacks.
- **Anti-oracle** — a BeamWeaver behaviour Fabric deliberately rejects; the
  Fabric test asserts the opposite.
- **Unverified** — not compared; no claim.

## Fixture provenance rules

1. A fixture is a JSON file under `test/oracle/fixtures/`. It is output of
   running BeamWeaver, not copied source.
2. Every fixture records: oracle repository and commit, toolchain versions,
   the capture script path (committed under `test/oracle/capture/`), the exact
   command, the capture date, and the license note.
3. Capture scripts that transcribe BeamWeaver test scenarios carry the notice
   "Portions derived from BeamWeaver (https://github.com/caudena/beam_weaver,
   Apache-2.0), as of commit 60fdcd7 / fork d0aa1f9."
4. Fixtures hold only normalized observables: transcript roles, tool call ids
   and names, tool message status and content, effect-log entries, outcome
   tags. Message UUIDs, checkpoint ids, run ids, timestamps, provider metadata,
   and literal interrupt ids are removed at capture.
5. Tool execution order inside a concurrent group is compared as a multiset;
   transcript order is compared exactly.
6. A fixture is recaptured, never hand-edited. A changed pin requires a new
   capture and a ledger update.

## Ledger

| Behaviour                                                                                           | Category                                              | Status                                                              | Evidence                                                                    |
| --------------------------------------------------------------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Two tool calls with distinct ids are executed and fed back in call order                            | Executed differential (match)                         | Passing                                                             | `test/oracle/fixtures/two_tool_calls.json`, `test/fabric/oracle_test.gleam` |
| A failing tool and an unknown tool become model-visible errors; the run continues to a final answer | Executed differential (match, error wording excluded) | Passing                                                             | `test/oracle/fixtures/tool_error_visible.json`                              |
| A model-call limit of 2 stops a looping agent                                                       | Executed differential (deliberate divergence)         | Passing; divergence asserted                                        | `test/oracle/fixtures/model_call_limit.json`                                |
| Unknown tool name becomes a model-visible error (`tool_node_test.exs:432`)                          | Inspired test                                         | Fabric test only                                                    | `test/fabric/controller_test.gleam`                                         |
| HITL pause before a tool is data, no process held (`human_in_the_loop_test.exs`)                    | Inspired test                                         | Fabric test only                                                    | `test/fabric/runner_test.gleam`                                             |
| Parallel tools are bounded by a concurrency limit                                                   | Original Fabric contract                              | Fabric test only                                                    | `test/fabric/runner_test.gleam`                                             |
| Cancel during a tool: in-flight uncertain, never retried; terminal `Cancelled`                      | Original Fabric contract                              | Fabric test only                                                    | `test/fabric/runner_test.gleam`                                             |
| Uncertain effect blocks the next model turn until reconciled                                        | Original Fabric contract                              | Fabric test only                                                    | `test/fabric/controller_test.gleam`, `runner_test.gleam`                    |
| Token budget from observed usage; missing usage reported                                            | Original Fabric contract                              | Fabric test only                                                    | `test/fabric/controller_test.gleam`                                         |
| Foreign and duplicate reports rejected                                                              | Original Fabric contract                              | Fabric test only                                                    | `test/fabric/controller_test.gleam`                                         |
| Crash mid-tool re-runs the tool on recovery (B5); a raising tool becomes a model-visible error      | Anti-oracle                                           | Slice 1 records a crash after the fence as uncertain, never retried | `test/fabric/runner_test.gleam`; restart is slice 2                         |
| Stale, duplicate, unknown-thread resume accepted (B2)                                               | Anti-oracle                                           | Slice 2                                                             | —                                                                           |
| Concurrent double resume executes twice (B3)                                                        | Anti-oracle                                           | Slice 2                                                             | —                                                                           |
| Invalid resume burns the pending interrupt (B4)                                                     | Anti-oracle                                           | Slice 2                                                             | —                                                                           |
| Child sub-agent interrupt stringified and dropped (B1)                                              | Anti-oracle                                           | Slice 2                                                             | —                                                                           |
| Durable pause survives VM restart and executes once (A13)                                           | Executed differential                                 | Unverified (slice 2)                                                | —                                                                           |
| HITL approve / reject / edit / respond decisions (A1–A7)                                            | Executed differential                                 | Unverified (slice 2)                                                | —                                                                           |
| Run, step and node timeouts (A19)                                                                   | Unverified                                            | No Fabric timeout yet                                               | —                                                                           |

## Slice 1 results

Captured 2026-09-27 at `d0aa1f90d31c55d49be2f7b5a24224b5e18145a1` (Elixir
1.19.5, OTP 28) by `test/oracle/capture/capture.exs`, run from the scratch
clone with the default `~/.mix` (its Hex archive; overriding `MIX_HOME` makes
`mix` prompt for Hex and hang):

```sh
cd <scratch>/fork_clone   # git clone --no-local of the fork, at the pin
PATH=/nix/store/5fbjxaaizi26pmghbyn09llww48qg01q-elixir-1.19.5/bin:/nix/store/cyr4xsis8csd0sjvmy6lxaw9214f1sjf-erlang-28.5/bin:$PATH \
  MIX_ENV=test FIXTURE_DIR=<fabric>/test/oracle/fixtures \
  mix run --no-compile <fabric>/test/oracle/capture/capture.exs < /dev/null
```

Each fixture carries its provenance fields (`oracle`, `script`, `command`,
`captured`, `license`); the Fabric test refuses a fixture from another commit.
`test/fabric/oracle_test.gleam` runs the same scenario rules through Fabric
with a transcript-pure model and compares normalized observables.

| Fixture              | Compared                                                                                                 | Result                                                                                                                                                                                                                                                                                                                                                                                         |
| -------------------- | -------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `two_tool_calls`     | Full transcript (ids, order, success contents, final text), tool effects as a multiset, model-call count | Equal.                                                                                                                                                                                                                                                                                                                                                                                         |
| `tool_error_visible` | Transcript without the final answer, tool statuses, success contents, effects, model-call count          | Equal. Error wording differs by package (`Tool error: ...` versus `{"error": ...}`) and is not compared. In BeamWeaver the failing tool returned `{:error, reason}`; in Fabric it is a typed error bound with `bind_reporting` and `Explain`.                                                                                                                                                  |
| `model_call_limit`   | Model-call count, first four transcript entries, then the divergence                                     | Deliberate divergence, asserted. Both call the model twice. BeamWeaver checks its limit before the third model call, so the tool requested by the second reply runs (`tool:step:2`) and the run ends with a limit message. Fabric does not start a tool whose result could not reach the model within the limit: `step 2` stays `NotStarted` and the run ends `BudgetExhausted(TurnLimit(2))`. |

Not claimed: parity for error wording, BeamWeaver's `recursion_limit`
(super-steps, not model turns), or a raising tool, which BeamWeaver turns into
a model-visible error and Fabric records as an uncertain effect (anti-oracle
B5 row above).

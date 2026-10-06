# Fabric oracle ledger

BeamWeaver is a partial behavioural oracle for the agent-loop subset Fabric
migrates. This ledger records the pin, the fixture rules, and the retained checks for
compared or deliberately divergent behaviour. Source inspection is never
recorded as a passing comparison.

## Pin

| Item         | Value                                                                                                                                        |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Oracle       | BeamWeaver fork `lostbean/beam_weaver`, commit `d0aa1f90d31c55d49be2f7b5a24224b5e18145a1`                                                    |
| Relationship | Upstream `caudena/beam_weaver` tag `v0.1.23` (`60fdcd7`) plus four fork-only durability commits (`3c36caa`, `caaa129`, `9bd7057`, `d0aa1f9`) |
| Pin by       | SHA only. The fork's `mix.exs` still says `0.1.23`, which differs from the Hex 0.1.23 release.                                               |
| Toolchain    | Elixir 1.19.5 on OTP 28.5 (historical execution provenance in ADR 0011), `MIX_ENV=test`                                                      |
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

| Behaviour                                                                                                            | Category                                                  | Status                                                                                                                                                                                                                                                   | Evidence                                                                                                                                                                                                                                               |
| -------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Two tool calls with distinct ids are executed and fed back in call order                                             | Executed differential (match)                             | Compared by the retained test                                                                                                                                                                                                                            | `test/oracle/fixtures/two_tool_calls.json`, `test/fabric/oracle_test.gleam`                                                                                                                                                                            |
| A failing tool and an unknown tool become model-visible errors; the run continues to a final answer                  | Executed differential (match, error wording excluded)     | Compared by the retained test                                                                                                                                                                                                                            | `test/oracle/fixtures/tool_error_visible.json`                                                                                                                                                                                                         |
| A model-call limit of 2 stops a looping agent                                                                        | Executed differential (deliberate divergence)             | The retained comparison asserts the divergence                                                                                                                                                                                                           | `test/oracle/fixtures/model_call_limit.json`                                                                                                                                                                                                           |
| Unknown tool name becomes a model-visible error (`tool_node_test.exs:432`)                                           | Inspired test                                             | Fabric test only                                                                                                                                                                                                                                         | `test/fabric/controller_test.gleam`                                                                                                                                                                                                                    |
| HITL pause before a tool is data, no process held (`human_in_the_loop_test.exs`)                                     | Inspired test                                             | Fabric test only                                                                                                                                                                                                                                         | `test/fabric/runner_test.gleam`                                                                                                                                                                                                                        |
| Parallel tools are bounded by a concurrency limit                                                                    | Original Fabric contract                                  | Fabric test only                                                                                                                                                                                                                                         | `test/fabric/runner_test.gleam`                                                                                                                                                                                                                        |
| Cancel during a tool: in-flight uncertain, never retried; terminal `Cancelled`                                       | Original Fabric contract                                  | Fabric test only                                                                                                                                                                                                                                         | `test/fabric/runner_test.gleam`                                                                                                                                                                                                                        |
| Uncertain effect blocks the next model turn until reconciled                                                         | Original Fabric contract                                  | Fabric test only                                                                                                                                                                                                                                         | `test/fabric/controller_test.gleam`, `runner_test.gleam`                                                                                                                                                                                               |
| Token budget from observed usage; missing usage reported                                                             | Original Fabric contract                                  | Fabric test only                                                                                                                                                                                                                                         | `test/fabric/controller_test.gleam`                                                                                                                                                                                                                    |
| Foreign and duplicate reports rejected                                                                               | Original Fabric contract                                  | Fabric test only                                                                                                                                                                                                                                         | `test/fabric/controller_test.gleam`                                                                                                                                                                                                                    |
| Crash mid-tool re-runs the tool on recovery, or wedges the thread (B5); a raising tool becomes a model-visible error | Anti-oracle                                               | Covered by retained assertions. A crash after the fence, a killed runner, and a restart with every process killed all record the running tool as uncertain, never retried; `await` reports `Unattended` instead of waiting                               | `test/fabric/runner_test.gleam`, `durable_test.gleam` (`a_killed_runner_is_reported_and_its_run_recovered_test`, `an_effect_whose_result_was_never_committed_is_uncertain_test`, `restart_keeps_results_and_takes_over_running_and_queued_tools_test`) |
| Stale, duplicate, unknown-thread resume accepted (B2)                                                                | Anti-oracle                                               | Covered by retained assertions. Wrong reference, stale revision or requirement, already answered, and run ended are distinct refusals; an unknown run is `RunNotFound`                                                                                   | `test/fabric/approval_test.gleam` (`refused_answers_are_distinct_and_keep_the_pause_test`), `durable_test.gleam` (`recovery_reports_a_run_that_does_not_exist_test`)                                                                                   |
| Concurrent double resume executes twice (B3)                                                                         | Anti-oracle                                               | Covered by retained assertions. Eight concurrent answers: one wins, seven get `AlreadyAnswered`, the tool runs once                                                                                                                                      | `approval_test.gleam` (`concurrent_answers_have_one_winner_and_the_tool_runs_once_test`)                                                                                                                                                               |
| Invalid resume burns the pending interrupt (B4)                                                                      | Anti-oracle                                               | Covered by retained assertions. Every refused answer leaves the pending request unchanged and answerable                                                                                                                                                 | `approval_test.gleam` (`refused_answers_are_distinct_and_keep_the_pause_test`)                                                                                                                                                                         |
| Child sub-agent interrupt stringified and dropped (B1)                                                               | Anti-oracle                                               | Covered by retained assertions. A child's pending approval is the parent's pending approval (its reference names the child run); the parent waits, answering through the parent resumes the child, and the child's completion is the delegation's result | `test/fabric/delegation_test.gleam` (`a_child_pause_surfaces_to_the_parent_and_is_answered_through_it_test`), `consumers/app` (`an_acquisition_needs_the_committee_then_the_treasurer_test`)                                                           |
| Sub-agent start gated by review (`interrupt_on: %{"task" => true}`): approve runs the child once (S1)                | Executed differential (match)                             | Compared by the retained test                                                                                                                                                                                                                            | `test/oracle/fixtures/subagent_gate_approve.json`, `oracle_test.gleam` (`an_approved_sub_agent_start_matches_beamweaver_test`)                                                                                                                         |
| Sub-agent start rejected: the child never runs (S2)                                                                  | Executed differential (match, rejection wording excluded) | Compared by the retained test                                                                                                                                                                                                                            | `test/oracle/fixtures/subagent_gate_reject.json`, `oracle_test.gleam` (`a_rejected_sub_agent_start_matches_beamweaver_test`)                                                                                                                           |
| Durable pause survives the loss of every process and executes once (A13; BeamWeaver side: a VM restart)              | Executed differential (match)                             | Compared by the retained test                                                                                                                                                                                                                            | `test/oracle/fixtures/hitl_cold_restart.json`, `oracle_test.gleam`                                                                                                                                                                                     |
| HITL approve executes the reviewed call once (A1)                                                                    | Executed differential (match)                             | Compared by the retained test                                                                                                                                                                                                                            | `test/oracle/fixtures/hitl_approve.json`                                                                                                                                                                                                               |
| HITL reject answers the call with an error and never runs the tool (A3, reject)                                      | Executed differential (match, rejection wording excluded) | Compared by the retained test                                                                                                                                                                                                                            | `test/oracle/fixtures/hitl_reject.json`                                                                                                                                                                                                                |
| HITL edit and respond decisions; decision-count mismatch (A2, A3 respond, A4–A7)                                     | Unverified                                                | Fabric has no edit or respond answer; answers are per request, so a count mismatch cannot occur                                                                                                                                                          | —                                                                                                                                                                                                                                                      |
| Run, step and node timeouts (A19)                                                                                    | Unverified                                                | Per-call bounds and durable wait deadlines are implemented; whole-agent elapsed time remains unbuilt. No executed upstream timeout differential is claimed                                                                                               | —                                                                                                                                                                                                                                                      |

## Running and recapture

The package tests compare the committed normalized fixtures with Fabric:

```sh
nix develop --command gleam test
```

For recapture, prepare and compile a disposable clone at the exact oracle pin
in an appropriate Nix shell containing the recorded Elixir/OTP toolchain.
Use the committed capture script from that clone:

```sh
MIX_ENV=test FIXTURE_DIR=/path/to/fabric/test/oracle/fixtures \
  mix run --no-compile /path/to/fabric/test/oracle/capture/capture.exs < /dev/null
```

The paths are placeholders. The script's recorded command and toolchain metadata
must agree with the actual run before replacement fixtures are accepted. Old Nix
store paths are historical provenance, not portable setup instructions. Review
the resulting fixtures and rerun the comparisons; never repair a mismatch by
hand-editing an expected observable.

The cold-restart capture starts separate VMs over temporary SQLite storage and a
file-backed effect log. Its preload step is necessary for the pinned oracle's
existing-atom checkpoint decoder. Fabric's matching scenario has its own store
and process lifecycle; equality of normalized observables does not make their
storage guarantees identical.

## Comparison limits

- Concurrent tool effects compare as a multiset; transcript order remains exact.
- Error/rejection wording and final text that embeds that wording are excluded
  where the native protocols differ. Whole interrupt payloads, provider metadata
  and native identifiers are not an application authorization contract.
- The model-call-limit fixture deliberately differs: Fabric refuses a tool whose
  result could not reach another model turn. The upstream fixture's final tool
  effect is not a behavior Fabric promises to reproduce.
- Approval fixtures cover approve, reject and process-loss recovery. Edit/respond
  answers and a complete timeout differential remain outside their evidence.
- Sub-agent start fixtures do not establish every interrupted-child behavior.
  Fabric-specific tests cover the rejected upstream hazards and managed ownership.
- The evaluation-only agent-as-graph comparisons exercise supported ordinary
  round trips. They do not prove approval, delegation or interrupted-batch
  equivalence to the retained agent controller.

[ADR 0011](adr/0011-limit-oracle-evidence-and-reject-upstream-hazards.md)
records the capture history, measured correspondence and upstream hazards.
[ADR 0002](adr/0002-retain-agent-controller-and-managed-composition.md)
records the controller counterexample. The [native design](design/design.typ)
owns current Fabric behavior and retained intended scope.

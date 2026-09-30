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

| Behaviour                                                                                                            | Category                                                  | Status                                                                                                                                                                                                                             | Evidence                                                                                                                                                                                                                                               |
| -------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Two tool calls with distinct ids are executed and fed back in call order                                             | Executed differential (match)                             | Passing                                                                                                                                                                                                                            | `test/oracle/fixtures/two_tool_calls.json`, `test/fabric/oracle_test.gleam`                                                                                                                                                                            |
| A failing tool and an unknown tool become model-visible errors; the run continues to a final answer                  | Executed differential (match, error wording excluded)     | Passing                                                                                                                                                                                                                            | `test/oracle/fixtures/tool_error_visible.json`                                                                                                                                                                                                         |
| A model-call limit of 2 stops a looping agent                                                                        | Executed differential (deliberate divergence)             | Passing; divergence asserted                                                                                                                                                                                                       | `test/oracle/fixtures/model_call_limit.json`                                                                                                                                                                                                           |
| Unknown tool name becomes a model-visible error (`tool_node_test.exs:432`)                                           | Inspired test                                             | Fabric test only                                                                                                                                                                                                                   | `test/fabric/controller_test.gleam`                                                                                                                                                                                                                    |
| HITL pause before a tool is data, no process held (`human_in_the_loop_test.exs`)                                     | Inspired test                                             | Fabric test only                                                                                                                                                                                                                   | `test/fabric/runner_test.gleam`                                                                                                                                                                                                                        |
| Parallel tools are bounded by a concurrency limit                                                                    | Original Fabric contract                                  | Fabric test only                                                                                                                                                                                                                   | `test/fabric/runner_test.gleam`                                                                                                                                                                                                                        |
| Cancel during a tool: in-flight uncertain, never retried; terminal `Cancelled`                                       | Original Fabric contract                                  | Fabric test only                                                                                                                                                                                                                   | `test/fabric/runner_test.gleam`                                                                                                                                                                                                                        |
| Uncertain effect blocks the next model turn until reconciled                                                         | Original Fabric contract                                  | Fabric test only                                                                                                                                                                                                                   | `test/fabric/controller_test.gleam`, `runner_test.gleam`                                                                                                                                                                                               |
| Token budget from observed usage; missing usage reported                                                             | Original Fabric contract                                  | Fabric test only                                                                                                                                                                                                                   | `test/fabric/controller_test.gleam`                                                                                                                                                                                                                    |
| Foreign and duplicate reports rejected                                                                               | Original Fabric contract                                  | Fabric test only                                                                                                                                                                                                                   | `test/fabric/controller_test.gleam`                                                                                                                                                                                                                    |
| Crash mid-tool re-runs the tool on recovery, or wedges the thread (B5); a raising tool becomes a model-visible error | Anti-oracle                                               | Executed. A crash after the fence, a killed runner, and a restart with every process killed all record the running tool as uncertain, never retried; `await` reports `Unattended` instead of waiting                               | `test/fabric/runner_test.gleam`, `durable_test.gleam` (`a_killed_runner_is_reported_and_its_run_recovered_test`, `an_effect_whose_result_was_never_committed_is_uncertain_test`, `restart_keeps_results_and_takes_over_running_and_queued_tools_test`) |
| Stale, duplicate, unknown-thread resume accepted (B2)                                                                | Anti-oracle                                               | Executed. Wrong reference, stale revision or requirement, already answered, and run ended are distinct refusals; an unknown run is `RunNotFound`                                                                                   | `test/fabric/approval_test.gleam` (`refused_answers_are_distinct_and_keep_the_pause_test`), `durable_test.gleam` (`recovery_reports_a_run_that_does_not_exist_test`)                                                                                   |
| Concurrent double resume executes twice (B3)                                                                         | Anti-oracle                                               | Executed. Eight concurrent answers: one wins, seven get `AlreadyAnswered`, the tool runs once                                                                                                                                      | `approval_test.gleam` (`concurrent_answers_have_one_winner_and_the_tool_runs_once_test`)                                                                                                                                                               |
| Invalid resume burns the pending interrupt (B4)                                                                      | Anti-oracle                                               | Executed. Every refused answer leaves the pending request unchanged and answerable                                                                                                                                                 | `approval_test.gleam` (`refused_answers_are_distinct_and_keep_the_pause_test`)                                                                                                                                                                         |
| Child sub-agent interrupt stringified and dropped (B1)                                                               | Anti-oracle                                               | Executed. A child's pending approval is the parent's pending approval (its reference names the child run); the parent waits, answering through the parent resumes the child, and the child's completion is the delegation's result | `test/fabric/delegation_test.gleam` (`a_child_pause_surfaces_to_the_parent_and_is_answered_through_it_test`), `consumers/app` (`an_acquisition_needs_the_committee_then_the_treasurer_test`)                                                           |
| Sub-agent start gated by review (`interrupt_on: %{"task" => true}`): approve runs the child once (S1)                | Executed differential (match)                             | Passing                                                                                                                                                                                                                            | `test/oracle/fixtures/subagent_gate_approve.json`, `oracle_test.gleam` (`an_approved_sub_agent_start_matches_beamweaver_test`)                                                                                                                         |
| Sub-agent start rejected: the child never runs (S2)                                                                  | Executed differential (match, rejection wording excluded) | Passing                                                                                                                                                                                                                            | `test/oracle/fixtures/subagent_gate_reject.json`, `oracle_test.gleam` (`a_rejected_sub_agent_start_matches_beamweaver_test`)                                                                                                                           |
| Durable pause survives the loss of every process and executes once (A13; BeamWeaver side: a VM restart)              | Executed differential (match)                             | Passing                                                                                                                                                                                                                            | `test/oracle/fixtures/hitl_cold_restart.json`, `oracle_test.gleam`                                                                                                                                                                                     |
| HITL approve executes the reviewed call once (A1)                                                                    | Executed differential (match)                             | Passing                                                                                                                                                                                                                            | `test/oracle/fixtures/hitl_approve.json`                                                                                                                                                                                                               |
| HITL reject answers the call with an error and never runs the tool (A3, reject)                                      | Executed differential (match, rejection wording excluded) | Passing                                                                                                                                                                                                                            | `test/oracle/fixtures/hitl_reject.json`                                                                                                                                                                                                                |
| HITL edit and respond decisions; decision-count mismatch (A2, A3 respond, A4–A7)                                     | Unverified                                                | Fabric has no edit or respond answer; answers are per request, so a count mismatch cannot occur                                                                                                                                    | —                                                                                                                                                                                                                                                      |
| Run, step and node timeouts (A19)                                                                                    | Unverified                                                | No Fabric timeout yet                                                                                                                                                                                                              | —                                                                                                                                                                                                                                                      |

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
| `tool_error_visible` | Transcript without the final answer, tool statuses, success contents, effects, model-call count          | Equal. Error wording differs by package (`Tool error: ...` versus `{"error": ...}`) and is not compared. In BeamWeaver the failing tool returned `{:error, reason}`; in Fabric it is a typed error that `bind`'s classifier maps to `Explain`.                                                                                                                                                 |
| `model_call_limit`   | Model-call count, first four transcript entries, then the divergence                                     | Deliberate divergence, asserted. Both call the model twice. BeamWeaver checks its limit before the third model call, so the tool requested by the second reply runs (`tool:step:2`) and the run ends with a limit message. Fabric does not start a tool whose result could not reach the model within the limit: `step 2` stays `NotStarted` and the run ends `BudgetExhausted(TurnLimit(2))`. |

Not claimed: parity for error wording, BeamWeaver's `recursion_limit`
(super-steps, not model turns), or a raising tool, which BeamWeaver turns into
a model-visible error and Fabric records as an uncertain effect (anti-oracle
B5 row above).

## Slice 2a results

Recaptured 2026-09-27 at the same pin with the same command. Every fixture
now records that exact command in its `command` field (`<scratch clone>` is
the clone and `<fabric>` the Fabric repository root); the three slice 1
fixtures changed only in that field. The script adds three HITL scenarios over
a transcript-pure model that requests `pay` (`call_t`, `{"to":"bob"}`), with
`interrupt_on: %{"pay" => true}`. Each fixture holds the paused step (the
calls under review, the snapshot transcript, and the effects before the
pause; the literal interrupt id is reduced to whether it matches the
snapshot's) and the resumed step.

`hitl_cold_restart` runs two further `mix run` VMs of the same script, one
after the other, over a temporary SQLite database through the fork's Ecto
checkpointer and a file-backed effect log. Each VM loads every
`:beam_weaver` module first; without that a fresh VM cannot read the
checkpoint (`String.to_existing_atom` in the JSON decoder).

| Fixture             | Compared                                                                                                    | Result                                                                                                                                                                                                                                                                                                              |
| ------------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `hitl_approve`      | At the pause: calls under review, transcript, effects. After approve: full transcript, effects, model calls | Equal. `pay` runs once, after the answer.                                                                                                                                                                                                                                                                           |
| `hitl_reject`       | At the pause as above. After reject: transcript without the final answer, tool status, effects              | Equal. Both answer the call with an error result and never run `pay`. BeamWeaver sends the reviewer's message as the tool content with status `error`; Fabric sends `{"error":"rejected","detail":...}` and records the action `Rejected`. Wording is not compared, so the final answer that embeds it is excluded. |
| `hitl_cold_restart` | As `hitl_approve`, with every process lost between the pause and the answer                                 | Equal. BeamWeaver exits a VM between two SQLite-backed VMs; Fabric kills every process over a directory store and calls `recover`. `pay` runs once across the restart. Fabric's recovery of a suspended run does not take it over (incarnation stays 1).                                                            |

Deliberate differences: a Fabric approval is a policy decision with a
requirement and revision, answered per request with `fabric.approve`
(checked again against the policy at answer time) or `fabric.reject`;
BeamWeaver answers a whole interrupt with a list of decisions. Fabric has no `edit` or `respond`
answer. Not claimed: the interrupt payload (`description`, `review_configs`,
`nodes`, `timing`), which is BeamWeaver-specific.

## Slice 2b results

Recaptured 2026-09-28 at the same pin with the same command (the whole
script; every earlier fixture reproduced its observables, and only the
capture date and the order of two concurrent tool effects, compared as a
multiset, changed). The script adds two scenarios over a transcript-pure
model shared by a parent and its sub-agent, told apart by their first user
message: the parent calls the `task` tool (`subagent_type` `researcher`,
description `Paris`) under `interrupt_on: %{"task" => true}`; the child
(`Subagent.Spec`, inheriting the parent's model) calls `lookup` and
answers.

| Fixture                 | Compared                                                                                                       | Result                                                                                                                                                                                                                                                       |
| ----------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `subagent_gate_approve` | At the pause: the call under review, the parent transcript, effects. After approve: parent transcript, effects | Equal. At the pause only the parent's model has run. After approve the child's model runs twice and its `lookup` once, and the child's final text is the `task` result. Fabric's delegation returns the child's text as a JSON string, compared by its text. |
| `subagent_gate_reject`  | At the pause as above. After reject: parent transcript without the final answer, tool status, effects          | Equal. The child never runs (no child model call, no `lookup`). Wording is not compared.                                                                                                                                                                     |

Deliberate differences: a Fabric delegation is declared per sub-agent
(`agent.with_sub_agent`, one typed definition and one child agent) rather
than one `task` tool selecting a `subagent_type`; the gate is the policy's
decision on `policy.StartAgent`, not middleware keyed by tool name; the
child is its own durable run in the store rather than a run inside the
parent's tool worker. Anti-oracle B1 (BeamWeaver stringifies a child's
interrupt into the `task` result and the parent completes, probe S3 in
research/beamweaver-oracle.md) is not captured as a fixture; Fabric's test
asserts the opposite behaviour.

## Agent-recipe evaluation, 2026-09-30

Two additional tests execute the evaluation-only model-turn/tool-batch graph
against `two_tool_calls`, `tool_error_visible` and `model_call_limit`, using the
same normalizer and exclusions above. Supported round trips match; the last
case retains Fabric's deliberate turn-limit divergence. These tests do not
recapture BeamWeaver or extend parity to approval, delegation or interrupted
batches. The eight existing ordinary-runtime comparisons remain unchanged.
The [evaluation report](implementation/graph-flow/agent-recipe-evaluation.md)
records the lifecycle counterexample and decision to retain ordinary agents as
managed graph children. Ten oracle tests pass at this checkpoint.

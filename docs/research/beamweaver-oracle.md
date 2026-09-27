> Research evidence produced 2026-09-27 by read-only inspection and execution of sibling repositories and BeamWeaver; the scratchpad paths it references (`/private/tmp/claude-501/...`, `$SP/...`) were ephemeral and may no longer exist.

# BeamWeaver as a behavioural oracle for Fabric

Research date: 2026-09-27. Researcher mode: read-only. No file in
`/code/edgar/forks/beam_weaver` or `/code/gleam-dream/fabric` was modified; no remote was
added to the fork. All clones, worktrees, probes and logs live under the session scratchpad:
`/private/tmp/claude-501/-code-gleam-dream-fabric/9e7d32e8-ff23-46ee-93b7-9e29dc013d14/scratchpad/`
(abbreviated `$SP` below).

Evidence levels used throughout:

- **[ran]** observed by executing code in this session (upstream ExUnit suites or my probe scripts).
- **[src]** read in source, with file:line; not executed.
- **[inferred]** follows from source reading, no test or probe exercised it.
- **[unverified]** not traced.

Source inspection is not a passing comparison. Only the rows marked [ran] are executed evidence,
and even those are executions of BeamWeaver alone; no Fabric code exists to compare against yet.

Paths without a prefix are relative to the fork root `/code/edgar/forks/beam_weaver` at
`d0aa1f90d31c55d49be2f7b5a24224b5e18145a1`.

---

## 0. Key conclusions

1. **Pin `d0aa1f90d31c55d49be2f7b5a24224b5e18145a1`** (fork `lostbean/beam_weaver`, branches
   `integrate/smith-runtime` = `fix/durable-native-joins`). It is upstream tag `v0.1.23`
   (`60fdcd7`) plus four fork-only durability fixes. For every non-durable behaviour I probed,
   fork, `v0.1.23` and upstream head `v0.1.29` produced byte-identical probe output [ran]. The
   fork differs exactly where Fabric's top priorities live: restart-safe checkpoint identity,
   atomic checkpoint+write boundaries, and cold replay [ran, src].
2. **The fork adds no human-in-the-loop, policy-gate or sub-agent escalation code.** The four
   fork commits touch only graph execution and checkpoint persistence. "Checkpoint before a
   tool call / before starting a sub-agent" is an upstream capability: `interrupt_on` on the
   `HumanInTheLoop` middleware, where the sub-agent start is the tool call named `"task"`.
3. **Durable pause before a tool call works and survives a VM restart.** Pause before sub-agent
   start also works, via `interrupt_on: %{"task" => ...}`. The mechanism is an `after_model`
   graph node that throws a graph interrupt. The interrupt is persisted as an `"__interrupt__"`
   pending write on the thread's checkpoint. Resume is a new caller-owned run that re-executes
   that node with the resume value [ran on ETS and on SQLite across separate VMs].
4. **Several behaviours are hazards that Fabric should not copy**, all [ran]:
   - A HITL interrupt raised inside a sync sub-agent never reaches the parent. It becomes the tool
     result string `"Subagent interrupted: ..."`, and the parent run completes. This contradicts
     `docs/human_in_the_loop.md` ("Subagent Interrupts").
   - A stale or duplicate resume is not rejected. It starts a new run from START. A scalar resume
     value on a thread with no pending interrupt is fed to the next interrupt the run reaches.
   - Two concurrent resumes of one paused thread both execute the approved tool.
   - A resume that fails validation consumes the pending interrupt. The next valid resume
     re-pauses, and only a third call completes.
   - Sending new input to a paused thread re-raises the same interrupt, so the pause cannot be
     "cancelled" by new input.
   - After a hard kill during a tool call, a plain `invoke(%{})` or `resume(nil)` on the thread
     starts a new turn. It fails with `:invalid_chat_history` and moves the head checkpoint so
     the thread is wedged. Only `invoke(%{}, config: <explicit checkpoint_id>)` recovers, and it
     re-runs the tool (at-least-once).
   - A fresh VM using lazy code loading (`mix run`) cannot decode an agent checkpoint.
     `"atom is not loaded in the current VM"` goes away after pre-loading the beam_weaver modules.
5. **Cancellation is not a first-class concept on the agent/graph path.** There is no cancel API,
   no cancelled status, and no cooperative signal to nodes or tools. The means that exist:
   - `Task.shutdown` of an `async_invoke` handle;
   - killing the caller;
   - node, step and run timeouts (`:brutal_kill`);
   - live-stream consumer halt.

   Each leaves the last committed checkpoint and loses the in-flight step. A cooperative
   cancel-then-kill protocol exists only on the separate low-level `BeamWeaver.Runtime.Agent`
   GenServer, which the agent graph does not use.

6. **Executing upstream is feasible here.** Elixir 1.19.5 / OTP 28.5 from the nix store compiles
   in about 20 s. Full suites ran in 30–40 s:

   | Revision  | Tests | Failures | Excluded |
   | --------- | ----- | -------- | -------- |
   | fork      | 2240  | 0        | 66       |
   | `v0.1.23` | 2187  | 0        | 66       |
   | `v0.1.29` | 2275  | 0        | 72       |

   The excluded tests are the postgres and docker tags. SQLite-backed cold-restart tests ran.
   Deterministic scripted-model scenarios can be exported as JSON fixtures by a scratch
   `mix run` script. The probe scripts in `$SP/probes/` are working prototypes of this.

---

## 1. Part 1: oracle revision

### 1.1 Repositories and relationship [ran]

| Item              | Value                                                                                                                                                                                                                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Local fork        | `/code/edgar/forks/beam_weaver`, checked out on branch `integrate/smith-runtime`, HEAD `d0aa1f90d31c55d49be2f7b5a24224b5e18145a1`, working tree clean, **no local tags**                                                                                                                           |
| Fork remote       | `origin git@github.com:lostbean/beam_weaver.git`. Local tracking refs show `origin/integrate/smith-runtime` = `origin/fix/durable-native-joins` = `d0aa1f9`, and `origin/master` = `60fdcd7`. I did not fetch from GitHub, so these refs reflect the last fetch on this machine [unverified live]. |
| Upstream          | `https://github.com/caudena/beam_weaver`, cloned to `$SP/beam_weaver_upstream`. `master` = `3b04989` (2026-09-23), tags `v0.1.0` … `v0.1.29`.                                                                                                                                                      |
| Merge base        | `60fdcd73a37a291319ef659b899f6242508c3ca2` = **tag `v0.1.23`**, "deepseek + fixes (#27)", 2026-09-10.                                                                                                                                                                                              |
| Fork-only commits | 4 (below), all by lostbean, 2026-09-12.                                                                                                                                                                                                                                                            |
| Upstream ahead    | 6 commits = tags `v0.1.24` (`0a32db6`), `v0.1.25` (`9d0b554`), `v0.1.26` (`be54662`), `v0.1.27` (`f65e31b`), `v0.1.28` (`6b3a038`), `v0.1.29` (`3b04989`).                                                                                                                                         |
| Hex               | `mix hex.info beam_weaver` lists releases 0.1.22 … 0.1.29. 0.1.23 was published 2026-09-10 and corresponds to tag `v0.1.23`.                                                                                                                                                                       |
| Version ambiguity | The fork's `mix.exs` still says `version: "0.1.23"` (`mix.exs:7`), and its root contains a locally built `beam_weaver-0.1.23.tar` dated Sep 12 18:49, between `9bd7057` and `d0aa1f9`. Both "0.1.23" artifacts differ from the hex 0.1.23 release, so **pin by SHA, never by version string**.     |

The fork's other branches are prefixes of the same linear stack:

| Branch                               | Commit                           |
| ------------------------------------ | -------------------------------- |
| `fix/durable-execution-boundaries`   | `3c36caa`                        |
| `fix/durable-task-replay`            | `caaa129`                        |
| `fix/globally-unique-checkpoint-ids` | `9bd7057`                        |
| `fix/durable-native-joins`           | `d0aa1f9`                        |
| `master`                             | `60fdcd7` (= upstream `v0.1.23`) |

### 1.2 Fork-only changes (intent and files) [src, tests ran]

| Commit                                                                       | Intent                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Main files                                                                                                                                    | Added tests                                                                                                                                                |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `3c36caa` fix: commit graph checkpoint boundaries atomically                 | Adds the optional saver callback `put_checkpoint_with_writes/7` (`lib/beam_weaver/checkpoint/saver.ex:36-65`). Only Ecto implements it; it commits one checkpoint and its full pending-write set in one transaction. Graph execution uses it for ordinary and halted (error or interrupt) boundaries (`lib/beam_weaver/graph/execution/checkpoint_io.ex:147-172, 314-340`). On error the outcome is unknown and the runtime does not retry. ETS deliberately does not advertise the callback and keeps the legacy non-atomic `put`/`put_writes`. | `checkpoint.ex`, `checkpoint/ecto.ex`, `checkpoint/saver.ex`, `graph/execution/checkpoint_io.ex`, `step_transition.ex`, `docs/persistence.md` | `test/beam_weaver/checkpoint/ecto_atomic_boundary_test.exs` (7), `test/beam_weaver/graph/atomic_checkpoint_boundary_test.exs` (19 at HEAD)                 |
| `caaa129` fix(graph): preserve durable task outcomes and occurrence identity | Adds a private versioned `ExecutionEnvelope` in raw checkpoints (`graph/execution/execution_envelope.ex`). It records completed-sibling identity, frontier order and outgoing Send/routing work, so a cold restart does not re-run completed siblings. Old in-flight checkpoints are refused with `:unsupported_checkpoint_format`; malformed ones with `:corrupt_execution_checkpoint`.                                                                                                                                                         | 20+ files under `graph/execution/*`                                                                                                           | `test/beam_weaver/graph/cold_replay_test.exs` (6, spawn separate `mix run` VMs), fixtures `test/fixtures/durable_replay/{cold,interrupt,matrix}_worker.ex` |
| `9bd7057` fix(checkpoint): preserve identities across VM restarts            | Generated checkpoint ids change from a per-VM `System.unique_integer` counter (which repeats after restart) to UUIDv7.                                                                                                                                                                                                                                                                                                                                                                                                                           | `checkpoint/utils.ex`, `checkpoint/ecto/config.ex`                                                                                            | `test/beam_weaver/checkpoint/ecto_checkpoint_identity_test.exs` (3)                                                                                        |
| `d0aa1f9` fix(graph): preserve durable native join membership                | `NamedBarrierValue` persists partial join membership and validates it on restore (`graph/channels/named_barrier_value.ex:48-66`). Same-step arrivals after a consumed join count for the next cycle.                                                                                                                                                                                                                                                                                                                                             | `graph/channels/named_barrier_value.ex`, `channel_merge.ex`, `run_init.ex`, `snapshot.ex`                                                     | `cold_native_join_test.exs` (4), `native_join_checkpoint_test.exs` (2), `state_graph_test.exs:196`                                                         |

None of the four commits touches `agent/`, `runtime/`, middleware, HITL, sub-agents or policy code.
The pieces that could look like fork additions are all upstream (`git log` authors "Nate"):

- `BeamWeaver.DispatchHook` (`lib/beam_weaver/dispatch_hook.ex`)
- `Subagent.Host` (`lib/beam_weaver/agent/subagent/host.ex`, commit `a40b620`)
- `Checkpoint.ResumeDelivery` (`lib/beam_weaver/checkpoint/resume_delivery.ex`, commit `31863b7`)

### 1.3 What upstream added after v0.1.23 [src]

`git diff --stat v0.1.23 v0.1.29` touches 121 files, and none of them is under
`lib/beam_weaver/graph`, `lib/beam_weaver/checkpoint` or `lib/beam_weaver/runtime`. Content:

- Provider refreshes: OpenAI GPT-6 and Anthropic Opus 5.5 profiles, request builders, Google
  streaming.
- The TypeSafe decision model and `TypeSafeModelRouter` middleware.
- A structured-output validation fix.
- Prompt-cache key length.
- Memory docs.
- A **breaking** tool-input change in 0.1.27: `use BeamWeaver.Tool` schema defaults now arrive
  under string keys.

For graph, checkpoint and agent-loop behaviour, the fork is therefore the more advanced line.
The probe diffs in §4 confirm identical agent/HITL behaviour on ETS across all three revisions.

### 1.4 Recommendation

- **Primary oracle pin: `d0aa1f90d31c55d49be2f7b5a24224b5e18145a1`.**
  - It contains `v0.1.23` exactly, so upstream history remains the attribution anchor.
  - It fixes the restart-identity bug. On `v0.1.23` and `v0.1.29` I observed checkpoint id
    `00000000000000000004` generated again in a fresh VM, after which the persisted head did not
    reflect the returned result [ran, §4.3].
  - It gives atomic halted boundaries on Ecto, which Fabric's "durable pause" and "resume after
    restart" cases depend on.
- **Keep the pin reproducible.** The fork commit exists only on the user's GitHub fork. The
  harness should reference `git@github.com:lostbean/beam_weaver.git@d0aa1f9…`, or vendor a
  `git bundle`, because a force-push on `integrate/smith-runtime` would lose it.
- **Secondary reference: `v0.1.29` (`3b04989`)**, only for provider wire adapters (OpenAI and
  Anthropic request/response shapes) if Fabric ports adapters newer than September 10. Do not use
  it for durability cases.
- **Not a pin: `9194f02`.** It is an Oversight design baseline, not a BeamWeaver commit.

### 1.5 License and notice obligations [src]

- `LICENSE` is Apache-2.0, and `mix.exs:361` declares `licenses: ["Apache-2.0"]`.
- The appendix copyright line is the unfilled template `Copyright [yyyy] [name of copyright owner]`.
- There is **no NOTICE file** in the fork or upstream, so no NOTICE text needs propagating.
- If Fabric copies or translates BeamWeaver source, tests, fixtures or docs, Apache-2.0 §4
  requires:
  - shipping a copy of the license;
  - prominent notices in modified or ported files stating they were changed;
  - retaining copyright and attribution notices.
- Suggested attribution: "Portions derived from BeamWeaver (https://github.com/caudena/beam_weaver,
  Apache-2.0), as of commit 60fdcd7 / fork d0aa1f9."
- Fixtures produced by running BeamWeaver, such as recorded transcripts, are outputs rather than
  copied code. Scenario scripts that transcribe BeamWeaver tests are derivative works and should
  carry the notice.
- Fabric's CLAUDE.md already names BeamWeaver as the ported work. This is an engineering reading,
  not legal advice.

### 1.6 Toolchain and exact commands [ran]

- **Default PATH is too old.** `which elixir mix erl` resolves to `/etc/profiles/per-user/edgar/bin/*`,
  which is Elixir 1.18.4 on OTP 27. The project requires `elixir: "~> 1.19"` (`mix.exs:13`), and
  CI uses 1.19.5 on OTP 28.4 (`.github/workflows`).
- **Nix store toolchain:** `/nix/store/5fbjxaaizi26pmghbyn09llww48qg01q-elixir-1.19.5` (OTP 28,
  erts 16.4) and `/nix/store/cyr4xsis8csd0sjvmy6lxaw9214f1sjf-erlang-28.5`.
- These store paths are not GC roots. A harness should pin them through a flake devShell, for
  example `elixir_1_19` + `erlang_28` from a pinned nixpkgs [nix-shell variant not tested].
- `~/.mix/archives/hex-2.5.1` exists, so no Hex credentials are needed. Public
  `mix deps.get` worked for `v0.1.29`, which needed `exqlite 0.41.0` and `mint 1.10.1`.

```sh
export PATH=/nix/store/cyr4xsis8csd0sjvmy6lxaw9214f1sjf-erlang-28.5/bin:/nix/store/5fbjxaaizi26pmghbyn09llww48qg01q-elixir-1.19.5/bin:$PATH
git clone --no-local /code/edgar/forks/beam_weaver $SP/fork_clone
cd $SP/fork_clone && git checkout d0aa1f90d31c55d49be2f7b5a24224b5e18145a1
cp -R /code/edgar/forks/beam_weaver/deps ./deps     # or: MIX_ENV=test mix deps.get (public hex)
MIX_ENV=test mix compile                            # ~19 s incl. deps
MIX_ENV=test mix test                               # 2240 tests, 0 failures, 66 excluded, ~37 s
MIX_ENV=test mix test test/beam_weaver/agent/human_in_the_loop_test.exs
MIX_ENV=test mix test test/beam_weaver/graph/cold_replay_test.exs   # shells out to `mix run` VMs; needs mix on PATH
# Postgres-tagged tests (not run here): BEAM_WEAVER_POSTGRES_URL=... MIX_ENV=test mix test --include postgres
# Probe / fixture export (scratch scripts, no repo change):
PROBE_LOG=$SP/probes/x.log MIX_ENV=test mix run --no-compile $SP/probes/probe_ets.exs
PRELOAD=1 PROBE_LOG=... MIX_ENV=test mix run --no-compile $SP/probes/probe_cold.exs -- produce $DB
```

Upstream tags were run from scratch worktrees, `$SP/wt_v0.1.23` (2187 tests, 0 failures) and
`$SP/wt_v0.1.29` (2275 tests, 0 failures, after public `deps.get`). Logs:

- `$SP/fork_test_full.log`
- `$SP/v0123_test.log`
- `$SP/v0129_test.log`

---

## 2. Part 2: capability inventory

Legend for the Fit column:

- **REQ**: serves an actual Fabric-relevant requirement (durable pause, approval, cancellation,
  budget, correlation, observability).
- **SCOPE**: consequence of BeamWeaver's LangChain/LangGraph/DeepAgents-compatibility breadth.

### 2.1 Summary table

| #   | Capability                               | Public behaviour (short)                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Source / tests                                                                                                                                                                                                           | Runtime owner and lifecycle                                                                                                                                                                                                                                                                                                                                                                                                            | Fit                                                                    |
| --- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| 1   | Agent loop / turn                        | `Agent.invoke/stream_events/resume/get_state` → `{:ok, state} \| {:interrupted, i} \| {:error, e}`. The agent compiles to a graph: `before_agent*` → `before_model*` → `model` → `after_model*` (reverse order) → `tools` → loop, then `after_agent*`.                                                                                                                                                                                                                                            | `agent/runner.ex:25-160`, `agent/compiler.ex:26-105, 286-384`, `agent/compiler/routing.ex:6-157`; tests `test/beam_weaver/agent/dsl_test.exs:201-244`, `dsl_behavior_test.exs:861`                                       | The **caller process** runs the loop (`graph/execution/runner.ex:1-3, 98-109`). Each super-step's nodes run in `Task.async` tasks linked to the caller, or `Task.Supervisor.async_nolink` if the caller passes `task_supervisor:` (`graph/execution/task_launcher.ex:6-15`). There is no BeamWeaver-owned run process; `Agent.Server` is a thin GenServer wrapper (`agent/server.ex:10-30`). Only checkpointed state survives a crash. | REQ core (DSL breadth is SCOPE)                                        |
| 2   | Tool definition / dispatch / parallelism | `Tool.from_function!` / `use BeamWeaver.Tool`. The ToolNode executes the pending calls of the last AI message. Consecutive `concurrent?` tools run in one `Task.async_stream` (`ordered: true`, `on_timeout: :kill_task`, default `max_concurrency` = schedulers). Non-concurrent tools are barriers. Output order equals call order.                                                                                                                                                             | `graph/nodes/tool_node/execution.ex:17-112`, `input.ex:104-126`; tests `test/beam_weaver/graph/tool_node_test.exs:1036, 1063, 1088, 1144`                                                                                | Tool workers are children of the `tools` node task. The whole tools node is one graph task, so its writes commit at the step boundary. **There is no per-tool-call durability**: a crash mid-node re-runs every call of that turn [ran §4.2 S7, §4.3].                                                                                                                                                                                 | REQ                                                                    |
| 3   | Concurrency limits                       | No explicit limit knob. Only the `async_stream` default (`System.schedulers_online()`) applies [src, subagent survey].                                                                                                                                                                                                                                                                                                                                                                            | `tool_node/execution.ex:63-100`                                                                                                                                                                                          | n/a                                                                                                                                                                                                                                                                                                                                                                                                                                    | REQ gap                                                                |
| 4   | Tool-call id correlation                 | Pending calls are matched by `call_id \|\| tool_call_id \|\| id` against later `:tool` messages. HITL preserves ids on edit, reject and respond. Nil ids are not generated by default, and one nil-id answer satisfies all nil-id calls [inferred]. Duplicate ids are not deduplicated [inferred].                                                                                                                                                                                                | `tool_node/input.ex:112-168`, `routing.ex:102-157`, `human_in_the_loop.ex:289-341`; `tool_call_normalization.ex:47-106` (opt-in id fill)                                                                                 | State lives in `messages` in the checkpoint                                                                                                                                                                                                                                                                                                                                                                                            | REQ                                                                    |
| 5   | Errors vs tool failures                  | Tool errors (unknown tool, invalid args, raise, exit, timeout) become error `ToolMessage`s (`status: "error"`) by default (`handle_errors: true`). With `handle_errors: false`, or for non-tool node errors, the run returns `{:error, e}` and successful sibling writes persist as pending writes.                                                                                                                                                                                               | `tool_node/execution.ex:145-182, 323-339, 384-396`; tests `tool_node_test.exs:432, 567, 1010, 1017`; `compiled_test.exs:1014`                                                                                            | Pending writes live in the checkpointer                                                                                                                                                                                                                                                                                                                                                                                                | REQ                                                                    |
| 6   | HITL interrupts (before tool)            | `interrupt_on` → `HumanInTheLoop.after_model` batches matching calls (`interrupt_mode :all \| :first`) into one `Graph.interrupt(%{action_requests, review_configs})`. Resume takes `%{decisions: [...]}`, one decision per action, in order: `approve \| edit \| reject \| respond`.                                                                                                                                                                                                             | `agent/middleware/human_in_the_loop.ex:74-244`; tests `test/beam_weaver/agent/human_in_the_loop_test.exs` (11 tests, §5)                                                                                                 | The pause is **data in the checkpointer**: an `"__interrupt__"` pending write plus the checkpoint. No process lives while paused. See §3.                                                                                                                                                                                                                                                                                              | REQ                                                                    |
| 7   | HITL before sub-agent                    | Same middleware with key `"task"` (the sub-agent tool). Other admission seams are `wrap_tool_call` (deny/rewrite, cannot pause) and `Subagent.Host.admit_child` (deny, cannot pause).                                                                                                                                                                                                                                                                                                             | `agent/middleware/subagents.ex:266-307`; `agent/subagent/host.ex:85-107`; probe S1/S2 [ran]. No upstream test covers `"task"`.                                                                                           | as #6                                                                                                                                                                                                                                                                                                                                                                                                                                  | REQ                                                                    |
| 8   | Multiple pending interrupts              | Parallel nodes that interrupt in one super-step require a resume map keyed by interrupt id or task id. A single pending interrupt accepts a scalar, or any map whose keys match no pending id.                                                                                                                                                                                                                                                                                                    | `graph/execution/resume.ex:8-113`; tests `pregel_behavior_test.exs:1009` ("parallel interrupts require map resume and resume by interrupt id"), `:1063` (sequential interrupts)                                          | as #6                                                                                                                                                                                                                                                                                                                                                                                                                                  | REQ                                                                    |
| 9   | Static breakpoints                       | `interrupt_before:` / `interrupt_after:` on node names at compile time                                                                                                                                                                                                                                                                                                                                                                                                                            | `step_transition.ex:23-40, 174-180`; test `compiled_test.exs:1575`                                                                                                                                                       | as #6                                                                                                                                                                                                                                                                                                                                                                                                                                  | SCOPE (debug)                                                          |
| 10  | Durable checkpointing: saver API         | `Checkpoint.Saver` behaviour (`checkpoint/saver.ex:25-83`), required and optional callbacks below this table.                                                                                                                                                                                                                                                                                                                                                                                     | `checkpoint.ex`; tests `test/beam_weaver/checkpoint/conformance_test.exs`                                                                                                                                                | Adapter struct passed by value                                                                                                                                                                                                                                                                                                                                                                                                         | REQ (API breadth partly SCOPE)                                         |
| 11  | ETS saver                                | Three ETS tables created by `ETS.new/1` (`checkpoint/ets.ex:33-41`), owned by the **creating process** and deleted with it. No atomic callback. No version or conflict check on `put`.                                                                                                                                                                                                                                                                                                            | `checkpoint/ets.ex`                                                                                                                                                                                                      | Dies with its owner process; never survives restart                                                                                                                                                                                                                                                                                                                                                                                    | REQ for tests only                                                     |
| 12  | Ecto saver (PostgreSQL / SQLite)         | Transactional `put` under a per-(thread, ns) owner lock: `pg_advisory_xact_lock` on PG, **no lock on SQLite** (`checkpoint/ecto/query.ex:75-96`). Monotonic `commit_order`. `on_conflict: {:replace, [:checkpoint, :metadata]}` on the id (`checkpoint/ecto.ex:115-180`). Atomic `put_checkpoint_with_writes` (fork).                                                                                                                                                                             | `checkpoint/ecto.ex`; tests `ecto_test.exs`, `ecto_atomic_boundary_test.exs`, `ecto_checkpoint_identity_test.exs`                                                                                                        | Durable DB rows. Tables come from app migrations (`BeamWeaver.Migrations`).                                                                                                                                                                                                                                                                                                                                                            | REQ (Ecto coupling is SCOPE for a Gleam port)                          |
| 13  | Versions / revisions / conflicts         | Channel versions are integers via `next_version` (`saver.ex:85-105`), with `versions_seen` per node. **No optimistic concurrency on ordinary puts**: the parent id is the configured `checkpoint_id` or the latest one. The only compare-and-set is `continue_staged` (`:checkpoint_conflict` if the source is not the latest, `checkpoint/ecto.ex:250-291`).                                                                                                                                     | as above                                                                                                                                                                                                                 |                                                                                                                                                                                                                                                                                                                                                                                                                                        | REQ gap                                                                |
| 14  | Resume delivery                          | Ordinary path: `Compiled.resume/3` → `Runner.execute` with `resume:` → `Resume.normalize` maps the value to the task id of the pending interrupt → the interrupted node re-runs and `Graph.interrupt/1` returns the value. Separate strict primitive: `Checkpoint.stage_resume/3` + `continue_staged/2` (idempotent, receipt-hashed, Ecto only, **not wired into graph execution**).                                                                                                              | `graph/compiled/runtime.ex:93-106`; `graph/execution/resume.ex`; `graph/execution/scratchpad.ex:82-127`; `checkpoint.ex:280-345`, `checkpoint/resume_delivery.ex`; tests `ecto_test.exs:270`, `conformance_test.exs:988` | Caller process                                                                                                                                                                                                                                                                                                                                                                                                                         | REQ; the strict delivery is closest to a Fabric requirement but unused |
| 15  | Cancellation                             | Agent/graph: none as an API. Available means are `Core.Async.cancel/2` = `Task.shutdown` (`core/async.ex:57-62`), killing the caller (linked tasks die), node/step/run timeouts (`Task.shutdown(:brutal_kill)`, `graph/execution/task_awaiter.ex:23-55`), and live-stream halt (`stream/mux.ex:190-199`). Low-level `Runtime.Agent`: `cancel/2` → cooperative `{:beam_weaver_cancel, ...}` message → kill after `cancel_grace_ms` → `:cancel_timeout` failure (`runtime/agent/server.ex:62-123`). | tests `compiled_test.exs:429, 1498`; `runtime_surface_test.exs:788`; `runtime/agent_server_test.exs:77, 161, 187`; `stream/mux_test.exs:130`                                                                             | See §3.4                                                                                                                                                                                                                                                                                                                                                                                                                               | REQ (partially served)                                                 |
| 16  | Budgets / limits                         | Budget mechanisms listed below this table.                                                                                                                                                                                                                                                                                                                                                                                                                                                        | `graph/execution/runner.ex:100-101`, `run_options.ex:53`; `agent/middleware/{model_call_limit,tool_call_limit}.ex`; tests `compiled_test.exs:699`, `middleware_builtin_test.exs:1088, 1308-1404, 1556-1745`              | Run counters are untracked; thread counters are checkpointed                                                                                                                                                                                                                                                                                                                                                                           | REQ (no token/cost/time-per-thread budget)                             |
| 17  | Sub-agents (sync)                        | The model calls tool `"task"` with `{subagent_type, description}`. The child is a prebuilt agent run synchronously **inside the parent's tool worker** via `Runner.invoke`. It shares `thread_id` with checkpoint namespace `parent_ns\|tools:<task_id>\|subagent.<name>:<tool_call_id>`. Child `interrupt_on` inherits the parent's unless the spec overrides it (`nil` and `false` both inherit).                                                                                               | `agent/middleware/subagents.ex:266-307, 380, 640-668, 746-753, 1201-1209, 1364-1407`; tests `deep_agents_test.exs:1662, 2297, 2343`; `subagent_host_test.exs:35, 47, 74`                                                 | The child lives only while the parent tool worker lives. There is no independent supervision and no cancel except tool timeout. **Child interrupts are dropped** [ran S3].                                                                                                                                                                                                                                                             | REQ (linkage and correlation); DeepAgents features are SCOPE           |
| 18  | Sub-agents (async)                       | Tools `start_async_task`, `check_async_task`, `update_async_task`, `cancel_async_task` and `list_async_tasks` talk to a **remote** Agent Protocol server (`ReqClient`). The `async_tasks` channel caches task ids and status. `client: nil` runs nothing.                                                                                                                                                                                                                                         | `agent/middleware/async_subagents.ex:52-314`, `agent/protocol/req_client.ex:7-23`; tests `agent/middleware/async_subagents_test.exs:83, 139`; `req_client_test.exs:33`                                                   | Owned by the remote server; BeamWeaver keeps only a checkpointed record                                                                                                                                                                                                                                                                                                                                                                | SCOPE (LangGraph Platform compat)                                      |
| 19  | Middleware / hooks                       | Callbacks: `before_agent`, `before_model`, `after_model`, `after_agent` (graph nodes), `wrap_model_call`, `wrap_tool_call` (wrappers). Results can be `nil \| map \| {:jump, :model\|:tools\|:end, map} \| Command \| {:error, e}`. Node hooks can call `Graph.interrupt`. `wrap_tool_call` runs in tool workers where the scratchpad is absent and every throw is caught, so it **can deny or rewrite but not pause**.                                                                           | `agent/middleware.ex:17-51`, `agent/middleware/hooks.ex:23-68`, `tool_node/execution.ex:131-221`; tests `agent/middleware_framework_test.exs:222, 282`, `graph/tool_node_test.exs:455, 480`                              | In the graph node task                                                                                                                                                                                                                                                                                                                                                                                                                 | REQ (the external policy-gate seam)                                    |
| 20  | DispatchHook                             | `before_dispatch/3` returns `:ok` or `{:error, reason}` before each model or tool attempt, and is policy-neutral. **Only called from `Runtime.ToolRunner`** (`runtime/tool_runner.ex:38-58`), i.e. only on `Runtime.Agent.start_*_call`, not on the agent graph path (grep over `lib/`).                                                                                                                                                                                                          | `dispatch_hook.ex:1-40`; test `runtime/agent_server_test.exs:247`                                                                                                                                                        | `Runtime.Agent.Server` (temporary GenServer)                                                                                                                                                                                                                                                                                                                                                                                           | REQ-shaped but disconnected                                            |
| 21  | Event streaming                          | `stream_events` returns envelopes `%Stream.Envelope{event, run_id, graph, node, task_id, step, namespace, metadata, timestamp}`. Tool events carry `tool_call_id`. There are no sequence numbers or parent-run field. Non-live mode returns a list, and `{:interrupted, i}` carries `i.events`. Live mode uses `Stream.Mux` with bounded buffer and overflow policy.                                                                                                                              | `stream/events.ex:1-197`, `graph/compiled/runtime.ex:74-203`, `stream/mux.ex`; tests `human_in_the_loop_test.exs:536`, `compiled_test.exs:1519, 1545`, `stream/mux_test.exs`                                             | Caller-owned `Stream.resource`, producer tasks                                                                                                                                                                                                                                                                                                                                                                                         | REQ (observability); projections are SCOPE                             |
| 22  | Tracing / telemetry                      | Run tree (`Tracing.Store` Agent, UUIDv7 ids, process-dictionary context). Telemetry `[:beam_weaver, :graph, :start\|:stop\|:interrupt\|:exception\|:node_*\|:*_timeout\|:node_cancel]`, `[:beam_weaver, :checkpoint, op]`, and others.                                                                                                                                                                                                                                                            | `tracing.ex`, `tracing/store.ex`, `graph/execution/runner.ex:41-95`, `task_awaiter.ex`; tests `test/beam_weaver/tracing/*`                                                                                               | Global supervised processes under `BeamWeaver.Tracing.Supervisor`. The store is unbounded [inferred].                                                                                                                                                                                                                                                                                                                                  | REQ (correlation) with SCOPE (WeaveScope export)                       |
| 23  | Graph runtime                            | Pregel super-steps. Channels: `LastValue` (rejects more than one write per step), `BinaryOperatorAggregate` reducers, `Topic`, `Ephemeral`, `Untracked`, `DeltaChannel`. Also `Send` fan-out, `Command{goto, update, resume, graph: :parent}`, joins via `NamedBarrierValue` (`add_join`), a node cache, retry and error handlers. `defer:` is metadata only. `failure_policy` has no reader [src, subagent survey].                                                                              | `graph/execution/*`, `graph/channels/*`, `graph/state_graph.ex:177-202`; tests `pregel_behavior_test.exs`, `compiled_test.exs`, `state_graph_test.exs`, `channel_merge_test.exs`                                         | Caller-owned `Run` struct; tasks per node                                                                                                                                                                                                                                                                                                                                                                                              | Core loop REQ; channel zoo, Send, cache, DeltaChannel mostly SCOPE     |
| 24  | Context compaction / summarization       | Four mechanisms, listed below this table.                                                                                                                                                                                                                                                                                                                                                                                                                                                         | tests `compaction_test.exs`, `middleware_builtin_test.exs:1763-2237`, `deep_agents_test.exs:755-997`                                                                                                                     | Pure or middleware; the summary is persisted via state                                                                                                                                                                                                                                                                                                                                                                                 | (a) REQ-adjacent; (b)–(d) SCOPE                                        |
| 25  | Structured output                        | Tool or provider strategy, auto-selected from the model profile. `StructuredOutputRetry` middleware.                                                                                                                                                                                                                                                                                                                                                                                              | `agent/structured_output*.ex`; tests `structured_output_retry_test.exs`, `structured_output_strategy_test.exs`                                                                                                           | —                                                                                                                                                                                                                                                                                                                                                                                                                                      | SCOPE                                                                  |
| 26  | Provider adapters                        | Anthropic Messages, OpenAI Responses and Chat Completions, Google, and OpenAI-compatible providers (DeepSeek, xAI, Z.ai, Moonshot). Shared SSE parser (`provider/sse.ex`, drops undecodable frames). Offline tests via `Transport.Replay` + VCR YAML cassettes, `test/fixtures/provider_conformance/<provider>/*.json` (43, no Anthropic dir), and `support/conformance/fakes.exs` Transport.                                                                                                     | `lib/beam_weaver/{anthropic,open_ai,google,provider}/*`; `test/beam_weaver/provider_conformance/provider_conformance_test.exs`                                                                                           | Finch pool under `Transport.Supervisor`                                                                                                                                                                                                                                                                                                                                                                                                | REQ for wire adapters in Fabric                                        |
| 27  | Retrieval / vector / loaders             | vector_store (ETS, Ecto), retriever, loaders, splitters, indexing                                                                                                                                                                                                                                                                                                                                                                                                                                 | `docs/retrieval.md`                                                                                                                                                                                                      | —                                                                                                                                                                                                                                                                                                                                                                                                                                      | SCOPE; exclude                                                         |
| 28  | Application tree                         | `ProcessRegistry`, `Runtime.AgentSupervisor` (`Task.Supervisor` + `DynamicSupervisor` for `Runtime.Agent.Server`), `Transport.Supervisor` (Finch), `Tracing.Supervisor`, `RateLimiter.Supervisor`; `:one_for_one`                                                                                                                                                                                                                                                                                 | `application.ex:7-18`, `runtime/agent_supervisor.ex:10-18`                                                                                                                                                               | Nothing in this tree owns agent runs or paused flows                                                                                                                                                                                                                                                                                                                                                                                   | —                                                                      |

Details that did not fit in the table:

- **Saver callbacks (#10).**
  - Required: `get_tuple`, `list`, `put`, `put_writes`, `delete_thread`, `delete_for_runs`,
    `copy_thread`, `prune`, `next_version`, `get_delta_channel_history`.
  - Optional: `fetch_tuple`, `list_result`, `put_checkpoint_with_writes/7` (fork), `put_many`,
    `continue_staged`, `fork_at`.
  - Tuples carry `config`, `checkpoint`, `metadata`, `parent_config`, `pending_writes`
    `{task_id, channel, value}`, plus paths.
- **Budget mechanisms (#16).**
  - `recursion_limit` counts super-steps, default 25 (agents with capabilities and sub-agents use
    9999). Exceeding it is a hard `:recursion_limit` error.
  - `remaining_steps` produces a soft apology reply.
  - `ModelCallLimit` (thread limit is checkpointed, run limit is untracked;
    `exit_behavior :error | :end`).
  - `ToolCallLimit` (`:continue | :error | :end`).
  - Timeouts: node default 5 000 ms, agent tools node `:infinity` unless `tool_timeout` is set,
    plus `step_timeout` and `run_timeout`.
  - **No token or cost budget enforcement.** `Agent.Usage` only accounts, and `ContextBudget`
    only triggers compaction.
- **Compaction mechanisms (#24).**
  - (a) `BeamWeaver.Compaction`: a pure engine returning immutable checkpoints; the app persists
    them.
  - (b) `Summarization` middleware in `before_model`, which writes `Overwrite(messages)`.
  - (c) `CompactConversation`, a tool that offloads history to the filesystem backend.
  - (d) `ContextEditing` and `OverflowRecovery`.
  - All are deterministic with a stub model.

### 2.2 Notes on the scripted-model pattern (needed for oracle fixtures)

- `BeamWeaver.Models.FakeChatModel` is **stateless**: `responses: [...]` always returns the first
  element (`lib/beam_weaver/models/fake_chat_model.ex:114-122`). It cannot script multiple turns.
- Upstream tests define inline `@behaviour BeamWeaver.Core.ChatModel` modules with only
  `invoke/3`, whose reply is a pure function of the message list (e.g. `ReviewModel` in
  `test/beam_weaver/agent/human_in_the_loop_test.exs:15-40`, `ToolCallingModel` in
  `test/beam_weaver/agent/dsl_test.exs:26-53`), or an ETS counter
  (`structured_output_retry_test.exs:13-27`).
- **For fixtures, prefer transcript-pure scripted models.** A resume re-runs only the interrupted
  node, and the model node is not re-invoked for committed steps, so a pure transcript→reply
  function stays deterministic across replay and restart. `$SP/probes/common.exs`
  (`Probe.ScriptedModel`) follows this pattern.

---

## 3. Top priorities: pause, persist, resume, cancel (precise mechanics)

### 3.1 How BeamWeaver pauses before a tool call [src + ran]

1. The model node appends an AI message with `tool_calls`. This is committed as a normal
   super-step checkpoint.
2. The next node is `human_in_the_loop.after_model`, a graph node generated from the middleware
   hook (`agent/compiler.ex:307-324`). Its task runs with a per-task scratchpad in the process
   dictionary (`graph/execution/scratchpad.ex:1-70`).
3. `HumanInTheLoop.after_model/3` (`human_in_the_loop.ex:74-93`) looks up each call name in
   `interrupt_on`, evaluates `:when` / `:predicate` (arity 1–3), builds `action_requests` and
   `review_configs` (`:116-186`), and calls `Graph.interrupt(request)` (`:98-114`).
4. `Scratchpad.interrupt/1` (`scratchpad.ex:82-119`) finds no resume value. It creates
   `%Interrupt{id: "interrupt_" <> sha256(task_id, node, step, counter), value, task_id, node,
step, resumes: consumed}` and `throw`s `{:beam_weaver_graph_interrupt, interrupt}`, which
   `NodeInvoker` catches.
5. Interrupt ids are deterministic. The same graph name, node and step give the same id across
   different threads (probe: `interrupt_0f444dad…` on threads s1, s2, s5, s6). Correlation
   therefore needs the pair `(thread_id, interrupt_id)` [ran].
6. `HumanInTheLoop.requires_checkpointer?/1` returns `true` (`:71-72`). Without a checkpointer
   the run fails up front with `:missing_checkpointer` (test `human_in_the_loop_test.exs:481`).

**Before a sub-agent start** the mechanism is identical, because the sub-agent is started by the
tool call named `"task"` (`subagents.ex:266-307`). Probe S1 [ran]: with
`interrupt_on: %{"task" => true}`, invoke returns `{:interrupted, …}` with
`action_requests: [{"task", %{"subagent_type" => "worker", "description" => "child work"}}]`,
and the child model is **not** called. On approve, the child runs, including its own tools, and
its result becomes the `task` tool message. On reject (S2), the child never runs, and the parent
sees an error tool message carrying the rejection text.

### 3.2 How the pause is persisted [src + ran]

- The halted step writes the `"__interrupt__"` channel as a pending write keyed by task id and
  path (`graph/execution/task_write.ex:31-39`). Successful sibling writes of the same super-step
  are persisted alongside it.
- **Fork + Ecto path.** `CheckpointIO.maybe_write_halted_boundary/2`
  (`checkpoint_io.ex:147-172`) builds an `ExecutionEnvelope` (frontier, completed siblings,
  write references). It commits **one new checkpoint and all its pending writes atomically** via
  `put_checkpoint_with_writes/7` (`:314-340`). The interrupt's `config` is the committed
  successor config, which is what the cold worker saves as its receipt
  (`test/fixtures/durable_replay/interrupt_worker.ex`).
- **ETS path, or `v0.1.23` / `v0.1.29`.** `persist_pending_writes/2` (`checkpoint_io.ex:175-199`)
  issues non-atomic `put_writes` against the current checkpoint.
- Pending interrupts are later discovered by scanning the latest tuple's pending writes for
  channel `"__interrupt__"` (`graph/execution/replay.ex:177-196`). `get_state` exposes them as
  `snapshot.interrupts`, with `snapshot.next == ["human_in_the_loop.after_model"]` [ran].
- **No process holds a paused flow.** The pause is entirely checkpoint data. Nothing times out,
  expires or leases it.

### 3.3 How it resumes, including after a restart [src + ran]

**Mechanics.**

- `Agent.resume(agent, value, config: …)` → `Compiled.resume/3` (`graph/compiled/runtime.ex:93-106`)
  → `Runner.execute(compiled, %{}, resume: value)`.
- `Resume.normalize/3` (`graph/execution/resume.ex:8-52`) reads the pending interrupt records:
  - 1 pending + scalar, or a map not keyed by a pending id: the value is attached to that
    interrupt's task id, prefixed by earlier consumed resumes.
  - More than 1 pending: a map keyed by interrupt id or task id is required, otherwise
    `:invalid_resume`.
  - 0 pending: the value is passed through unchanged (see hazards below).
- `RunInit` replays the pending frontier. The interrupted node **re-runs from its beginning**.
  `Graph.interrupt/1` now returns the resume value (`scratchpad.ex:84-95`).
- Code before the interrupt re-executes. For HITL this includes the `when`/`predicate` and
  `description` functions, so they must be deterministic (`docs/human_in_the_loop.md` "Rules Of
  Interrupts") [src, doc].
- Decisions are validated. A count mismatch, a disallowed decision or edited args failing the
  schema all give `:invalid_human_decision`, which is a **run error**, not a re-prompt
  (`human_in_the_loop.ex:191-209, 246-319`).
- On success the middleware returns `%{messages: [revised_ai_message | synthetic_tool_messages]}`:
  - Approved and edited calls stay pending. The edited call keeps its id and may change name and
    args.
  - Reject produces an error `ToolMessage`; respond produces a success `ToolMessage`.
  - The ToolNode executes only unanswered calls (test `:369`).
  - Observed message order in the transcript: synthetic reject messages come before executed tool
    results (S5a) [ran].

**Across restart** [ran, `$SP/probes/probe_cold.exs`, SQLite Ecto, separate `mix run` VMs,
`PRELOAD=1`]:

- VM1 invoke leaves the flow paused.
- VM2 resume/approve executes the tool exactly once, and the run completes.
- The upstream-shipped equivalent at graph level is fork test `cold_replay_test.exs:23`
  ("Ecto SQLite retains a direct-Send producer beside a dynamic interrupt").

**Hazards observed** [ran; identical on fork, v0.1.23 and v0.1.29 unless noted]:

| Probe                        | Behaviour                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| S1 dup, cold VM3             | **Stale or duplicate resume after completion.** It is accepted, starts a new run from START, calls the model again and appends a second final assistant message.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| G1                           | For a graph: the node re-runs and a **new** interrupt is raised.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| S4, G1                       | **Resume on an unknown thread** runs from START. At graph level the scalar resume value is consumed by the first interrupt reached, giving `{:ok, %{answer: "x"}}`. A stale scalar resume can therefore approve a _new_ pause. HITL map-shaped resumes on a thread with no pending interrupt are not delivered, because `values_for_task` looks up the task id key.                                                                                                                                                                                                                                                                                     |
| S8                           | **Concurrent double resume** of one paused thread on ETS: both calls return `{:ok}` and the approved tool executed **twice**. The Ecto path has no lease either. PG serializes only the row write under an advisory lock, and SQLite has no lock [src], so the same outcome is expected [inferred].                                                                                                                                                                                                                                                                                                                                                     |
| S5b                          | **A failed resume burns the pause.** After `:invalid_human_decision`, `snapshot.interrupts == 0` while `next` is still `after_model`. The next valid resume re-raises the same interrupt id instead of applying, and only a third call completes.                                                                                                                                                                                                                                                                                                                                                                                                       |
| cold, `PRELOAD=0`            | **Fresh-VM decode.** Reading the HITL checkpoint in a new `mix run` VM fails with `:checkpoint_read_failed` / `"atom is not loaded in the current VM"`. The JSON decoder uses `String.to_existing_atom` (`lib/beam_weaver/serialization/json/decoder.ex:90-98`). The stored checkpoint contains the atoms `awaiting_client_tools`, `requires_action`, `complete`, `tool_call`, `assistant`, `user`, `interrupt` and `start`, and the offending one is likely a provider-outcome atom [unverified which]. Pre-loading all `:beam_weaver` modules fixes it. A release with embedded code loading probably avoids it [inferred]. Seen on fork and v0.1.29. |
| cold, v0.1.23 / v0.1.29 only | **Checkpoint id collision after restart.** A fresh VM re-generated `00000000000000000004`, and after VM3 the persisted head did not match the returned result. Fixed on the fork by `9bd7057` (UUIDv7 ids) [ran].                                                                                                                                                                                                                                                                                                                                                                                                                                       |

### 3.4 Cancellation [src + ran]

**Active agent run.** There is no `cancel` on `Agent` or `Compiled`. The available means:

- `Agent.Runner.async_invoke` / `Compiled.async_invoke` return a `Task`, and
  `Core.Async.cancel(task)` is `Task.shutdown(task, 5000)` (`core/async.ex:57-62`).
- Node tasks are `Task.async`-linked to the runner, so shutdown propagates and in-flight tools
  die. Probe S7: `slow:start` logged, `slow:end` never logged [ran].
- With `task_supervisor:`, node tasks are `async_nolink`, so they may outlive the caller
  [unverified].
- Nothing records a cancelled status. The thread keeps the last committed checkpoint
  (`next: ["tools"]`, AI tool call without a tool message).

**Budget-triggered kill.** `run_timeout`, `step_timeout` and node timeouts `brutal_kill`
unresolved tasks, emit `[:beam_weaver, :graph, :node_cancel]`, and return
`:run_timeout` / `:step_timeout` / `:node_timeout` (`task_awaiter.ex:23-55, 106-221`). Probe S9:
`run_timeout: 500` during a 1.5 s tool returns `:run_timeout`, and the state is the same as after
a kill [ran].

**Recovery after a kill, crash or timeout** [ran S7, cold crash probes]:

| Call                                                                                               | Outcome                                                                                                                                                                                                                                  |
| -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `invoke(%{}, config: thread)`                                                                      | Fails with `:invalid_chat_history` ("assistant tool calls must have matching tool messages"). With only a thread id, `%{}` input starts a new turn from START (`replay.ex:46-54` requires an explicit `checkpoint_id` for continuation). |
| `resume(nil, config: thread)`                                                                      | Same failure.                                                                                                                                                                                                                            |
| Either of the above                                                                                | The failed attempt also writes a new head with `next: ["model"]`, **wedging** the thread for later plain calls.                                                                                                                          |
| `invoke(%{}, config: snapshot.config)` (explicit `checkpoint_id`, taken before any failed attempt) | Replays `tools`. The tool **runs again** (`slow:start` ×2), so delivery is at-least-once, and the run completes.                                                                                                                         |

**Paused flow.** There is no process to cancel. The options are:

- never resume;
- resume with `reject` decisions;
- `Checkpoint.delete_thread/2` or `prune/3`.

New input on a paused thread does not cancel it: `invoke` re-raises the same interrupt, and the
new message is not added to state (S6) [ran]. `resume(nil)` on a paused HITL thread returns
`:invalid_human_decision` and burns the pause (S7b) [ran].

**Sub-agents.**

- A sync child can be cancelled only by the parent tools-node timeout
  (`model_opts[:tool_timeout]`, default `:infinity`, `agent/compiler.ex:251-252`) or by killing
  the parent run. The child's own checkpoints under its namespace are left behind [inferred].
- Async children: `cancel_async_task` issues a best-effort remote `POST /runs/:id/cancel`
  (`async_subagents.ex:276-314`).

**Low-level `Runtime.Agent`.** This is the only cooperative protocol (`runtime/agent/server.ex:62-123`):

1. `cancel/2` sends `{:beam_weaver_cancel, work_id, :requested}`.
2. Work polls `Runtime.Agent.cancellation/0` and returns `{:cancelled, reason}`.
3. After `cancel_grace_ms` (default 100) the work task is killed with a `:cancel_timeout`
   failure. The server does not report that as a successful cancel.
4. Owner `DOWN` kills all work and stops the server.

Tests: `test/beam_weaver/runtime/agent_server_test.exs:161` "cancellation stops active work
cleanly", `:187` "unacknowledged cancellation is reported as a failure". This layer is in-memory
only (`restart: :temporary`) and is not connected to checkpoints or the agent graph.

### 3.5 Child (sub-agent) interrupts [ran + src]

- Probe S3: child `interrupt_on: %{"danger" => true}` and no parent policy.
- Probe S3b: parent `interrupt_on: %{"danger" => true}`, inherited by the child.
- Result in both: the parent returns `{:ok, …}`. The `task` tool message content is
  `"Subagent interrupted: %{id: \"interrupt_…\", …}"`, the child's `danger` tool is **not**
  executed, and the parent model is called with that string and finishes.
- Source: `agent/middleware/subagents.ex:662-663` turns the child's `{:interrupted, state}` into
  that string.
- No test covers child interrupts. `docs/human_in_the_loop.md` ("Subagent Interrupts") claims
  the parent returns `{:interrupted, interrupt}`, and `docs/subagents.md` claims child HITL
  "requires checkpointing to resume". Both are contradicted by execution.
- Contrast: a compiled subgraph used as a graph **node** does re-throw its interrupt to the parent
  (`graph/execution/node_invoker.ex:81-83`, test `pregel_behavior_test.exs:1092` "parent graph
  resume reaches interrupted subgraph task").
- **Implication for Fabric.** Mirror the "gate the `task` call in the parent" behaviour. Do not
  mirror child-interrupt handling; design it from Fabric's own requirements.

---

## 4. Executed probe results (my scripts; BeamWeaver only)

Scripts:

- `$SP/probes/common.exs`: `Probe.ScriptedModel`, `danger` and `slow` tools, a file-based
  side-effect log.
- `$SP/probes/probe_ets.exs`, `$SP/probes/probe_ets2.exs`: ETS, single VM.
- `$SP/probes/probe_cold.exs`: SQLite Ecto, one VM per step.

Outputs:

- `$SP/probes/probe_ets.out`, `probe_ets2.out`
- `probe_cold.out`, `probe_cold_crash.out`
- `v0123_*.out`, `v0129_*.out`

### 4.1 Differential across revisions

`diff probe_ets*.out v0123_probe_ets*.out` and `diff probe_ets*.out v0129_probe_ets*.out` are
**empty**. Fork `d0aa1f9`, `v0.1.23` and `v0.1.29` behave identically on every ETS scenario
below. This is an executed three-way comparison of BeamWeaver revisions, not of Fabric.

### 4.2 ETS scenarios (all three revisions identical)

| Id       | Scenario                                                        | Observed                                                                                                                            |
| -------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| S1       | `interrupt_on {"task"}`, invoke                                 | `{:interrupted}` with a `task` action request; model log shows the parent model called once and the child not called                |
| S1       | approve                                                         | Child runs (`child work` model, `danger:c`, child final), then parent final                                                         |
| S1       | duplicate resume after completion                               | `{:ok}`; parent model called again; a second final message is appended                                                              |
| S2       | reject the `task` call                                          | Child never runs; `T(call-task-1, error): no sub-agent`; parent final                                                               |
| S3 / S3b | child-internal HITL                                             | Parent `{:ok}`; tool message `"Subagent interrupted: …"`; child tool not executed                                                   |
| S4       | resume on unknown thread                                        | `{:ok}`; model called with no user message                                                                                          |
| S5       | 2 reviews, 1 decision                                           | `:invalid_human_decision`                                                                                                           |
| S5a      | 2 reviews, approve + reject                                     | Executes `a` only; transcript `T(b, error)` then `T(a)`; final                                                                      |
| S5b      | bad resume, then good resume, then good resume                  | Error → `interrupts=0` → re-interrupt (same id) → ok                                                                                |
| S6       | new user input while paused                                     | Same interrupt re-raised; new message not persisted; later approve works                                                            |
| S7       | `Task.shutdown` mid-tool                                        | Tool killed; `next=["tools"]`; `invoke(%{})` and `resume(nil)` fail with `:invalid_chat_history` and move `next` to `["model"]`     |
| S7b      | `resume(nil)` while HITL-paused                                 | `:invalid_human_decision` "HITL resume value must include decisions"; interrupt consumed                                            |
| S8       | concurrent double resume                                        | Both `{:ok}`; `tool:danger:p` logged twice                                                                                          |
| S9       | `run_timeout: 500` during tool                                  | `:run_timeout`; tool killed; `next=["tools"]`                                                                                       |
| S10      | `recursion_limit: 2`                                            | `:recursion_limit` after one tool execution                                                                                         |
| G1       | graph interrupt, resume by id, duplicate resume, unknown thread | `{:ok, %{answer: "yes"}}`; duplicate gives a **new** interrupt after re-running `ask`; unknown thread gives `{:ok, %{answer: "x"}}` |

### 4.3 Cold-restart scenarios (SQLite Ecto, `PRELOAD=1`)

| Step                                                           | Fork `d0aa1f9`                                                     | `v0.1.23` / `v0.1.29`                                                                                     |
| -------------------------------------------------------------- | ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| VM1 produce                                                    | interrupted; checkpoint id is UUIDv7                               | interrupted; checkpoint id `00000000000000000002`                                                         |
| VM2 resume approve                                             | ok; `danger:p` once                                                | ok; `danger:p` once                                                                                       |
| VM3 duplicate resume                                           | ok; model called again; persisted head = returned state (2 finals) | ok; model called again; **persisted head id `…0004` reused and state shows 1 final** (identity collision) |
| crash mid-tool → `invoke(%{}, config: explicit checkpoint_id)` | ok; tool re-executed                                               | ok; tool re-executed (v0.1.23)                                                                            |
| crash mid-tool → `resume(nil)`                                 | `:invalid_chat_history`, head → `next=["model"]`                   | not run on upstream                                                                                       |
| `PRELOAD=0` fresh-VM read                                      | `:checkpoint_read_failed` (atom)                                   | same (v0.1.29)                                                                                            |

---

## 5. Part 3: oracle candidates

Classification:

- **(a)** executed differential candidate: a deterministic scripted model and observable
  outputs that can be captured as fixtures by running BeamWeaver here. "Producible" means I
  already ran either the upstream test or an equivalent probe in this environment.
- **(b)** inspiration only: mirror the behaviour in an original Fabric test, or treat BeamWeaver's
  behaviour as a known divergence that Fabric should deliberately _not_ reproduce (marked
  **anti-oracle**).
- **(c)** not applicable.

### 5.1 Fixture shape for (a)

A scratch exporter script (`mix run --no-compile export.exs`, modelled on `$SP/probes/*.exs`)
writes one JSON object per scenario:

```json
{
  "oracle": {"repo": "lostbean/beam_weaver", "commit": "d0aa1f9…", "elixir": "1.19.5", "otp": "28.5"},
  "scenario": "hitl_gate_subagent_approve",
  "agent": {"tools": ["danger"], "subagents": ["worker"], "interrupt_on": {"task": true}},
  "scripted_model": "transcript-pure rules (first user msg, #tool msgs) -> reply",
  "steps": [
    {"call": "invoke", "input": {"messages": [{"role": "user", "content": "parent go"}]},
     "result": {"tag": "interrupted", "value": {"action_requests": [{"name": "task", "args": {...}}],
                "review_configs": [{"action_name": "task", "allowed_decisions": ["approve","edit","reject","respond"]}]}},
     "snapshot": {"next": ["human_in_the_loop.after_model"], "interrupts": 1},
     "effects": ["model:parent go:tool_msgs=0"]},
    {"call": "resume", "value": {"decisions": [{"type": "approve"}]},
     "result": {"tag": "ok", "transcript": [["user","parent go"], ["assistant", {"tool_calls": [["task","call-task-1"]]}],
                ["tool","call-task-1","success","final(child work): danger-done:c"], ["assistant","final(parent go): …"]]},
     "effects": ["model:child work:tool_msgs=0","tool:danger:c","model:child work:tool_msgs=1","model:parent go:tool_msgs=1"]}
  ]
}
```

Normalise away:

- message UUIDs;
- checkpoint ids;
- run ids and timestamps;
- the `response_metadata` provider blocks;
- literal interrupt ids. They are deterministic sha256 values over BeamWeaver-internal task ids,
  so compare only "same id across re-raise" or "distinct ids".

Tool **execution order** inside a concurrent group is nondeterministic (S5b logged `b` before
`a`). Compare it as a multiset. Transcript order is deterministic.

### 5.2 (a) Executed-differential candidates

| #   | Scenario                                                                                                              | BeamWeaver source                                                                                                | Fixture captured                                                              | Producible here                                                       |
| --- | --------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| A1  | HITL approve executes the reviewed call once, final answer follows                                                    | `human_in_the_loop_test.exs:244`                                                                                 | Interrupt payload, decisions, transcript, effect log (`lookup_executed` once) | Yes: upstream test passes [ran]; probe S1-like                        |
| A2  | Edit keeps tool_call_id and validates edited args                                                                     | `:282`, `:440` (invalid edit → `:invalid_human_decision`)                                                        | Edited call id/args in transcript; error tag                                  | Yes [ran suite]                                                       |
| A3  | Reject / respond synthesise tool messages; the tool is not executed                                                   | `:336`, `:313` (typed decision)                                                                                  | Tool message status/content/tool_call_id; effect log empty                    | Yes [ran suite]                                                       |
| A4  | Mixed auto-approved and rejected calls: only unanswered calls execute                                                 | `:369`                                                                                                           | Transcript order and effect multiset                                          | Yes [ran suite]                                                       |
| A5  | `interrupt_mode: :first` reviews only the first matching call; later calls run after approve                          | `:414`                                                                                                           | Payload with one request; both effects after resume                           | Yes [ran suite]                                                       |
| A6  | `when` predicate skips review                                                                                         | `:393`                                                                                                           | ok vs interrupted per context flag                                            | Yes [ran suite]                                                       |
| A7  | Decision-count mismatch is an error                                                                                   | `:440`; probe S5                                                                                                 | Error tag                                                                     | Yes [ran]                                                             |
| A8  | Pending interrupts visible in state (`snapshot.interrupts`, `next`)                                                   | `:481`; probes                                                                                                   | Snapshot projection                                                           | Yes [ran]                                                             |
| A9  | **Gate sub-agent start** (`interrupt_on "task"`): approve runs the child, reject never starts it                      | Probe S1/S2 (no upstream test)                                                                                   | Full fixture as §5.1                                                          | Yes [ran probe]                                                       |
| A10 | Graph `interrupt/1` scalar resume; null resume; sequential interrupts in one node remember prior answers              | `pregel_behavior_test.exs:956, 1044, 1063`                                                                       | Returned states and node effect counts                                        | Yes [ran suite]                                                       |
| A11 | Parallel interrupts require a keyed map; resume by id                                                                 | `pregel_behavior_test.exs:1009`; `resume.ex:28-38`                                                               | Error tag for scalar; ok for map                                              | Yes [ran suite]                                                       |
| A12 | Static `interrupt_before` pauses and resumes                                                                          | `compiled_test.exs:1575`                                                                                         | `timing: :before`, resumed state                                              | Yes [ran suite]                                                       |
| A13 | Durable pause survives a VM restart and executes once on approve (agent level)                                        | Probe `probe_cold.exs` produce/resume (`PRELOAD=1`)                                                              | Two-VM fixture: VM1 result + snapshot, VM2 result + effect log                | Yes [ran probe]                                                       |
| A14 | Graph-level cold resume with a completed sibling not re-run                                                           | `cold_replay_test.exs:23, 61` (fork); `atomic_checkpoint_boundary_test.exs`, `ecto_atomic_boundary_test.exs:125` | Event-log strings (`"P"`, `"PT"`, `"P\nT\n"`) per VM                          | Yes [ran suite]                                                       |
| A15 | Pending writes: failed fan-out resumes without re-running the successful sibling                                      | `pregel_behavior_test.exs:84`; `compiled_test.exs:1014`; `durable_execution.md` example                          | Effect counts and final state                                                 | Yes [ran suite]                                                       |
| A16 | Tool errors become error ToolMessages (unknown tool, schema error, timeout)                                           | `tool_node_test.exs:432, 567, 1144`                                                                              | Tool message content/status/error_type metadata                               | Yes [ran suite]                                                       |
| A17 | Parallel tools preserve output order; non-concurrent tools are barriers                                               | `tool_node_test.exs:1036, 1088`                                                                                  | Transcript order and start/finish log                                         | Yes [ran suite] (timing-sensitive; compare order only)                |
| A18 | Recursion limit is a hard error                                                                                       | `compiled_test.exs:699`; probe S10                                                                               | Error tag plus number of executed steps and effects                           | Yes [ran]                                                             |
| A19 | Run/step/node timeout kills in-flight work; error tag; post-state `next=["tools"]`                                    | `compiled_test.exs:429`, `runtime_surface_test.exs:788`; probe S9                                                | Error tag, effect log (start without end)                                     | Yes [ran] (timing-based: use generous margins)                        |
| A20 | Model/tool call limits (`:error` / `:end` / `:continue`)                                                              | `middleware_builtin_test.exs:1088, 1308, 1313, 1556-1745`                                                        | Transcript and error tags                                                     | Yes [ran suite]                                                       |
| A21 | Strict resume delivery: stage → continue → replay yields an identical receipt; unrelated pending writes are preserved | `checkpoint/ecto_test.exs:270`, `conformance_test.exs:988`                                                       | Channel values and receipt equality (hashes normalised)                       | Yes [ran suite]; saver-level, not agent-level                         |
| A22 | Checkpoint identity is unique across VM restarts                                                                      | `ecto_checkpoint_identity_test.exs`; cold probe                                                                  | Distinct ids and lineage                                                      | Yes [ran]                                                             |
| A23 | `Runtime.Agent` cooperative cancel vs cancel_timeout                                                                  | `runtime/agent_server_test.exs:161, 187, 77`                                                                     | Subscriber message sequence `{:cancelled \| :failed, work_id, error.type}`    | Yes [ran suite]. Useful only if Fabric has an equivalent work runner. |

### 5.3 (b) Inspiration-only, including anti-oracles

| #   | Behaviour                                                                                                                                                                           | Why (b)                                                                                                                                                                                                                                    |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| B1  | **Anti-oracle:** a child sub-agent interrupt is stringified and dropped (probe S3/S3b)                                                                                              | Contradicts BeamWeaver's own docs and Fabric's escalation goal. Fabric should propagate the child pause to the parent and route the resume back. Capture BeamWeaver's output only as a documented divergence.                              |
| B2  | **Anti-oracle:** stale, duplicate or unknown-thread resume accepted and re-runs from START; stale scalar resume consumed by a new interrupt (S1 dup, S4, G1)                        | Fabric should reject a resume without a matching pending interrupt id, with a typed error.                                                                                                                                                 |
| B3  | **Anti-oracle:** concurrent double resume double-executes the tool (S8)                                                                                                             | Fabric needs a single-winner resume (CAS on the pause record, or a lease).                                                                                                                                                                 |
| B4  | **Anti-oracle:** an invalid resume burns the pending interrupt (S5b, S7b)                                                                                                           | Fabric should leave the pause intact on a validation failure.                                                                                                                                                                              |
| B5  | **Anti-oracle:** crash mid-tool wedges the thread unless continued from an explicit checkpoint id; tool re-execution is at-least-once (S7, cold crash)                              | Fabric should decide explicitly between an in-flight tool-call record with idempotency keys and "unknown outcome" escalation. BeamWeaver's `durable_execution.md` "Determinism And Replay" guidance (idempotency keys) is the inspiration. |
| B6  | New input to a paused thread re-raises the pause (S6)                                                                                                                               | Plausible semantics. Fabric may instead define an explicit cancel-pause operation.                                                                                                                                                         |
| B7  | `Runtime.Agent` cancel protocol (cooperative signal → grace → kill → `cancel_timeout` is a failure, not a cancel)                                                                   | A good model for Fabric's in-flight tool cancellation. The agent graph does not use it, so there is no end-to-end fixture.                                                                                                                 |
| B8  | `DispatchHook.before_dispatch/3` (policy-neutral allow/deny immediately before each attempt) and `Subagent.Host.admit_child` (closed Proposal with `correlation_id = tool_call_id`) | The shape of Fabric's runtime action-authorization seam. It is disconnected from the agent graph in BeamWeaver.                                                                                                                            |
| B9  | `wrap_tool_call` deny/rewrite (`tool_node_test.exs:455, 480`)                                                                                                                       | Non-pausing policy gate.                                                                                                                                                                                                                   |
| B10 | Atomic halted boundary contract: an unknown outcome on error, no retry, no partial boundary (`saver.ex:36-65`; tests `atomic_checkpoint_boundary_test.exs:581, 616`)                | Mirror as a Fabric store contract. Fixtures are Elixir-saver-specific.                                                                                                                                                                     |
| B11 | Join / NamedBarrier membership durability; ExecutionEnvelope sibling replay                                                                                                         | Relevant only if Fabric's DAG compiler has joins and fan-out. Mirror the invariants; the internal envelope format is not portable.                                                                                                         |
| B12 | Event envelope fields (`tool_call_id` on tool events; namespace for child runs; no sequence numbers)                                                                                | Inspiration for Fabric event schema. Capture as shape, not bytes.                                                                                                                                                                          |
| B13 | Interrupt ids deterministic per (graph, node, step, counter), not per thread                                                                                                        | Fabric should key pauses by thread plus id.                                                                                                                                                                                                |
| B14 | Fresh-VM atom decode failure                                                                                                                                                        | Serialization hazard to avoid (Gleam has no atom table issue for strings, but custom-type decoding must be total).                                                                                                                         |
| B15 | ModelCallLimit run counters are untracked (reset per invocation/resume)                                                                                                             | Decide Fabric budget scoping explicitly.                                                                                                                                                                                                   |

### 5.4 (c) Not applicable

- Retrieval, vector stores, loaders, splitters and indexing.
- Async sub-agents over the remote Agent Protocol (`ReqClient`), unless Fabric targets LangGraph
  Platform.
- DeepAgents filesystem, skills, todos and sandboxes.
- Prompt caching and TypeSafe routing.
- WeaveScope exporter.
- LangGraph API-compat surface: time travel `fork_at`, `update_state as_node`, DeltaChannel, node
  cache, UI messages, and the remaining-steps apology. These are useful only as inspiration if
  Fabric exposes them.
- Structured-output strategy selection.
- Provider model profiles and pricing.
- Ecto migrations and SQL specifics. Mirror the saver contract instead.

---

## 6. Unverified or open items

- Whether nested tool workers under `task_supervisor:` (`async_stream_nolink`) die when the
  caller is cancelled.
- The exact atom that fails to decode in a fresh VM, and whether an OTP release (embedded mode)
  is immune.
- Concurrent double resume on Ecto/PG. It is expected to double-execute, because there is no
  lease, but this was not run.
- The recursion limit appears cumulative across resumes (`replay.ex:168-169`) [inferred by
  subagent survey].
- `failure_policy` appears unread, so `:panic` and `:proceed` look identical [src grep by
  subagent survey].
- Nil or duplicate `tool_call_id` semantics are inferred, not tested.
- Remote state of `lostbean/beam_weaver` on GitHub was not fetched; the local tracking refs show
  `d0aa1f9` pushed.
- Postgres-tagged tests (66) were not run.

## 7. Artifacts

| Path under `$SP/`                                        | Contents                                             |
| -------------------------------------------------------- | ---------------------------------------------------- |
| `beam_weaver_upstream/`                                  | Upstream clone                                       |
| `fork_clone/`                                            | Fork clone at `d0aa1f9`, compiled for test           |
| `wt_v0.1.23/`, `wt_v0.1.29/`                             | Worktrees at upstream tags                           |
| `fork_test_full.log`, `v0123_test.log`, `v0129_test.log` | Suite logs                                           |
| `probes/`                                                | Probe scripts, outputs, and per-run SQLite databases |
| `research/beamweaver-oracle.md`                          | This report                                          |

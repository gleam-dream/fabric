# Agent Instructions

## About this repo

`fabric` — A bounded, typed LLM agent and agentic graph runtime for Gleam: typed application operations, an explicit policy gate, pure controllers, and supervised OTP runners with cancellation. It consumes llm_wire for providers and json_blueprint for codecs. Neither Saga nor Grind is a core dependency. The design layer under `docs/` owns the contracts, the vocabulary and the rationale; the PostgreSQL adapter has its own nested design layer.

## Tooling

- `nix develop` (or direnv): dev shell with `gleam`, Erlang/OTP 29, `rebar3`, `lefthook`, Python and PostgreSQL 16.
- `nix fmt`: formats the whole repo via treefmt (`gleam format`, `nixfmt`, `prettier`).
- `lefthook`: pre-commit hook formats staged files and re-stages them.
- `nix flake check`: fails iff the tree is not formatted (plus any existing checks).
- `gleam test`: runs the core test suite.

## Gate

- `nix develop -c python3 scripts/check.py fast`: formatting, static tooling and the core suite for the local edit loop.
- `nix develop -c python3 scripts/check.py full`: every retained package, consumer, local service, compiler-negative check and temporary PostgreSQL. `ci` runs the same checks in hosted CI after the pinned sibling checkout (`sibling-revisions.txt`).
- The recipes that the module documentation describes are compiled consumers: `consumers/saga_tool`, `consumers/relay_tools` and `consumers/approvers_warden`. The gate builds and tests them, and `scripts/test_check.py` keeps each within 50 lines (60 for the Saga recipe).
- `nix develop -c integrations/fabric_postgres/scripts/test-postgres.sh`: the adapter's tests against a private disposable cluster. Never select a production database.
- `nix develop -c consumers/jobs/test-service.sh`: the jobs consumer against its own HTTP service.
- Live-provider commands in `consumers/decision` and `consumers/writing` are explicit, make real requests and are never part of the gate. The gate removes provider credentials from child environments and never loads `.env.local`.
- Oracle fixtures under `test/oracle/fixtures` are recaptured with the committed capture script and never hand-edited. The pin, rules and limits are in [docs/ORACLE.md](docs/ORACLE.md).
- `nix develop -c sh -c 'cd examples/usage && gleam test && gleam run'`: the usage examples, which `scripts/check.py fast` also runs. A changed public signature fails them.
- An unpublished coordinated API change is validated in a normalized copy of the whole source graph made by `scripts/local_sources.py` of the [Oversight repository](https://github.com/gleam-dream/oversight), never against the immutable pins.

## References

- [docs/ORACLE.md](docs/ORACLE.md): the BeamWeaver oracle pin, fixture rules, comparison tables, recapture steps and limits, plus the frozen version-2 reader and the classifier protocol fixture. Read it before touching `test/oracle`.
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md): the dated live-provider measurements with their method, rerun commands and limits. Fabric has no runtime benchmark harness. The two documents link each other.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(machine-owned; do not edit inside this fence — re-run setup to refresh)

## Agent skills

**Design layer** — `docs/design/design.typ` describes the design,
`docs/design/CONTEXT.typ` defines its vocabulary, and `docs/adr/` records
decision rationale. The rendered document is `docs/design/design-layer.pdf`.
`docs/COVERAGE.md` maps repository parts to their design owners.

**Tracker** — local markdown under `issues/`: one directory per feature
(`issues/<feature-slug>/`), the PRD at `issues/<feature-slug>/PRD.md`, issue
files at `issues/<feature-slug>/issues/<NN>-<slug>.md` numbered from 01. Each
issue file carries two header lines near the top — `Status: <state>`,
`Category: <category>`. Conversation appends to the bottom
of the file under a `## Comments` heading. Labels (canonical strings, adopted
verbatim): states `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `in-progress`, `done`, `wontfix`; categories `bug`,
`enhancement`.

**AI disclaimer** — AI-authored tracker comments start with
`AI-assisted contribution.`

**Design gate** — `nix run .#design-gate-check -- docs/design . --nested-project integrations/fabric_postgres` checks render freshness,
vocabulary references and layer integrity (exit 0 clean, 1 violation, 2 error).
The gate is supplied by the pinned `design-layer` flake input.
`nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`
rebuilds the rendered document. `nix run .#design-gate-context -- docs/design --estimate`
estimates agent context; the same command without `--estimate` emits ephemeral
Markdown. `--manifest`, `--preview`, and `--section PATH --expect-digest DIGEST`
support loading selected sections. A bare Typst compilation does not run the gate.

**Context verification** — use native semantic blocks for lists, tables,
models and behavior. After authoring, verify context estimation and a selected
section export as well as rendering and the design gate.
Run these commands sequentially for each layer; they share its generated
`.render` workspace.

**Staleness** — source changes since the design last changed require a
conformance review before the layer is treated as current.

<!-- agent-skills:end -->

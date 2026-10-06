# Agent Instructions

## About this repo

`fabric` — A bounded, typed LLM agent and agentic graph runtime for Gleam: typed application operations, an explicit policy gate, pure controllers, and supervised OTP runners with cancellation. It consumes llm_wire for providers and json_blueprint for codecs. Fabric owns conditional agentic graphs; Saga remains an optional integration for independent workflows with compensation. Neither Saga nor Grind is a core dependency.

Behavioural oracle: BeamWeaver, scoped by [ORACLE](docs/ORACLE.md). Native design: [source](docs/design/design.typ) and [rendered layer](docs/design/design-layer.pdf); canonical [vocabulary](docs/design/CONTEXT.typ), [coverage](docs/COVERAGE.md), and [ADRs](docs/adr/). The PostgreSQL adapter has its own nested design layer.

## Tooling

- `nix develop` (or direnv): dev shell with `gleam`, Erlang/OTP 28, `rebar3`, `lefthook`.
- `nix fmt`: formats the whole repo via treefmt (`gleam format`, `nixfmt`, `prettier`).
- `lefthook`: pre-commit hook formats staged files and re-stages them.
- `nix flake check`: fails iff the tree is not formatted (plus any existing checks).
- `gleam test`: runs the test suite.
- `nix develop -c python3 scripts/check.py full`: runs all retained packages,
  consumers, local services, compiler-negative checks and temporary PostgreSQL.
  See `docs/VERIFICATION.md`. CI invokes the same registry after pinned sibling checkout.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(machine-owned; do not edit inside this fence — re-run setup to refresh)

## Agent skills

**Design layer** — `docs/design/design.typ` describes the design,
`docs/design/CONTEXT.typ` defines its vocabulary, and `docs/adr/` records
decision rationale. The rendered document is `docs/design/design-layer.pdf`.
`docs/COVERAGE.md` maps repository parts to their design owners.

**Tracker** — GitHub issues in `gleam-dream/fabric`, accessed with
`gh issue list --repo gleam-dream/fabric` and `gh issue view NUMBER --repo gleam-dream/fabric`.
Labels bind roles as follows: `needs-triage` → `needs-triage`,
`needs-info` → `question`, `ready-for-agent` → `ready-for-agent`,
`ready-for-human` → `ready-for-human`, `in-progress` → `in-progress`,
`done` → `done`, `wontfix` → `wontfix`, `bug` → `bug`,
and `enhancement` → `enhancement`.

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

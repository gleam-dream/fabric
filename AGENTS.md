# Agent Instructions

## About this repo

`fabric` — A bounded, typed LLM agent and agentic graph runtime for Gleam: typed application operations, an explicit policy gate, pure controllers, and supervised OTP runners with cancellation. It consumes llm_wire for providers and json_blueprint for codecs. Neither Saga nor Grind is a core dependency. The design layer under `docs/` owns the contracts, the vocabulary and the rationale; the PostgreSQL adapter has its own nested design layer.

## Tooling

- `nix develop` (or direnv): dev shell with `gleam`, Erlang/OTP 29, `rebar3`, `lefthook`, Python and PostgreSQL 16.
- `nix fmt`: formats the whole repo via treefmt (`gleam format`, `nixfmt`, `prettier`).
- `lefthook`: pre-commit hook formats staged files and re-stages them.
- `nix flake check`: fails iff the tree is not formatted (plus any existing checks).
- `gleam test`: runs the core test suite.

## Validation

Use the shared tools directly, then run application tests:

```sh
nix flake check
nix run .#design-gate-check -- docs/design . --nested-project integrations/fabric_postgres
nix develop --command bash scripts/test.sh
```

For the core edit loop, run `nix develop --command gleam test`.
`scripts/test.sh` compiles and tests the retained packages and service fixtures;
it does not wrap formatting or design validation.

- `nix develop -c integrations/fabric_postgres/scripts/test-postgres.sh`: the adapter's tests against a private disposable cluster. Never select a production database.
- `nix develop -c consumers/jobs/test-service.sh`: the jobs consumer against its own HTTP service.
- Live-provider commands in `consumers/decision` and `consumers/writing` are explicit, make real requests and are never part of the gate. The gate removes provider credentials from child environments and never loads `.env.local`.
- Oracle fixtures under `test/oracle/fixtures` are recaptured with the committed capture script and never hand-edited. The pin, rules and limits are in [docs/ORACLE.md](docs/ORACLE.md).
- Unpublished sibling packages (`gleam-dream/*` and `lostbean/json_blueprint`) are Git dependencies with `ref = "main"`; each `manifest.toml` is the lock. Update one by hand with `gleam update <package>` when needed. No gate or job updates them.

## References

- [docs/ORACLE.md](docs/ORACLE.md): the BeamWeaver oracle pin, fixture rules, comparison tables, recapture steps and limits, plus the frozen version-2 reader and the classifier protocol fixture. Read it before touching `test/oracle`.
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md): the dated live-provider measurements with their method, rerun commands and limits. Fabric has no runtime benchmark harness. The two documents link each other.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(Updated for the repository validation policy.)

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

**Shared design validation** — `nix run .#design-gate-check -- docs/design . --nested-project integrations/fabric_postgres`
uses the pinned design-layer implementation for render freshness, vocabulary and
layer integrity. `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`
updates the rendered document; `nix run .#design-gate-context -- docs/design` exports
context. Run these tools sequentially because they share `.render`.

<!-- agent-skills:end -->

## README snippets

Keep README Gleam examples in compiled example or consumer source. Use named
`snips-start` / `snips-end` regions (or include a whole example module), and retain
Prettier ignore ranges around generated README blocks. Format the source first,
then run `nix run .#snips -- --commands deny README.md integrations/fabric_postgres/README.md`. CI runs
`nix run .#snips -- --check --commands deny README.md integrations/fabric_postgres/README.md` using the shared pinned
package. Snips checks synchronization; existing example tests check behavior.

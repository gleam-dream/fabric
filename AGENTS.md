# Agent Instructions

## About this repo

`fabric` — A bounded, typed LLM agent and agentic graph runtime for Gleam: typed application operations, an explicit policy gate, pure controllers, and supervised OTP runners with cancellation. It consumes llm_wire for providers and json_blueprint for codecs. Fabric owns conditional agentic graphs; Saga remains an optional integration for independent workflows with compensation. Neither Saga nor Grind is a core dependency.

Behavioural oracle: BeamWeaver (partial migration of its agent loop; see docs/ORACLE.md). Plan: docs/PLAN.md. Agent design: [gleam-dream/oversight](https://github.com/gleam-dream/oversight)/fabric-design.md. Graph design and selected implementation program: docs/GRAPH-FLOW.md and docs/implementation/graph-flow/wave-tracker.md.

## Tooling

- `nix develop` (or direnv): dev shell with `gleam`, Erlang/OTP 28, `rebar3`, `lefthook`.
- `nix fmt`: formats the whole repo via treefmt (`gleam format`, `nixfmt`, `prettier`).
- `lefthook`: pre-commit hook formats staged files and re-stages them.
- `nix flake check`: fails iff the tree is not formatted (plus any existing checks).
- `gleam test`: runs the test suite.
- `nix develop -c python3 scripts/check.py full`: runs all retained packages,
  consumers, local services, compiler-negative checks and temporary PostgreSQL.
  See `docs/VERIFICATION.md`. CI activation awaits library publication.

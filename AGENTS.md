# Agent Instructions

## About this repo

`fabric` — A bounded, typed LLM agent runtime for Gleam: typed application tools, an explicit policy gate, a pure agent controller, and a thin OTP runner with cancellation. It consumes llm_wire for providers and json_blueprint for tool codecs; typed workflows (DAGs) belong to Saga.

Behavioural oracle: BeamWeaver (partial migration of its agent loop; see docs/ORACLE.md). Plan: docs/PLAN.md. Design: [gleam-dream/oversight](https://github.com/gleam-dream/oversight)/fabric-design.md.

## Tooling

- `nix develop` (or direnv): dev shell with `gleam`, Erlang/OTP 28, `rebar3`, `lefthook`.
- `nix fmt`: formats the whole repo via treefmt (`gleam format`, `nixfmt`, `prettier`).
- `lefthook`: pre-commit hook formats staged files and re-stages them.
- `nix flake check`: fails iff the tree is not formatted (plus any existing checks).
- `gleam test`: runs the test suite.

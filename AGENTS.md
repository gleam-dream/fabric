# Agent Instructions

## About this repo

`fabric` — A partial Gleam port of BeamWeaver: a typed DAG compiler, durable OTP execution, an autonomous LLM agent loop, and provider wire adapters, with a runtime action-authorization seam.

Ports/wraps: BeamWeaver. Design: [gleam-dream/oversight](https://github.com/gleam-dream/oversight)/fabric-design.md.

## Tooling

- `nix develop` (or direnv): dev shell with `gleam`, Erlang/OTP 28, `rebar3`, `lefthook`.
- `nix fmt`: formats the whole repo via treefmt (`gleam format`, `nixfmt`, `prettier`).
- `lefthook`: pre-commit hook formats staged files and re-stages them.
- `nix flake check`: fails iff the tree is not formatted (plus any existing checks).
- `gleam test`: runs the test suite.

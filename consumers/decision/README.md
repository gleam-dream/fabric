# Typed decision consumer

[![CI](https://github.com/gleam-dream/fabric/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/fabric/actions/workflows/ci.yml)
[![fabric on Hex](https://img.shields.io/hexpm/v/fabric?label=Hex%3A%20fabric)](https://hex.pm/packages/fabric)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A native enum chooses `publish` or `revise`. One routing definition accepts
either structured LLM output or a non-generative TypeSafe classifier answer.
Each producer keeps its own receipt and recovery codec, and neither path needs
an agent conversation, Saga or Grind.

## Offline gate

```sh
nix develop -c sh -c 'cd consumers/decision && gleam build --warnings-as-errors && gleam test'
```

The tests exercise both routes with an offline HTTP Gun script and a loopback
TypeSafe protocol fixture. They read no credentials and contact no provider.

## Live commands

Each command makes one real provider request with a 20-second deadline, prints
the route, typed answers, model identities and usage, and fails on a missing
key, a provider failure or an invalid result. Neither retries or falls back to a
script.

```sh
# OPENAI_API_KEY; model gpt-4.1-nano-2025-04-14 or FABRIC_DECISION_MODEL
nix develop -c sh -c 'cd consumers/decision && gleam run'

# TYPESAFE_API_KEY; model jev-latest or FABRIC_CLASSIFIER_MODEL
nix develop -c sh -c 'cd consumers/decision && gleam run -m fabric_decision_classifier'
```

The [design](../../docs/design/design-layer.pdf) specifies the adapters, and
[ADR 0017](../../docs/adr/0017-retain-live-provider-evidence-as-dated-sanitized-captures.md)
records the dated live results; [BENCHMARKS.md](../../docs/BENCHMARKS.md) keeps their method and limits.

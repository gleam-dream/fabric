# Typed decision consumer

A native enum chooses `publish` or `revise`. One application routing definition
accepts either structured LLM output or a non-generative TypeSafe classifier
answer. Each producer retains its own protocol receipt and recovery codec.
Neither path requires an agent conversation, Saga or Grind.

The LLM operation preserves typed output, raw JSON and reported usage. Refused
or incomplete responses block acceptance before either business route. The
classifier batches yes/no, enum and score questions, then routes on the enum.
It also retains the yes probability, full distributions, rubric, confidence,
requested/resolved models and usage. Application code chooses how that evidence
controls routing; this example deliberately uses only the selected enum.

Run the offline gate from the repository root:

```sh
nix develop -c sh -c 'cd consumers/decision && gleam build --warnings-as-errors && gleam test'
```

Tests exercise both routes with llm_wire's scripted transport and an explicit
loopback TypeSafe protocol fixture. The fixture is not Jev inference. Tests do
not read credentials or contact a provider.

## Live LLM

This command makes **one live OpenAI request**, using `OPENAI_API_KEY` and
synthetic input `2 + 2 = 4`:

```sh
nix develop -c sh -c 'cd consumers/decision && gleam run'
```

The default requested model is `gpt-4.1-nano-2025-04-14`; override it with
`FABRIC_DECISION_MODEL`. OpenAI documents structured output support on the
[model page](https://developers.openai.com/api/docs/models/gpt-4.1-nano).
The request is bounded to 64 output tokens and 20 seconds.

## Live classifier

This command makes **one live TypeSafe request** containing the three independent
questions, using `TYPESAFE_API_KEY` and the same synthetic input:

```sh
nix develop -c sh -c 'cd consumers/decision && gleam run -m fabric_decision_classifier'
```

The default requested model is `jev-latest`; override it with
`FABRIC_CLASSIFIER_MODEL`. The request has a 20-second deadline. It uses
[TypeSafe's System One API](https://docs.typesafe.ai/api) directly, without
converting the questions into chat messages.

Both live commands print the route, typed answers, model identities and reported
usage. Credentials stay in process configuration. Missing keys, provider
failures and invalid results fail the live command. Neither command retries or
falls back to a script. A live run is accepted only when the actual provider
returns a validated answer that reaches the expected route.

## Accepted live execution

Both entry points completed against their actual providers on 2026-09-30 and
selected `publish` for the synthetic statement. OpenAI used
`gpt-4.1-nano-2025-04-14`; TypeSafe resolved `jev-latest` to `jev-1.13.0` and
returned the three typed answers. See the [completion audit and sanitized output](../../docs/implementation/graph-flow/completion-audit.md)
for observed values, usage, scope and the broader regression evidence.

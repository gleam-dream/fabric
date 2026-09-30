# Structured LLM decision consumer

This separate consumer uses a native enum to choose `publish` or `revise`.
`fabric/graph/llm` retains the structured result, original JSON and usage. The
same graph runs with scripted transport in tests or OpenAI in the live entry
point. Neither path uses a chat-agent continuation, Saga or Grind.

From the repository root, run the offline gate:

```sh
nix develop -c sh -c 'cd consumers/decision && gleam build --warnings-as-errors && gleam test'
```

The following command makes **one live OpenAI request**, using the existing
`OPENAI_API_KEY` environment variable and synthetic input `2 + 2 = 4`:

```sh
nix develop -c sh -c 'cd consumers/decision && gleam run'
```

The default requested model is `gpt-4.1-nano-2025-04-14`; override it with
`FABRIC_DECISION_MODEL`. OpenAI documents structured output support on the
[model page](https://developers.openai.com/api/docs/models/gpt-4.1-nano).
The request is bounded to 64 output tokens and 20 seconds. There are no
automatic retries. An unavailable key/provider or invalid result fails the
live command; it never falls back to a script.

Only the route, typed output, requested model and reported token counts are
printed. Credentials stay in process configuration. Tests do not read them or
contact the provider. Refused/incomplete results block this graph's acceptance
callback instead of reaching either business route.

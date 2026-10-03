# fabric_typesafe

Optional TypeSafe System One decision operations for Fabric graphs. The adapter
asks non-generative questions through the native HTTP API; it adds no chat-model
variant or dependency to Fabric core.

`question.noul` returns a yes probability. `question.choice` maps provider labels
to application-native values and retains the complete distribution.
`question.score` retains a fractional position on the authored rubric, its
levels and distribution. `question.ask` names a question; `question.combine`
batches heterogeneous answers into native tuples. Confidence is provider
concentration evidence, not a probability that the answer is correct.

```gleam
let assert Ok(correct) =
  question.noul(value.String("Is the arithmetic statement correct?"), None)
let assert Ok(questions) = question.ask("correct", correct)
let classify = fabric_typesafe.new(
  run.DefinitionId("check-arithmetic", 1),
  codec.string(),
  questions,
  fn(settings, input) {
    #(settings, fabric_typesafe.Request("jev-latest", value.String(input)))
  },
)
```

Bind the operation to any graph node and route on its typed receipt. Application
code owns thresholds and consequences. Dependent questions belong in separate
activations; questions within a batch share one state and are independent.
See the [decision consumer](../../consumers/decision/README.md), where LLM and
classifier producers use the same `publish`/`revise` routing definition.

Create live configuration with `client.new(key)` and supply it through fresh
graph context. Defaults are one 20-second request, 1 MiB request and response
bounds and 16 KiB headers. `with_bounds` and `with_endpoint` configure explicit
limits/endpoints. Remote endpoints require verified TLS; plaintext is allowed
only for explicit loopback fixtures. Redirects and retries are never automatic.
Cancellation closes local work but does not assert that inference stopped.

Local validation and proven unsent failures are definite. All failures after
dispatch, including HTTP error statuses, remain uncertain. Diagnostics expose
HTTP status and retry hints without response bodies or credentials. Ordinary
graph policy, approval and explicit reconciliation apply.

`fabric.typesafe.receipt.v1` retains exact request/response JSON, requested and
resolved models, token usage and the typed answer. Its codec restores without
I/O, checks saved questions against the deployed batch and refuses a native
value that disagrees with its protocol evidence. Saved request/response data
may contain application input; credentials remain in live configuration.
Meaning changes require an operation version change.

The [adapter contract](../../docs/implementation/graph-flow/classifier-adapter.md)
records limits, numeric tolerances and provider sources. The package gate uses a
loopback protocol fixture and does not establish actual Jev inference:

```sh
nix develop -c sh -c 'cd integrations/fabric_typesafe && gleam build --warnings-as-errors && gleam test && python3 -B -m unittest discover -s test/support -p "*_test.py"'
```

The separate consumer has an opt-in live command using `TYPESAFE_API_KEY`.
No provider key is read by offline tests. The
[live acceptance record](../../docs/implementation/graph-flow/completion-audit.md)
includes an actual Jev batch and its resolved model, typed answers and usage.

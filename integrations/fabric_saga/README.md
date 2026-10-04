# fabric_saga

A [Saga](https://github.com/gleam-dream/saga) workflow as one typed Fabric
tool. The model sees one tool; Saga orders the steps, retries them as the
workflow says, and compensates what completed when a step fails or the run
is cancelled. Fabric itself does not depend on Saga.

```gleam
import fabric/tool
import fabric_saga
import gleam/time/duration
import saga/execution

pub fn loan_tool() -> tool.Tool(Member) {
  fabric_saga.tool(
    tool.define("interlibrary_loan", "Borrow a book.", loan_codec(), delivery_codec()),
    loan_workflow(),
    execution.config(),
    // The workflow's input from the run's context, the call and the input.
    input: fn(_context, _call, loan) { loan },
    explain: fn(error) { describe_loan_error(error) },
    // A stopped loan waits this long for Saga to undo what it booked.
    rollback_within: duration.seconds(10),
  )
}
```

`consumers/app` uses it against a real Saga workflow.

## What the model sees

| Saga outcome                                                                               | Tool result                                                       |
| ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| `Completed(output)`                                                                        | the output                                                        |
| `Failed` by a typed error or a deadline, with every effect known and nothing left in place | `tool.Explain(explain(error))`: a definite failure the model sees |
| `Cancelled`, with every completed step undone                                              | a definite failure: the workflow was cancelled and undone         |
| anything else: an unknown effect, an effect left in place, a crash, a lost run             | `tool.Uncertain`, with evidence that summarizes Saga's report     |

An attempt that returned an error its step marks with `saga.unknown_when`
is an unknown effect, so a refund the provider may have taken waits for a
person instead of reaching the model as a failure it could retry. When Saga
holds a step's effects (`execution.Unresolved`, the default for such an
error, or a recovery decision's `saga.Hold(evidence)`), the evidence names
the step and renders the error with `explain`:

```text
the workflow's effects are not known: the workflow held the effects of step
refund unresolved: <explain(error)>; ... (Saga reported unresolved at refund)
```

Saga's report in the evidence names outcome kinds, actions and step
addresses only; the held error is the one typed error it renders, and only
through `explain`.

## Defaults and lifecycle

| Bound                                    | Default                                    | Change it with      |
| ---------------------------------------- | ------------------------------------------ | ------------------- |
| The tool's body                          | the agent's tool timeout (60 s)            | `tool.with_timeout` |
| Waiting for Saga's rollback once stopped | required                                   | `rollback_within`   |
| Saga's own retries, deadlines            | as the workflow and `execution.Config` say | Saga                |

Each call's Saga run carries the Fabric run's correlation
(`execution.with_correlation`), so its events join the run's, and every step
reads it from its `EffectKey` with `saga.correlation_of(key)` to pass on to
the clients it calls:

```gleam
let book_courier =
  saga.effect("book_courier", fn(loan: Loan, key) {
    courier_client
    |> http_gun.with_correlation(saga.correlation_of(key))
    |> book(loan, idempotency_key: saga.idempotency_key(key))
  })
```

The tool's `input` builds the workflow's input; it need not carry the
correlation. Cancelling the Fabric run, or any stop of
the tool's task, cancels the Saga run, which compensates the completed
steps; the stopped Fabric run waits up to `rollback_within` for that outcome
(`tool.bind_settling`). A later outcome is refused, the action stays an
uncertain effect, and Fabric observes the refusal (`settlement_refused`).

Saga checks the configuration when a call starts the workflow: one it
refuses fails that call definitely, naming every violation, and runs no
step.

## Development

The package needs the sibling checkouts `../saga`, `../json_blueprint` and
`../sinal` next to this repository. From the repository root:

```sh
nix develop -c sh -c 'cd integrations/fabric_saga && gleam build --warnings-as-errors && gleam test'
```

See [CHANGELOG.md](CHANGELOG.md).

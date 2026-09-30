# Public graph consumer

This separate package runs the production Fabric graph API. An integer
generator and a boolean reviewer share native integer state. Rejected drafts
return to the generator; the third draft is accepted. Six activations finish
the loop, while a bound of five stops before the last review.

From the Fabric repository:

```sh
nix develop -c sh -c 'cd consumers/graph && gleam build --warnings-as-errors && gleam test && gleam run'
```

`start_manual` replaces the scripted reviewer with a durable signal contract.
Its test delivers native boolean decisions through `graph.deliver`, first
requesting another draft and then accepting it. State, routes and bounds stay
the same; the graph waits as stored data between decisions.

`execute_agent` instead supplies the boolean through an ordinary managed agent.
Its versioned `fabric/graph/agent.Definition` builds a prompt from the native
revision and converts `approve`/`revise` replies into `Bool`. The same state,
routes and six-activation bound produce the same three-draft result. Every
review visit owns a separate durable agent run; this is not a blocking tool
wrapper. The model is scripted here; real provider adapters remain a later wave.

The example uses an in-memory store and scripted/manual decisions. Real restart
coverage lives in `test/fabric/graph_runtime_test.gleam` and the PostgreSQL
integration tests. The package has no Saga or Grind dependency.

`execute_batch([0, 2, 3])` maps the same six-activation review loop over three
private child states and joins `[3, 3, 4]` in input order. The map admits at most
three unsettled children and at most sixteen members. Empty input produces an
empty answer; oversized input is refused before any child starts. Public
directory-backend restart coverage for mapped work lives in
`test/fabric/graph_parallel_test.gleam`.

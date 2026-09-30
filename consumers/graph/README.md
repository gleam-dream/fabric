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

The example uses an in-memory store and scripted/manual decisions. Real restart
coverage lives in `test/fabric/graph_runtime_test.gleam` and the PostgreSQL
integration tests. The package has no Saga or Grind dependency.

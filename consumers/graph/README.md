# Public graph consumer

A separate package that runs the production Fabric graph API: an integer
generator and a boolean reviewer share native integer state, rejected drafts
return to the generator and the third draft is accepted.

```sh
nix develop -c sh -c 'cd consumers/graph && gleam build --warnings-as-errors && gleam test && gleam run'
```

- `start_manual` replaces the scripted reviewer with a durable signal contract answered through `graph.deliver`.
- `execute_agent` supplies the decision through a managed `fabric/graph/agent` definition whose typed answer is the boolean.
- `execute_batch([0, 2, 3])` maps the loop over three private child states and joins `[3, 3, 4]` in input order.

The example uses an in-memory store and scripted or manual decisions, and it
has no Saga or Grind dependency. The [design](../../docs/design/design-layer.pdf)
specifies the graph, signal and fork contracts.

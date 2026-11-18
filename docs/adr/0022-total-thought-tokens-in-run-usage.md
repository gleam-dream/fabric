# Total thought tokens in a run's usage

<a id="adr-0022"></a>

Accepted by the owner's ruling ("Add it to Fabric now"), after
`llm_wire` 0.2.0 began reporting a provider's thought count
(`message.Usage.thought_tokens`) and counting thoughts in `output_tokens` on
every built-in provider. An application that bounds a model's output saw the
limit spent without knowing how much of it was thinking: Fabric's usage held
only input and output counts, and its `llm_wire` adapter dropped the rest.

## Decision

Fabric's usage carries the thought count with the meaning `llm_wire` gave it.

- **One reply.** `model.Usage` gains `thought_tokens: Option(Int)`.
  `output_tokens` counts every generated token, thoughts included.
  `thought_tokens` is the provider's thought count where it reports one and
  `None` where it does not. `fabric/llm` copies it from `llm_wire`.
- **The run's total.** `run.TokenUsage` gains `thought_tokens: Option(Int)`:
  the sum of the counts its replies reported, and `None` until a reply reports
  one. A reply without a count adds nothing and does not reset the total.
  Fabric's rule that a missing report is never zero holds here too: a run on
  a provider that reports no thoughts is told apart from a run that thought
  zero tokens.
- **Token limits.** A token limit spends input plus output, as before.
  Thoughts are part of output, so they are spent once. The thought total is
  information about the output, never a third amount.
- **The run record.** The total is stored as an optional `"thought_tokens"`
  key inside `"usage"`, written in any writer version once the run has a
  total. A record without the key reads as a run whose thoughts were never
  reported, which is true of every record stored before this change. No record
  version was added.
- **Telemetry.** The model-turn event measures `thought_tokens` for an
  attempt whose reply reported a count, and the run-stop event carries the
  run's total (`telemetry.RunTotals.thought_tokens`). Both omit the
  measurement when nothing was reported. The model-turn measurement is the
  change in the run's total, so a reply that reported zero after an earlier
  report is measured as unreported.
- **Graph LLM receipts.** The `fabric.graph.llm.v2` receipt is unchanged. It
  stores input, output and total counts; the thought count of the provider's
  usage is not stored and a decoded receipt has none.

## Rejected alternatives

Each of the four choices below stands alone, so overruling one changes only
its part of the decision.

- **A plain `Int` total, zero when nothing was reported.** Simpler to read,
  but it makes "this provider does not report thoughts" and "this run did not
  think" the same value, against the rule the token totals already follow and
  the rule `llm_wire` kept for the count itself.
- **Record version 11.** A new version labels every write, so a node still on
  the previous release would refuse every record a new default writer stores
  (ADR 0021 describes that step for version 10). The total is additive and a
  reader that ignores it is still correct about everything else, which is how
  `"correlation"` and `"expires_at"` were added.
- **Storing the thought count in the graph LLM receipt.** Receipt objects are
  closed, so a key added to `fabric.graph.llm.v2` makes an earlier release
  refuse exactly the receipts that carry it, and a `v3` format adds a third
  reader for one number that the run record already holds for an agent run.
  What would bring a `fabric.graph.llm.v3`: an application that needs the
  thought count of a graph LLM decision from its stored receipt, since a graph
  run has no agent usage total to read it from.
- **Keeping the thought count out of telemetry.** It would leave
  `telemetry.RunTotals` unchanged now, and break its callers in a later
  release when a dashboard needs the share of output spent thinking. Adding
  the field here breaks callers once, in the release that already breaks
  `model.Usage`.

## Compatibility

Three public types gain a field, which breaks every construction that does not
name it, positional or labelled: `model.Usage`, `run.TokenUsage` and
`telemetry.RunTotals`. Code that reads them by label is unaffected. The change
needs fabric 0.4.0 together with `llm_wire` 0.2.0.

Who must change:

- **A custom model** that builds `model.Usage` adds `thought_tokens`: `None`,
  or the provider's count. dash-crm's `usage_of` in
  `src/dash_crm/agents/gemini.gleam` is one; it should pass
  `usage.thought_tokens` from `llm_wire`.
- **`fabric_postgres`**, when its requirement moves to 0.4.0: its test agents
  in `integrations/fabric_postgres/test/fabric_postgres/agents.gleam` build
  `model.Usage` positionally. Until then it compiles against the published
  0.3 release.
- **A test or projection** that builds `run.TokenUsage` or
  `telemetry.RunTotals` adds the field.
- **Dashboards and budgets** built on Gemini `output_tokens` change in value
  with `llm_wire` 0.2.0, not with this change: the figure now includes
  thoughts.

Stored data needs no migration. A node on an earlier release reads a record
that carries the key and ignores it; if that node then writes the record, the
total is dropped from that write, and later replies start a new sum.
`fabric_postgres` stores records as opaque bytes and is unaffected.

# A typed handover history that takes the tool definition and the decided value

Status: needs-triage
Category: enhancement

## What

`fabric.handover_history(snapshot, result:)` takes the decided result as
encoded content, so every caller first calls
`tool.reconciliation(definition, Ok(value))` and handles its encode error. A
typed variant taking the tool's `tool.Definition` and the decided value (or a
definite failure message) would encode it and could also check that the
handed-over call names that definition's tool.

Deferred by the owner while preparing 0.3.0; not built.

## Comments

AI-assisted contribution. Raised by the first consumer of the handover
(Oversight's `payout_desk`).

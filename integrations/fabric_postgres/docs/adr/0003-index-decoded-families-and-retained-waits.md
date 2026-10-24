# Index decoded families and retained waits without changing execution evidence

<a id="adr-0003"></a>

- Membership follows saved reciprocal attachments rather than run-id prefixes.
  Prefix deletion could miss hashed graph children or erase unrelated runs.
  Retention metadata uses actual supported agent/graph/budget decoders and
  includes the matching root ledger and every retained admitted fork member.
- A readable terminal phase alone cannot authorize deletion. Complete membership,
  matching attachment keys, definite settlement, age and lease checks govern one
  serializable pruning transaction. The immediate parent foreign key also stops
  a delayed child insert from recreating an orphan after deletion.
- Ready discovery is a hint to registered root recovery. Its versioned view
  records unfinished dependencies, interval observation or absolute due time.
  One claim saves the observed key/map/time with the lease so a concurrent child
  change remains discoverable. Stable polling keys preserve claim time across
  same-key writes and refresh rather than triggering immediate repeated polls.
- Projections carry decoder version and source revision. Old writers invalidate
  views; explicit bounded refresh reconstructs them without changing record
  bytes, revision, ownership or age. Unknown interpretations retain evidence and
  grant neither pruning nor scheduling authority.
- Evidence: retained adapter README at
  [baseline revision](https://github.com/gleam-dream/fabric/blob/ab678abe3b49b2d8dedc8b63845c35a60e6f918f/integrations/fabric_postgres/README.md),
  migrations 2–6, `internal/retention.gleam`, `internal/discovery.gleam`,
  `prune_test`, `discovery_test`, deadline/fork/graph runtime tests and parent
  retention/discovery decoders. The production/graph construction diary records
  successive rationale rather than one identifiable original decision date.

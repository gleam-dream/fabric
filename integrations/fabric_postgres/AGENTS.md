# Fabric PostgreSQL adapter instructions

- This nested package owns PostgreSQL storage and maintenance for Fabric's
  leased backend. The application owns its pog pool; parent Fabric owns
  controllers, effect fences, records, approvals, attachments and family budgets.
- Read [native design](docs/design/design.typ),
  [vocabulary](docs/design/CONTEXT.typ), [coverage](docs/COVERAGE.md) and
  [ADRs](docs/adr/) before changing storage guarantees. Parent instructions,
  skills configuration and GitHub tracker continue to apply.
- Keep the first README Gleam example synchronized byte-for-byte with
  `test/fabric_postgres/readme_example.gleam`. Keep runtime and cigogne migration
  statements synchronized under their equality check. Preserve fixture and
  license provenance when changing retained evidence.
- Use the parent `nix develop` shell. Run database tests only through
  `integrations/fabric_postgres/scripts/test-postgres.sh`; it creates and removes
  its own private cluster. Never select a production database for verification.
- From the parent repository, render the nested layer with
  `nix run .#design-gate-render -- integrations/fabric_postgres/docs/design integrations/fabric_postgres/docs/design/design-layer.pdf`.
  Check both layers with
  `nix run .#design-gate-check -- docs/design . --nested-project integrations/fabric_postgres`.
- Context commands use the parent app with the nested layer path:
  `nix run .#design-gate-context -- integrations/fabric_postgres/docs/design --estimate`.
  Verify its manifest and one selected section/digest after authoring. Run native
  layer apps sequentially because their ignored `.render` workspace is shared.
- No separate flake, issue tracker, pool or universal durability abstraction is
  introduced here. Never inspect or copy `.env.local` or credential values.

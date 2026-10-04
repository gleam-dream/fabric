# Verification

The complete local gate is `scripts/check.py`. The existing pinned Nix flake
supplies Gleam, Erlang/OTP, Rebar, Python and PostgreSQL 16. It uses the existing
sibling checkout arrangement: Fabric alongside llm_wire, json_blueprint, Sinal
and Saga. It reports a missing package before running suites.

```sh
# Local edit loop: formatting, gate checks and the core suite.
nix develop -c python3 scripts/check.py fast

# Every retained Fabric package and integration.
nix develop -c python3 scripts/check.py full

# Prepared CI profile: the same checks as full, not yet wired into CI.
nix develop -c python3 scripts/check.py ci
```

The user deferred library publication and CI activation. This change prepares
the logic, without vendoring sibling source or modifying the existing workflow.
A standalone checkout still needs those siblings. Local validation does not
claim that unpublished revisions can be fetched by a hosted runner.

Each executed check has a log under `.artifacts/check`. `results.json` records
the command, working directory, exit status and duration; `dependencies.json`
records actual local package paths and versions. A failed prerequisite
stops the gate nonzero; later checks are unexecuted, never counted as passes.
`--logs PATH` selects a separate evidence directory. Known provider credentials
are removed from the child environment, and the gate never loads `.env.local`.

## Obligations and owners

| Obligation and authority                                | Primary check                                              | Profiles                              | Evidence and limit                                                                                                      |
| ------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Formatting; AGENTS tooling                              | `nix flake check`, package `gleam format --check src test` | All                                   | Format check; does not judge prose or architecture                                                                      |
| Compiler correctness; manifests                         | `gleam build --warnings-as-errors` per package             | Core in fast; all packages in full/CI | Real compiler and FFI build                                                                                             |
| Core lifecycle and graphs; PLAN and G1–G11              | Root `gleam test`                                          | All                                   | Public behavior, recovery, policy, concurrency and oracle scenarios                                                     |
| Integrations and consumers; PLAN                        | Package `gleam test`                                       | Full/CI                               | Saga, Relay (in-process and HTTP MCP servers), TypeSafe, app, graph, decision and writing packages                      |
| Real PostgreSQL; S3–S6                                  | `integrations/fabric_postgres/scripts/test-postgres.sh`    | Full/CI                               | Temporary cluster, concurrent leases/recovery, migration and retention; ignores external PG settings                    |
| External jobs; G7/G8                                    | `consumers/jobs/test-service.sh`                           | Full/CI                               | Separate HTTP service/SQLite journal, Python and Gleam tests, cleanup                                                   |
| Classifier protocol                                     | Package Python unittest commands                           | Full/CI                               | Classifier fixture; no claim of live inference                                                                          |
| Writing application; W1–W8                              | Writing Gleam suite and `consumers/writing/test_live.py`   | Full/CI                               | Actual files/store restarts, scripted providers, frozen corpus and failure accounting; live comparison remains separate |
| Approvers recipe (warden)                               | `scripts/check.py recipe`, `consumers/approvers_warden`    | All (recipe); full/CI (package)       | README, module doc and consumer copies identical; the recipe against warden's test provider                             |
| Typed authoring; G1                                     | `experiments/graph_authoring/check.py`                     | Full/CI                               | Fresh valid consumer, rejected input/output type mismatches                                                             |
| Retained composition experiment                         | Experiment build and test                                  | Full/CI                               | Keeps retained evidence compilable                                                                                      |
| Dependency availability, coverage and failure reporting | `scripts/test_check.py`, preflight                         | All                                   | Missing siblings and unknown/missing packages fail; failed checks retain status and stop later checks                   |

No strict Python checker, static security scanner, mutation suite or general
architecture verifier is installed. Type annotations and design review remain
conventions where compiler/tests do not measure them. No scheduled credentialed
check is enabled. Live evaluation is a separate explicit command and does not
replace these deterministic tests.

## CI preparation and later activation

After publishing the required library revisions:

1. Select immutable versions in all affected package manifests and regenerate
   Gleam locks. Alternatively pin publicly accessible sibling commits in an
   explicit checkout arrangement. Verify availability first.
2. Prove a fresh standalone checkout without developer sibling directories.
3. Configure CI with checkout, the pinned Nix environment and
   `nix develop -c python3 scripts/check.py ci`. Upload `.artifacts/check/` even
   on failure. There must be no separate CI-only suite inventory.
4. Observe the actual hosted result before claiming hosted verification.

The [Nix installer action](https://github.com/cachix/install-nix-action) supports
GitHub-hosted Linux and macOS; its documented flake setup can run this command.
No publishing, deployment, secret configuration or workflow activation is part
of this verification-preparation slice.

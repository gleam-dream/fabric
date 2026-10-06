# Verification

The complete local gate is `scripts/check.py`. The existing pinned Nix flake
supplies Gleam, Erlang/OTP, Rebar, Python and PostgreSQL 16. It uses the existing
sibling checkout arrangement recorded in `sibling-revisions.txt`: Fabric
alongside http_gun, json_blueprint, llm_wire, Sinal, Saga, Relay and Warden. It reports a missing package before running suites.

```sh
# Local edit loop: formatting, gate checks and the core suite.
nix develop -c python3 scripts/check.py fast

# Every retained Fabric package and integration.
nix develop -c python3 scripts/check.py full

# Hosted CI profile: the same checks as full.
nix develop -c python3 scripts/check.py ci
```

The pull request and push workflow invokes the full profile in the pinned Nix
environment. Hosted execution requires configured read access to private siblings.
The workflow checks out immutable sibling revisions beside Fabric before running
the gate. Private sibling access uses a read-only GitHub App installation token
(`SIBLINGS_APP_CLIENT_ID`, `SIBLINGS_APP_PRIVATE_KEY`) or `SIBLINGS_READ_TOKEN` limited to
the required repositories. Credentials are confined to checkout and are not
persisted. Fork pull requests receive no sibling credential and stop with an
explicit private-source access error. Run their verification from an authorized
repository branch.

The 47-check registry covers 13 Gleam packages. Its first check runs formatting,
Ruff correctness lint, ShellCheck and actionlint. Each package build separately
runs Gleam with warnings as errors and compiles its authored Erlang in `src`
and `test` with `erlc -Werror`, generated dependency includes and `ERL_LIBS`.
Generated dependency Erlang is not relinted. Deliberate negative consumers remain
isolated with a passing control and the intended type-mismatch diagnostic.

The native design gate remains a separate job covering both layers. The final
`CI` status requires every mandatory job to succeed. Workflows retain logs on
failure; superseded runs are cancelled and every job has an explicit timeout.

Each executed check has a log under `.artifacts/check`. `results.json` records
the command, working directory, exit status and duration; `dependencies.json`
records actual local package paths, versions and Git revisions. A failed prerequisite
stops the gate nonzero; later checks are unexecuted, never counted as passes.
`--logs PATH` selects a separate evidence directory. Known provider credentials
are removed from the child environment, and the gate never loads `.env.local`.

## Obligations and owners

| Obligation and authority                                         | Primary check                                              | Profiles                              | Evidence and limit                                                                                                      |
| ---------------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Formatting; AGENTS tooling                                       | `nix flake check`, package `gleam format --check src test` | All                                   | Format check; does not judge prose or architecture                                                                      |
| Script and workflow correctness; native verification obligations | `scripts/check.py static`                                  | All                                   | Ruff correctness, ShellCheck and actionlint; no architecture or security certification                                  |
| Compiler correctness; manifests                                  | `scripts/check.py build` per package                       | Core in fast; all packages in full/CI | Real compiler and FFI build                                                                                             |
| Core lifecycle and graph design                                  | Root `gleam test`                                          | All                                   | Public behavior, recovery, policy, concurrency and oracle scenarios                                                     |
| Public integrations and consumers                                | Package `gleam test`                                       | Full/CI                               | Saga/Relay recipes, app, graph, decision, jobs, writing and approver consumers                                          |
| Real PostgreSQL backend                                          | `integrations/fabric_postgres/scripts/test-postgres.sh`    | Full/CI                               | Temporary cluster, concurrent leases/recovery, migration and retention; ignores external PG settings                    |
| Owned external jobs                                              | `consumers/jobs/test-service.sh`                           | Full/CI                               | Separate HTTP service/SQLite journal, Python and Gleam tests, cleanup                                                   |
| Classifier protocol                                              | Package Python unittest commands                           | Full/CI                               | Classifier fixture; no claim of live inference                                                                          |
| Writing application                                              | Writing Gleam suite and `consumers/writing/test_live.py`   | Full/CI                               | Actual files/store restarts, scripted providers, frozen corpus and failure accounting; live comparison remains separate |
| Approvers recipe (warden)                                        | `scripts/check.py recipe`, `consumers/approvers_warden`    | All (recipe); full/CI (package)       | README, module doc and consumer copies identical; the recipe against warden's test provider                             |
| Typed graph authoring                                            | `experiments/graph_authoring/check.py`                     | Full/CI                               | Fresh valid consumer, rejected input/output type mismatches                                                             |
| Retained composition experiment                                  | Experiment build and test                                  | Full/CI                               | Keeps retained evidence compilable                                                                                      |
| Dependency availability, coverage and failure reporting          | `scripts/test_check.py`, preflight                         | All                                   | Missing siblings and unknown/missing packages fail; failed checks retain status and stop later checks                   |

Ruff checks Python correctness; it is not a strict type checker. No static
security scanner, mutation suite or general
architecture verifier is installed. Type annotations and design review remain
conventions where compiler/tests do not measure them. No scheduled credentialed
check is enabled. Live evaluation is a separate explicit command and does not
replace these deterministic tests.

## Formatting and static tooling

The pinned flake supplies Ruff, ShellCheck and actionlint. Treefmt formats Gleam,
Nix, Prettier-supported files, authored Python and shell scripts. Ruff lint selects
syntax, import and undefined-name errors (`E4`, `E7`, `E9`, `F`). Upstream oracle captures, genuine legacy record fixtures, frozen provider/writing
evidence and generated output keep their provenance and are not rewritten
by static tooling. Native compiler warnings are checked without matching runtime
log text; deliberate fault tests may emit expected reports.

Run the tools without repair with `nix develop -c python3 scripts/check.py static`.
Run a package's warning checks from its directory with the absolute parent
`scripts/check.py build` path. The `fast`, `full` and `ci` commands remain the
authoritative profile entry points; hosted CI has no separate suite inventory.

## Measurement limits

There is no retained runtime benchmark or load/soak certificate. Check durations
measure verification execution. The writing comparison measures historical
provider-inclusive latency under its recorded limits; it is not a Fabric
performance gate. Live providers remain separate explicit commands. No scheduled
rerun is added without a distinct retained obligation.

# Source-based writing consumer

[![CI](https://github.com/gleam-dream/fabric/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/fabric/actions/workflows/ci.yml)
[![fabric on Hex](https://img.shields.io/hexpm/v/fabric?label=Hex%3A%20fabric)](https://hex.pm/packages/fabric)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A standalone application on Fabric's public graph operations:

```text
Read source → Generate draft → Review ──approve──→ Approval → Save Markdown
                  ↑             │
                  └──revise──────┘
                                └──reject──→ Finish without an artifact
```

Generation uses `fabric/graph/llm`. The reviewer uses that adapter or
`llm_wire/classify` and selects `Approve`, `Revise` or `Reject` against one
rubric. Revision is bounded to three drafts, and saving requires a durable
approval. Directory storage proves process and VM restart only.

## Offline checks

```sh
nix develop -c sh -c 'cd consumers/writing && gleam test'
nix develop -c python3 -B -m unittest discover -s consumers/writing -p test_live.py
```

The Gleam scenarios use an offline HTTP Gun script with real files and store
restarts, and the Python scenarios validate the corpus, credential loading and
failure accounting. Neither loads credentials or contacts a provider.

## Live run

Put `OPENAI_API_KEY` and `TYPESAFE_API_KEY` in the ignored root `.env.local` or
the environment. `FABRIC_DECISION_MODEL` and `FABRIC_CLASSIFIER_MODEL` select
models. The output directory must be new.

```sh
nix develop -c python3 consumers/writing/run_live.py --live --output /tmp/fabric-writing-example
nix develop -c python3 consumers/writing/run_live.py --live --mode compare --output /tmp/fabric-writing-timing
```

`--mode workflow` runs only the full application and `--mode compare` only the
paired review of the frozen corpus (24 requests). The script acts as a
demonstration operator across three VMs and is not human review.

## Manual operation

`gleam run -m fabric_writing/cli` reads the process environment, not `.env.local`.
Set `FABRIC_WRITING_REVIEWER` to `llm` or `typesafe` and:

| Setting                            | Meaning                                                                 |
| ---------------------------------- | ----------------------------------------------------------------------- |
| `FABRIC_WRITING_MODE`              | `start`, `inspect`, `approve` or `reject`                               |
| `FABRIC_WRITING_DIRECTORY`         | Directory holding the run and output artifact                           |
| `FABRIC_WRITING_ID`                | Stable run id, reused when reattaching                                  |
| `FABRIC_WRITING_SOURCE`            | Source file, required only for `start`                                  |
| `FABRIC_WRITING_BRIEF`             | Writing instructions, required only for `start`                         |
| `FABRIC_WRITING_EXPECTED_REVISION` | Revision returned by `inspect`, required for approve and reject         |
| `FABRIC_WRITING_OPERATOR`          | Who answers an approval; the terminal authenticates, default `operator` |

The [design walkthrough](../../docs/design/design-layer.pdf) specifies the flow.
[ADR 0017](../../docs/adr/0017-retain-live-provider-evidence-as-dated-sanitized-captures.md)
records dated live timings; [BENCHMARKS.md](../../docs/BENCHMARKS.md) keeps their method, rerun commands and limits.

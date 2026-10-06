# Source-based writing consumer

A standalone application using Fabric's public graph operations:

```text
Read source → Generate draft → Review ──approve──→ Approval → Save Markdown
                  ↑             │
                  └──revise──────┘
                                └──reject──→ Finish without an artifact
```

Generation uses `fabric/graph/llm`. The reviewer can use that same adapter or
`llm_wire/classify`; both select the native `Approve`, `Revise` or `Reject` value
against the same rubric. Reviewers retain their original receipt types and
provider evidence. Revision is bounded to three drafts. Saga and Grind are not
dependencies of this consumer.

The read and save operations touch real files. Saving requires a durable
approval. An artifact key combines the run and activation identities: saving
the same content again returns the same path and digest; conflicting content
is refused. Saving interrupted by process loss re-enters policy and requires
a fresh approval before bounded replay. Directory storage here proves process
and VM restart; it does not promise power-loss durability.

## Offline checks

From the repository root:

```sh
nix develop -c sh -c 'cd consumers/writing && gleam test'
nix develop -c python3 -B -m unittest discover -s consumers/writing -p test_live.py
```

The eight Gleam scenarios use an offline HTTP Gun script that answers each
exact expected generation and review request in order, with actual files and
store restarts. Any other or repeated provider request fails without network
access. They cover successful recovery, two revisions, rejection,
invalid/refused/incomplete results, missing source, conflicting saves and a
save whose result was lost. Python scenarios validate the corpus, credential
loading, measured values and failure accounting. The full repository gate
includes these checks and never loads credentials or makes live requests.

## Retained timings

On 30 September 2026 the [frozen twelve-case corpus](fixtures/cases.json) ran
once through each reviewer, alternating reviewer order without retries or
failed-case exclusions. Each case supplies source text, a brief and a draft;
the reviewer chooses approve, revise or reject using its native provider
protocol.

| Reviewer                                                     | Samples |     Median | Minimum–maximum |
| ------------------------------------------------------------ | ------: | ---------: | --------------: |
| GPT-4.1 nano (`gpt-4.1-nano-2025-04-14`)                     |      12 | 2,698.5 ms |  1,110–4,576 ms |
| TypeSafe Jev (requested `jev-latest`, resolved `jev-1.13.0`) |      12 |     465 ms |      425–506 ms |

Monotonic timing covers graph start through recorded decision, including
adapter, network and graph overhead. Each sample used a fresh VM and connection;
generation, compilation and VM startup were excluded. The LLM receipt records
the requested model; its separately resolved revision is unavailable. Runtime
versions and hardware were not recorded. These historical observations do not
establish current latency, Fabric-only overhead or production throughput.

The [raw capture](../../docs/evidence/writing-20260930.json) retains all 24
measurements, provider receipts and source-file SHA-256 values. Its corpus
SHA-256 is `1ad083bdb7a6dd4898de7b4e6577c8e40023aefd4c90dada21977b58be18a207`.
[ADR 0012](../../docs/adr/0012-keep-review-producers-interchangeable.md) links
the original comparison at Fabric revision
`ab678abe3b49b2d8dedc8b63845c35a60e6f918f` and describes the separate review-quality
result. Typed decisions and label matches are not performance measurements.

To rerun the workload with configured credentials, use a new output directory:

```sh
nix develop -c python3 consumers/writing/run_live.py \
  --live --mode compare --output /tmp/fabric-writing-timing
```

This makes 24 live provider requests using the current adapters. A rerun can
resolve different provider versions and is a new measurement, not a recreation
of the historical provider environment.

## Explicit live run

Put `OPENAI_API_KEY` and `TYPESAFE_API_KEY` in the ignored root `.env.local`, or
in the environment. Optional `FABRIC_DECISION_MODEL` and
`FABRIC_CLASSIFIER_MODEL` select models; defaults are
`gpt-4.1-nano-2025-04-14` and `jev-latest`. The script reads only these four
dotenv names as data, without executing shell expressions. Nonempty environment
values take precedence; empty values fall back to the file.

```sh
nix develop -c python3 consumers/writing/run_live.py \
  --live --output /tmp/fabric-writing-example
```

The output directory must be new. `--mode compare` runs only the paired review;
`--mode workflow` runs only the complete application. The default is both.
Comparison sends 24 requests: one per reviewer for each of the 12 frozen cases.
It alternates reviewer order, excludes generation and process startup from
decision timing, and retains failures without automatic retry. Expected labels
and rationales are never sent to providers. Full workflows allow at most six
generation/review requests per reviewer configuration. Token limits are 300
for generation and 64 for LLM review; provider calls have a 20-second deadline.

Each full workflow stops at approval, exits the VM, reattaches in another VM,
checks that state and receipts match, and approves through the public API in
a third VM. The script acts as a **demonstration operator**; it is not human
review. It verifies the saved file's SHA-256 and that earlier model receipts
did not change. Evidence includes requests, raw receipts, requested/resolved
models where available, usage, elapsed time, the confusion matrix and artifacts.
Billing is left unknown; the retained report explains any dated price estimate.

For manual operation, run `gleam run -m fabric_writing/cli` inside this package
with `FABRIC_WRITING_REVIEWER` set to `llm` or `typesafe` and:

| Setting                            | Meaning                                                                                                                  |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `FABRIC_WRITING_MODE`              | `start`, `inspect`, `approve` or `reject`                                                                                |
| `FABRIC_WRITING_DIRECTORY`         | Directory holding the run and output artifact                                                                            |
| `FABRIC_WRITING_ID`                | Stable run ID, reused when reattaching                                                                                   |
| `FABRIC_WRITING_SOURCE`            | Source file, required only for `start`                                                                                   |
| `FABRIC_WRITING_BRIEF`             | Writing instructions, required only for `start`                                                                          |
| `FABRIC_WRITING_EXPECTED_REVISION` | Revision returned by `inspect`, required for approve/reject                                                              |
| `FABRIC_WRITING_OPERATOR`          | Who answers an approval (default `operator`); the terminal is the authentication, so the CLI's approvers accept any name |

The manual entry point reads the process environment, not `.env.local`.
Inspect the draft before sending its revision back with an approval. A changed
revision is refused. Restore with the same compatible graph and operation
definitions. The application uses controlled source/output paths and UTF-8
source files of at most 16 KiB.

See the [native walkthrough](../../docs/design/design.typ#end-to-end-walkthrough)
and [scoped comparison rationale](../../docs/adr/0012-keep-review-producers-interchangeable.md).

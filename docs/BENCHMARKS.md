# Fabric retained measurements

Fabric has no runtime benchmark or load harness. The only measurements it
retains are dated live-provider observations, taken by explicit commands that
the gate never runs. They are observational: no threshold depends on them and
none is a performance claim.

This is one of two retained references. [ORACLE.md](ORACLE.md) records what is
compared against upstream behavior. The design states the rules in its
[verification section](design/design.typ#verification-and-extension-obligations),
[ADR 0017](adr/0017-retain-live-provider-evidence-as-dated-sanitized-captures.md)
records the decision to retain these captures, and
[AGENTS.md](../AGENTS.md#references) lists both references.

## Scope

- **Decision adapters** (`consumers/decision`): one OpenAI structured-output
  request and one TypeSafe classification request, each with a 20-second deadline.
- **Paired review** (`consumers/writing`): the frozen twelve-case corpus
  ([`fixtures/cases.json`](../consumers/writing/fixtures/cases.json)) through each
  reviewer. Each case supplies source text, a brief and a draft; the reviewer
  chooses approve, revise or reject with its native provider protocol.

## Method

- Each reviewer ran each case once, alternating reviewer order, without retries
  or failed-case exclusions. Expected labels and rationales are never sent to a
  provider.
- Monotonic time covers graph start through the recorded decision, including
  adapter, network and graph overhead. Each sample used a fresh VM and
  connection; generation, compilation and VM startup are excluded.
- Failures are retained, not retried. Billing is left unknown.

## Run

Live commands make real requests. Put `OPENAI_API_KEY` and `TYPESAFE_API_KEY` in
the environment or the ignored root `.env.local`; the script reads only those
names (and optional `FABRIC_DECISION_MODEL` and `FABRIC_CLASSIFIER_MODEL`) as
data. The output directory must be new.

```sh
# the decision adapters, one request each
nix develop -c sh -c 'cd consumers/decision && gleam run'
nix develop -c sh -c 'cd consumers/decision && gleam run -m fabric_decision_classifier'

# the paired review comparison: 24 requests
nix develop -c python3 consumers/writing/run_live.py \
  --live --mode compare --output /tmp/fabric-writing-timing
```

A rerun can resolve different provider versions, so it is a new measurement and
not a recreation of the historical environment.

## Retained results

Taken on 30 September 2026. Raw data: [`evidence/writing-20260930.json`](evidence/writing-20260930.json)
(all 24 measurements, provider receipts and source-file SHA-256 values; corpus
SHA-256 `1ad083bdb7a6dd4898de7b4e6577c8e40023aefd4c90dada21977b58be18a207`) and
[`evidence/live-adapters-2026-09-30.txt`](evidence/live-adapters-2026-09-30.txt).

| Reviewer                                                     | Samples |     Median | Minimum–maximum |
| ------------------------------------------------------------ | ------: | ---------: | --------------: |
| GPT-4.1 nano (`gpt-4.1-nano-2025-04-14`)                     |      12 | 2,698.5 ms |  1,110–4,576 ms |
| TypeSafe Jev (requested `jev-latest`, resolved `jev-1.13.0`) |      12 |     465 ms |      425–506 ms |

Both decision entry points also completed on that date and selected `publish`
for a synthetic statement; the capture keeps the observed values and usage.

## Limits

- These are historical observations. They establish neither current latency,
  Fabric-only overhead nor production throughput.
- Runtime versions and hardware were not recorded, and the LLM receipt records
  only the requested model, not its resolved revision.
- Typed decisions and label matches are not performance measurements. Review
  quality is judged separately in
  [ADR 0012](adr/0012-keep-review-producers-interchangeable.md); the original
  comparison is retrievable at Fabric revision
  `ab678abe3b49b2d8dedc8b63845c35a60e6f918f`.

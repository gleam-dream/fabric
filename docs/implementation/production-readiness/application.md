# Application evidence: source-based writing

This is wave 3 of the [accepted program](wave-tracker.md), implemented as a
separate public consumer in `consumers/writing`. It exercises the existing
Fabric graph and adapters without adding a core dependency or changing runtime
ownership. Publication in this example means saving a local Markdown artifact;
it does not deploy a website or send a message.

## Behavior and boundaries

- **W1 — real tools:** read the supplied source file through a graph operation,
  retain its content, and generate a draft from that source and the writing
  brief. Save an approved draft through a real filesystem operation that returns
  a path and SHA-256 receipt. The example uses application-controlled paths and
  synthetic public fixtures; it is not an untrusted file hosting service.
- **W2 — native decisions:** both reviewers consume the exact source, brief and
  draft and produce `Approve`, `Revise` or `Reject`. Approve means faithful and
  complete against the brief; Revise means the source supports the brief but
  the draft needs correction; Reject means the source cannot support the brief.
  These criteria are fixed before live measurement. Raw adapter receipts remain
  stored beside the selected route; confidence is not measured accuracy.
- **W3 — bounded revision:** generate at most three drafts (initial plus two
  revisions). Revise returns to generation with the retained previous draft.
  Reject and revision exhaustion finish explicitly without publishing. An
  invalid/refused/incomplete provider result cannot select a successful route.
  No implicit provider retries or scripted fallback are allowed in live runs.
- **W4 — approval:** saving the artifact requires the runtime's durable approval
  request. Withholding or rejecting it creates no artifact. Approval uses the
  saved reference and the policy gate; an identical repeated answer cannot
  create another file. Test and demonstration approval is explicitly supplied
  through the public API, never represented as an actual person's decision.
- **W5 — recovery:** restart at the approval wait, reattach the same run and
  observe the same draft, generation/review receipts and approval. Approving
  afterward must not call either provider again. The filesystem's stable
  run/activation key accepts identical content once and refuses conflicting
  content. This permits explicitly bounded interrupted replay of that save;
  it does not give provider operations a replay contract. An interrupted save
  re-enters policy and may require a fresh approval; its earlier approval does
  not outlive the admitted attempt. Directory persistence
  proves process/VM restart here, not power-loss durability.
- **W6 — failure evidence:** exercise invalid provider output, a rejected
  approval, the revision bound, absent source, conflicting artifact, and a
  saved artifact whose graph result was lost. Preserve uncertainty when effect
  completion cannot be confirmed. Core failure/recovery suites remain the
  runtime oracle; this consumer proves its own use of those boundaries.
- **W7 — fair live comparison:** freeze a balanced, labeled synthetic corpus
  before execution and run both actual review operations once per case through
  the same evaluation graph. Only the decision producer/receipt codec varies.
  Compare label accuracy, confusion counts, invalid/failure counts, elapsed
  decision time and reported token usage. Keep generation outside the paired
  decision timing, and separately exercise the full live writing flow.
- **W8 — reproducible evidence:** live execution is explicit and bounded, uses
  ignored local credentials, and retains sanitized input, expected/actual label,
  requested/resolved model, original provider receipt, usage and elapsed time.
  Missing usage or unavailable pricing is explicit. Cost estimates name their
  dated official price source; measured billing is never inferred. Report sample
  size and concrete authoring friction, without claiming a general benchmark.

The core model has a loading state and working stages for generation, review
and publication. The application owns source/brief/draft data and revision
counts. Graph receipts own completed operations and chosen routes. Live context
owns provider credentials and the output directory; no credentials are encoded.
The generator and reviewer are existing typed graph operations. Filesystem
operations remain application tools with declared error/recovery contracts.

Offline tests inject llm_wire scripted responses and explicit test reviewers;
they still read/write real temporary files and restart the real store. These
substitutions exercise routes and failure paths, not provider intelligence.
Acceptance also requires actual generation and both live review adapters.

## Verification and acceptance

The first scenario is source read → generated draft → accepted review → approval
wait → store restart → approval → one artifact, with no repeated provider work.
Additional scenarios cover W2–W6 refusals and revision bounds. Add this retained
consumer to `scripts/check.py` and run the complete local gate after implementation.
Live measurement is separate from that credential-free gate.

Current status: implementation and live evidence are complete. Eight Gleam
scenarios exercise W1–W6; seven Python scenarios cover the live evidence
boundary. The [comparison report](writing-comparison.md) and retained receipts
cover W7–W8, including both actual providers and separate-VM recovery. The
final complete local gate passed all 45 checks after the credential-loader
regression fix. The [wave tracker](wave-tracker.md) records acceptance and the
whole-goal audit.
No hosted CI, library publication, deployment, new service or Saga/Grind adoption
belongs to this wave. Normal implementation refinement is authorized by the
accepted program; incompatible changes to its outcomes require a new decision.

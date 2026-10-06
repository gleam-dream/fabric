# Native formats and lifecycle refinements preserve earlier evidence

<a id="adr-0010"></a>

The captured Fabric CHANGELOG has one Unreleased section and no published
release section. Its construction diary is condensed into current capability
notes. This record captures material compatibility and lifecycle rationale;
the exact former signatures remain in Git history rather than a second current
API specification. Decisions on typed construction, approval authority and
ports remain in ADRs 0003–0004.

Typed answers preserve the caller's native codec. Existing text completions
remain readable under the plain agent and under compatible typed codecs. Invalid
answers retain their raw value and reason. A corrective answer is an actual
model attempt with normal token/turn charges and persisted conversation, not a
parser retry outside the run. Provider object-root restrictions are handled by
the llm_wire adapter's wrapper without changing the stored native answer JSON.
The diary does not establish acceptance of every JSON Schema feature.

One package vocabulary replaced separate graph policy, timeout, failure and
command conventions. Opaque Specs retain settings until build reports all
configuration problems. Internal representation helpers moved to internal
modules so external consumers cannot forge runtime identities through public
constructors. Renamed paths and unpublished before/after examples are historical
surface changes, not additional supported public aliases.

Stored approval deadlines use the store clock. Earlier requests and waits
without a deadline retain none; reading them never invents a seven-day expiry.
Graph version 15 adds correlation, roots and approval evidence while retaining
version 5–14 reads. Agent readers retain string reviewers, typed reviewers,
missing verifier/deadline/replay fields and earlier model failure representations
through genuine fixtures. Writer selection is distinct from reader compatibility.
Approver Proof later replaced a caller-constructed Reviewer as answer authority;
the retained audit identity remains separate from the proof's issuing instance.

Records written before exact roots require a bounded walk of at most 64 parent
links. A complete walk produces the exact root saved at the next commit. Missing,
unreadable, cyclic or overlong ancestry produces a reported topmost-readable
fallback, never a persisted exact root; an unavailable store fails the read.
Closing ancestry before child admission produces a never-started cancellation,
not a fabricated policy fault. These refinements distinguish ownership loss
from application authorization failure.

Store and sweeper script lifetimes follow their caller, including normal exit.
The keeper waits for the store subtree to stop before its name can be reused.
Supervised sweeper construction owns the ordered store and sweeper subtree.
Shutdown counts processes still delivering completion observations even after
active ownership reaches zero. Readiness runner counts therefore cannot stand
in for a completed drain. Nested graph binding retains callback environments
once; that storage optimization did not replace deadlines or child contracts.

LLM content-filter outcomes map to refusal rather than retryable host failure.
Provider replay JSON moved to llm_wire's own turn encoding under the retained
tag; historical exact request bytes remain fixture evidence. New encodings were
not claimed readable by every older writer. Structured decision receipts write
the native v2 envelope while reading genuine v1 nested arrays. Fork result codec
construction changes retained its tagged JSON. Cassette conversion preserved
headers and response bytes while moving to the owning HTTP Gun schema.

Round 9 subsequently retired the bridge packages, framed composite invocation
keys, preserved native answers and unresolved effects through cancellation, and
separated fixed classification receipt bounds from fresh live settings. ADRs
0003, 0005–0007 record those semantics and their remaining defect. Mechanical
sibling revision refreshes, test executable lookup, check counts and formatting
diary entries do not create additional architecture decisions.

Provenance: Fabric CHANGELOG and current source at
`ab678abe3b49b2d8dedc8b63845c35a60e6f918f`; exact-byte fixtures under
`test/fixtures`, `llm_turn_format_test`, graph LLM receipt/record, record/root,
ancestry, approval, drain and public consumer tests. Individual original dates
are not inferred from unlabeled diary headings. This consolidation was authored
on 6 October 2026 under the documentation migration authorization; it changes
no runtime behavior or persisted bytes.

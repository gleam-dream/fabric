# Bind a proof to the request it answers

<a id="adr-0024"></a>

Accepted by the owner's ruling. It replaces the part of
[ADR 4](0004-typed-construction-bounds-and-proof-approval.md) that checks a
proof against the answered request's requirement only.

A proof was made by `approvers.check(approvers, credential, requirement)`.
The verifier saw the credential and the requirement, never the run, and an
answer accepted the proof for any pending request with an equal requirement
during the proof lifetime. In a multi-tenant application whose requirement
is named `"manager"`, a manager of tenant A could answer a request of tenant
B's run: the verifier authorized "may answer manager requests", and nothing
in the API made the separate "may this caller see that run" check hard to
forget. The store's commit made each request answerable once, so this was a
confused-deputy exposure, not a forgery.

## Decision

- A proof is checked for one request reference: `approvers.check` takes an
  agent request's `run.ApprovalRef`, and `graph.check_approval` a graph
  request's `graph.ApprovalRef`. The proof records that reference.
- An answer accepts a proof only for exactly that reference (run, action or
  activation and attempt, requirement and revision); any other is refused
  with `OtherRequest`, which replaces `OtherRequirement`.
- `verify` receives an `approvers.Request` with the run and the
  requirement, so the verifier itself can refuse a credential for a run
  outside its tenant.

## Rejected alternatives

- **A deprecated `check` that takes a requirement.** It would keep the
  exposure available, and the ecosystem is not yet in production.
- **One generic reference type for agents and graphs.** It would rename the
  identity fields of both references, which applications serialize, for no
  gain over two checking functions next to the two answering modules.
- **Passing the whole pending request to `verify`.** The run and the
  requirement are what authorization needs; the action's arguments are
  application data the application can read from the snapshot.

# Treat the record store as a trust boundary and recheck queued work

<a id="adr-0020"></a>

Accepted 2026-11-03 after a security review. Run records are unsigned JSON.
Decoding validates shape, versions and links, and loading checks that pending
tools are registered and their arguments decode. Nothing binds a stored
action state to the policy decision that produced it. An agent record edited
to hold a `queued` tool call, or an `awaiting_approval` action flipped to
`queued`, ran that tool on the next recovery with no policy decision and no
approver. Agent recovery also dispatched genuinely queued actions under the
decision made before the runner was lost, with a context that may since have
changed, whereas graph recovery already returned unfenced queued work to
policy inspection.

Fabric does not sign records. Whoever can write the backend (the directory's
files, a database role with update rights on the run table) is trusted as
the database is: it can also rewrite results, transcripts and approvals.
Applications protect the store with file permissions, database roles and
encryption at rest as they protect their other data.

Agent recovery now re-runs the policy gate, with the recovering context, for
every queued action that no answer approved, matching the graph runtime.
Allowed work stays queued and runs; a denial, unknown tool or malformed
argument becomes that action's model-visible state as a fresh request's
would; a required approval issues a new request. Queued actions that an
answer approved keep their earlier rule: they ask for the same approval
again, and the answer rechecks the policy. Actions that passed are not given
a new approval requirement the policy does not ask for.

The recheck limits what an edited record can make Fabric do; it does not
make the store an authorization boundary. A delegated child that is missing
at recovery is still started from the stored call, and stored results are
still shown to the model.

Rejected for this change: an HMAC over each record with an application key,
verified on every load. It needs key distribution and rotation for every
backend and node, and would not protect a store whose writer also holds the
key.

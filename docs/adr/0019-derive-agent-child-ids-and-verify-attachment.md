# Derive agent child ids and verify reciprocal attachment

<a id="adr-0019"></a>

Accepted 2026-11-03 after a security review. An agent delegation named its
child run by the parent's id, a hyphen and a sequence number. That text is
an ordinary caller-chosen RunId: `run.id_from_parts("job", ["42", "1"])` or
`parse_id("job-42-1")` names the first child of root `job-42`. A start that
found a record under the reserved id adopted it, recovery reattached it,
cancellation cancelled it and a lookup through the parent reached it without
checking that the record named the delegation as its parent. A parent could
receive an unrelated run's answer, drive it under the child agent or cancel
it.

Agent record version 9 derives the child id from a domain-separated SHA-256
of the parent run id and the delegating ActionId, prefixed `agent-`, as graph
children and fork members already do. Writers 2–8 keep numbered ids, because
their readers require them, and every reader still accepts numbered ids. A
version 9 record can hold both forms for delegations started before and after
a writer change; stored ids are never rewritten.

Derivation removes accidental aliasing; it is not a secret. Anyone who knows
the parent id and the provider call id can compute the child id and store a
run there first. The enforced rule is therefore reciprocal attachment: a
record under a child id counts as the child only when its parent link names
exactly that parent run and action, and the parent's record names that child
on that action. Adoption after a lost start, recovery reattachment, stopping
cleanup and cancellation, including any command sent through the child's
setup, refuse any other record, and the delegation records the refusal as
lost child evidence, so it becomes an uncertain effect for the application
to reconcile. Lookup through the parent (`fabric.child` and the routing of
approvals, rejections and reconciliations to a descendant) walks the
child's parent links upward and reaches no other record. Family reads
(status, await, pending approvals, snapshots) treat such a record as an
unreadable child: none of its approvals, arguments or status are reported
as the family's, and the family waits for recovery to settle the
delegation. A pre-created foreign run can block a delegation; it cannot
answer, run under or be cancelled by it.

Rejected: a reserved caller-id prefix refused by `parse_id`, which would break
applications that already use such ids and still leave numbered ids for older
writers; random child ids, which need an effectful source inside the pure
controller and would not remove the need for the attachment check.

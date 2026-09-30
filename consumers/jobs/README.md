# External job submission

This consumer submits an artifact job through a normal fenced Fabric graph
operation. Its graph answer is a typed **acceptance receipt**. A separate
service owns the queued work, produces an uppercase text artifact and retains
its SHA-256 digest. Business completion is observed separately from graph
completion.

Run from the repository root:

```sh
nix develop -c consumers/jobs/test-service.sh
```

The script starts a loopback-only HTTP service in a separate Python process,
uses a temporary SQLite journal and artifact directory, runs the Gleam consumer
scenarios, and cleans up. It also verifies that the job service can restart over
its own retained journal. Python and Erlang/OTP are already supplied by the
development shell; no Fabric dependency or external account is added.

The application supplies the typed submission callback:

```gleam
let runtime = fabric_jobs_demo.runtime(
  runs,
  fn(invocation, request) {
    client.submit(service_url, invocation, request)
  },
  operation.ReplayInterrupted(3),
)
```

The service key is the pair of graph run ID and activation. The attempt number
is excluded, so recovery of an interrupted submission finds the same job.
Every new visit has a different activation. The service atomically binds the
key to its input and receipt; a duplicate with different input is refused.

Enable `ReplayInterrupted` only when the service makes that promise. A returned
transport error is classified as an uncertain effect and still needs explicit
resolution. A service that cannot deduplicate or look up acceptance must use
`RequireReconciliation`. A stopped Fabric process does not cancel the external
job; this example submits detached work and owns no remote cancellation rights.

The scenarios prove:

- a graph can finish with a receipt while the job is still queued;
- losing Fabric after acceptance but before recording the receipt recovers the
  same receipt through safe interrupted replay;
- a saved receipt survives restart without another submit;
- unsafe replay stays blocked until explicit receipt reconciliation;
- concurrent duplicate submissions produce one job and one receipt;
- queued jobs and completed artifacts survive the job service's own restart.

Fabric's directory store proves store-process recovery, not power-loss safety.
The service writes and syncs its deterministic artifact before committing the
completion in SQLite. If that completion commit is lost, it may safely write
that same artifact again. This guarantee belongs to this example service; it
is not a general exactly-once effect guarantee.

Managed job attachment remains open: retaining a receipt as an active graph
wait, automatically observing completion, cancellation ownership and durable
deadlines still need runtime support. This consumer establishes the real
submission boundary that those features will use. Saga and Grind remain
optional consumer integrations.

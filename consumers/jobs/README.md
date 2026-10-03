# External job submission, observation and cancellation

This consumer submits an artifact job through a normal fenced Fabric graph
operation. Its graph answer is a typed **acceptance receipt**. A separate
service owns the queued work, produces an uppercase text artifact and retains
its SHA-256 digest. Business completion is observed separately from graph
completion.

`fabric_jobs_demo.waiting_runtime` adds a second node that retains the receipt
and waits for business completion. It binds `job.observe` through
`operation.await_job`; `graph.poll_job(handle, reference)` checks the service
once using the reference from `graph.AwaitingJob`. Pending observations leave
the record unchanged. A completed digest and the graph's route commit together.
The wait holds neither a runner nor a lease. Canceling this read-only binding
records `graph.JobDetached` and leaves the independently owned job running.

`fabric_jobs_demo.scheduled_runtime` opts into a 100 ms observation interval.
Register it with `sweeper.graph` in `sweeper.supervised` on a leased store. Its
first observation is immediately eligible; subsequent ready claims use the
backend's saved claim time and clock. The restarted sweeper example waits for
the real service artifact without calling `graph.poll_job`. Its test backend
survives store-process loss in the same VM; PostgreSQL scheduling and restart
are exercised separately by the integration package.

`fabric_jobs_demo.cancellation_runtime` explicitly requests cancellation and
waits for terminal evidence. The request is an ordinary policy-gated, fenced
operation. Its typed acknowledgment means the service accepted the stop; a
separate observation confirms `Stopped`. If completion won first, the workflow
returns `Finished(digest)` and preserves the artifact. The service deduplicates
stop requests by receipt, so a lost acknowledgment can use interrupted replay.
Returned transport uncertainty still needs reconciliation. Restarting Fabric
after a saved acknowledgment observes the outcome without requesting again.
This workflow establishes the independently usable request/observation boundary;
`graph.cancel` on a read-only job wait still only detaches observation.

`fabric_jobs_demo.owned_runtime` submits and retains an owned job wait through
`operation.own_job`. Its `OwnedJob` policy action admits cancellation authority.
`graph.cancel` then commits intent and starts a fenced stop request. A saved
`RequestAccepted` acknowledgment releases the runner and lease while the job
remains `CancellingJob`. Manual polling or the registered sweeper observes its
terminal outcome. Confirmed cancellation reports `JobStopped`; completion that
won remotely retains its digest with a canceled route. Neither resumes the graph.
An interrupted request stays uncertain and is resolved through observation,
without automatically repeating the request. The consumer exercises saved and
lost acknowledgments across Fabric restart against the real service.

`fabric_jobs_demo.deadline_runtime` bounds that owned wait with
`operation.with_deadline`. A restarted sweeper records expiration and requests
a stop using the existing ownership grant. It reports
`Expired(due, JobStopped(reference))` only after the service confirms cancellation.
A lost stop acknowledgment remains uncertain until observation settles it;
the request is not repeated. The retained cause distinguishes expiration from
caller-requested cancellation. The controlled test clock advances deadline and
lease eligibility; the separate HTTP service uses its own real clock and journal.

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
job. The submission and read-only observation runtimes use detached work;
cancellation requires the explicit cancellation workflow or an admitted owned
binding. Losing the Fabric process alone never means that remote work stopped.

The scenarios prove:

- a graph can finish with a receipt while the job is still queued;
- losing Fabric after acceptance but before recording the receipt recovers the
  same receipt through safe interrupted replay;
- a saved receipt survives restart without another submit;
- unsafe replay stays blocked until explicit receipt reconciliation;
- concurrent duplicate submissions produce one job and one receipt;
- queued jobs and completed artifacts survive the job service's own restart;
- a retained job wait reconnects after Fabric restart without resubmission;
- detaching observation leaves the real remote job to complete independently;
- a restarted registered sweeper observes real completion without resubmission
  or manual polling;
- stop requests require policy admission, and saved acknowledgments survive
  Fabric restart without another request;
- lost acknowledgments replay only under the service's idempotency guarantee;
- returned uncertainty and unsafe replay remain blocked until reconciliation;
- cancellation and artifact publication have one winner, retained across
  service restart; malformed requests leave the job unchanged;
- upgrading the service journal preserves previously accepted jobs;
- owned cancellation retains its request state across restart and resolves an
  interrupted request by observing the real service without replay;
- completion after local cancellation retains its digest and artifact without
  routing success.

Fabric's directory store proves store-process recovery, not power-loss safety.
The service writes and syncs its deterministic artifact before committing the
completion in SQLite. If that completion commit is lost, it may safely write
that same artifact again. Stop admission and publication share a database
transaction lock. Cancellation removes any unpublished residue before recording
its terminal outcome. These guarantees belong to this example service; they
are not a general exactly-once effect guarantee.

Manual observation works with any store; scheduled observation and automatic
deadline recovery need a leased backend and sweeper. Unleased deadlines require
explicit recovery or polling.
Saga and Grind remain optional consumer integrations.

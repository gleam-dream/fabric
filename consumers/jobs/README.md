# External job consumer

Submits an artifact job through a fenced Fabric graph operation and observes,
cancels and expires it against a separate HTTP service with its own SQLite
journal. The graph answer is a typed acceptance receipt, and business
completion is observed separately.

```sh
nix develop -c consumers/jobs/test-service.sh
```

The script starts a loopback-only service in a Python process, runs the Gleam
scenarios against it with a temporary journal and artifact directory, verifies
that the service restarts over its own journal, and cleans up. No external
account is needed.

| Runtime in `fabric_jobs_demo` | Shows                                                                               |
| ----------------------------- | ----------------------------------------------------------------------------------- |
| `runtime`                     | Submission with an application callback and an explicit replay contract.            |
| `waiting_runtime`             | A read-only observation wait, completed by `graph.poll_job` and detached on cancel. |
| `scheduled_runtime`           | Interval observation by a registered sweeper on a leased store.                     |
| `cancellation_runtime`        | An explicit stop request followed by observation of terminal evidence.              |
| `owned_runtime`               | An owned job whose cancellation authority is admitted by policy.                    |
| `deadline_runtime`            | An owned wait that expires and requests a stop under its existing grant.            |

The service key is the pair of graph run id and activation, never the attempt,
so recovery of an interrupted submission finds the same job. The service is
an example and gives no general exactly-once guarantee. The
[design](../../docs/design/design-layer.pdf) specifies the job, cancellation and
deadline contracts.

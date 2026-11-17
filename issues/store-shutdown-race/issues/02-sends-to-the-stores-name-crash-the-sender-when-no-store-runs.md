# Sends to the store's name crash the sender when no store runs

Status: needs-triage
Category: bug

## What

Seven functions in `src/fabric/internal/store.gleam` send a message to the
store without waiting for an answer: `draining`, `handoff_failed`,
`release_job_observation`, `unwatch`, `with_backend_timeout`, `renew_now` and
`tick_now`. Each sends through `target(store)`. For a store that is not pinned
to one process, `target` is the named subject of the store's name, and
`process.send` to a named subject asserts that the name is registered. When no
process holds the name, the sender crashes with "Sending to unregistered
name".

This is not the two-step shape of issue 01: these functions do not look the
name up first. The sender crashes whenever the store is not running, not only
in a short window.

## Evidence

Read from the code on the branch that fixes issue 01; no run shows it.

- `unwatch` is called when an application stops waiting for a run: in `wait`
  in `src/fabric.gleam` (the `done` function) and at the end of the graph
  await in `src/fabric/graph.gleam`. Both pass the store of the run's setup
  or of the graph runtime.
- The same `wait` already treats a store that stops during the wait as an
  outcome: "A store call that failed because the process stopped under it is
  the stop, not an outcome." It then calls `unwatch` on its way out.
- `src/fabric/internal/runner.gleam` also calls `unwatch`, with the runner's
  store.

## Not established

- Whether the stores these callers hold are pinned. A pinned store sends to a
  subject, which never crashes the sender. The audit for issue 01 read the
  application's stores as not pinned; that reading has not been checked by a
  run.
- Whether any caller of the other six functions can run while no store holds
  the name.

## Consequence

If the reading holds, an application process that waits for a run crashes when
the store stops during the wait, where the design of the wait is to return the
stop as an outcome.

## Acceptance

- A test shows whether an application's await crashes when its store stops
  during the wait. If it does not, this issue is closed as `wontfix` with the
  reason.
- If it does, no function of the list crashes its sender when the store is
  not running, and the await returns the stop.
- Each of the seven functions is listed here with the result.

## Comments

AI-assisted contribution. Found by the audit that issue 01 asked for. The fix
of issue 01 added `send_as_named`, which sends to a process already looked up;
these functions have no process in hand, so that fix does not cover them.

# The store's sentinel can crash while the store shuts down

## Problem

When a script-owned store stops because its starter exited, the store's
sentinel sometimes crashes with "Sending to unregistered name" and the VM logs
a crash report. The store still stops and every test still passes, so the only
symptom is the report. A reader of a gate log cannot tell it from a defect in
the change under test.

## Outcome

- The sentinel ends with its supervisor's exit reason whether or not the
  store's process is still registered when it wakes.
- A shutdown started by the starter's exit logs no crash report.

## Issues

- `issues/01-the-sentinel-sends-to-a-name-that-is-gone.md`: the race, its
  evidence and what a fix must show. Done.
- `issues/02-sends-to-the-stores-name-crash-the-sender-when-no-store-runs.md`:
  seven sends that crashed their sender when no store ran at all, found by
  the audit of issue 01. Reproduced through both public awaits. Done.

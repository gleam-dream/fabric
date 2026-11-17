# `await_or_shutdown` takes a gleam_erlang subject apart

Status: done
Category: enhancement

## What

`await_or_shutdown` in `src/fabric_ffi.erl` waits for the answer of the
helper that starts a runner, or for the exit signal `shutdown` from the
runner factory, whichever comes first. Its first argument is a gleam_erlang
`Subject`, which it matches as `{subject, _Owner, Tag}` to receive
`{Tag, Message}`. `Subject` is an opaque type. gleam_erlang 1.3.0 changed the
type of the tag; the match survived because the tuple kept three elements.

The wait has to stay an Erlang `receive`: a Gleam selector can take every
trapped exit, but not the exit of one sender only.

## Evidence

One instrumented run of the core suite on `f8583c7`: `await_or_shutdown`
returned an answer 1,370 times, timed out twice, and returned the shutdown 0
times. No test reaches the shutdown branch.

## Options considered

- A reply channel of Fabric's own: a reference and its owner, sent to and
  received from in `fabric_ffi`. Chosen: the behaviour is unchanged.
- Polling in Gleam: check for the shutdown, wait 10 ms for the answer,
  repeat. It sees a shutdown up to 10 ms later.
- A selector that takes every trapped exit and sends the others back. It
  reorders exit messages.

## Acceptance

- A test reaches the shutdown branch of `await_or_shutdown`: a start that is
  waiting when the factory's shutdown arrives is given up, and the shutdown
  is still queued for the caller afterwards. It passes before and after the
  change.
- `await_or_shutdown` no longer matches on a `Subject`.

## Comments

AI-assisted contribution. Filed from the same exploration as issue 01. The
three options passed the core suite in a copy of the repository, which says
nothing about the shutdown branch, for the reason under Evidence.

AI-assisted contribution. Done, in two steps.

The test first: `a_start_waiting_at_the_factorys_shutdown_is_given_up_test`
in `test/fabric/runner_host_test.gleam` calls `runner_host.prepare` with a
process that reports ready only when the test lets it, and delivers the
factory's exit signal 20 ms into the wait. It asserts that `prepare` returns
`Error`, that the shutdown is still queued for the caller, and that the
prepared process is told to abandon. It passed on the code before the change.
With the shutdown clause removed from `await_or_shutdown`, it times out in
`await_start`, so it does reach that branch.

Then the change: `runner_host` makes an `Answer`, a reference and its owner
built by `fabric_ffi:answer_new`. The helper sends on it with `answer_send`,
and `await_or_shutdown` and `answer_receive` receive
`{fabric_answer, Ref, Value}`. No function matches on a `Subject` any more.
The Erlang file gains three small functions for this; the receive itself is
as before.

The core suite passed with the change: 880 tests, no crash report.

Not covered: the exit signal in the test is the message a process that traps
exits receives, sent by the test. No test shuts a real factory down while one
of its runners starts another.

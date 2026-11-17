# `await_or_shutdown` takes a gleam_erlang subject apart

Status: in-progress
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

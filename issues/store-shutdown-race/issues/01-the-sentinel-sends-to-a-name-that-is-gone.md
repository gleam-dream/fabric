# The sentinel sends to the store's name after the store's process is gone

Status: done
Category: bug

## What

The store's sentinel (`sentinel` in `src/fabric/internal/store.gleam`) wakes
when its supervisor stops it and tells the store's process that the runners
are about to drain. It looks the store's name up, and when the name is
registered it sends `BeginDrain` to the named subject:

```gleam
case process.named(factory), process.named(name) {
  Ok(pid), Ok(store_process) -> {
    let down = process.monitor(store_process)
    let reply = process.new_subject()
    process.send(process.named_subject(name), BeginDrain(pid, reply))
```

The lookup and the send are two steps. When the store's process exits between
them, the name is registered at the lookup and gone at the send.
`process.send` to a named subject asserts that the name is registered, so the
sentinel crashes with "Sending to unregistered name" and never reaches the
code that ends it with its supervisor's exit reason.

A store started by `start` has two processes that react to the starter's exit
on their own. The store's process monitors the starter and stops at once
(`Down(pid, _) if state.starter == Some(pid) -> actor.stop()`). The keeper
traps the starter's exit and shuts the subtree down (`keep`), and the
supervisor stops the sentinel first. Nothing orders the two, so the sentinel
can wake while the store's process is exiting.

The monitor on the store's process does not help: the crash happens at the
send, before the sentinel waits on the monitor.

## Evidence

The crash report, from a run of the core suite at `store.gleam` line 480:

```text
=CRASH REPORT====
  crasher:
    initial call: fabric@internal@store:'-sentinel/2-anonymous-2-'/0
    exception error: #{function => <<"send">>,line => 220,
                       message => <<"Sending to unregistered name">>,
                       module => <<"gleam/erlang/process">>,
                       value => {error,nil}, gleam_error => let_assert}
      in function  gleam@erlang@process:send/2
      in call from fabric@internal@store:'-sentinel/2-anonymous-2-'/3
    messages: [{'DOWN',#Ref<...>,process,<0.1259.0>,noproc}]
    trap_exit: true
```

The `DOWN` message with `noproc` in the sentinel's mailbox shows that the
store's process was already gone when the sentinel monitored it, one line
before the send.

It was seen three times on 16 November 2026 while the handover was built:
twice in the core suite (`gleam test`, 11 saved runs) and once in the jobs
consumer's tests (`consumers/jobs`, 9 saved runs). Every one of those runs
passed. The sentinel's code dates from 24 October 2026 and the handover did
not change it.

## Reproduction

A throwaway probe on commit `cb636b6` reproduces it. Eight processes at once
each run this loop 1,000 times: start an in-memory store from a new process,
then end that process, by `process.kill` on even rounds and by an abnormal
exit on odd ones.

```gleam
let name = process.new_name("race_probe")
let done = process.new_subject()
let pid =
  process.spawn_unlinked(fn() {
    let started = store.start(store.in_memory(name))
    process.send(done, started)
    process.sleep_forever()
  })
let assert Ok(Ok(Nil)) = process.receive(done, 5000)
process.kill(pid)
```

Of the 8,000 stores, 178 ended with the crash report above, and no other
process crashed. An earlier probe that started 3,000 stores one after another
from a process that ended normally showed none. The two probes differ in both
the concurrency and the way the starter ends, and which of the two matters was
not separated.

Two further runs of the core suite on `cb636b6` showed no crash report.

The same file already names the hazard in `stop`: "its name then names no
process, which a send to it does not survive", and guards that send with
`bounded.call`. The sentinel's send has no such guard.

## Consequence

- A crash report in the log of a run that passes. The store still stops.
- The sentinel exits with the assertion's error. Its supervisor is stopping it
  at that moment, so no restart follows.
- Not examined: whether an application whose supervisor owns the store
  (`supervised`) can reach the same window. There the store's process has no
  starter to follow, and the supervisor stops the sentinel before the store's
  process.

## Acceptance

- The sentinel does not crash when the store's process exits between the
  lookup and the send. It ends with the exit reason its supervisor gave it.
- A test with the probe's shape (concurrent loops, a killed starter) fails
  before the fix and passes after it. It asserts that the sentinel does not
  exit with an error.
- The other sends to the store's name in `store.gleam` are checked for the
  same two-step shape, and the result is written here.

## Comments

AI-assisted contribution. Found in gate logs while building the handover
(`issues/tool-outcome-ends-run`). The mechanism above is read from the code
and the crash report. The probe was run in a copy of the repository and is not
committed; it shows that the crash happens, not which step of the window it
hits.

AI-assisted contribution. Fixed. The sentinel no longer sends to the store's
name: `announce_drain` sends `BeginDrain` to the process it looked up and
monitors, in the form a send to the name would deliver
(`fabric_ffi:send_as_named`). A send to a process that has exited is dropped,
so there is no second lookup left to fail; the monitor then ends the wait at
once and the sentinel exits with its supervisor's reason. `call` had the same
two-step shape (`pid(store)`, then a send to the name) and now sends the same
way, so a caller whose store stops in that window gets `Unavailable("the store
stopped")` instead of crashing.

Tests, in `test/fabric/lifecycle_test.gleam`:

- `the_sentinel_survives_a_store_process_gone_since_its_lookup_test` is
  deterministic: it calls `announce_drain` with a process that has exited and
  a name that is not registered. Before the fix it exits with "Sending to
  unregistered name"; after it, `Normal`.
- `a_store_whose_starter_dies_stops_its_sentinel_cleanly_test` has the probe's
  shape and is probabilistic: eight loops start 4,000 stores, kill or crash
  each starter and collect each sentinel's exit reason. It takes about 0.3 s
  alone. Before the fix it failed 20 of 20 runs alone, with 31 to 52 crashed
  sentinels each; after it, 30 of 30 runs passed. The test confirms that each
  sentinel has taken its monitor before it ends the starter. Without that,
  the supervisor's shutdown can reach the sentinel before the test's monitor
  does, and the monitor then reports `noproc`.

The probe above, rerun on the fix: 0 crash reports in 8,000 stores (206
before, on the same machine).

Audit of the other places in `store.gleam` that look up, send to or call the
store's name or the factory's name:

- `await_earlier_factory`: looks both names up and monitors the factory. A
  monitor of a process that has exited reports at once. Safe.
- `pid`: a lookup only. Its callers compare or monitor the pid. Safe.
- `call`: looked up with `pid`, then sent to the name. Same defect; fixed.
  `stop` already guarded its `call` with `bounded.call`; its comment is
  updated.
- `target`: builds the named subject. The sends through it with an unpinned
  store (`draining`, `handoff_failed`, `release_job_observation`, `unwatch`,
  `with_backend_timeout`, `renew_now`, `tick_now`) do not look the name up
  first, so they do not have this two-step shape. They do crash the sender
  when the store is not running at all. `unwatch` is called from the
  application's await in `fabric.gleam` and `fabric/graph.gleam`, which use
  the unpinned store and already handle a store that stops. Not fixed here;
  filed as issue 02.
- `Runners` (the store's process): looks up the factory's name and replies
  with it. The runner host reaches the factory through `start_runner`, which
  rescues a factory that has gone. Safe.
- `report_readiness`: a lookup for a Boolean. Safe.
- `sentinel`: the factory's lookup gives a pid used only as an identity in
  `BeginDrain`. Safe.

Supervised stores, shown by a throwaway probe of 2,000 stores per case under
a static supervisor: when the supervisor stops the subtree in order, the
window was not reached before or after the fix. When the store's subtree
supervisor is killed outright, the store's process and the sentinel get the
exit at once: before the fix 2 sentinels crashed with "Sending to
unregistered name", after it none did.

AI-assisted contribution. The deterministic test is revised. It ran
`announce_drain` in a spawned process and monitored that process afterwards.
The process could end before the monitor was taken, and the monitor then
reported `noproc` where the test expected `Normal`. That happened once in
about 30 runs of the core suite, on a tree that did not change this code;
20,000 repetitions of the test's body alone did not show it. The test now
calls `announce_drain` in its own process, so a crash fails the test itself
and no monitor is involved. With the fix the core suite passed three times
(878 tests, no crash report). On a copy with the send to the name put back,
the test fails with "Sending to unregistered name".

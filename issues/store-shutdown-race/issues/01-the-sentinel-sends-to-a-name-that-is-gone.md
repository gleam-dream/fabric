# The sentinel sends to the store's name after the store's process is gone

Status: needs-triage
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

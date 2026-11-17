# The store's process is sent to in gleam_erlang's named-subject form

Status: done
Category: enhancement

## What

`send_as_named` in `src/fabric_ffi.erl` sends `{Name, Message}` straight to a
pid. The store's sentinel (`announce_drain`) and `call` use it after they
looked the store's process up and monitored it, so that a process that has
exited drops the message (`issues/store-shutdown-race`, issue 01).

`{Name, Message}` is the form gleam_erlang 1.3.0 uses to deliver a send to a
named subject (`process.send`, the `NamedSubject` branch). The store's process
receives it through `process.select` on its named subject. That form is not
documented, and `Subject` is an opaque type. If a later gleam_erlang 1.x
delivers named sends differently, these two sends stop arriving and nothing
fails to compile.

## Options considered

- Keep the send to the name and rescue its panic. No layout is assumed, but
  the send looks the name up a second time, so the message can reach a
  process that took the name after the sender's lookup.
- `process.unsafely_create_subject(pid, name)`. It is marked `@internal`, and
  it works only through the same layout.
- A message format that Fabric defines, received with the public
  `process.select_record`. Chosen: the message still goes only to the process
  that was looked up.

## Acceptance

- The sentinel and `call` send to the looked-up process in a format defined in
  `store.gleam`, and `send_as_named` is gone from `src/fabric_ffi.erl`.
- The two tests of the shutdown race in `test/fabric/lifecycle_test.gleam`
  pass, and the core suite logs no crash report.
- A test asserts what the change assumes about `process.select_record`: that
  the mapping receives the whole tuple.

## Comments

AI-assisted contribution. Filed from an exploration of the FFI on commit
`f8583c7`. Each option above was built in a copy of the repository and passed
the core suite three times (878 tests, no crash report).

AI-assisted contribution. Done. `send_direct` in `store.gleam` sends the tuple
`#(direct_tag(), message)` to the looked-up process with `erlang:send`, and
the store's process selects it with `process.select_record`. The sentinel and
`call` use it; `send_as_named` is removed. `announce_drain` no longer takes
the store's name, which it needed only for the old form.

What remains assumed, and where it is held:

- `select_record` hands its mapping the whole tuple. Asserted by
  `select_record_hands_its_mapping_the_whole_tuple_test` in
  `test/fabric/dependency_contract_test.gleam`.
- The store's process reads the second element as a `Message` without a
  check. Only `send_direct` sends that tag, and its type admits only a
  `Message`. A named subject trusts its senders in the same way.

The core suite passed with the change: 880 tests (the 878 before, the
contract test and the test of issue 02), no crash report.

# Eight foreign functions need no Erlang

Status: done
Category: enhancement

## What

Eight functions in `src/fabric_ffi.erl` do work that public functions of
packages Fabric already depends on can do:

| Function                                                                                | Public replacement                                                                                |
| --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `family_budget_id`, `graph_child_id`, `agent_child_id`, `graph_branch_id`, `sha256_hex` | `crypto.hash` (gleam_crypto), `bit_array.base16_encode` (gleam_stdlib)                            |
| `random_id`                                                                             | `crypto.strong_random_bytes`                                                                      |
| `system_time_ms`                                                                        | `timestamp.system_time` (gleam_time), which reads `erlang:system_time` as the Erlang version does |
| `shut_down`                                                                             | `process.monitor`, `process.send_abnormal_exit`, `process.select_specific_monitor`                |

Six modules each declare their own external for `random_id`.

The four id functions name stored records: a family's budget, a graph's child
run, a delegated agent run and a branch of a parallel activation. A changed
byte in one of them would orphan records written before the change.

## Acceptance

- The eight functions are Gleam, and their exports are gone from
  `src/fabric_ffi.erl`.
- A test fixes the four ids and `sha256_hex` to expected values computed by
  the Erlang versions before they were removed.

## Comments

AI-assisted contribution. Filed from the same exploration as issue 01. A
parity test in a copy of the repository compared Gleam versions with the
Erlang ones on 5 strings (empty, non-ASCII and NUL among them) and 6 integers
(0 and a negative among them): the hashes were identical.

AI-assisted contribution. Done.

- `src/fabric/internal/ids.gleam` holds `random`, `sha256_hex`,
  `family_budget`, `graph_child`, `agent_child` and `graph_branch`. The six
  modules that each declared an external for `random_id` call `ids.random`.
- `clock.now` reads `timestamp.system_time`; the store and the leased memory
  backend call it where they called `system_time_ms`.
- `shut_down` in `store.gleam` is a monitor, `process.send_abnormal_exit`
  with reason `shutdown`, and a wait for the monitor.
- `src/fabric_ffi.erl` exports 18 functions, down from 24 before this
  feature. `random_id` stays there unexported: `publish` names its temporary
  file with it.

`test/fabric/ids_test.gleam` fixes the four ids and `sha256_hex` to values
printed by the Erlang functions before they were removed, for inputs that
include an empty string, a negative number, a NUL and non-ASCII text.

The core suite passed three times with the change: 886 tests, no crash
report.

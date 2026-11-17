# Eight foreign functions need no Erlang

Status: in-progress
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
